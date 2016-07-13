require 'asm/errors'
require 'asm/private_util'
require 'asm/translatable'
require 'json'
require 'rest_client'
require 'hashie'
require 'logger'

module ASM
  class Razor
    include Translatable

    attr_reader :logger

    def initialize(options = {})
      url = options.delete(:url) || ASM.config.url.razor || "http://localhost:8080"
      @logger = options[:logger] || Logger.new(nil)
      options = options[:options] || ASM.config.rest_client_options || {}
      @transport = RestClient::Resource.new(url, options)
    end

    def get(type, *name_and_args)
      begin
        path = ["api", "collections", type, *name_and_args].join('/')
        response = @transport[path].get
        if response.code.between?(200, 299)
          result = JSON.parse(response)
          result.include?('items') ? result['items'] : result
        else
          raise(ASM::CommandException, "Bad http code: #{response.code}:\n#{response.to_str}")
        end
      rescue RestClient::ResourceNotFound => e
        raise(ASM::CommandException, "Rest call to #{path} failed: #{e}")
      end
    end

    # Post a command to razor.
    #
    # @raise [StandardError] If the HTTP response code is not 202
    # @return [Object] The RestClient response
    def post_command(url, args)
      response = @transport["api/commands/#{url}"].post(args.to_json, {:content_type => :json, :accept => :json})
      unless response.code == 202
        raise(StandardError, "Razor post failed with HTTP code #{response.code}: #{response.to_str}")
      end
      response
    end

    def find_node(serial_num)
      matches = get('nodes').collect { |node| get('nodes', node['name']) }.find_all do |details|
        details.extend Hashie::Extensions::DeepFetch
        details.deep_fetch('hw_info', 'serial') { |k| nil } == serial_num.downcase
      end

      if matches.size <= 1
        matches.first
      else
        dups = matches.collect {|n| n['name']}.join(', ')
        raise("Multiple razor node matches found for serial number #{serial_num}: #{dups}")
      end
    end

    def find_host_ip(serial_num)
      node = find_node(serial_num)
      if node
        node.extend Hashie::Extensions::DeepFetch
        node.deep_fetch('facts', 'ipaddress') { |k| nil }
      end
    end

    def find_node_blocking(serial_num, timeout)
      max_sleep = 30
      ASM::Util.block_and_retry_until_ready(timeout, ASM::CommandException, max_sleep) do
        find_node(serial_num) or
            raise(ASM::CommandException,
                  'Did not find our node by its serial number. Will try again')
      end
    end

    STATUS_ORDER = [nil, :microkernel, :bind, :reboot, :boot_install, :boot_local, :boot_local_2,]

    class InvalidStatusException < Error; end

    def cmp_status(status_1, status_2)
      index_1 = STATUS_ORDER.find_index(status_1) or raise(InvalidStatusException, "Invalid status: #{status_1}")
      index_2 = STATUS_ORDER.find_index(status_2) or raise(InvalidStatusException, "Invalid status: #{status_2}")
      index_1 <=> index_2
    end

    # Returns result_1 if its status is later in STATUS_ORDER than result_2;
    # otherwise returns result_1
    def newer_result(result_1, result_2)
      if cmp_status(result_1[:status], result_2[:status]) > 0
        result_1
      else
        result_2
      end
    end

    # Given a node name, returns the status of the install of the O/S
    # corresponding to policy_name, or nil if none is found.
    #
    # Possible statuses (in order of occurrence) are:
    #   :microkernel - node has booted the razor microkernel
    #   :bind - razor policy has been attached to the node
    #   :reboot - node has rebooted to begin running O/S installer
    #   :boot_install - node has booted into the O/S installer
    #   :boot_local - install has completed and node has booted into O/S
    #   :boot_local_2 - node has booted into O/S a second time. (In the case
    #                   of ESXi the install is not complete until this event)
    #
    # Works by going through the razor node logs and looking at events between
    # the bind and reinstall events for the given policy_name. If the
    # policy_name is reused for more than one install this will cause p
    def task_status(node_name, policy_name)
      logs = get('nodes', node_name, 'log')
      result = {:status=> nil, :timestamp => Time.now}
      n_boot_local = 0
      logs.each do |log|
        # Check for policy-related events
        timestamp = Time.parse(log['timestamp'])
        case log['event']
          when 'bind'
            if policy_name.casecmp(log['policy']) == 0
              result = {:status=> :bind, :timestamp => timestamp}
            else
              result = {:status=> nil, :timestamp => timestamp}
            end
            n_boot_local = 0
          when 'reinstall'
            result = {:status=> nil, :timestamp => timestamp}
          when 'boot'
            if !result[:status].nil?
              case log['template']
                when 'boot_install'
                  result = newer_result(result, {:status=> :boot_install, :timestamp => timestamp})
                when 'boot_wim' # for windows
                  result = newer_result(result, {:status=> :boot_install, :timestamp => timestamp})
                when 'boot_local'
                  if n_boot_local == 0
                    result = newer_result(result, {:status=> :boot_local, :timestamp => timestamp})
                  else
                    result = newer_result(result, {:status=> :boot_local_2, :timestamp => timestamp})
                  end
                  n_boot_local += 1
                else
                  logger.warn("Unknown boot template #{log['template']}") if logger && log['template'] != 'boot'
              end
            elsif log['task'] == 'microkernel'
              # NOTE: The bind event has not occurred yet, so we don't really know
              # if this event will result in progress towards installing the specified
              # policy. Nevertheless this is useful status information, i.e.
              # that razor is progressing.
              result = {:status=> :microkernel, :timestamp => timestamp}
            end
          else
            if !result[:status].nil? && log['action'] == 'reboot' && policy_name.casecmp(log['policy']) == 0
              result = newer_result(result, {:status=> :reboot, :timestamp => timestamp})
            end
        end
      end
      result
    end

    def get_latest_log_event(node_name, event, params={})
      logs = get('nodes', node_name, 'log')
      events = logs.find_all do |log|
        if log['event'] == event
          match = true
          unless params.empty?
            params.each do |k, v|
              unless log[k] == v
                match = false
                break
              end
            end
          end
          match
        end
      end
      events.last
    end

    def os_name(task_name)
      case
        when task_name.start_with?('vmware')
          'VMWare ESXi'
        when task_name.start_with?('windows')
          'Windows'
        when task_name.start_with?('redhat')
          'Red Hat Linux'
        when task_name.start_with?('ubuntu')
          'Ubuntu Linux'
        when task_name.start_with?('debian')
          'Debian Linux'
        else
          task_name
      end
    end

    def block_until_task_complete(serial_number, ip_address, policy_name, task_name, terminal_status=nil, db=nil)
      raise(ArgumentError, 'Both task_name and terminal_status are nil') unless task_name || terminal_status
      # The vmware ESXi installer has to reboot twice before being complete
      terminal_status ||= if task_name.start_with?('vmware') || task_name.start_with?('windows') || task_name.start_with?('suse')
                            :boot_local_2
                          else
                            :boot_local
                          end
      ip_address ||= ''
      logger.debug("Waiting for server #{serial_number} to PXE boot") if logger
      db.log(:info, t(:ASM027, "Waiting for server %{serial} %{ip} to PXE boot", :serial => serial_number, :ip => ip_address)) if db
      begin
        node = find_node_blocking(serial_number, 600)
      rescue Timeout::Error => e
        raise(ASM::UserException, t(:ASM015, "Server %{serial} %{ip} failed to PXE boot", :serial => serial_number, :ip => ip_address))
      end
      # task_name may be nil in some cases. Could look it up from razor based
      # on policy but it is only being used for debug logging below.
      os_info = task_name ? os_name(task_name) : policy_name

      # Max time to wait at each stage
      max_times = {nil => 300,
                   :microkernel => 600,
                   :bind => 300,
                   :reboot => 300,
                   # for esxi / linux most of the install happens in :boot_install
                   :boot_install => 2700,
                   # for windows most of the install happens in :boot_local
                   :boot_local => 2700,
                   :boot_local_2 => 600}
      status = nil
      result = nil
      while cmp_status(status, terminal_status) < 0
        timeout = max_times[status] or raise("Invalid status #{status}")
        begin
          result = new_status = ASM::Util.block_and_retry_until_ready(timeout, ASM::CommandException, 60) do
            temp_status = task_status(node['name'], policy_name)
            logger.debug("Current install status for server #{serial_number} and policy #{policy_name} is #{temp_status[:status]}") if logger
            if temp_status[:status] == status
              raise(ASM::CommandException, "Task status remains #{status}")
            else
              temp_status
            end
          end
          result = new_status
          if new_status[:status] == status
            raise(UserException, t(:ASM016, "Server %{serial} %{ip} O/S install has failed to make progress, aborting.", :serial => serial_number, :ip => ip_address))
          else
            status = new_status[:status]
          end

          logger.debug("Server #{serial_number} O/S status has progressed to #{status}") if logger
          db.log(:info, t(:ASM028, "Server %{serial} %{ip} O/S status is now: %{status}", :serial => serial_number, :ip => ip_address, :status => status)) if db
          msg = case status
                  when :bind
                    "Server #{serial_number} has been configured to boot the #{os_info} installer"
                  when :boot_install
                    "Server #{serial_number} has rebooted into the #{os_info} installer"
                  when status == terminal_status
                    "Server #{serial_number} has completed installation of #{os_info}"
                  else
                    logger.debug("Server #{serial_number} task installer status is #{status}") if logger
                    nil
                end
          logger.info(msg) if msg && logger
        rescue Timeout::Error
          raise(UserException, t(:ASM018, "Server %{serial} %{ip} O/S install timed out", :serial => serial_number, :ip => ip_address))
        end
      end
      result
    end

    # Delete the named policy.
    #
    # @return [void]
    def delete_policy(name)
      post_command("delete-policy", { "name" => name })
      logger.info("Deleted razor policy %s" % name)
    end

    # Delete the named tag.
    #
    # @return [void]
    def delete_tag(name)
      post_command("delete-tag", { "name" => name })
      logger.info("Deleted razor tag %s" % name)
    end

    # Reinstall the named node. On next boot the node will boot the razor
    # microkernel unless it is matched by another policy.
    #
    # @return [void]
    def reinstall_node(name)
      post_command("reinstall-node", { "name" => name })
      logger.info("Reinstalled razor node %s" % name)
    end

    # Delete any policy and tags associated with the specified node. The
    # reinstall-node command is issued as well if the node was previously
    # attached to a policy.
    #
    # @example The node argument can be retrieved via get or find_node
    #    node = razor.find_node("serial-number")
    #    razor.delete_node_policy(node)
    #
    # @example or can be manually specified as a hash with a name key
    #    razor.delete_node_policy({"name" => "node1"})
    #
    # @return [void]
    def delete_node_policy(node)
      node = get('nodes', node["name"])
      if node['policy']
        delete_policy(node['policy']['name'])
        reinstall_node(node["name"])
      end
      (node['tags'] || []).each do |tag|
        delete_tag(tag['name'])
      end
    end

    # Disassociate the node with the specified `serial_num` from any policy and
    # tags other than the specified `desired_policy`.
    #
    # @return [void]
    def delete_stale_policy!(serial_num, desired_policy)
      node = find_node(serial_num)
      if node && node["policy"] && desired_policy.casecmp(node["policy"]["name"]) != 0
        # Delete any pre-existing policy so that desired_policy can be added
        delete_node_policy(node)
        logger.info("Deleted stale policy and tags from server %s" % serial_num)
      end
    end

    # Whether the argument is a valid mac address
    #
    # @return [Boolean]
    def valid_mac_address?(mac_address)
      !!(mac_address.downcase =~ /^([a-f0-9]{2}:){5}[a-f0-9]{2}$/)
    end

    # Register a razor node
    #
    # If the node already exists, its installed value will be updated to match
    # the specified value. Installed servers are not eligible for policy matching,
    # so razor will not install an OS on them.
    #
    # @param params [Hash]
    # @option params [Array] :mac_addresses server mac addresses (required)
    # @option params [String] :serial server serial number (optional)
    # @option params [String] :asset server asset tag (optional)
    # @option params [String] :uuid server uuid (optional)
    # @option params [Boolean] :installed whether the server should be treated as already installed.
    # @return [Hash] the razor response
    #
    # @example response
    #   {"spec"=>"http://api.puppetlabs.com/razor/v1/collections/nodes/member",
    #    "id"=>"http://asm-razor-api:8080/api/collections/nodes/node10",
    #    "name"=>"node10",
    #    "command"=>"http://asm-razor-api:8080/api/collections/commands/77"}
    def register_node(params)
      params = {:mac_addresses => [], :installed => false}.merge(params)
      invalid = params.keys.reject { |k| [:mac_addresses, :serial, :asset, :uuid, :installed].include?(k) }
      raise("Unrecognized option(s) passed to register_node: %s" % invalid.join(", ")) unless invalid.empty?
      raise("Invalid mac_addresses parameter: %s" % params[:mac_addresses]) unless params[:mac_addresses].is_a?(Array)
      invalid_macs = params[:mac_addresses].find_all {|mac| !valid_mac_address?(mac) }
      raise("Invalid mac addresses: %s" % invalid_macs.join(", ")) unless invalid_macs.empty?

      payload = {:hw_info => {}}
      params[:mac_addresses].each_with_index do |mac, index|
        payload[:hw_info][("net%d" % index).to_sym] = mac.downcase
      end
      [:serial, :asset, :uuid].each do |k|
        payload[:hw_info][k] = params[k].downcase if params[k]
      end
      payload[:installed] = params[:installed]
      JSON.parse(post_command("register-node", payload))
    end

    # Build razor hw_id from mac addresses
    #
    # The hw_id removes colons and joins the mac addresses with an underscore.
    #
    # @param mac_addresses [Array] server mac addresses
    # @return [String] the hw_id
    def build_hw_id(mac_addresses)
      mac_addresses.map { |mac| mac.downcase.gsub(":", "") }.join("_")
    end

    # Get the node id from its name
    #
    # The node id is part of the name and is important to a node's functioning but
    # strangely isn't returned as it's own field.
    #
    # @param node_name [String] the node name
    # @return [FixNum] the node id
    def node_id(node_name)
      raise("Invalid node name: %s" % node_name) unless node_name =~ /([0-9]+)$/
      Integer($1)
    end

    # Build hash of mac address facts
    #
    # Builds a hash of facts that can be added to razor inventory containing
    # the specified mac addresses
    #
    # @api private
    # @param mac_addresses [Array] mac addresses
    # @return [Hash]
    def build_mac_address_facts(mac_addresses)
      mac_addresses.each_with_index.inject({}) do |acc, ary|
        mac, i = ary
        acc[("macaddress_net%d" % i).to_sym] = mac.downcase
        acc
      end
    end

    # Issue a check-in for the specified node
    #
    # Calls the razor checkin URL for the specified node. This is the same REST
    # service that the microkernel calls to report its facts. Razor will respond
    # with an action that the microkernel should take, such as "reboot" or "none".
    #
    # The node facts will be replaced with those specified. If the check-in causes
    # the node to match a razor policy the response action will be "reboot" and
    # when the server performs an iPXE boot off of razor it will boot into the
    # OS installer.
    #
    # @param node_name [String] the node name
    # @param mac_addresses [Array] server mac addresses
    # @param facts [Hash] node inventory data as key/value pairs
    # @return [Hash] the razor response
    #
    # @example response
    #     {"action" => "reboot"}
    def checkin_node(node_name, mac_addresses, facts)
      raise("Invalid mac_addresses parameter: %s" % mac_addresses) unless mac_addresses.is_a?(Array)
      raise("Invalid facts parameter: %s" % facts) unless facts.is_a?(Hash)

      resource = @transport["svc/checkin/%d" % node_id(node_name)]

      # If mac addresses aren't included in the facts razor will remove them from the hw_info
      facts = build_mac_address_facts(mac_addresses).merge(facts)

      # If is_virtual is not set or is true razor will issue a sanboot command that fails on bare metal
      facts = {:is_virtual => "false"}.merge(facts)

      payload = {:hw_id => build_hw_id(mac_addresses), :facts => facts}
      response = resource.post(payload.to_json, :content_type => :json, :accept => :json)
      unless response.code == 200
        raise(StandardError, "Razor node %s checkin failed with HTTP code %d: %s" %
            [node_name, response.code, response.to_str])
      end
      JSON.parse(response)
    end
  end
end

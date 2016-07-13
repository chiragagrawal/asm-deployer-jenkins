require "asm/util"

module ASM
  class Provider
    class Virtualmachine
      class Scvmm < Provider::Base
        puppet_type "asm::vm::scvmm"

        VALID_START_ACTIONS = ["always_auto_turn_on_vm", "never_auto_turn_on_vm", "turn_on_vm_if_running_when_vs_stopped"].freeze
        VALID_STOP_ACTIONS  = ["save_vm", "shutdown_guest_os", "turn_off_vm"].freeze

        property :template,                   :default => nil,                       :validation => String
        property :path,                       :default => nil,                       :validation => String
        property :cpu_count,                  :default => nil,                       :validation => /^\d+$/
        property :memory_mb,                  :default => nil,                       :validation => /^\d+$/
        property :scvmm_server,               :default => nil,                       :validation => String
        property :ensure,                     :default => "present",                 :validation => ["present", "absent"]
        property :description,                :default => nil,                       :validation => String
        property :block_dynamic_optimization, :default => false,                     :validation => :boolean
        property :vm_host,                    :default => nil,                       :validation => String
        property :vm_cluster,                 :default => nil,                       :validation => String
        property :domain,                     :default => nil,                       :validation => String
        property :domain_username,            :default => nil,                       :validation => String
        property :domain_password,            :default => nil,                       :validation => String
        property :product_key,                :default => nil,                       :validation => String
        property :scvmm_options,              :default => {},                        :validation => Hash
        property :highly_available,           :default => true,                      :validation => :boolean
        property :network_interfaces,         :default => nil,                       :validation => Array
        property :decrypt,                    :default => true,                      :validation => :boolean
        property :start_action,               :default => "always_auto_turn_on_vm",  :validation => VALID_START_ACTIONS
        property :stop_action,                :default => "turn_off_vm",             :validation => VALID_STOP_ACTIONS

        property :name,                       :default => nil,                       :validation => String, :tag => :extra
        property :hostname,                   :default => nil,                       :validation => String, :tag => :extra

        def configure_hook
          configure_uuid!
          configure_certname!
          configure_network!
        end

        def cluster_supported?(cluster)
          cluster.provider_path == "cluster/scvmm"
        end

        def configure_certname!
          type.puppet_certname = "vm-%s" % hostname.downcase
        end

        def configure_uuid!
          self.uuid = hostname if hostname
        end

        def lazy_configure_related_cluster
          return if @__cluster_configured

          configure_related_cluster!

          @__cluster_configured = true
        end

        def scvmm_server_prefetch_hook
          lazy_configure_related_cluster
        end

        def vm_cluster_prefetch_hook
          lazy_configure_related_cluster
        end

        def configure_related_cluster!
          cluster = type.related_cluster
          self[:scvmm_server] = cluster.puppet_certname
          self[:vm_cluster] = cluster.provider.name
        end

        # Configures the network interfaces for the resources
        #
        # This should implement all the work from ASM::Resource::VM::Scvmm#process! but as teardown
        # sets network_interfaces to nil anyway we can luckily skip that for now
        #
        # @api private
        # @return [void]
        def configure_network!
          if self[:ensure] == "absent" || type.teardown?
            self[:network_interfaces] = nil
          else
            logger.warn("Cannot configure networking for Virtual Machine %s as it only supports teardown" % type.puppet_certname)
          end
        end

        def prepare_for_teardown!
          delete_vm_cert!

          true
        end

        def hostname
          self[:name] || self[:hostname] || uuid
        end

        # Returns the agent certname
        #
        # @return [String]
        def agent_certname
          "vm%s" % macaddress.delete(":").downcase
        end

        # Deletes the certificate for this VM
        #
        # SCVMM virtual machines run puppet to install services ontop of them
        # and the certname is dynamically generated based on their mac address
        #
        # This calculates the certname and attempts to delete it, errors are
        # squashed and logged
        #
        # @return [void]
        def delete_vm_cert!
          logger.info("Removing certificate %s" % agent_certname)

          ASM::DeviceManagement.clean_cert(agent_certname) unless debug?
        rescue
          logger.warn("Could not delete certificate for %s: %s: %s" % [type.puppet_certname, $!.class, $!.to_s])
        end

        # Look up and cache the VM macaddress on the SCVMM cluster
        #
        # This is done using the scvmm_macaddress.rb helper command and
        # can only fetch a valid mac if the VM is on
        #
        # @param tries [Fixnum] how many times to try the lookup
        # @param sleep_time [Fixnum] how long to sleep between tries
        # @return [String] the macaddress
        # @raise [StandardError] when the vm is off or lookup failed
        def macaddress(tries=2, sleep_time=60)
          return @macaddress if @macaddress
          return "06:00:00:00:00:01" if debug?

          found_mac = nil

          tries.times do |try|
            break if found_mac = scvmm_macaddress_lookup
            sleep sleep_time unless try == tries - 1
          end

          if !found_mac
            raise("Could not lookup the mac address for vm %s, it might not exist" % type.puppet_certname)
          elsif found_mac == "00000000000000"
            raise("Virtual machine %s is not powered on cannot look up it's mac address" % type.puppet_certname)
          end

          @macaddress = found_mac
        end

        # Extracts the mac address from the SCVM cluster
        #
        # @api private
        # @return [String, nil] mac address might be 00000000000000 when the vm is off
        def scvmm_macaddress_lookup
          data = {}

          begin
            cmd, args = scvmm_macaddress_command
            result = ASM::Util.run_with_clean_env(cmd, true, *args)
            data = scvmm_macaddress_parse(result.stdout)
          rescue
            logger.warn("Running scvmm_macaddress.rb for %s failed: %s" % [type.puppet_certname, $!.to_s])
          end

          data["MACAddress"]
        end

        # Parse the output of the scvm_macaddress.rb script
        #
        # When invalid data is sent a empty hash is produced
        #
        # @api private
        # @return [Hash]
        def scvmm_macaddress_parse(output)
          return {} unless output.is_a?(String)

          lines = output.each_line.select do |line|
            line.match(/\s+:\s+/)
          end

          Hash[lines.map do |line|
            line.chomp!
            line.split(/\s+:\s/)
          end]
        end

        # Create the command and arguments for the scvm_macaddress.rb script
        #
        # @api private
        # @return [Array<String, Array>] array of command arguments
        # @raise [StandardError] when device config for a related cluster cannot be found
        def scvmm_macaddress_command
          unless cluster = type.related_cluster.device_config
            raise("Could not find device data for the related cluster")
          end

          domain, user = cluster.user.split('\\')

          cmd = File.expand_path(File.join(File.dirname(__FILE__), "..", "..", "scvmm_macaddress.rb"))
          args = ["-u", user, "-d", domain, "-p", cluster.password, "-s", cluster.host, "-v", hostname]

          [cmd, args]
        end
      end
    end
  end
end

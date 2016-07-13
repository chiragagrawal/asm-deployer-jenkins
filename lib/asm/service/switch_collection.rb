require "asm/translatable"
require "asm/errors"

module ASM
  class UnconnectedServerException < Error
    attr_reader :unconnected_servers
    def initialize(servers)
      super
      @unconnected_servers = servers
    end
  end

  class Service
    class SwitchCollection
      include Enumerable
      include ASM::Translatable

      attr_reader :inventories, :inventory
      attr_accessor :logger, :service

      def initialize(logger=ASM.logger)
        @logger = logger
        reset!
      end

      # Returns the switch in the collection with the specified certificate name
      # if found, nil otherwise.
      #
      # @param puppet_certname [String] Puppet certificate name
      # @return [ASM::Type::Switch, nil]
      def switch_by_certname(puppet_certname)
        find do |switch|
          switch.puppet_certname == puppet_certname
        end
      end

      # Returns the switch and port connected to the specified mac address
      #
      # @param mac [String] mac address
      # @return [Array<ASM::Type::Switch, String>]
      def switch_port_for_mac(mac)
        map do |switch|
          port = switch.find_mac(mac)
          port && [switch, port]
        end.compact.first
      end

      # Finds the first switch to report having a certain mac address
      #
      # @param mac [String] a mac address
      # @param options [Hash] same options as {ASM::Type::Switch#find_mac}
      # @return [ASM::Type::Switch, nil]
      # @raise [StandardError] if inventory or facts updates fail
      def switch_for_mac(mac, options={})
        # in cases where an interface is not completely configured like some FCoE
        # ones there will be no wwpn on the interface and a nil mac might be requested
        # this should probably be handled in the callers but to avoid having to always
        # remember to check and handle it it's safest to return nil here
        return nil unless mac

        find do |switch|
          switch.has_mac?(mac, options)
        end
      end

      # Retrieves the ASM managed inventory
      #
      # @note this is a cached method, to reset it use {#reset!}
      # @see ASM::PrivateUtil.fetch_managed_inventory
      # @raise [StandardError] when fetching inventories fails
      def managed_inventory
        @inventory ||= ASM::PrivateUtil.fetch_managed_inventory
      end

      # Resets the internal caches of switches
      #
      # This will discard the managed inventory, switch inventories
      # and all type instances.
      #
      # @return [void]
      def reset!
        @switches = []
        @inventories = []
        @inventory = nil
      end

      # Retrieves a list of managed switches
      #
      # @note this is a cached method, to reset it use {#reset!}
      # @return [Array<ASM::Type::Switch>]
      def switches
        populate! unless @switches.is_a?(Array) && !@switches.empty?

        @switches
      end

      # Iterate over known switches
      #
      # This enables the Enumerable module so methods like find, select,
      # map, etc all work over this collection
      #
      # @yield [ASM::Type::Switch] all switches
      def each
        switches.each do |switch|
          yield(switch)
        end
      end

      # @private
      def debug?
        @debug ||= begin
          service ? service.debug? : ASM.config.debug_service_deployments
        end
      end

      # Executes a block asynchronously, unless {#debug?} is true.
      #
      # @private
      def execute_async(&block)
        thread = ASM.execute_async(logger, &block)
        thread.join if debug?
        thread
      end

      # Performs inventory for a selection of switches
      #
      # @example update inventories for all blade switches
      #
      #    collection.update_inventory do |switch|
      #       switch.blade_switch?
      #     end
      #
      # Inventories are updated in parallel and it will wait for all to complete
      #
      # @yield [ASM::Type::Switch] each switch
      # @return [void]
      def update_inventory
        selected_switches = select do |switch|
          yield(switch)
        end

        threads = selected_switches.map do |switch|
          execute_async do
            switch.update_inventory
            # TODO: is retrieve_facts! thread-safe?
            switch.retrieve_facts!
          end
        end

        threads.each(&:join)
      end

      # Returns servers from the passed list that do not have network topology
      # data.
      #
      # @param servers [Array<ASM::Type::Server>] servers to check
      # @return [Array<ASM::Type::Server>]
      # @private
      def missing_topology(servers)
        servers.select(&:missing_network_topology?)
      end

      # Returns a string describing the server ports missing switch connectivity information.
      #
      # Intended for use in switch configuration-related log messages.
      #
      # @example returned data
      #   "NIC.Integrated.1-1-1 (54:9F:35:0C:59:C0), NIC.Integrated.1-2-1 (54:9F:35:0C:59:C1)"
      #
      # @api private
      # @param server [ASM::Type::Server]
      # @return [String]
      def missing_ports(server)
        server.missing_network_topology.map do |partition|
          "%s (%s)" % [partition.fqdd, partition.mac_address]
        end.join(", ")
      end

      # Updates switch inventory until network topology data has been found
      # for all servers in the passed list.
      #
      # Returns true if all network topology data has been discovered, false otherwise.
      #
      # @param servers [Array<ASM::Type::Server>] servers to check
      # @param options [Hash] The inventory options
      # @option options [Fixnum] :sleep_secs the number of seconds to sleep between inventory runs
      # @option options [Fixnum] :max_tries the maximum number of inventory runs
      # @return [Boolean]
      def await_inventory(servers, options={})
        options = {:sleep_secs => 60, :max_tries => 10}.merge(options)
        tries = 0

        missing = servers
        until missing.empty? || tries >= options[:max_tries]
          tries += 1
          sleep(options[:sleep_secs])
          update_inventory {true}
          missing = missing_topology(servers)
          missing.each do |server|
            logger.debug("Waiting for connectivity info for %s NICs %s try %d/%d" %
                             [server.puppet_certname, missing_ports(server), tries, options[:max_tries]])
          end
        end

        missing.empty?
      end

      # Find managed switch inventories from all managed devices
      #
      # @note this is a cached method, to reset it use {#reset!}
      # @return [Array<Hash>] managed switch inventories
      def switch_inventories
        unless @inventories.is_a?(Array) && !@inventories.empty?
          @inventories = managed_inventory.select do |device|
            ["dellswitch", "genericswitch"].include?(device["deviceType"])
          end
        end

        @inventories
      end

      # Create switch types from the entire inventory
      #
      # If deployment has been set using {#deployment=} then the switch
      # types will all have it set
      #
      # @return [Array<ASM::Type::Switch>]
      def populate!
        @switches = []

        switch_inventories.each do |switch|
          types = Type::Switch.create_from_inventory(service, switch, logger)
          types.each do |switch_type|
            switch_type.deployment = service.deployment if service
          end

          @switches.concat(types)
        end

        @switches
      end

      # Call {ASM::Type::Server#enable_switch_inventory!} on servers in parallel.
      #
      # @api private
      # @param servers [Array<ASM::Type::Server>]
      # @return [Void]
      def enable_switch_inventory!(servers)
        threads = servers.map do |server|
          server.db_log(:info, t(:ASM064, "Checking switch connectivity for server %{server}",
                                 :server => server.puppet_certname), :server_log => true)
          next if server.deployment_completed?
          execute_async do
            server.enable_switch_inventory!
          end
        end

        threads.each {|t| t.join if t}

        nil
      end

      # Re-run inventory on switches in parallel until server connectivity found or timeout
      #
      # @api private
      # @param servers[Array<ASM::Type::Server>]
      # @param options (see #await_inventory)
      # @return [Void]
      def poll_for_switch_inventory!(servers, options={})
        logger.info("Polling switch inventory for server connectivity")
        found_all = await_inventory(servers, options)

        # NOTE: missing_topology? servers do not have the LLDP microkernel ISO
        # disconnected and are not shut down. That is to make it easier to debug
        # connectivity failures. Future retries or deployments should automatically
        # disconnect the old ISO because that is part of the wsman.boot_rfs_iso_image
        # workflow
        threads = servers.reject(&:missing_network_topology?).map do |server|
          execute_async do
            logger.info("Disabling switch inventory for %s" % server.puppet_certname)
            server.disable_switch_inventory!
          end
        end

        threads.each(&:join)

        unless found_all
          unconnected_servers = servers.select(&:missing_network_topology?)
          unconnected_servers.each do |server|
            msg = t(:ASM0059, "Unable to find switch connectivity for server %{serial} %{ip} on NICs: %{nics}",
                    :serial => server.serial_number,
                    :ip => (server.device_config || {})[:host],
                    :nics => missing_ports(server))
            logger.error(msg)
            service.database.log(:error, msg)
          end
        end
      end

      # Configure server-facing ports on switches in parallel
      #
      # @api private
      # @return [Void]
      # @raise [ASM::UserException] when switch configuration fails
      def configure_server_switches!(update_inventory=false)
        invalid_switches = []

        configurable_switches = switches.reject {|s| s.related_servers.empty?}

        configurable_switches.each do |switch|
          next unless switch.valid_inventory?

          if switch.managed?
            logger.info("Configuring server VLANs on %s" % switch.puppet_certname)
            switch.configure_server_networking!(true)
          else
            logger.info("Skipping switch configuration on unmanaged switch %s, validating configuration only" % switch.puppet_certname)
            valid = switch.validate_server_networking!(update_inventory)
            invalid_switches << switch.puppet_certname unless valid
          end
        end

        unless invalid_switches.empty?
          raise(ASM::UserException, t(:ASM066, "Invalid switch configurations found on unmanaged switches: %{invalid_switches}",
                                      :invalid_switches => invalid_switches.join(", ")))
        end

        threads = configurable_switches.map do |switch|
          execute_async do
            logger.info("Applying server VLANs on %s" % switch.puppet_certname)
            Thread.current[:puppet_certname] = switch.puppet_certname
            switch.process!
            Thread.current[:success] = true
          end
        end

        threads.each(&:join)
        failed = threads.select { |t| !t[:success] }

        unless failed.empty?
          raise(ASM::UserException, t(:ASM060, "Switch configuration failed for %{switch_certs}",
                                      :switch_certs => failed.map { |t| t[:puppet_certname] }.join(", ")))
        end
        nil
      end

      # Given a list of servers powers on those that are FC
      def power_on_fc_servers(servers)
        Array(servers).select(&:valid_fc_target?).each(&:power_on!)
      end

      # Configures server networking.
      #
      # @param (see #await_inventory)
      # @return [Void]
      # @raise [StandardError] when service is not set
      # @raise [ASM::UnconnectedServerException] when switch connectivity cannot be determined for any servers
      # @raise [ASM::UserException] when switch configuration fails
      def configure_server_networking!(options={})
        raise("Cannot configure networking without a service") unless service

        servers = service.servers.reject(&:brownfield?)
        return if servers.empty?

        if options[:server]
          logger.debug("Only searching switch connectivity for server %s" % options[:server])
          servers = servers.find_all {|server| server.uuid == options[:server]}
        end

        logger.info("Beginning server network configuration for %s" % servers.map(&:puppet_certname).join(", "))

        missing_servers = missing_topology(servers)
        enable_switch_inventory!(missing_servers)

        # above enable_switch_inventory turns on machines based on missing
        # ethernet portview data and does not support FC, this powers on
        # machines that are FC since deployment cant work for turned off FC
        # machines.  Once portview knows about FC this should be able to go away
        power_on_fc_servers(servers)
        update_inventory(&:san_switch?)

        if missing_servers.empty?
          update_inventory = true
        else
          poll_for_switch_inventory!(missing_servers, options)
          update_inventory = false
        end

        unconnected_servers = missing_topology(servers).reject(&:deployment_completed?)
        unconnected_certs = unconnected_servers.map(&:puppet_certname)

        logger.debug("Failed to determine switch connectivity for %s" % unconnected_certs.join(", "))

        if servers.size > unconnected_servers.size
          configure_server_switches!(update_inventory)
          write_portview_cache(servers - unconnected_servers)
        end

        unless unconnected_certs.empty?
          raise(ASM::UnconnectedServerException.new(unconnected_certs),
                t(:ASM061, "Failed to determine switch connectivity for %{server_certs}",
                  :server_certs => unconnected_certs.join(", ")))
        end

        nil
      end

      def write_portview_cache(servers)
        return if debug?

        servers.each do |server|
          filename = "/opt/Dell/ASM/cache/%s_portview.json" % server.puppet_certname.downcase
          logger.debug("Writing cache for server network overview for %s at %s" % [server.puppet_certname, filename])
          ASM::PortView.write_cache(server)
        end
      end
    end
  end
end

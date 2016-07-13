require "asm/type"

module ASM
  class Type
    class Switch < Base
      # Creates switch types from managed inventories
      #
      # Given a switch from the managed inventory like those returned by
      # {ASM::PrivateUtil.fetch_managed_inventory} this will create
      # {ASM::Type::Switch} instances as if they are components
      #
      # @see ASM::Service::SwitchCollection#populate!
      # @param [ASM::Service] service
      # @param [Hash] switch switch inventory data
      # @param [Logger] logger
      # @return [Array<Type::Switch>]
      def self.create_from_inventory(service, switch, logger)
        providers = select_providers do |provider|
          provider[:class].handles_switch?(switch)
        end

        providers.map do |provider|
          # TODO: its not a component, need some inventory wrapper that behaves like it
          component = Service::Component.new("id" => switch["refId"],
                                             "puppetCertName" => switch["refId"],
                                             "type" => "SWITCH",
                                             "relatedComponents" => {},
                                             "resources" => [])
          component.service = service
          instance = Type::Switch.new(component, provider, switch, logger)

          if RUBY_PLATFORM == "java"
            require "jruby/synchronized"
            instance.extend(JRuby::Synchronized)
          end

          instance
        end
      end

      # Retrieves FC Zone information from a SAN switch
      #
      # @param wwpn [String] limit returned zones to those a wwpn belong to.  When nil all zones are returned.
      # @return [Array<String>] list of zone names
      def fc_zones(wwpn=nil)
        provider.fc_zones(wwpn)
      end

      # Retrieves Nameserver data from the san switch facts
      #
      #
      # @return [Array<Hash>] list of Nameserver_data that can be used to find storage alias
      def nameserver_info
        facts.fetch("Nameserver", {})
      end

      # Retrieves the active zone on a FC switch
      #
      # In some cases like with Nexus FCoE switches there are many
      # active zone sets limited to a specific VSAN.  In those cases the
      # wwpn is needed to figure out what VSAN the WWPN is in so that
      # the active zone set for that VSAN can be found
      #
      # @param wwpn [String] the wwpn to find the active zone for
      # @return [String,nil] zone name
      def active_fc_zone(wwpn=nil)
        provider.active_fc_zone(wwpn)
      end

      # Find all related servers that are not missing connectivity to any of their related switches
      #
      # @return [Array<ASM::Type::Server>]
      def connected_servers
        related_servers.reject(&:missing_network_topology?)
      end

      # Configures networking on all connected servers.
      #
      # If staged is true, the caller must call {#process!} in order to apply the
      # calculated switch configuration.
      #
      # @param staged [Boolean] (false) whether to apply the configuration immediately.
      # @return [void]
      def configure_server_networking!(staged=false)
        connected_servers.each do |server|
          server.configure_networking!(staged, :switch => self)
        end
      end

      # Validates the network configuration for all the related servers.
      #
      # For each server, it will check the current switch configuration to make sure
      # the ports and VLANS are configured correctly for the deployment.
      #
      # All servers are checked to ensure the user visible logging that gets produced
      # are shown for all problems in the entire deploy.
      #
      # @param update_inventory [Boolean] causes the switch inventory to be udpated before validation
      # @return [Boolean] true if all server configurations are valid
      def validate_server_networking!(update_inventory=false)
        update_inventory! if update_inventory

        connected_servers.map do |server|
          validate_network_config(server)
        end.all?
      end

      # Finds the port on this switch that a certain mac address exist in
      #
      # Updating the inventory will also update the facts so it's generally not needed to supply both
      # but it wont stop you from doing both if you have a need, in that case inventory gets updated
      # first and then the facts will be refreshed
      #
      # If the optional :server argument is passed in and the mac address is not found
      # in current switch inventory, it will be searched for in the {ASM::Type::Server#network_topology}
      # cache of network connectivity information.
      #
      # @param [Hash] options
      # @option options [Boolean] :update_facts force fetch a new set of facts before looking for a mac
      # @option options [Boolean] :update_inventory force an inventory update before looking for a mac
      # @option options [ASM::Type::Server] :server fall back to finding mac in server network_topology cache
      # @return [String, nil] the interface the mac is plugged into
      # @raise [StandardError] if inventory or fact updating fails
      def find_mac(mac, options={})
        options = {
          :update_facts => false,
          :update_inventory => false
        }.merge(options)

        update_inventory! if options[:update_inventory]

        retrieve_facts! if options[:update_inventory] || options[:update_facts]

        ret = provider.find_mac(mac)

        if ret.nil? && options[:server]
          cache = options[:server].network_topology_cache
          switch_cert, port = cache[mac.downcase]
          ret = port if puppet_certname == switch_cert
        end

        ret
      end

      # Determines if a mac address is plugged into this switch
      #
      # Arguments match exactly those of {#find_mac}
      #
      # @see #find_mac
      # @return [Boolean]
      def has_mac?(*args)
        !!find_mac(*args)
      end

      # Configures networking for a given server
      #
      # If staged is true, the configuration will be immediately applied. Otherwise
      # the caller must call process! to apply the configuration. That allows
      # multiple the configuration for multiple servers to be applied in one batch.
      #
      # @param server [ASM::Type::Server] server to configure
      # @param staged [Boolean] whether to apply the configuration immediately
      # @raise [StandardError] when switch configuration fails
      def configure_server(server, staged=false)
        delegate(provider, :configure_server, server, staged)
      end

      # Determine if a network VLAN should be configured on the switch port.
      #
      # - FIP_SNOOPING is never configured (works on the native VLAN)
      #
      # - PXE is always configured for ESXi. This is so that the PXE network can
      #   be used for OS installation of VMs running on the ESXi host.
      #
      # - PXE is not configured after the OS is installed for OS's other than ESXi.
      #   In these cases PXE is only used for ths OS installation itself, so it
      #   is desirable to remove it once done.
      #
      # @param network [Hashie::Mash] member of partition.networkObjects
      # @param server [ASM::Type::Server]
      # @return [Boolean]
      def configured_network?(network, server)
        case network.type
        when "FIP_SNOOPING"
          false
        when "PXE"
          server.os_image_type == "vmware_esxi" || !server.os_installed?
        else
          true
        end
      end

      # Determines if a network VLAN should be tagged or untagged
      #
      # @note was ServiceDeployment#get_vlan_info
      # @param network [Hashie::Mash] member of partition.networkObjects
      # @param server [ASM::Type::Server]
      # @return [Boolean]
      def tagged_network?(network, server)
        raise("Network %s VLAN %s should not be configured" % [network.name, network.vlanId]) unless configured_network?(network, server)
        if server.boot_from_iscsi? && network.type == "STORAGE_ISCSI_SAN"
          false
        elsif server.is_hypervisor?
          supported_post_os_tagged_network?(network, server)
        else
          bare_metal_tagged_network?(network, server)
        end
      end

      # Whether the server is an FCoE ESXi server that has completed the O/S install
      #
      # @api private
      # @return [Boolean]
      def fcoe_and_esxi_installed_on?(server)
        server.fcoe? && server.os_image_type == "vmware_esxi" && server.os_installed?
      end

      # Determine if a network VLAN should be tagged for VMware and HyperV Server deployment
      #
      # * PXE VLAN will be untagged unless the server is an ESXi FCoE server with
      #   the OS already installed.
      # * All other VLANs will be tagged.
      #
      # @param network [Hashie::Mash] member of partition.networkObjects
      # @param server [ASM::Type::Server]
      # @return [Boolean]
      def supported_post_os_tagged_network?(network, server)
        if network.type == "PXE" && !fcoe_and_esxi_installed_on?(server)
          false
        elsif hyperv_with_dedicated_intel_iscsi?(network, server)
          false
        else
          true
        end
      end

      # Determines if a server is a HyperV iSCSI install with a dedicated Intel iSCSI card
      #
      # By convention if a machine have 2 cards the first is for general
      # traffic and the 2nd for iSCSI.  If the 2nd is a Intel card we
      # cannot tag that as the OS doesn't support it
      #
      # If there's just one card it carries both iSCSI and LAN traffic and
      # so must be tagged.
      #
      # @param network [Hashie::Mash] member of partition.networkObjects
      # @param server [ASM::Type::Server]
      # @return [Boolean]
      def hyperv_with_dedicated_intel_iscsi?(network, server)
        return false unless network.type == "STORAGE_ISCSI_SAN"
        return false unless server.is_hyperv?

        iscsi_card = server.network_cards[1]

        iscsi_card && iscsi_card.nic_info.product =~ /Intel/
      end

      # Determine if a network VLAN should be tagged for Bare-Metal Server deployment
      #
      # * PXE VLAN will be untagged before the OS is installed
      # * PXE VLAN will be tagged after the OS is installed
      # * Workload VLAN will be tagged it there are more than one workload VLANs mapped to the server
      # * Workload VLAN will be tagged if same VLAN is marked as tagged on any other port
      #
      # @param network [Hashie::Mash] member of partition.networkObjects
      # @param server [ASM::Type::Server]
      # @return [Boolean]
      def bare_metal_tagged_network?(network, server)
        if network.type == "PXE"
          server.os_installed?
        elsif server.workload_network_vlans.size > 1
          true
        elsif workload_network_count(network, server) > 1
          true
        elsif workload_with_pxe?(network, server)
          true
        else
          false
        end
      end

      # Determine if workload and PXE network are on same partition
      #
      # If MAC Address of PXE partition is same as this network, then network needs to be tagged
      #
      # @param network [ASM::NetworkConfiguration]
      # @param server [ASM::Type::Server]
      # @return [Boolean] True when PXE and input network is on same partition
      def workload_with_pxe?(network, server)
        network_partitions = server.network_config.get_partitions(network.type)
        return true if network_partitions.count > 1

        pxe_partition = server.network_config.get_partitions("PXE")
        return false if pxe_partition.empty?

        pxe_mac = pxe_partition[0].mac_address
        network_partitions[0]["mac_address"] == pxe_mac
      end

      # Determine count of workload networks associated with a server
      #
      # @param network [ASM::NetworkConfiguration]
      # @param server [ASM::Type::Server]
      # @return [Fixnum] Count of workload networks associated with the server
      def workload_network_count(network, server)
        workload_count = 1
        server.nic_teams .each do |teams|
          teams[:networks].each do |net|
            if net.vlanId == network.vlanId
              workload_count = teams[:mac_addresses].count
              break
            end
          end
        end
        workload_count
      end

      # Retrieves the last stored running configuration
      #
      # @return [String] of the full switch config
      def running_config
        provider.facts["running_config"]
      end

      # Calculates the desired ip address from the certname
      #
      # @return [String,nil]
      def cert2ip
        puppet_certname.scan(/dell_iom-(\S+)/).flatten.first
      end

      # Determines the preferred IP address for the appliance to communicate with the switch
      #
      # @see {ASM::Util.get_preferred_ip}
      # @return [String,nil] ip address of the preferred route to the management ip
      def appliance_preferred_ip
        ASM::Util.get_preferred_ip(provider.facts["management_ip"])
      end

      # Determines if the last stored running config sets a ManagementEthernet address via dhcp
      #
      # @return [Boolean]
      def management_ip_dhcp_configured?
        !!running_config.match(%r{interface ManagementEthernet \d+/\d+.*?\s+ip address\s+dhcp})
      end

      # Determines if the last stored running config sets a ManagementEthernet address statically
      #
      # @return [Boolean]
      def management_ip_static_configured?
        !!running_config.match(%r{interface ManagementEthernet \d+/\d+.*?\s+ip address\s+\d+.\d+.\d+.\d+\/\d+})
      end

      # Determines if a ManagementEthernet section is configured regardless of DHCP or Static
      #
      # @return [Boolean]
      def management_ip_configured?
        !!running_config.match(/interface ManagementEthernet.*?!/m)
      end

      # Fetch the configured ManagementEthernet IP and CIDR from the last seen running config
      #
      # @return [Array<String, String>,nil] ip and cidr
      def configured_management_ip_information
        if management_ip_static_configured?
          match_data = running_config.match(%r{interface ManagementEthernet \d+/\d+.*?\s+ip address\s+(\d+.\d+.\d+.\d+)\/(\d+)})
          [match_data[1], match_data[2]]
        end
      end

      # Retrieves the hostname from the last stored running config
      #
      # @return [String,nil] hostname
      def configured_hostname
        running_config.scan(/hostname\s*(\S+)/).flatten.first
      end

      # Retrieves the boot configuration lines from the last stored running config
      #
      # @return [String]
      def configured_boot
        running_config.scan(/(boot.*?)$/m).flatten.join("\n")
      end

      # Retrieves the configured username strings from the last stored running config
      #
      # @return [Array<String>]
      def configured_credentials
        running_config.scan(/(username.*?)$/m).flatten.map(&:strip!)
      end

      # Determines if a hostname is configured in the last stored running config
      #
      # @see {#configured_hostname}
      # @return [Boolean]
      def hostname_configured?
        !!configured_hostname
      end

      # Loosely determine if the unmanaged switch is configured correctly for an
      # server
      #
      # @param server [ASM::Type::Server] server to configure
      # @return [Boolean]
      def validate_network_config(server)
        provider.validate_network_config(server)
      end

      # previously ServiceDeployment#process_switch
      def connection_url
        provider.connection_url
      end

      # Initialize all ports in the switch to defaults
      #
      # This effectively does what a teardown flow would do, it's
      # intended to be use during switch on-boarding to remove ports
      # from existing VLANs etc
      #
      # This does not run puppet but it's destructive in that the resource
      # creators for force10 switches will put them in a strange state wrt
      # their usual helpers to produce interface resources.  And in the case
      # of IOA's will produce a bunch of force10_interface resources which
      # would be surprising.
      #
      # As such this method is only really useful in the configuration flow
      # as per {Provider::Configuration::Force10#configure_networking!}
      #
      # @return [void]
      # @raise [StandardError] for switches that do not support initialization
      def initialize_ports!
        delegate(provider, :initialize_ports!)
      end

      # Retrieves the iom_mode value of the switch
      #
      # @return [String] when nothing is set, returns a empty string
      def iom_mode
        provider.facts["iom_mode"] || ""
      end

      # Determins if the switch is configured in VLT mode
      #
      # @return [Boolean]
      def vlt_mode?
        !!iom_mode.match(/vlt/i)
      end

      # Retrieve the hardware model
      #
      # @return [String]
      def model
        provider.model
      end

      # Retrieves the port channel members
      #
      # The format of this is as would be created by the device inventory
      # scripts, it should in theory be normalised but might not be
      #
      # @note ported from {ASM::PrivateUtil#get_mxl_portchannel}
      # @return [Hash]
      def portchannel_members
        provider.facts["port_channel_members"]
      end

      # Retrieves the VLAN information for the switch
      #
      # The format of this is as would be created by the device inventory
      # scripts, it should in theory be normalised but might not be
      #
      # @note ported from {ASM::PrivateUtil#get_mxl_vlan}
      # @return [Hash]
      def vlan_information
        provider.facts["vlan_information"]
      end

      # previously ServiceDeployment#populate_blade_switch_hash
      # could probably do without and use provider_name or something
      def device_type
        provider.device_type
      end

      def blade_switch?
        provider.blade_switch?
      end

      def fcflexiom_switch?
        provider.fcflexiom_switch?
      end

      def npiv_switch?
        provider.npiv_switch?
      end

      def npv_switch?
        provider.npv_switch?
      end

      def san_switch?
        provider.san_switch?
      end

      def rack_switch?
        provider.rack_switch?
      end
    end
  end
end

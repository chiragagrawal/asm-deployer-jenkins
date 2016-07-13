require "asm/type"
require "asm/network_configuration"

module ASM
  class Type
    class Server < Base
      def startup_hook
        # used to synchronize access to the node data file
        @__node_data_file_mutex = Mutex.new
      end

      # Retrieves the asm::esxiscsiconfig resource for the server
      #
      # Just the parameters will be returned, {} when the server does not
      # have asm::esxiscsiconfig
      #
      # @return [Hash]
      def network_params
        if config = service_component.resource_by_id("asm::esxiscsiconfig")
          config.parameters
        else
          {}
        end
      end

      # Constructs a NetworkConfiguration object based on asm::esxiscsiconfig
      #
      # @return [ASM::NetworkConfiguration]
      # @raise [ASM::UserException] when network configuration is invalid
      def network_config
        @network_config ||= begin
          raw_config = network_params["network_configuration"] || {"interfaces" => []}
          config = NetworkConfiguration.new(raw_config)
          config.add_nics!(device_config, :add_partitions => true) if dell_server?
          config
        end
      end

      def retrieve_inventory!
        return {} unless dell_server?
        @inventory = PrivateUtil.fetch_server_inventory(puppet_certname)
      end

      def management_network
        network = (network_params["hypervisor_network"] || network_config.get_networks("HYPERVISOR_MANAGEMENT")).first
        logger.warn("Management network has not been set for %s" % puppet_certname) if network.nil?
        network
      end

      # Returns workload VLANS associated with the server
      #
      # @return [Array] of workload networks
      def workload_networks
        network_config.get_networks("PUBLIC_LAN", "PRIVATE_LAN") || []
      end

      # Returns VLAN IDs of all workload VLANS (PUBLIC and PRIVATE)
      #
      # @return [Array] of workload VLANS
      def workload_network_vlans
        workload_networks.map {|x| x["vlanId"]}.flatten
      end

      # Retrieve information of the NICs that can be teamed together based on network selected
      #
      # @return [HASH] all interfaces on {ASM::NetworkConfiguration#teams}
      def nic_teams
        network_config.teams
      end

      def network_cards
        network_config.cards
      end

      def static_network_config
        management_network["staticNetworkConfiguration"]
      end

      def primary_dnsserver
        static_network_config["primaryDns"]
      end

      def secondary_dnsserver
        static_network_config["secondaryDns"]
      end

      def fcoe_san_networks
        network_config.get_networks("STORAGE_FCOE_SAN")
      end

      def fcoe_san_partitions
        network_config.get_partitions("STORAGE_FCOE_SAN")
      end

      def pxe_partitions
        network_config.get_partitions("PXE")
      end

      def pxe_network
        network_config.get_network("PXE")
      end

      # Determines if a server is eligible for static booting
      #
      # @return [Boolean]
      def static_boot_eligible?
        provider.static_boot_eligible?
      end

      # Determines if the PXE network is configured for static booting
      #
      # @return [Boolean]
      def static_pxe?
        pxe_network.static
      end

      # Retrieves a NetworkConfiguration::NicInfo object for a server
      #
      # @return [Array<NetworkConfiguration::NicInfo>]
      # @raise [StandardError] when an error occurs retrieving the NIC information
      def nic_info
        provider.nic_info
      end

      # Settings needed for the asm::bios type
      #
      # @return [Hash] as per the asm::bios resource
      def bios_settings
        provider.bios_settings
      end

      # The server model
      #
      # @return [String]
      def model
        provider.model
      end

      # Retrieve server interfaces from the network configuration
      #
      # @return [Array] all interfaces on {ASM::NetworkConfiguration#cards}
      def network_interfaces
        network_config.cards.map(&:interfaces).flatten
      end

      # Extract the serverType from the inventory
      #
      # @return ["RACK", "BLADE", "TOWER", "SLED", "COMPELLENT", nil]
      def physical_type
        provider.physical_type
      end

      # Determines if a server is a blade server
      #
      # @return [Boolean]
      def bladeserver?
        physical_type == "BLADE"
      end

      alias_method :blade_server?, :bladeserver?

      # Determines if a server ia rackserver
      #
      # @return [Boolean]
      def rackserver?
        physical_type == "RACK"
      end

      alias_method :rack_server?, :rackserver?

      # Determines if a server is a towerserver
      #
      # @return [Boolean]
      def towerserver?
        physical_type == "TOWER"
      end
      alias_method :tower_server?, :towerserver?

      # Retrieves the FCoE WWPNs for the server
      #
      # @note ported from ServiceDeployment#get_specific_dell_server_fcoe_wwpns
      # @return [Array<String>] list of WWPNs obtained from WsMan
      def fcoe_wwpns
        fqdds = fcoe_san_partitions.map do |network|
          network["fqdd"]
        end

        return [] if Array(fqdds).empty?

        fcoe_wwpns = ASM::WsMan.get_fcoe_wwpn(device_config, logger)

        return [] if Array(fcoe_wwpns).empty?

        fcoe_wwpns.map do |interface, dets|
          fqdds.include?(interface) ? dets["wwpn"] : nil
        end.compact.uniq
      end

      # Retrieves a list of FC interfaces
      #
      # @note the return format should be the same as what ASM::WsMan#fc_views would return
      # @return [Array<Hash>]
      def fc_interfaces
        provider.fc_interfaces
      end

      # Retrieves the Fibre Channel WWPNs for the server
      #
      # @return [Array<String>] list of WWPNs obtained from WsMan
      def fc_wwpns
        provider.fc_wwpns
      end

      # Determines if a server is a Fibre Channel over Ethernet server
      #
      # @return [Boolean]
      def fcoe?
        !fcoe_san_networks.empty?
      end

      alias_method :fcoe_enabled?, :fcoe?

      # Determines if a server is FC enabled
      #
      # This is determined by looking at the related storage volumes and checking if any of them
      # needs FC to be enabled - typically by looking at their porttypes.
      #
      # Additionally we check there are WWPNs on the server
      #
      # @return [Boolean]
      def fc?
        related_volumes.map(&:fc?).include?(true) && !fc_wwpns.empty?
      end

      alias_method :fc_enabled?, :fc?

      # Determines if a server is a valid target for FC deployment
      #
      # @note ported from ServiceDeployment#is_hyperv_deployment_with_compellent? and process_san_switches
      # @return [Boolean]
      def valid_fc_target?
        dell_server? &&
          !brownfield? &&
          has_related_storage? &&
          related_storage_volumes.map(&:fc?).all?
      end

      # The hosts IP Address on the management network
      #
      # @todo rename for clarity
      def hostip
        static_network_config["ipAddress"]
      end

      alias_method :static_ipaddress, :hostip

      # @see ASM::ServiceDeployment#lookup_hostname
      def lookup_hostname
        @__lookup_hostname ||= deployment.lookup_hostname(hostname, static_network_config).downcase
      end

      def hostname
        provider.hostname
      end

      def agent_certname
        provider.agent_certname
      end

      def admin_password
        provider.admin_password
      end

      def os_image_type
        provider.os_image_type
      end

      def os_image_version
        provider.os_image_version
      end

      def os_only?
        provider.os_only?
      end

      # Determines if this is a windows machine
      #
      # @return [Boolean]
      def windows?
        has_os? && !!os_image_type.match(/windows/i)
      end

      # Determines if this is a linux machine
      #
      # @note this seems ok for now but we need to have a master list of support OS names somewhere
      # @return [Boolean]
      def linux?
        has_os? && !!os_image_type.match(/suse|redhat|ubuntu|debian|centos|fedora/i)
      end

      # Determines if a specific OS supports our post install mechanism
      #
      # @note ported from incorrectly named var @supported_os_postinstall in ServiceDeployment
      # @return [Boolean]
      def can_post_install?
        return false unless has_os?

        !["vmware_esxi", "hyperv", "suse11", "suse12"].include?(os_image_type.downcase)
      end

      # Procude a Processor::WinPostOS instance
      #
      # @return [Processor::WinPostOS]
      def windows_post_processor
        Processor::WinPostOS.new(deployment, component_configuration)
      end

      # Procude a Processor::LinuxPostOS instance
      #
      # @return [Processor::LinuxPostOS]
      def linux_post_processor
        Processor::LinuxPostOS.new(deployment, component_configuration)
      end

      # Retrieves the post install processor for the server
      #
      # At present this uses the {Processor::PostOS} based system, but this is not
      # a good long term solution since the post install support will need to be
      # pluggable in line with providers.
      #
      # Further the post install system has no understanding of types and providers.
      # Thus we pass the ServiceDeployment and old school {component_configuration}
      # into them as a backwards compatability measure
      #
      # @todo VM post install is not supported at present by new code
      # @return [Processor::PostOS, nil]
      def post_install_processor
        return nil unless can_post_install?

        return windows_post_processor if windows?
        return linux_post_processor if linux?

        logger.debug("Could not determine the Post Install system for %s as it's neither Linux nor Windows" % [puppet_certname])
        nil
      end

      # Retrieves the post install config from the post install processor
      #
      # @todo VM post install is not supported at present by new code
      # @note ported from ServiceDeployment#get_post_installation_config
      # @return [Hash] containing puppet node data
      def post_install_config
        return {} unless post = post_install_processor

        result = {}

        # It's unbelievable that objects are designed around respond_to? but
        # that's how it is used in ServiceDeployment and how the processors
        # are designed so just have to go with it, these will have to be rewritten
        if post.respond_to?(:post_os_config)
          result = post.post_os_config
        else
          result["classes"] = post.post_os_classes if post.respond_to?(:post_os_classes)
          result["resources"] = post.post_os_resources if post.respond_to?(:post_os_resources)
        end

        # This appears to be a badly implemented deep merge but it's copied
        # from current code, moving to actual deep merge at this stage will
        # almost certainly introduce a behaviour change
        post.post_os_services.each do |k, v|
          result[k] ||= {}
          result[k].merge!(v)
        end

        result
      end

      # Calculate and write the node data file for the Puppet node classifier
      #
      # @note ported from {ServiceDeployment#write_post_install_config}
      # @return [void]
      # @raise [StandardError] on failure to write the node data
      def write_post_install_config!
        config = post_install_config

        return false if config.empty?

        write_node_data(agent_certname => config)
      end

      # The path to the node data for our node terminus
      #
      # @todo this is using the {PrivateUtil::NODE_DATA_DIR} constant, we need a better place for those
      # @return [String]
      def node_data_file
        File.join(PrivateUtil::NODE_DATA_DIR, "%s.yaml" % agent_certname)
      end

      # Returns the node data parsed from YAML
      #
      # @return [Hash, nil]
      # @raise [StandardError] on invalid yaml data
      def node_data
        n_file = node_data_file

        @__node_data_file_mutex.synchronize do
          return nil unless File.readable?(n_file)

          YAML.load_file(n_file)
        end
      end

      # Determine the file mtime for the node data
      #
      # @return [Time]
      # @raise [StandardError] when there are no node data or it's unreadable
      def node_data_time
        n_file = node_data_file

        @__node_data_file_mutex.synchronize do
          raise("Node data for %s not found in %s" % [puppet_certname, n_file]) unless File.readable?(n_file)

          File.mtime(n_file)
        end
      end

      # Stores the note data for our classifier
      #
      # Writing to the file is skipped when the data being written matches
      # what is already in the file in order to maintain the original timestamps
      # on the file
      #
      # @note ported from {PrivateUtil.write_node_data}
      # @return [void]
      # @raise [StandardError] on any errors like I/O issues etc
      def write_node_data(config)
        n_file = node_data_file

        @__node_data_file_mutex.synchronize do
          if File.readable?(n_file) && YAML.load_file(n_file) == config
            logger.info("Requested to update node data for %s but it is identical to that in %s" % [puppet_certname, n_file])
            return
          end

          logger.info("Updated node data for %s in %s" % [puppet_certname, n_file])
          File.write(n_file, config.to_yaml)
        end
      end

      def serial_number
        provider.serial_number
      end

      def serial_number=(serial)
        provider.serial_number = serial
      end

      # Determines if a server is configured to boot from SAN
      #
      # @return [Boolean]
      def boot_from_san?
        delegate(provider, :boot_from_san?)
      end

      # Determines if a server is being deployed with an OS
      #
      # @return [Boolean]
      def has_os?
        delegate(provider, :has_os?)
      end

      # Determines if a server has esxi installed on it
      #
      # @return [Boolean]
      def esxi_installed?
        os_image_type == "vmware_esxi" && os_installed?
      end

      def os_installed?
        if os_image_type.nil?
          false
        elsif is_hypervisor_os?(os_image_type) || os_image_type.start_with?("windows") || os_image_type.start_with?("suse")
          razor_status[:status] == :boot_local_2
        else
          [:boot_local, :boot_local_2].include?(razor_status[:status])
        end
      end

      # Determines if an OS is supported for post install
      #
      # @param os [String] the Operating System like 'hyperv'
      # @return [Boolean]
      def is_hypervisor_os?(os)
        return false if os.nil?

        ["vmware_esxi", "hyperv"].include?(os.downcase)
      end

      # Determines if the machine being deployed is part of a HyperV cluster
      #
      # @return [Boolean]
      def is_hyperv?
        return false if os_image_type.nil?

        "hyperv" == os_image_type.downcase
      end

      # Retrieves from the related volumes of compellent or vnx
      #
      # @note ported from ServiceDeployment#compellent_in_service_template
      # @return [Array<Type::Volume>]
      def related_storage_volumes
        related_volumes.find_all do |volume|
          volume.provider_name == "compellent" || volume.provider_name == "vnx"
        end
      end

      # Determines if this deployment has a related Compellent or vnx based storage
      #
      # This would be an indicator that this server must be FC when its compellent or vnx
      # and HyperV (see {#is_hyperv?}
      #
      # @return [Boolean]
      def has_related_storage?
        !related_storage_volumes.empty?
      end

      # Determines if the configured OS is supported for post install
      #
      # @return [Boolean]
      def is_hypervisor?
        is_hypervisor_os?(provider.os_image_type)
      end

      # Determines if a server is configured to boot from iSCSI
      #
      # @return [Boolean]
      def boot_from_iscsi?
        delegate(provider, :boot_from_iscsi?)
      end

      # Determines if the server is a Dell server
      #
      # @return [Boolean]
      def dell_server?
        provider.dell_server?
      end

      # Determines if the server is a bare metal server
      #
      # In ASM terminology a Bare Metal machine is one without any clustering or storage
      # on top, it's just a managed machine with an OS and potentially some related switches
      #
      # @return [Boolean]
      def baremetal?
        if dell_server?
          !related_switches.empty? && related_volumes.empty? && related_clusters.empty?
        else
          related_volumes.empty? && related_clusters.empty?
        end
      end

      # Retrieves a local cache of network topology data, falling back to
      # PuppetDB if none has yet been retrieved.
      #
      # The data is returned as a hash of server network interface mac address
      # to a tuple of [ switch cert, port name ]
      #
      # @example
      #     { "e0:db:55:22:f9:a0" => ["dell_iom-172.17.9.171", "Te 0/2"],
      #       "e0:db:55:22:f9:a2" => ["dell_iom-172.17.9.174", "Te 0/2"] }
      #
      # @return [Hash]
      def network_topology_cache
        @network_topology_cache ||= begin
          saved = JSON.parse(facts.fetch("network_topology", "{}"))
          ret = saved.inject({}) do |acc, row|
            mac, switch_cert, port = row
            switch = switch_collection.switch_by_certname(switch_cert)
            if switch
              acc[mac.downcase] = [switch_cert, port]
            else
              logger.warn("Rejected switch %s from %s topology cache because it is not inventory" %
                              [switch_cert, puppet_certname])
            end
            acc
          end

          ret.values.map(&:first).uniq.each do |switch_cert|
            switch = switch_collection.switch_by_certname(switch_cert)
            add_relation(switch)
            switch.add_relation(self)
          end

          ret
        end
      end

      # Adds network topology data to the local cache.
      #
      # @param mac [String] the network interface mac address
      # @param switch [ASM::Type::Switch] the connected switch
      # @param port [String] the switch port name, e.g. Te 0/2
      # @return [void]
      # @private
      def add_network_topology_cache(mac, switch, port)
        # Set component relations between switch and server
        add_relation(switch)
        switch.add_relation(self)

        network_topology_cache[mac.downcase] = [switch.puppet_certname, port]
      end

      # Injects the network topology cache into the local facts and calls
      # {ASM::Type::Base.save_facts!} to save them to PuppetDB.
      #
      # The PuppetDB fact used is "network_topology" and it is stored as a list
      # of triples of [interface mac, switch cert name, switch port name]
      #
      # @example
      #   [["e0:db:55:22:f9:a0", "dell_iom-172.17.9.171", "Te 0/2"],
      #     "e0:db:55:22:f9:a2", "dell_iom-172.17.9.174", "Te 0/2"]]
      #
      # @return [void]
      # @private
      def save_facts!
        facts["network_topology"] = network_topology_cache.map do |mac, val|
          switch_cert, port = val
          [mac, switch_cert, port]
        end.to_json

        super
      end

      # Returns configured NIC interfaces and the switch and switch port they are connected to.
      #
      # The returned values are looked up from persistent cache, falling back
      # to lookup from switch inventory.
      #
      # The interface is either that returned by {ASM::NetworkConfiguration}.cards.interface
      # or by the {ASM::WsMan#fc_views}.  You can determine which by looking at the :interface_type
      # which would be one of "ethernet" or "fc"
      #
      # @example output
      #
      #     [{:interface => #<Hashie::Mash enabled=false id="02AC9AAD-5015-4D2C-9C5F-52D42A28C755" interface_index=0 name="Port 1" ...",
      #       :interface_type => "ethernet",
      #       :switch => #<ASM::Type::Switch:70222712819080:switch/force10 dell_iom-172.17.9.171>,
      #       :port => "Te 0/4"},
      #      {:interface => #<Hashie::Mash enabled=false id="2BBB30EF-687E-46AA-9027-7EDD50DC5213"" interface_index=1 name="Port 2" ...",}
      #       :switch => #<ASM::Type::Switch:70222712822040:switch/force10 dell_iom-172.17.9.174>",
      #       :port => "Te 0/4"}]
      #
      # @return [Array<Hash>]
      def network_topology
        cache_updated = false

        ret = (network_interfaces + fc_interfaces).map do |interface|
          if interface.include?(:partitions)
            interface_identifier = interface.partitions.first.mac_address
            interface_type = "ethernet"
          else
            interface_identifier = interface[:wwpn]
            interface_type = "fc"
          end

          # Check cache first
          switch_cert, port = network_topology_cache[interface_identifier.downcase]
          switch = switch_cert.nil? ? nil : switch_collection.switch_by_certname(switch_cert)

          unless switch
            switch, port = switch_collection.switch_port_for_mac(interface_identifier)
            if switch
              add_network_topology_cache(interface_identifier, switch, port)
              cache_updated = true
            end
          end

          {:interface => interface,
           :interface_type => interface_type,
           :switch => switch,
           :port => port}
        end

        save_facts! if cache_updated

        ret
      end

      # Override {ASM::Type::Base#related_switches} to ensure network_topology has been calculated.
      #
      # @return [Array<ASM::Type::Switch]
      def related_switches
        network_topology
        super
      end

      # Returns an array containing the unique networks on the interface.
      #
      # @param interface [Hashie::Mash] an interface on {ASM::NetworkConfiguration#cards}
      # @return [Hashie::Mash] member of partition.networkObjects
      # @api private
      def interface_networks(interface)
        interface.partitions.map(&:networkObjects).flatten.compact.uniq
      end

      # Whether the interface should be configured.
      #
      # There is no need to configure interfaces that do not have networks on them.
      #
      # @param interface [Hashie::Mash] an interface on {ASM::NetworkConfiguration#cards}
      # @return [Boolean] whether the interface should be configured.
      def configured_interface?(interface)
        !interface_networks(interface).empty?
      end

      # Retrieve server interfaces that should be configured from the network configuration
      #
      # @return [Array<Hashie::Mash>] configured interfaces on {ASM::NetworkConfiguration#cards}
      def configured_interfaces
        network_interfaces.select { |i| configured_interface?(i) }
      end

      # Returns true if switch connectivity cannot be found for a configured NIC interface
      #
      # @return [Boolean]
      def missing_network_topology?
        !missing_network_topology.empty?
      end

      # Returns the first partition on each port with missing switch connectivity data
      #
      # See {ASM::NetworkConfiguration} for more details on the partition data format.
      #
      # @example returned data
      #   [{"fqdd"=>"NIC.Integrated.1-1-1", "mac_address"=>"54:9F:35:0C:59:C0", ...},
      #    {"fqdd"=>"NIC.Integrated.1-2-1", "mac_address"=>"54:9F:35:0C:59:C1", ...},]
      #
      # @return [Array<Hash>]
      def missing_network_topology
        network_topology.map do |t|
          if t[:interface_type] == "ethernet"
            t[:interface].partitions.first if t[:port].nil? && configured_interface?(t[:interface])
          end
        end.compact
      end

      # Configure networking for the server on any known switches
      #
      # @param staged [Boolean] (false) order the configuration
      # @param options [Hash] optional configuration settings
      # @option options [ASM::Type::Switch] :switch Only perform configuration on given switch
      # @raise [StandardError] when configuration fails or when no supported switches are found
      # @return [void]
      def configure_networking!(staged=false, options={})
        switches = related_switches

        if options[:switch]
          unless switches.include?(options[:switch])
            raise("Switch %s not connected to %s" % [options[:switch].puppet_certname, puppet_certname])
          end
          switches = [options[:switch]]
        end

        if !switches.empty?
          switches.each do |switch|
            db_log(:info, t(:ASM065, "Configuring server %{server_serial} %{server_ip} networking on %{switch_model} %{switch_ip}",
                            :server_serial => cert2serial,
                            :server_ip => management_ip,
                            :switch_model => switch.model,
                            :switch_ip => switch.management_ip))
            switch.configure_server(self, staged)
          end
        else
          logger.warn("Could not find any switches to configure for server %s" % puppet_certname)
        end

        nil
      end

      # Check if the servers has a valid network for the switch
      #
      # This is used to validate if a switch is configured correctly
      # for a given server. It does this by checking the that vlan contains
      # the right port in the right state (tagged, untagged)
      #
      # @param network [ASM::NetworkConfiguration#cards] network hash
      # @param port [String]
      # @param switch [ASM::Type::Switch]
      # @return [Boolean] true if the network is valid
      def valid_network?(network, port, switch)
        tagged = switch.tagged_network?(network, self)
        tagged_msg = tagged ? "tagged" : "untagged"

        db_log(:info, t(:ASM063, "Validating switch %{switch} contains port %{port} with VLAN %{vlan} %{tagged}",
                        :vlan => network.vlanId, :tagged => tagged ? "tagged" : "untagged",
                        :port => port,      :switch => switch.puppet_certname), :server_log => true)

        if interface_in_vlan?(switch, port, network.vlanId.to_s, tagged)
          logger.info("Valid switch configuration detected")
          true
        else
          db_log(:error, t(:ASM062, "Invalid switch configuration detected on %{state} switch %{switch}. Port %{port} needs VLAN %{vlan} to be %{tagged}. "\
                           "Manually correct the switch configuration or set the switch to be managed by ASM and retry the service",
                           :state => switch.retrieve_inventory["state"].downcase, :switch => switch.puppet_certname,
                           :port => port, :vlan => network.vlanId, :tagged => tagged_msg), :server_log => true)
          false
        end
      end

      # Check for inclusion of interface from vlan_information switch fact
      #
      # Switches report interfaces on a vlan as a string with comma-seperated
      # port groups ex: (Po11-12,Po126-127,Te1/0/2-12,Te1/0/29,Te1/1/33)
      # notice interface Te/1/0/3 would be included within Te1/0/2-12.
      # We need to parse this out to check for the existance of an interface
      # on the correct stack (Te*/*)
      #
      # @param switch [ASM::Type::Switch]
      # @param port_interface [String] the interface we are searching for
      # @param tagged [Boolean]
      # @return [Boolean] true if interface exists
      def interface_in_vlan?(switch, port_interface, vlan, tagged)
        return false unless switch.facts["vlan_information"]

        _, wanted_port, wanted_stack = parse_interface(port_interface)

        tagged ? type = "tagged" : type = "untagged"

        return false unless switch.facts["vlan_information"][vlan]

        ["#{type}_tengigabit", "#{type}_fortygigabit"].each do |t|
          next if switch.facts["vlan_information"][vlan][t].empty?

          switch.facts["vlan_information"][vlan][t].split(",").each do |group|
            _, existing_port, existing_stack = parse_interface(group)

            next unless wanted_stack == existing_stack

            if existing_port.include?("-")
              configured_port_range = existing_port.split("-")
              return true if wanted_port.to_i.between?(configured_port_range[0].to_i, configured_port_range[1].to_i)
            elsif wanted_port == existing_port
              return true
            end
          end
        end

        false
      end

      # Parse interface information
      #
      # Takes typical interface notation as input and returns normalized parts
      #
      # @param interface [String]
      # @return [Array<(String,String,String)>] group_set, port_group, stack
      def parse_interface(interface)
        set = interface.scan(/(\d*-*\d*)/).flatten.reject(&:empty?)
        [set, set.pop, set.join("/")]
      end

      # Put the server into a state that allows collection of switch connectivity
      #
      # Typically this involves booting the server into a microkernel image
      # that enables LLDP on the server NICs.
      #
      # @return [void]
      def enable_switch_inventory!
        delegate(provider, :enable_switch_inventory!)
      end

      # Perform any needed clean-up from calling {#enable_switch_inventory!}
      #
      # Typically results in detaching any network ISO that the server was booted
      # off of and powering it off.
      #
      # @return [void]
      def disable_switch_inventory!
        delegate(provider, :disable_switch_inventory!)
      end

      # Creates and caches a instance of the ASM PuppetDB client
      #
      # @return [Client::Puppetdb]
      def puppetdb
        @_puppetdb ||= Client::Puppetdb.new(:logger => logger)
      end

      # Determines if this nodes Puppet Agent have been seen by PuppetDB since a certain time
      #
      # @param timestamp [Time] checks for a PuppetDB event after this time
      # @return [Boolean]
      def puppet_checked_in_since?(timestamp)
        puppetdb.successful_report_after?(puppet_certname, timestamp, :verbose => true)
      rescue CommandException, StandardError, Timeout::Error
        logger.warn("Could not determine if Puppet Checked in since %s on %s: %s: %s" % [timestamp, puppet_certname, $!.class, $!.to_s])
        false
      end

      # Waits for a Puppet run to complete
      #
      # @param timestamp [Time] wait for a succesull puppet run since this time
      # @param timeout [Numeric, Float] give up after this many seconds
      # @param sleep_time [Numeric] time between checks
      # @return [Boolean]
      # @raise [StandardError, Timeout::Error, CommandException]
      def wait_for_puppet_success(timestamp=Time.now, timeout=5400, sleep_time=30)
        Timeout.timeout(timeout) do
          loop do
            return(true) if puppet_checked_in_since?(timestamp)

            sleep(sleep_time)
          end
        end
      end

      # Get the razor policy name for a server
      #
      # @return [String]
      # @raise [StandardError] when deployment has not been set
      def razor_policy_name
        raise("deployment as not been set") unless deployment

        delegate(provider, :policy_name)
      end

      # Blocks until a certain event happens in razor
      #
      # @param task_name [String] Razor task name
      # @param terminal_status [Symbol] Razor terminal status
      # @return [Hash] one of those returned by {Razor#task_status}
      # @raize [StandardError] when an error happens or timeout occurs
      def razor_block_until(task_name, terminal_status)
        razor.block_until_task_complete(cert2serial, management_ip, razor_policy_name, task_name, terminal_status, database)
      end

      # Creates a Razor node and issue a check-in for the node based on its serial number
      #
      # If a razor node for the specified serial_number does not exist one will be
      # registered for it. Subsequently a check-in will be created for the node.
      #
      # If a razor policy already exists for the specified serial_number, after this
      # method is called the server will boot directly into the policy OS installer
      # the next time it PXE boots.
      #
      # @note Ported from {ServiceDeployment#enable_razor_boot}
      # @return [void]
      # @raise [StandardError] when there are no PXE networks or registration fails
      def enable_razor_boot
        pxe_macs = pxe_partitions.map(&:mac_address).compact

        raise("No PXE networks are configured or add_nics! failed for %s, cannot enable Razor booting" % puppet_certname) if pxe_macs.empty?

        unless node = razor.find_node(cert2serial)
          result = razor.register_node(
            :mac_addresses => pxe_macs,
            :serial => cert2serial,
            :installed => false
          )

          unless node = razor.get("nodes", result["name"])
            raise("Failed to register %s to Razor: %s" % [puppet_certname, result.inspect])
          end
        end

        razor.checkin_node(node["name"], pxe_macs, node["facts"] || {:serialnumber => cert2serial})

        nil
      end

      # Find Razorp olicies other than the desired and delete them
      #
      # @see {Razor#delete_stale_policy!}
      # @return [void]
      def delete_stale_policy!
        razor.delete_stale_policy!(cert2serial, razor_policy_name)
      end

      # Resets any Virtual MAC addresses back to permenent MAC addresses
      #
      # @return [void]
      def reset_mac_addresses!
        delegate(provider, :reset_mac_addresses!)
      end

      # Resets the management IP assigned to the OS for this server
      #
      # @return [void]
      def reset_management_ip!
        delegate(provider, :reset_management_ip!)
      end

      # Delete an associated puppet certificate for the host
      #
      # @return [void]
      # @raise [StandardError] when removal fails
      def delete_server_cert!
        delegate(provider, :delete_server_cert!)
      end

      # Delete the network overview cache of the server. Nothing is deleted if cache doesn't exist.
      #
      # @return [void]
      def delete_server_network_overview_cache!
        delegate(provider, :delete_server_network_overview_cache!)
      end

      # Delete the node data for server that contains the post-installation information
      #
      # @return [void]
      # @raise [StandardError] when removal fails
      def delete_server_node_data!
        delegate(provider, :delete_server_node_data!)
      end

      # Delete the server network topology cache
      #
      # @return [void]
      # @raise [StandardError] when removal fails
      def delete_network_topology!
        delegate(provider, :delete_network_topology!)
      end

      # Remove the server from any cluster it might belong to
      #
      # @return [void]
      # @raise [StandardError] when leaving the cluster fails
      def leave_cluster!
        delegate(provider, :leave_cluster!)
      end

      # Remove access rights from all volumes associated with this server
      #
      # @return [void]
      def clean_related_volumes!
        delegate(provider, :clean_related_volumes!)
      end

      # Clean up boot from SAN virtual identies
      #
      # A virtual identity is a virtual MAC and World Wide Port Name (WWPN)
      # which gets assigned to it from a ASM managed pool.  On termination the
      # node needs to be reset to factory values and the MAC and WWPN returned
      # to the pool
      #
      # @return [void]
      def clean_virtual_identities!
        delegate(provider, :clean_virtual_identities!)
      end

      # Get the machine power status
      #
      # @note this method has no debug checking and should not be called in debug mode
      # @return [:off, :on]
      def power_state
        delegate(provider, :power_state)
      end

      # Checks if a machine is on
      #
      # @see {#power_state}
      # @return [Boolean]
      def powered_on?
        power_state == :on
      end

      # Checks if a machine is off
      #
      # @see {#power_state}
      # @return [Boolean]
      def powered_off?
        !powered_on?
      end

      # Powers on the particular machine
      #
      # If the machine is already turned on no action is taken
      #
      # @param [Fixnum] wait how long to sleep after turning the server on
      # @return [void]
      def power_on!(wait=0)
        delegate(provider, :power_on!, wait)
      end

      # Powers off the particular machine
      #
      # @return [void]
      def power_off!
        delegate(provider, :power_off!)
      end

      # Reboots the particular machine
      #
      # @note this is done via {power_off!} and {power_on!}
      # @return [void]
      def reboot!
        power_off!
        power_on!
      end

      # Extracts the HyperV configuration as a hash from a server
      #
      # Extracts a hash of all non nil value properties tagged as :hyperv in the provider.
      #
      # @raise [StandardError] on servers that are not HyperV compatible
      # @return [Hash] of non nil properties and values
      def hyperv_config
        provider.to_hash(true, :hyperv)
      end

      # Extracts Fabric configuration from the server network configuation
      #
      # Based on the information found in the cards # found in {#network_config}
      # for rack servers it produce a Hash of # fabrics
      #
      # For rack servers the fabrics map 1:1 to the card slot index
      #
      # The number indicates a 2 port or 4 port card
      #
      # @example output
      #
      #     {"Fabric A"=>4, "Fabric B"=>2, "Fabric C"=>2}
      #
      # @note left over from earlier attempt at switch work, might not be needed
      # @return [Hash, nil] of Fabric information
      def fabric_info
        fabric_info = {}
        curr_fabric = "A"
        network_config.cards.each do |card|
          fabric = curr_fabric
          curr_fabric = curr_fabric.succ
          fabric_info["Fabric %s" % fabric] = card.nictype.n_ports
        end

        fabric_info
      end

      # Disables PXE booting for this server
      #
      # @return [void]
      def disable_pxe
        delegate(provider, :disable_pxe)
      end

      # Enablese PXE booting for this server
      #
      # @return [void]
      def enable_pxe
        delegate(provider, :enable_pxe)
      end

      # Determine if a machine has been deployed based on the database and Razor
      #
      # @return [Boolean]
      def deployment_completed?
        begin
          return true if db_execution_status == "complete"
        rescue Data::NoExecution # rubocop:disable Lint/HandleExceptions
        end

        return false if boot_from_san? || !has_os?

        os_installed?
      end

      # Creates and caches a instance of {Razor}
      #
      # @return [Razor]
      def razor
        @__razor ||= Razor.new(:logger => logger)
      end

      # Retrieves the razor task status for the server
      #
      # Possible status values can be seen in {Razor#task_status}
      #
      # @return [Hash] the razor status returned from task_status
      def razor_status
        node = razor.find_node(cert2serial)

        status = {}

        unless node["name"].nil?
          status = razor.task_status(node["name"], razor_policy_name)
        end

        status
      rescue
        logger.debug("Razor policy for %s is not applied correctly or retrieval failed: %s: %s" % [puppet_certname, $!.class, $!.to_s])
        {}
      end

      # Get the server info for port view
      #
      # @return [Hash] of non nil properties and values
      def network_overview
        delegate(provider, :network_overview)
      end
    end
  end
end

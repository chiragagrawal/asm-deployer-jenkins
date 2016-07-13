module ASM
  class Provider
    class Switch
      # Common switch behaviours
      #
      # Switches are not real components in our services, all we have about them are what is in the managed
      # inventory.  This is a base class that mimics a components based type using inventory data
      #
      # The normal Provider::Base#configure! assumes a component, this overrides that configure to assume
      # a inventory hash, end result is a switch type that behaves a lot like normal types but it's kind
      # of a false mirage
      #
      # @abstract Subclass and override {#resource_creator!} to implement a custom Switch class.
      class Base < Provider::Base
        attr_reader :connection_url

        attr_writer :resource_creator

        property :refId,                      :default => nil,  :validation => String,      :tag => :inventory
        property :ipAddress,                  :default => nil,  :validation => :ipaddress,  :tag => :inventory
        property :serviceTag,                 :default => nil,  :validation => String,      :tag => :inventory
        property :model,                      :default => nil,  :validation => String,      :tag => :inventory
        property :deviceType,                 :default => nil,  :validation => String,      :tag => :inventory
        property :discoverDeviceType,         :default => nil,  :validation => String,      :tag => :inventory
        property :displayName,                :default => nil,  :validation => String,      :tag => :inventory
        property :state,                      :default => nil,  :validation => String,      :tag => :inventory
        property :manufacturer,               :default => nil,  :validation => String,      :tag => :inventory
        property :health,                     :default => nil,  :validation => String,      :tag => :inventory
        property :operatingSystem,            :default => nil,  :validation => String,      :tag => :inventory
        property :numberOfCPUs,               :default => nil,  :validation => Fixnum,      :tag => :inventory
        property :nics,                       :default => nil,  :validation => Fixnum,      :tag => :inventory
        property :memoryInGB,                 :default => nil,  :validation => Fixnum,      :tag => :inventory
        property :inventoryDate,              :default => nil,  :validation => String,      :tag => :inventory
        property :complianceCheckDate,        :default => nil,  :validation => String,      :tag => :inventory
        property :discoveredDate,             :default => nil,  :validation => String,      :tag => :inventory
        property :deviceGroupList,            :default => nil,  :validation => Hash,        :tag => :inventory
        property :credId,                     :default => nil,  :validation => String,      :tag => :inventory
        property :compliance,                 :default => nil,  :validation => String,      :tag => :inventory
        property :firmwareDeviceInventories,  :default => nil,  :validation => Array,       :tag => :inventory
        property :failuresCount,              :default => nil,  :validation => Fixnum,      :tag => :inventory

        def json_facts
          super + [
            "Nameserver",
            "RemoteDeviceInfo ",
            "RemoteDeviceInfo",
            "Zone_Members",
            "flexio_modules",
            "modules",
            "nameserver_info",
            "port_channel_members",
            "port_channels",
            "quad_port_interfaces",
            "remote_device_info",
            "remote_fc_device_info",
            "snmp_community_string",
            "software_protocol_configured",
            "vlan_information",
            "vlans",
            ["interfaces", []],
            ["dcb-map", []],
            ["fcoe-map", []]
          ]
        end

        def fc_zones(wwpn=nil)
          logger.warn("Retrieving zone information is not supported on %s, returning empty list of zones" % type.puppet_certname)
          []
        end

        def active_fc_zone(wwpn=nil)
          facts["Effective Cfg"]
        end

        def resource_creator
          @resource_creator ||= resource_creator!
        end

        def resource_creator!
          raise(NotImplementedError, "Subclasses must override #resource_creator!")
        end

        def additional_resources
          resource_creator.to_puppet
        end

        # Processes the resources created using the resource creator
        #
        # Some resource creator functions support build and teardown phases
        # and this method will prepare the creator for that phase and call
        # the base process! method for each phase should there be resources
        #
        # @param options [Hash] options for processing and pre-processing, all those from {Provider::Base#process!} are passed on
        # @option options [Boolean] :skip_prepare when true the prepare method on the creators will not be ran
        # @return [void]
        def process!(options={})
          if !options.delete(:skip_prepare)
            [:remove, :add].each do |action|
              super if resource_creator.prepare(action)
            end
          else
            super
          end

          # always reset the resource creator after a puppet run
          resource_creator!
        end

        # Creates the inventory properties on any switch class that inherits from this base
        #
        # The {ASM::Provider::Phash} module creates property configs and defaults on the eigenclass
        # which in the case here would be that of the Base class.  They would not magically appear
        # on any class that inherits from this one.
        #
        # Here we catch the inherit and then create all the properties on the one that inherits
        # from this class which results in a seamless inheritance of properties
        def self.inherited(klass)
          phash_config.each do |k, c|
            klass.send(:property, k, c)
          end

          # Provider::Base will register the provider into the type system
          super
        end

        # Resets a port to default or a specific vlan
        #
        # @param port [String] the port to reset
        # @param vlan [String,nil] the vlan to set it to, provider default when not supplied
        # @raise [StandardError] when not able to set the port
        def reset_port(port, vlan=nil)
          raise("Resetting ports to default is not implemented for %s" % self.class)
        end

        def rack_switch?
          false
        end

        def blade_switch?
          false
        end

        def fcflexiom_switch?
          false
        end

        def npiv_switch?
          false
        end

        def san_switch?
          false
        end

        def valid_mac?(mac)
          !!(mac.downcase =~ /^[0-9a-f]{2}([-:])[0-9a-f]{2}(\1[0-9a-f]{2}){4}$/)
        end

        def valid_wwpn?(wwpn)
          !!(wwpn.downcase =~ /^[0-9a-f]{2}([-:])[0-9a-f]{2}(\1[0-9a-f]{2}){6}$/)
        end

        def find_mac(mac)
          return nil unless facts.include?("remote_device_info")

          interface = nil
          # For backwards compatability
          if facts["remote_device_info"].is_a? Hash
            interface = facts["remote_device_info"].find do |_int, dets|
              dets["remote_mac"].downcase == mac.downcase
            end
            interface = interface.first if interface
          else
            facts["remote_device_info"].each do |iface|
              if iface["remote_mac"].downcase == mac.downcase
                interface = iface["interface"]
                break
              end
            end
          end

          interface
        end

        # Updates the inventory of a device
        #
        # Inventory updates are done using the normal {ASM::Provider::Base#update_inventory}
        # process but once the update is done the provider will be reconfigured using
        # the newly fetched inventory.
        #
        # Thus individual switches can still provide their own update_inventory methods though
        # that seems unlikely to be needed.  If they do though they should also call the
        # {#configure!} method like here.
        #
        # Switches are not real components they are a reflection of what ASM knows of their
        # inventories.  In a sense they are a cache of the inventory, so this acts like a
        # refresh of the cache
        #
        # @api private
        # @raise (see ASM::Provider::Base#update_inventory)
        # @return [void]
        def update_inventory
          super
          configure!(type.retrieve_inventory)
        end

        # Retrieve device features, often stored in the device facts as 'features'
        #
        # Actual contents will vary by switch model, so this is not really suitable
        # as a public interface and so not exposed via the switch type.
        #
        # @note derived from {ASM::Util.get_cisconexus_features}
        # @return [Hash]
        def features
          facts.fetch("features", {})
        end

        # Loosely validate current switch config for a server
        #
        # This is meant for deployments with unmanaged switches.
        # We loosely validated that the correct configuration is found
        # on the switches for the server we are trying to deploy to
        #
        # @param server [ASM::Type::Server]
        # @return [Boolean]
        def validate_network_config(server)
          server.network_interfaces.map do |interface|
            next unless port = type.find_mac(interface.partitions.first.mac_address, :server => server)
            networks = interface.partitions.map(&:networkObjects).flatten.compact.uniq

            networks.map do |network|
              next unless type.configured_network?(network, server)

              server.valid_network?(network, port, type)
            end
          end.flatten.compact.all?
        end

        # Configure the inventory based switch types
        #
        # Switches are based off inventory data and not component resources
        # so the {Provider::Base#configure!} method is replaced with one that
        # takes all the properties tagged as :inventory and populate their values
        # from the incoming inventory data and fakes up some things like setting
        # puppet_certname from the inventory data.
        #
        # @see ASM::Type::Switch.create_from_inventory
        # @return [void]
        def configure!(inventory)
          properties(:inventory).each do |property|
            self[property] = inventory.fetch(property, default_property_value(property))
          end

          retrieve_facts!

          type.puppet_certname = inventory["refId"]

          if device_conf = type.device_config
            @connection_url = device_conf["url"]
          end

          configure_hook if respond_to?(:configure_hook)
        end

        # Configures the switch port as per the server template
        #
        # @param server [ASM::Type::Server]
        # @param interface [Hashie::Mash] an interface on {ASM::NetworkConfiguration#cards}
        # @return [void]
        def provision_server_interface(server, interface)
          partition = interface.partitions.first

          port = type.find_mac(partition.mac_address, :server => server)
          return unless port

          logger.info("Configuring NIC %s / %s connected on %s port %s" % [server.puppet_certname, partition.fqdd, type.puppet_certname, port])
          networks = interface.partitions.map(&:networkObjects).flatten.compact.uniq

          if use_portchannel?(server, interface)
            portchannel = find_portchannel(server, interface)
            mtu = server.network_params["mtu"] || "12000"
          else
            portchannel = ""
            mtu = "12000"
          end

          untagged_seen = false

          networks.each do |network|
            if type.configured_network?(network, server)
              tagged = type.tagged_network?(network, server)
              untagged_seen ||= !tagged

              logger.info("Configuring NIC %s / %s on network %s %s VLAN %s" %
                              [server.puppet_certname, partition.fqdd, network.name, tagged ? "tagged" : "untagged", network.vlanId])
              resource_creator.configure_interface_vlan(port, network.vlanId, tagged, server.teardown?, portchannel, mtu)
            else
              logger.info("Skipping un-configured network %s VLAN %s on NIC %s / %s" %
                              [network.name, network.vlanId, server.puppet_certname, partition.fqdd])
            end
          end

          unless untagged_seen
            logger.info("Configuring native VLAN on NIC %s / %s" % [server.puppet_certname, partition.fqdd])
            resource_creator.configure_interface_vlan(port, "1", false, server.teardown?)
          end
        end

        def portchannel_members
          facts["port_channel_members"]
        end

        def use_portchannel?(server, interface)
          # Windows and esxi are not supported for LACP configuration
          return false if server.os_image_type =~ /vmware_esxi|windows/

          partition = interface.partitions.first
          mac = partition.mac_address

          team = server.network_config.teams.find do |t|
            t[:mac_addresses].include?(mac)
          end

          # Multiple mac_addresses here means we are teaming/bonding nics
          # Some networks won't show in teams (like PXE) so team is nil
          team && team[:mac_addresses].size > 1
        end

        def find_portchannel(server, interface)
          raise("LACP teaming not implemented for %s" % self.class)
        end
      end
    end
  end
end

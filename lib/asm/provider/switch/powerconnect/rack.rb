module ASM
  class Provider
    class Switch
      class Powerconnect
        # Manage Interface VLAN membership for Dell Powerconnect rack switches
        #
        # This class builds a temporary map of every interface and all its
        # VLAN memberships via {#configure_interface_vlan} and then turns that into
        # an appropriate puppet resource using {#to_puppet}
        class Rack
          attr_reader :logger, :sequence
          attr_accessor :type, :provider

          def initialize(provider, resources={})
            @interfaces = []
            @resources = resources
            @provider = provider
            @logger = provider.logger
            @type = provider.type
          end

          def reset!
            @resources.clear
          end

          def interface_map
            @interfaces
          end

          def port_resources
            @resources
          end

          # Determines if a resource is present in the current set of port resources
          #
          # @see {#port_resources}
          # @param type [String] a Puppet type
          # @param name [String] a Puppet resource name
          # @return [Boolean]
          def has_resource?(type, name)
            return false unless port_resources.include?(type)
            return true if port_resources[type].include?(name)
            false
          end

          def prepare(action)
            reset!
            validate_vlans!
            populate_resources(action)
            !port_resources.empty?
          end

          def process!
            [:remove, :add].each do |action|
              super if prepare(action)
            end
          end

          # Configures an interface as part of a vlan
          #
          # @example configuring 2 interfaces
          #
          #    server.configure_interface_vlan("Te 1/1", "10", true)
          #    server.configure_interface_vlan("Te 1/1", "11", true)
          #    server.configure_interface_vlan("Te 1/1", "18", false)
          #
          #    rack.prepare(:add)
          #    rack.to_puppet
          #
          # The example above shows that all interface related VLANs get
          # created using {#configure_interface_vlan} - here 18 would be
          # untagged while the rest are tagged
          #
          # Once all the interfaces are known the {#prepare} and {#to_puppet}
          # calls will turn the list of interfaces into actual puppet resources
          #
          # @param interface [String] the interface name
          # @param vlan [String] the vlan to add the interface to
          # @param tagged [Boolean] true when its tagged
          # @param remove [Boolean] true if this is a teardown and needs to be removed
          # @param portchannel [String] placeholder, unused for powerconnect
          # @return [void]
          def configure_interface_vlan(interface, vlan, tagged, remove=false, portchannel="", mtu="12000")
            raise "Interface not specified for vlan %s" % vlan if interface.empty?
            action = remove ? :remove : :add

            interface_map << {
              :interface   => interface.to_s,
              :portchannel => portchannel.to_s,
              :vlan        => vlan.to_s,
              :tagged      => tagged,
              :action      => action
            }
          end

          # Validate the interface map for impossible configurations
          #
          # @return [void]
          # @raise [StandardError] for invalid config
          def validate_vlans!
            errors = 0

            interface_map.map {|i| i[:interface]}.sort.uniq.each do |interface|
              untagged = interface_map.count {|i| !i[:tagged] && i[:interface] == interface}

              if untagged > 1
                logger.warn("Attempt to configure %d untagged vlans on port %s" % [untagged, interface])
                errors += 1
              end
            end

            if errors > 0
              raise("Can only have one untagged network but found multiple untagged vlan requests for the same port on %s" % type.puppet_certname)
            end
          end

          # Find all the interfaces for a certain action and create interface/portchannel resources
          #
          # Interfaces are made using {#configure_interface_vlan} and are
          # marked as add or remove.  This finds all previously made interfaces
          # for a given action and populates the {#port_resources} hash with the
          # right resources
          #
          # @param [:add, :remove] action
          # @return [void]
          def populate_resources(action)
            # Collect all the interface/portchannel vlans together so we only have to manage/created each interface
            # and/or portchannel once each.
            resource_map = {}
            interface_map.collect {|i| i[:interface]}.uniq.each do |name|
              interface_configs = interface_map.find_all {|i| i[:interface] == name && i[:action] == action}
              next if interface_configs.empty?

              tagged = interface_configs.find_all {|config| config[:tagged]}.collect {|config| config[:vlan]}
              untagged = interface_configs.find_all {|c| !c[:tagged]}.collect {|config| config[:vlan]}
              # Interface should only have 1 portchannel across entries according to how code works
              portchannel = interface_configs.first[:portchannel]

              resource_map[name] =
                {
                  :tagged => tagged,
                  :untagged => untagged,
                  :portchannel => portchannel,
                  :action => action
                }
            end

            resource_map.each do |interface, config|
              # Create interface resource
              if config[:portchannel].empty?
                populate_interface_resource(interface, config)
                populate_vlan_resources(config[:tagged] + config[:untagged])
              else
                populate_portchannel_resource(config[:portchannel], config)
                populate_vlan_resources(config[:tagged] + config[:untagged])
                populate_interface_resource(interface, config)
              end
            end
          end

          # Construct powerconnect_interface resources
          #
          # Interfaces added with {#configure_interface_vlan} have various
          # associated VLANs and/or portchannels, this adds resources to manage those
          # relationships with regard to server facing ports
          #
          # @param name [String] interface name
          # @param [Hash] properties
          # @option properties [Array[String]] :tagged
          # @option properties [Array[String]] :untagged
          # @option properties [Array[String]] :action
          # @return [void]
          def populate_interface_resource(name, properties)
            portchannel = properties[:portchannel]
            tagged = properties[:tagged]
            untagged = properties[:untagged]
            action = properties[:action]

            if has_resource?("Powerconnect_interface", name)
              raise("Powerconnect_interface[%s] is already being managed on %s" % [name, type.puppet_certname])
            end

            port_resources["powerconnect_interface"] ||= {}
            config = port_resources["powerconnect_interface"][name] = {}

            config["shutdown"] = "false"

            if portchannel.empty?
              config["switchport_mode"] = "general"
              config["portfast"] = "true"
              config["tagged_general_vlans"] = tagged
              config["untagged_general_vlans"] = untagged
            elsif action == :add
              config["add_interface_to_portchannel"] = portchannel
            elsif action == :remove
              config["remove_interface_from_portchannel"] = portchannel
            end

            config["require"] = sequence if sequence

            @sequence = "Powerconnect_interface[%s]" % name
          end

          # Construct powerconnect_vlan resources
          #
          # Interfaces added with {#configure_interface_vlan} have various
          # associated interfaces and vlans. This adds resources to ensure existence of those vlans
          #
          # @param vlans Array[[String]] list of vlans to manage
          # @return [void]
          def populate_vlan_resources(vlans)
            vlans.each do |vlan|
              port_resources["powerconnect_vlan"] ||= {}
              port_resources["powerconnect_vlan"][vlan] ||= {
                "ensure"  => "present",
                "before"  => sequence
              }
            end
          end

          # Construct powerconnect_portchannel resources
          #
          # Interfaces added with {#configure_interface_vlan} have various
          # associated interfaces and vlans. This adds resources to manage those
          # relationships with regard to portchannels
          #
          # @param number [String] portchannel name/number
          # @param [Hash] properties
          # @option properties [Array[String]] :tagged
          # @option properties [Array[String]] :untagged
          # @option properties [Array[String]] :action
          # @return [void]
          def populate_portchannel_resource(number, properties)
            tagged = properties[:tagged]
            untagged = properties[:untagged]
            action = properties[:action]

            if has_resource?("Powerconnect_portchannel", number)
              raise("Powerconnect_portchannel[%s] is already being managed on %s" % [number, type.puppet_certname])
            end

            port_resources["powerconnect_portchannel"] ||= {}
            config = port_resources["powerconnect_portchannel"][number] = {}

            config["shutdown"] = "false"
            config["switchport_mode"] = "general"

            if action == :add
              config["tagged_general_vlans"] = tagged
              config["untagged_general_vlans"] = untagged
            elsif action == :remove
              config["remove_general_vlans"] = tagged + untagged
            end

            config["require"] = sequence if sequence

            @sequence = "Powerconnect_portchannel[%s]" % number
          end

          # Creates interfaces resources for consumption by puppet
          #
          # @return [Hash]
          def to_puppet
            possible_resources = %w(powerconnect_vlan powerconnect_interface powerconnect_portchannel)
            possible_resources.each do |r_source|
              next unless port_resources[r_source]
              port_resources[r_source].keys.each do |name|
                resource = port_resources[r_source][name]

                %w(tagged_general_vlans untagged_general_vlans remove_general_vlans).each do |prop|
                  next unless resource[prop].is_a?(Array)
                  resource[prop] = resource[prop].sort.uniq.join(",")
                end
              end
            end

            port_resources
          end
        end
      end
    end
  end
end

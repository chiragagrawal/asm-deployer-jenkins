module ASM
  class Provider
    class Switch
      class Nexus5k
        # Manage Interface VLAN membership for Dell Force10 rack switches
        #
        # This class builds a temporary map of every interface and all its
        # VLAN membership vi {#configure_interface_vlan} and then turns that into
        # an appropriate puppet resource using {#to_puppet}
        class Rack
          attr_reader :logger
          attr_accessor :type, :provider, :sequence

          def initialize(provider, resources={})
            @interfaces = []
            @vsans = []
            @resources = resources
            @provider = provider
            @logger = provider.logger
            @type = provider.type
            @sequence = nil
          end

          # Configures an interface as part of a vlan
          #
          # @example configuring 2 interfaces
          #
          #    rack.configure_interface_vlan("Te 1/1", "10", true)
          #    rack.configure_interface_vlan("Te 1/1", "11", true)
          #    rack.configure_interface_vlan("Te 1/1", "18", false)
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
          # @param portchannel [String] unused for nexus5k
          # @return [void]
          def configure_interface_vlan(interface, vlan, tagged, remove=false, portchannel="", mtu="12000")
            raise "Interface not specified for vlan %s" % vlan if interface.empty?
            action = remove ? :remove : :add

            interface_map << {
              :interface => interface.to_s,
              :vlan      => vlan.to_s,
              :tagged    => tagged,
              :mtu       => mtu,
              :action    => action
            }
          end

          # Configures an interface for vsan
          #
          # @example configuring 1 vsan interface
          #
          #
          #    rack.configure_interface_vsan("Te 1/21", "255")
          #
          #    rack.prepage(:add)
          #    rack.to_puppet
          #
          # The example above shows configuring the interface to use a
          # specific active vsan zoneset.
          #
          # Once all the interfaces are known the {#prepare} and {#to_puppet}
          # calls will turn the list of interfaces into actual puppet resources
          #
          # @param interface [String] the interface name
          # @param vsan [String] the vsan zoneset
          # @return [void]
          def configure_interface_vsan(interface, vsan, remove=false)
            raise "Interface not specified for cisco vsan confiugration" if interface.empty?
            raise "Vsan zoneset not specified for cisco vsan configuration" if vsan.empty?

            action = remove ? :remove : :add

            vsan_map << {
              :interface => interface.to_s,
              :vsan      => vsan,
              :action    => action
            }
          end

          # Creates interfaces resources for consumption by puppet
          #
          # @return [Hash]
          def to_puppet
            possible_resources = ["cisconexus5k_interface", "cisconexus5k_vlan", "cisconexus5k_vfc"]
            possible_resources.each do |r_source|
              next unless port_resources[r_source]
              port_resources[r_source].keys.each do |name|
                resource = port_resources[r_source][name]
                resource.each do |k, v|
                  resource[k] = v.sort.uniq.join(",") if v.is_a? Array
                end
              end
            end

            port_resources
          end

          # Validate the interface map for impossible configurations
          #
          # @return [void]
          # @raise [StandardError] for invalid config
          def validate_vlans!
            errors = 0

            interface_map.map { |i| i[:interface] }.sort.uniq.each do |interface|
              untagged = interface_map.count { |i| !i[:tagged] && i[:interface] == interface }

              if untagged > 1
                logger.warn("Attempt to configure %d untagged vlans on port %s" % [untagged, interface])
                errors += 1
              end
            end

            if errors > 0
              raise("Can only have one untagged network but found multiple untagged vlan requests for the same port on %s" % type.puppet_certname)
            end
          end

          # Prepares the final internal state for a given action
          #
          # This should be called before {#to_puppet} to construct
          # the state based on interface information created using
          # {#configure_interface_vlan}
          #
          # The return value indicates if there were any interfaces to
          # configure for the action, if it's false there's no point
          # in calling process for the type as there's nothing to process
          #
          # @param [:add, :remove] action
          # @return [Boolean] if any interfaces were found for the action
          def prepare(action)
            reset!
            validate_vlans!
            populate_vlan_resources(action)
            populate_vsan_resources(action)

            !port_resources.empty?
          end

          def reset!(start_sequence=nil)
            @resources.clear
            @sequence = start_sequence
          end

          def interface_map
            @interfaces
          end

          def vsan_map
            @vsans
          end

          def port_resources
            @resources
          end

          def process!
            [:remove, :add].each do |action|
              super if prepare(action)
            end
          end

          def configure_server(server)
            if !server.teardown?
              provision_server_networking(server)
            else
              teardown_server_networking(server)
            end
          end

          # Find all the interfaces for a certain action and create VLANs
          #
          # Interfaces are made using {#configure_interface_vlan} and are
          # marked as add or remove.  This finds all previously made interfaces
          # for a given action and calls {#vlan_resource) for each to construct
          # the correct asm::cisconexus5k resources
          #
          # @param [:add, :remove] action
          # @return [void]
          def populate_vlan_resources(action)
            action_interfaces = interface_map.select { |i| i[:action] == action }

            action_interfaces.each do |iface|
              properties = {
                :tagged_tengigabitethernet   => [],
                :untagged_tengigabitethernet => []
              }

              action_interfaces.select { |i| i[:interface] == iface[:interface] }.each do |interface|
                if interface[:tagged]
                  properties[:tagged_tengigabitethernet] << interface[:vlan]
                else
                  properties[:untagged_tengigabitethernet] << interface[:vlan]
                end
              end

              vlan_resource(iface[:interface], action, properties)
            end
          end

          # Find all the vsans for a certain action and create VFC & VSAN resources
          #
          # Interfaces are made using {#configure_interface_vsan} and are marked as
          # add or remove. This finds all previously made vlans for a given action
          # and calls {#vsan_resource} and {#vfc_resource}for each to construct the
          # correct cisconexus5k_vsan and cisconexus5k_vfc resources
          #
          # @param [:add, :remove] action
          # @return [void]
          def populate_vsan_resources(action)
            action_vsans = vsan_map.select { |i| i[:action] == action }
            vsan_names = action_vsans.map { |i| i[:vsan] }.sort.uniq

            vsan_names.each do |vsan|
              properties = {
                :membership => [],
                :vlan       => []
              }

              action_vsans.select { |i| i[:vsan] == vsan }.each do |vs|
                if vs[:interface].match(fex_interface_pattern)
                  vfc = $1.to_i + $2.to_i + $3.to_i
                  fex_feature_set
                  fex_fcoe(vfc)
                  fex_vfc_resource(vs[:interface])
                  properties[:membership] = "vfc%s" % vfc
                  properties[:vlan] = vfc
                else
                  vlan_id = vs[:interface].scan(/(\d+)/).flatten.last
                  properties[:vlan] = vlan_id
                  properties[:membership] = "vfc#{vlan_id}"
                  vfc_resource(vlan_id, vs[:interface])
                end
              end
              vsan_resource(vsan, action, properties)
            end
          end

          # Construct cisconexus5k_vsan resources for a vSAN zone
          #
          # @param vlan_id [String, FixNum] vlan id
          # @param interface [String] interface
          # @return [void]
          def vfc_resource(vlan_id, interface)
            vlan = vlan_id.to_s

            port_resources["cisconexus5k_vfc"] ||= {}

            unless port_resources["cisconexus5k_vfc"][vlan]
              port_resources["cisconexus5k_vfc"][vlan] = {
                "bind_interface" => interface,
                "shutdown"       => "false"
              }
            end
          end

          # Construct cisconexus5k_fex resources for a vSAN zone
          #
          # @param vfc [String] VFC ID
          # @return [void]
          def fex_fcoe(vfc)
            port_resources["cisconexus5k_fex"] ||= {}
            port_resources["cisconexus5k_fex"][vfc] = {
              "fcoe"    => "true",
              "require" => "Cisconexus5k_featureset[virtualization]"
            }
          end

          # Construct cisconexus5k_featureset resources for a FCoE vSAN zone
          #
          # @return [void]
          def fex_feature_set
            port_resources["cisconexus5k_featureset"] ||= {}
            port_resources["cisconexus5k_featureset"]["virtualization"] = {
              "feature" => "virtualization"
            }
          end

          # Construct cisconexus5k_vfc resources for a vSAN zone
          #
          # @param interface [String] interface
          # @return [void]
          def fex_vfc_resource(interface)
            vfc_temp = interface.scan(fex_interface_pattern).flatten
            vfc = vfc_temp[0].to_i + vfc_temp[1].to_i + vfc_temp[2].to_i

            port_resources["cisconexus5k_vfc"] ||= {}
            port_resources["cisconexus5k_vfc"][vfc] = {
              "bind_interface" => interface.strip,
              "shutdown"       => "false",
              "require"        => "Cisconexus5k_fex[%s]" % vfc
            }
          end

          # Construct cisconexus5k_vsan resources for a vSAN zone
          #
          # @param zone [String, Fixnum] vsan zone
          # @param [:add, :remove] action
          # @param [Hash] properties
          # @option properties [String] :vlan
          # @option properties [String] :membership
          # @return [void]
          def vsan_resource(zone, action, properties)
            vsan = zone.to_s
            port_resources["cisconexus5k_vsan"] ||= {}

            unless port_resources["cisconexus5k_vsan"][vsan]
              if action == :add
                port_resources["cisconexus5k_vsan"][vsan] = {
                  "membership"          => properties[:membership],
                  "membershipoperation" => "add",
                  "require"             => "Cisconexus5k_vfc[%s]" % properties[:vlan]
                }
              elsif action == :remove
                port_resources["cisconexus5k_vsan"][vsan] = {
                  "membership"          => properties[:membership],
                  "membershipoperation" => "remove",
                  "require"             => "Cisconexus5k_vfc[%s]" % properties[:vlan]
                }
              end
            end
          end

          # Construct asm::cisconexus5k resources for a VLAN
          #
          # Interfaces added with {#configure_interface_vlan} have various
          # associated VLANs, this adds resources to manage those VLANs
          # to the {#port_resources} hash
          #
          # @param interface [String] interface name
          # @param [:add, :remove] action
          # @param [Hash] properties
          # @option properties [Array<String>]:tagged
          # @option properties [Array<String>]:untagged
          # @return [void]
          def vlan_resource(interface, action, properties={})
            interface = interface.to_s
            tagged = properties.fetch(:tagged_tengigabitethernet, [])
            untagged = properties.fetch(:untagged_tengigabitethernet, [])

            port_resources["cisconexus5k_interface"] ||= {}

            unless port_resources["cisconexus5k_interface"][interface]
              port_resources["cisconexus5k_interface"][interface] = {
                "switchport_mode"        => "trunk",
                "shutdown"               => "false",
                "ensure"                 => "present",
                "tagged_general_vlans"   => tagged,
                "untagged_general_vlans" => untagged
              }
              # For teardown
              port_resources["cisconexus5k_interface"][interface]["interfaceoperation"] = "remove" unless action == :add
            end

            if action == :add
              vlans = tagged + untagged
              port_resources["cisconexus5k_vlan"] ||= {}
              vlans.each do |vlan|
                next if port_resources["cisconexus5k_vlan"][vlan]
                port_resources["cisconexus5k_vlan"][vlan] = {
                  "ensure"  => "present",
                  "require" => "Cisconexus5k_interface[#{interface}]"
                }
              end
            end
          end

          def fex_interface_pattern
            %r{Eth(\d+)\/(\d+)\/(\d+)}
          end
        end
      end
    end
  end
end

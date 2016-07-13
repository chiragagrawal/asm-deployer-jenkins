module ASM
  class Provider
    class Switch
      class Force10
        class Base
          attr_reader :logger
          attr_accessor :type, :provider, :sequence

          def initialize(provider, resources={})
            @interfaces = []
            @resources = resources
            @provider = provider
            @logger = provider.logger
            @type = provider.type
            @sequence = nil
          end

          # Resets the internal state of the creator
          #
          # @param start_sequence [String,nil] The Puppet resource name to use as first require
          def reset!(start_sequence=nil)
            @resources.clear
            @sequence = start_sequence
          end

          def interface_map
            @interfaces
          end

          def port_resources
            @resources
          end

          # (see Provider::Switch::Force10#portchannel_resource)
          def portchannel_resource(number, fcoe=false, remove=false, vlt_peer=false, ungroup=false, mtu="12000")
            number = number.to_s

            if has_resource?("mxl_portchannel", number)
              raise("Mxl_portchannel[%s] is already being managed on %s" % [number, type.puppet_certname])
            end

            port_resources["mxl_portchannel"] ||= {}
            port_resources["mxl_portchannel"][number] = {
              "ensure" => remove ? "absent" : "present",
              "switchport" => "true",
              "portmode" => "hybrid",
              "shutdown" => "false",
              "mtu" => mtu,
              "fip_snooping_fcf" => fcoe.to_s,
              "vltpeer" => vlt_peer.to_s,
              "ungroup" => ungroup.to_s
            }

            port_resources["mxl_portchannel"][number]["require"] = sequence if sequence

            @sequence = "Mxl_portchannel[%s]" % number

            nil
          end

          # (see Provider::Switch::Force10#ioa_interface_resource)
          def ioa_interface_resource(interface, tagged_vlans, untagged_vlans)
            logger.warn("Creating ioa_interface resources is unsupported on %s" % type.puppet_certname)
            nil
          end

          # (see Provider::Switch::Force10#mxl_interface_resource)
          def mxl_interface_resource(interface, port_channel=nil)
            if has_resource?("mxl_interface", interface)
              raise("Mxl_interface[%s] is already being managed on %s" % [interface, type.puppet_certname])
            end

            port_resources["mxl_interface"] ||= {}
            port_resources["mxl_interface"][interface] = {
              "shutdown" => "false"
            }

            port_resources["mxl_interface"][interface]["portchannel"] = port_channel.to_s if port_channel
            port_resources["mxl_interface"][interface]["require"] = sequence if sequence

            @sequence = "Mxl_interface[%s]" % interface

            nil
          end

          # (see Provider::Switch::Force10#mxl_vlan_resource)
          def mxl_vlan_resource(vlan, name, description, port_channels, remove=false)
            vlan = vlan.to_s

            if has_resource?("mxl_vlan", vlan)
              raise("Mxl_vlan[%s] is already being managed on %s" % [vlan, type.puppet_certname])
            end

            port_resources["mxl_vlan"] ||= {}
            port_resources["mxl_vlan"][vlan] = {
              "ensure" => remove ? "absent" : "present"
            }

            unless remove
              port_resources["mxl_vlan"][vlan].merge!(
                "vlan_name" => name,
                "desc" => description,
                "shutdown" => "false"
              )

              port_resources["mxl_vlan"][vlan]["tagged_portchannel"] = port_channels.sort.uniq.join(",") if port_channels && !port_channels.empty?
            end

            port_resources["mxl_vlan"][vlan]["require"] = sequence if sequence

            @sequence = "Mxl_vlan[%s]" % vlan

            nil
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

          # Configures a list of interfaces for quodmode
          #
          # Only 40 Gb interfaces can be part of a group, any non 40 Gb interfaces
          # listed when enable is true will be silently skipped and logged
          #
          # @param interfaces [Array] list of interfaces
          # @param enable [Boolean] should it be enabled or not for quadmode
          # @param reboot [Boolean] should the last interface set reboot required
          # @return [String] the last resource made that can be used to sequence puppet requires on
          def configure_quadmode(interfaces, enable, reboot=true)
            logger.debug("Configuring quadmode is not supported on %s" % type.puppet_certname)
            nil
          end

          # Configures the switch for VLT or PMUX mode
          #
          # @param pmux [boolean] configure pmux mode
          # @param ethernet_mode [Boolean] for use in PMUX configurations
          # @param vlt_data [Hash] vlt from deployment having vlt configuration data
          # @return [void]
          # @raise [StandardError] when called multiple times
          def configure_iom_mode!(pmux, ethernet_mode, vlt_data)
            logger.debug("Configuring iom mode is not supported on %s" % type.puppet_certname)
            nil
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
          # @abstract
          # @param [:add, :remove] action
          # @return [Boolean] if any interfaces were found for the action
          def prepare(action)
            raise NotImplementedError
          end

          # Configures the switch using the force10_settings array
          #
          # By default the settings are applied verbatim with no additional
          # processing.
          #
          # Some switches like the MXL switch does additional work
          #
          # @note this used to be ServiceDeployment#process_uplink_config_file
          # @param settings [Hash] of force10_settings properties
          # @return [void]
          def configure_force10_settings(settings)
            port_resources["force10_settings"] = {type.puppet_certname => settings.clone}
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
          # Once all the interfaces are known the {#prepare} and {Base#to_puppet}
          # calls will turn the list of interfaces into actual puppet resources
          #
          # @param interface [String] the interface name
          # @param vlan [String] the vlan to add the interface to
          # @param tagged [Boolean] true when its tagged
          # @param remove [Boolean] true if this is a teardown and needs to be removed
          # @param portchannel [String] the portchannel this port is/will be on
          # @return [void]
          def configure_interface_vlan(interface, vlan, tagged, remove=false, portchannel=nil, mtu="12000")
            raise "Interface not specified for vlan %s" % vlan if interface.empty?
            action = remove ? :remove : :add

            interface_map << {
              :interface => interface.to_s,
              :portchannel => portchannel.to_s,
              :vlan      => vlan.to_s,
              :tagged    => tagged,
              :mtu       => mtu,
              :action    => action
            }
          end

          # Validates the interface map for impossible configurations
          #
          # @return [void]
          # @raise [StandardError] for invalid configurations
          def validate_vlans!
            errors = 0
            interface_map.map {|i| i[:interface]}.sort.uniq.each do |interface|
              untagged = interface_map.count {|i| !i[:tagged] && i[:interface] == interface}

              if untagged > 1
                logger.warn("attempt to configure %d untagged vlans on port %s" % [untagged, interface])
                errors += 1
              end
            end

            if errors > 0
              raise("can only have one untagged network but found multiple untagged vlan requests for the same port on %s" % type.puppet_certname)
            end
          end

          # Convert a series of Force10 port names of the form 0/1 to a list for the CLI
          #
          # @param ports [String] like 0/1,0/2,0/5,1/4
          # @return [String] CLI compatible list eg. 0/1,2,5,1/4
          def ports_to_cli_ranges(ports)
            return ports if @provider.model == "S4048-ON"
            units = Hash.new {|hash, key| hash[key] = []}

            ports.split(",").each do |port_def|
              next unless port_def =~ %r{^\d+\/\d+$}

              unit, port = port_def.split("/")
              units[unit] << port
            end

            units.map {|unit, range| "%s/%s" % [unit, range.join(",")]}.join(",")
          end

          # The amount of ports a specific type of switch has
          #
          # @note logic from ServiceDeployment#process_configuration_iomuplink
          # @return [Fixnum]
          def port_count
            provider.model =~ /MXL|Aggregator/ ? 32 : 8
          end

          def initialize_ports!
            raise("Initializing ports for %s is not supported" % type.puppet_certname)
          end

          # Given a name of a port returns just the number part
          #
          # @param name [String] port name like "Te 10"
          # @return [String] the port number
          def port_number_from_name(name)
            name.gsub(/^(Te|Gi) /, "")
          end

          # Find all the interfaces for a certain action and create interface resources
          #
          # Interfaces are made using {#configure_interface_vlan} and are
          # marked as add or remove.  This finds all previously made interfaces
          # for a given action and calls {#interface_resource) for each to construct
          # the correct force10_interface resources
          #
          # @param [:add, :remove] action
          # @return [void]
          def populate_port_resources(action)
            # Populate the portchannels to be created first
            interface_map.collect {|i| i[:portchannel]}.uniq.each do |channel|
              next if channel.empty?
              mtu = interface_map.find_all {|i| i[:portchannel] == channel}.first[:mtu]
              portchannel_resource(channel, false, false, false, true, mtu)
            end

            interface_map.each do |interface|
              next unless interface[:action] == action
              port_resources["force10_interface"] ||= {}
              port_resources["force10_interface"][interface[:interface]] ||=
                {
                  "shutdown" => "false",
                  "mtu" => interface[:mtu],
                  "protocol" => "lldp",
                  "ensure" => "present",
                  "tagged_vlan" => [],
                  "untagged_vlan" => []
                }
              port_config = port_resources["force10_interface"][interface[:interface]]

              port_config["require"] = sequence if sequence

              if !interface[:portchannel].empty?
                port_config["portchannel"] = interface[:portchannel]
              else
                if interface[:tagged]
                  port_config["tagged_vlan"] << interface[:vlan]
                else
                  port_config["untagged_vlan"] << interface[:vlan]
                end

                port_config["switchport"] = "true"
                port_config["portmode"] = "hybrid"
                port_config["portfast"] = "portfast"
                port_config["edge_port"] = "pvst,mstp,rstp"

                @sequence = "Force10_interface[%s]" % interface[:interface]
              end
            end
          end
        end
      end
    end
  end
end

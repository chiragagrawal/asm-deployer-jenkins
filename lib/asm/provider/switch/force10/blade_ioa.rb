require "asm/provider/switch/force10/base"

module ASM
  class Provider
    class Switch
      class Force10
        # Manage Interface VLAN membership for Dell Force10 blade switches
        #
        # These switches unlike their TOR cousins are configured using a simple
        # 1 resource per interface method so this class mainly builds a temporary
        # map of every interface and all its VLAN memberships via {#configure_interface_vlan}
        # and then turns that into an appropriate puppet resource using {#to_puppet}
        class BladeIoa < Base
          def iom_mode
            provider.facts["iom_mode"]
          end

          def configure_iom_mode!(pmux, ethernet_mode, vlt_data=nil)
            raise("iom mode resource is already created in this instance for switch %s" % type.puppet_certname) if port_resources["ioa_mode"]

            if vlt_data
              interface = vlt_data["portMembers"]
              port_channel = vlt_data["portChannel"]
              destination_ip = vlt_data["Destination_ip"]
              unit_id = vlt_data["unit-id"]

              if vlt_data["model"] =~ /PE-FN.*/
                mode = "fullswitch"
              else
                mode = "vlt"
              end

              port_resources["ioa_mode"] = vlt_ioa_mode_resource(interface, port_channel, destination_ip, unit_id, mode)
            elsif pmux

              if type.model =~ /PE-FN/
                mode = "fullswitch"
              else
                mode = "pmux"
              end

              port_resources["ioa_mode"] = pmux_ioa_mode_resource(ethernet_mode, mode)
            end

            if port_resources["ioa_mode"]
              key, resource = port_resources["ioa_mode"].first
              resource["require"] = sequence if sequence
              @sequence = "Ioa_mode[%s]" % key
            end

            nil
          end

          # (see Provider::Switch::Force10#ioa_interface_resource)
          def ioa_interface_resource(interface, tagged_vlans, untagged_vlans)
            if has_resource?("ioa_interface", interface)
              raise("Ioa_interface[%s] is already being managed on %s" % [interface, type.puppet_certname])
            end
            port_resources["ioa_interface"] ||= {}
            port_resources["ioa_interface"][interface] = {}
            port_resources["ioa_interface"][interface]["vlan_tagged"] = tagged_vlans.join(",") unless tagged_vlans.empty?
            port_resources["ioa_interface"][interface]["vlan_untagged"] = untagged_vlans.join(",") unless untagged_vlans.empty?
            port_resources["ioa_interface"][interface]["switchport"] = true
            port_resources["ioa_interface"][interface]["portmode"] = "hybrid"
            port_resources["ioa_interface"][interface]["require"] = sequence if sequence
            @sequence = "Ioa_interface[%s]" % interface
            nil
          end

          # Creates vlt resources
          #
          # Creates a resources as hash normally parameters taken from vlt_data
          #
          # @note It will just sent as hash to to_puppet method, Run by puppet from the Yaml file
          # @param interface [String] port interface to assigned to a port channel
          # @param destination_ip [String] ip_address to set for creating back-up link
          # @param port_channel [String] port-channel to create up-link
          # @param unit_id [String] priority for th back-up link
          # @param mode [String] mode [pmux, vlt, fullswitch] configure in iom
          # @return [Hash] a resource for puppet run
          def vlt_ioa_mode_resource(interface, port_channel, destination_ip, unit_id, mode)
            {
              mode => {
                "iom_mode" => mode,
                "ioa_ethernet_mode" => "true",
                "ensure" => "present",
                "port_channel" => port_channel,
                "destination_ip" => destination_ip,
                "unit_id" => unit_id.to_s,
                "interface" => interface.to_s
              }
            }
          end

          def pmux_ioa_mode_resource(ethernet_mode, mode)
            {
              mode => {
                "iom_mode" => mode,
                "ensure" => "present",
                "ioa_ethernet_mode" => ethernet_mode.to_s,
                "vlt" => false
              }
            }
          end

          # Creates interfaces resources for consumption by puppet
          #
          # @return [Hash]
          def to_puppet
            %w(ioa_interface force10_portchannel).each do |r_source|
              next unless port_resources[r_source]
              port_resources[r_source].keys.each do |name|
                resource = port_resources[r_source][name]

                ["vlan_tagged", "vlan_untagged", "tagged_vlan", "untagged_vlan"].each do |prop|
                  next unless resource[prop].is_a?(Array)
                  resource[prop] = resource[prop].sort.uniq.join(",")
                end
              end
            end

            port_resources
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
            validate_mode!
            populate_interface_resources(action)
            !port_resources.empty?
          end

          def validate_mode!
            # For IOAs, we can't configure LACP/teams if IOA is standalone mode
            if interface_map.find { |i| !i[:portchannel].empty? } && iom_mode == "standalone"
              raise(ASM::UserException, "IOA %s cannot be in standalone mode for NIC teaming" % type.puppet_certname)
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
          def populate_interface_resources(action)
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
              mtu = interface_configs.first[:mtu]

              resource_map[name] =
                {
                  :tagged => tagged,
                  :untagged => untagged,
                  :portchannel => portchannel,
                  :mtu => mtu,
                  :action => action
                }
            end

            resource_map.each do |interface, config|
              # Create interface resource
              unless config[:portchannel].empty?
                populate_portchannel_resource(config[:portchannel], config)
              end
              populate_interface_resource(interface, config)
            end
          end

          def populate_interface_resource(name, properties)
            portchannel = properties[:portchannel]
            tagged = properties[:tagged]
            untagged = properties[:untagged]

            if has_resource?("Ioa_interface", name)
              raise("Force10_portchannel[%s] is already being managed on %s" % [name, type.puppet_certname])
            end

            port_resources["ioa_interface"] ||= {}
            config = port_resources["ioa_interface"][name] = {}

            config["shutdown"] = "false"
            config["mtu"] = properties[:mtu]

            if portchannel.empty?
              config["switchport"] = "true"
              config["portmode"] = "hybrid"
              config["vlan_tagged"] = tagged
              config["vlan_untagged"] = untagged
            else
              config["portchannel"] = portchannel
            end
            config["require"] = sequence if sequence

            @sequence = "Ioa_interface[%s]" % name
          end

          def populate_portchannel_resource(number, properties)
            tagged = properties[:tagged]
            untagged = properties[:untagged]

            if has_resource?("force10_portchannel", number)
              raise("Force10_portchannel[%s] is already being managed on %s" % [number, type.puppet_certname])
            end

            port_resources["force10_portchannel"] ||= {}
            config = port_resources["force10_portchannel"][number] = {}

            config["switchport"] = "true"
            config["portmode"] = "hybrid"
            config["shutdown"] = "false"
            config["tagged_vlan"] = tagged
            config["untagged_vlan"] = untagged
            config["ungroup"] = "true"
            config["mtu"] = properties[:mtu]
            config["require"] = sequence if sequence

            @sequence = "Force10_portchannel[%s]" % number
          end

          # Find all the interfaces for a certain action and create VLAN resources
          #
          # Interfaces are made using {#configure_interface_vlan} and are
          # marked  as add or remove.  This finds all previously made interfaces
          # for a given action and calls {#vlan_resource) for each to construct
          # the correct asm::mxl resources
          #
          # @param [:add, :remove] action
          # @return [void]
          def populate_vlan_resources(action)
            action_interfaces = interface_map.select {|i| i[:action] == action}
            vlan_info = {}
            action_interfaces.each do |i|
              vlan_info[i[:vlan]] = i
            end

            vlan_info.each do |vlan, props|
              vlan_resource(vlan, props) unless action == :remove
            end
          end

          def disable_autolag
            port_resources["ioa_autolag"] = {
              "ioa_autolag" => {
                "ensure" => "absent"
              }
            }
          end

          # Reset each port in the switch to a default state
          #
          # @note this will populate the resources without running puppet
          # @return [void]
          def initialize_ports!
            if provider.model =~ /Aggregator/
              port_names.each do |port|
                configure_interface_vlan(port, "1", false, true)
                configure_interface_vlan(port, "1", true, true)
              end

              populate_interface_resources(:remove)
            end
          end

          # Produce a list of port names for a certain switch
          #
          # @note only returned TE names not FC and only for a single unit
          # @return [Array<String>] array of port names
          def port_names
            (1..port_count).map {|i| "Te 0/%s" % i}
          end
        end
      end
    end
  end
end

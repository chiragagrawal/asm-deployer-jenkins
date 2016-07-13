require "asm/provider/switch/force10/base"

module ASM
  class Provider
    class Switch
      class Force10
        # Manage VLAN membership for Dell Force10 top of rack switches
        #
        # These switches are managed using at least 2 resources for every
        # interface.
        #
        # First a force10_interface resource needs to exist for every
        # interface under management then for every VLAN a asm::force10
        # resource exist that lists all the tagged and untagged interfaces
        # that belong to it.
        #
        # To achieve this the {Base#configure_interface_vlan} method is called
        # for every VLAN - can be called many times per interface
        #
        # Once that is done the prepare method is used to populate the VLAN
        # and Interfaces and finally the built resources are fetched using
        # {#to_puppet}
        #
        # There is a notion of an action to these methods, the action can be
        # either :add or :remove to facilate teardown
        class Rack < Base
          def portchannel_resource(number, fcoe=false, remove=false, vlt_peer=false, ungroup=false, mtu="12000")
            number = number.to_s

            if has_resource?("force10_portchannel", number)
              raise("force10_portchannel[%s] is already being managed on %s" % [number, type.puppet_certname])
            else
              port_resources["force10_portchannel"] ||= {}
              port_resources["force10_portchannel"][number] = {
                "ensure"     => remove ? "absent" : "present",
                "portmode"   => "hybrid",
                "switchport" => "true",
                "shutdown"   => "false",
                "mtu"        => mtu,
                "ungroup"    => ungroup.to_s
              }

              port_resources["force10_portchannel"][number]["require"] = sequence if sequence
            end

            @sequence = "Force10_portchannel[%s]" % number

            nil
          end

          def mxl_interface_resource(interface, port_channel=nil)
            raise("Managing MXL interfaces for Uplinks on TOR switches are not supported")
          end

          # Creates interfaces resources for consumption by puppet
          #
          # @return [Hash]
          def to_puppet
            if port_resources["force10_interface"]
              port_resources["force10_interface"].keys.each do |interface|
                resource = port_resources["force10_interface"][interface]

                # the puppet type does not accept arrays for interfaces at the moment, so join them as csv and delete empty ones
                ["tagged_vlan", "untagged_vlan"].each do |prop|
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
          # {Base#configure_interface_vlan}
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
            populate_port_resources(action)
            populate_vlan_resources(action)

            !port_resources.empty?
          end

          # Contrust asm::force10 resources for a VLAN
          #
          # Interfaces added with {Base#configure_interface_vlan} have various
          # associated VLANs, this adds resources to manage those VLANs
          # to the {Base#port_resources} hash
          #
          # @param number [String, Fixnum] vlan number
          # @param [Hash] properties
          # @option properties [String] :vlan_name
          # @option properties [String] :vlan_desc
          # @option properties [String] :portchannel
          # @option properties [String] :tagged
          # @return [void]
          def vlan_resource(number, properties={:portchannel => ""})
            vlan = number.to_s

            port_resources["force10_vlan"] ||= {}

            unless port_resources["force10_vlan"][vlan]
              vlan_config = {
                "vlan_name" => properties.fetch(:vlan_name, "VLAN_%s" % vlan),
                "desc" => properties.fetch(:desc, "VLAN Created by ASM"),
                "before" => []
              }

              unless properties[:portchannel].empty?
                if properties[:tagged]
                  vlan_config["tagged_portchannel"] = properties[:portchannel]
                else
                  vlan_config["untagged_portchannel"] = properties[:portchannel]
                end
              end

              port_resources["force10_vlan"][vlan] = vlan_config
            end

            if (interfaces = interface_map.select {|i| i[:vlan] == vlan})
              interfaces.each do |interface|
                config = port_resources["force10_vlan"][vlan]
                before_name = "Force10_interface[%s]" % interface[:interface]
                config["before"] |= [before_name]
                unless interface[:portchannel].empty?
                  config["require"] ||= []
                  config["require"] |= ["Force10_portchannel[%s]" % interface[:portchannel]]
                end
              end
            end
          end

          # Find all the interfaces for a certain action and create VLANs
          #
          # Interfaces are made using {Base#configure_interface_vlan} and are
          # marked as add or remove.  This finds all previously made interfaces
          # for a given action and calls {#vlan_resource) for each to construct
          # the correct asm::force10 resources
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
        end
      end
    end
  end
end

require "asm/provider/switch/base"

module ASM
  class Provider
    class Switch
      # A provider to configure Force10 switches
      #
      # Force10 switches are broken down into many different models with different puppet
      # modules and completely different means of configuring vlans and interfaces between
      # them.
      #
      # To manage the complexity resulting from the wide range of Force10 switches this class
      # use something called creators to take care of interacting with the switches. See the
      # {ASM::Provider::Switch::Force10::Rack} and {ASM::Provider::Switch::Force10::Blade} classes
      # for examples
      class Force10 < Switch::Base
        puppet_type "force10"

        def self.handles_switch?(switch)
          !!(switch["refId"] =~ /^(dell_ftos|dell_iom)/)
        end

        def normalize_facts!
          super

          if facts["interfaces"].is_a?(Array)
            facts["interfaces"] = facts["interfaces"].map do |interface|
              # Some force10 switches like the S5000 has an interface fact showing all
              # tagged and untagged vlans etc and not just the list of interface names
              # this parses those cases if they appear to be a string matching that
              if interface.is_a?(String) && interface =~ /untagged_vlans/
                JSON.parse(interface)
              else
                interface
              end
            end
          end
        end

        def server_supported?(server)
          return true if (server.rack_server? || server.tower_server?) && rack_switch?

          return true if server.blade_server? && blade_switch?
          false
        end

        def load_switch_creator(creator)
          path = "asm/provider/switch/force10/%s" % creator
          logger.debug("Configuring %s using %s" % [type.puppet_certname, path])
          require path
        end

        def resource_creator!
          if rack_switch?
            load_switch_creator("rack")
            self.resource_creator = Rack.new(self)
          elsif blade_ioa_switch?
            load_switch_creator("blade_ioa")
            self.resource_creator = BladeIoa.new(self)
          elsif blade_mxl_switch?
            load_switch_creator("blade_mxl")
            self.resource_creator = BladeMxl.new(self)
          else
            raise("Do not know how to manage resources for switch %s with model %s, no suitable resource creator could be found" % [type.puppet_certname, model])
          end
        end

        def initialize_ports!
          resource_creator.initialize_ports!
        end

        def resource_creator
          @resource_creator ||= resource_creator!
        end

        def additional_resources
          resource_creator.to_puppet
        end

        # Creates a ioa_interface resource
        #
        # @note this should only be used in cases where the {#Base#configure_interface_fvlan} approach isn't used
        # @param interface [String] the interface name
        # @param tagged_vlans [Array<String>] list of VLANs tagged on this interface
        # @param untagged_vlans [Array<String>] list of VLANs untagged on this interface
        # @return [void]
        def ioa_interface_resource(interface, tagged_vlans, untagged_vlans)
          resource_creator.ioa_interface_resource(interface, tagged_vlans, untagged_vlans)
        end

        # Creates a port channel resource
        #
        # @param number [String,Fixnum] the port channel number to create
        # @param fcoe [Boolean] enables fip_snooping_fcf when true
        # @param remove [Boolean] sets ensure = absent when true
        # @param vlt_peer [Boolean] sets true = false when true it will configure vlt-peer-lag in switch
        # @return [void]
        # @raise [StandardError] when attempting to manage the same resource twice
        # @raise [StandardError] when attempting to manage unsupported switches
        def portchannel_resource(number, fcoe=false, remove=false, vlt_peer=false, ungroup=false)
          resource_creator.portchannel_resource(number, fcoe, remove, vlt_peer, ungroup)
        end

        # Creates a mxl vlan resource
        #
        # @param vlan [String,Fixnum] the vlan number to create
        # @param name [String] the vlan name
        # @param description [String] the vlan description
        # @param port_channels [Array<String>] list of tagged port channels
        # @param remove [Boolean] sets ensure = absent when true
        # @return [void]
        # @raise [StandardError] when attempting to manage the same resource twice
        # @raise [StandardError] when attempting to manage unsupported switches
        def mxl_vlan_resource(vlan, name, description, port_channels, remove=false)
          resource_creator.mxl_vlan_resource(vlan, name, description, port_channels, remove)
        end

        # Creates a MXL interface resource
        #
        # @param interface [String] the interface to manage
        # @param port_channel [String,Fixnum] the port channel it belongs to
        # @return [void]
        # @raise [StandardError] when attempting to manage the same resource twice
        # @raise [StandardError] when attempting to manage unsupported switches
        def mxl_interface_resource(interface, port_channel=nil)
          resource_creator.mxl_interface_resource(interface.gsub("TenGigabitEthernet", "Te"), port_channel)
        end

        # Configures a list of interfaces for quodmode
        #
        # Only 40 Gb interfaces can be part of a group, any non 40 Gb interfaces
        # listed when enable is true will be silently skipped and logged
        #
        # @param interfaces [Array,nil] list of interfaces, when nil will use the quad_port_interfaces fact
        # @param enable [Boolean] should it be enabled or not for quadmode
        # @param reboot [Boolean] should the last interface set reboot required
        # @return [String] the last resource made that can be used to sequence puppet requires on
        def configure_quadmode(interfaces, enable, reboot=true)
          resource_creator.configure_quadmode(interfaces, enable, reboot)
        end

        # Configures the switch for VLT or PMUX mode
        #
        # @param pmux [boolean] configure pmux mode
        # @param ethernet_mode [Boolean] for use in PMUX configurations
        # @param vlt_data [Hash] by default nil normally a hash of vlt settings
        # @return [void]
        # @raise [StandardError] when called multiple times
        def configure_iom_mode!(pmux, ethernet_mode, vlt_data=nil)
          resource_creator.configure_iom_mode!(pmux, ethernet_mode, vlt_data)

          process!(:skip_prepare => true)
        end

        # Configures the switch using the force10_settings hash found in the component
        #
        # @note this will reset the creator and run puppet, be careful when running this in something that should be a sequence
        # @param settings [Hash] the force10_settings hash from a component configuration
        # @return [void]
        # @raise [StandardError] when invalid settings are received
        def configure_force10_settings(settings)
          if settings.nil? || !settings.is_a?(Hash) || settings.empty?
            raise("Received invalid force10_settings for %s: %s" % [type.puppet_certname, settings.inspect])
          end

          resource_creator!

          resource_creator.configure_force10_settings(settings)

          process!(:skip_prepare => true)
        end

        # Configures each partition as per the template
        #
        # @param server [ASM::Type::Server]
        # @return [void]
        def provision_server_networking(server)
          server.configured_interfaces.each do |interface|
            provision_server_interface(server, interface)
          end
        end

        # Resets associated switch ports to defaults
        #
        # When resetting the ports they are configured to default VLANs
        # by setting tagged and untagged vlans to '1'
        #
        # @note depending on how asm::force10 teardown is built this might need to change to become creator specific
        # @param server [ASM::Type::Server]
        # @return [void]
        def teardown_server_networking(server)
          server.configured_interfaces.each do |interface|
            partition = interface.partitions.first

            next unless port = type.find_mac(partition["mac_address"], :server => server)

            logger.info("Resetting port %s / %s to untagged vlan 1 and no tagged vlans" % [server.puppet_certname, partition.fqdd])

            resource_creator.configure_interface_vlan(port, "1", false, true)
          end
        end

        # (see ASM::Type::Server#configure_server)
        def configure_server(server, staged=false)
          if !server.teardown?
            provision_server_networking(server)
          else
            teardown_server_networking(server)
          end

          process! unless staged
        end

        def rack_switch?
          refId.start_with?("dell_ftos")
        end

        def blade_switch?
          blade_ioa_switch? || blade_mxl_switch? ? true : false
        end

        def blade_ioa_switch?
          !!model.match(/Aggregator|IOA|PE-FN/)
        end

        def blade_mxl_switch?
          !!model.match(/MXL/)
        end

        def fcflexiom_switch?
          return false unless blade_switch?

          !facts["interfaces"].grep(/fc/).empty?
        end

        def san_switch?
          facts["switch_fc_mode"] == "Fabric-Services"
        end

        def npiv_switch?
          facts["switch_fc_mode"] == "NPG"
        end

        def find_portchannel(server, interface)
          partition = interface.partitions.first
          port = type.find_mac(partition.mac_address, :server => server)
          port_full = port.gsub("Te ", "TenGigabitEthernet ")

          portchannel = portchannel_members.find_all do |_, members|
            # We want to also ensure this port is in a portchannel alone
            members.include?(port_full) && members.size == 1
          end.flatten.first

          # If there's no portchannel, we need to create one. We choose the first
          # unused portchannel from 1 to 128
          portchannel ||= (1..128).find {|n| !portchannel_members[n.to_s]}.to_s
          raise("No portchannels available for LACP config") unless portchannel
          portchannel
        end
      end
    end
  end
end

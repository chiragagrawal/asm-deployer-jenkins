require "asm/provider/switch/base"

module ASM
  class Provider
    class Switch
      class Powerconnect < Switch::Base
        puppet_type "dell_powerconnect"

        def json_facts
          super + [
            "portchannelmap"
          ]
        end

        def self.handles_switch?(switch)
          switch["refId"].start_with?("dell_powerconnect")
        end

        def server_supported?(server)
          return true if server.rack_server? && rack_switch?
          false
        end

        def load_switch_creator
          path = "asm/provider/switch/powerconnect/rack.rb"
          logger.debug("Configure %s using %s" % [type.puppet_certname, path])
          require path
        end

        def resource_creator!
          load_switch_creator
          self.resource_creator = Rack.new(self)
        end

        def rack_switch?
          true
        end

        def blade_switch?
          false
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

        # Resets associated switch ports to defaults
        #
        # When resetting the ports they are configured to default VLANs
        # by setting not tagged vlans and "1" as the untagged vlan
        #
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

        # Configures each partition as per the template
        #
        # @param server [ASM::Type::Server]
        # @return [void]
        def provision_server_networking(server)
          server.configured_interfaces.each do |interface|
            provision_server_interface(server, interface)
          end
        end

        # Fairly similar to force10 due to similar facts in portchannelmap
        def find_portchannel(server, interface)
          partition = interface.partitions.first
          port = type.find_mac(partition.mac_address, :server => server)

          portchannel = facts["portchannelmap"].find_all do |_, members|
            # We want to also ensure this port is in a portchannel alone
            members.include?(port) && members.size == 1
          end.flatten.first

          # If there's no portchannel, we need to create one. We choose the first
          # unused portchannel from 1 to 128
          portchannel ||= (1..128).find {|n| !facts["portchannelmap"][n.to_s]}.to_s
          raise("No portchannels available for LACP config") unless portchannel
          # We just return the number of the channel just to have some
          # consistency with the other switch types
          portchannel.gsub("Po", "")
        end
      end
    end
  end
end

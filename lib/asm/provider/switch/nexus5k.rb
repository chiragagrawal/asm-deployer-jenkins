require "asm/provider/switch/base"

module ASM
  class Provider
    class Switch
      class Nexus5k < Switch::Base
        puppet_type "cisconexus5k"

        def json_facts
          super + [
            "vsan_member_info",
            "vsan_zoneset_info",
            "flogi_info",
            "fex_info",
            "fex",
            "features",
            "zone_member"
          ]
        end

        def self.handles_switch?(switch)
          switch["refId"].start_with?("cisconexus5k")
        end

        def find_mac(mac)
          if valid_mac?(mac)
            super
          elsif valid_wwpn?(mac)
            if (host_flogi = flogi(mac))
              host_flogi[0]
            end
          end
        end

        # Retrieves the FCoE Login Information for a WWPN
        #
        # @api private
        # @param wwpn [String] the wwpn to look for
        # @return [Array<String>, nil]
        def flogi(wwpn)
          facts["flogi_info"].find do |flogi|
            flogi[3] == wwpn.downcase
          end
        end

        # Retrieve the VSAN ID a WWPN belong to
        #
        # @api private
        # @param wwpn [String] the wwpn to look for
        # @return [String,nil] the VSAN ID
        def host_vsan(wwpn)
          host_flogi = flogi(wwpn)

          return nil unless host_flogi

          host_flogi[1]
        end

        # Retrieves the Zones a wwpn belongs to within a VSAN
        #
        # @param vsan_id [String] the VSAN ID
        # @param wwpn [String] the wwpn to look for
        # @return [Array<String>] list of zone names
        def host_vsan_zones(vsan_id, wwpn)
          return [] unless (vsan_zones = facts["zone_member"][vsan_id])

          host_zones = vsan_zones.select do |_, members|
            members.include?(wwpn.downcase)
          end

          host_zones.map do |zone, _|
            zone
          end
        end

        def active_fc_zone(wwpn=nil)
          return nil unless wwpn
          return nil unless (vsan_id = host_vsan(wwpn))

          active_set = facts["vsan_zoneset_info"].find do |_, vsan|
            vsan == vsan_id
          end

          active_set ? active_set[0] : nil
        end

        def fc_zones(wwpn=nil)
          unless wwpn
            return facts["zone_member"].map {|_, zones| zones.keys}.flatten.sort.uniq
          end

          return [] unless (vsan_id = host_vsan(wwpn))

          host_vsan_zones(vsan_id, wwpn)
        end

        def normalize_facts!
          super

          facts.keys.each do |fact|
            # Interface information is JSON encoded but there is no list of interfaces so this
            # looks for these JSON strings and parse just those
            if facts[fact].is_a?(String) && facts[fact] =~ /^{.+interface_name/
              parse_json_fact(fact)
            end
          end
        end

        def server_supported?(server)
          return true if server.rack_server? && rack_switch?
          false
        end

        def reset_port(_port, _vlan=nil)
          logger.warn("Resetting ports have not yet been implemented for %s" % type.puppet_certname)
        end

        def load_switch_creator
          path = "asm/provider/switch/nexus5k/rack.rb"
          logger.debug("Configuring %s using %s" % [type.puppet_certname, path])
          require path
        end

        def resource_creator!
          load_switch_creator
          self.resource_creator = Rack.new(self)
        end

        def npiv_switch?
          features.include?("npiv")
        end

        def npv_switch?
          features.include?("npv")
        end

        def san_switch?
          !npiv_switch?
        end

        def rack_switch?
          true
        end

        # (see ASM::Type::Server#configure_server)
        def configure_server(server, staged=false)
          if server.teardown?
            teardown_server_networking(server)
          else
            provision_server_networking(server)
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

            partition = interface.partitions.first
            next unless port = type.find_mac(partition.mac_address, :server => server)
            next unless server.fcoe?

            server.related_volumes.select {|v| v.provider_name == "compellent"}.each do |volume|
              active_zoneset = active_zoneset(volume)
              vsan = active_zoneset["vsan"] || []
              raise("Cannot configure FC on %s as a vsan coult not be found for volume %s" % [type.puppet_certname, volume.puppet_certname]) if vsan.empty?
              logger.info("Configuring %s connected to %s using VSAN %s" % [type.puppet_certname, volume.puppet_certname, vsan])
              resource_creator.configure_interface_vsan(port, vsan, server.teardown?)
            end
          end
        end

        # Finds the active zoneset for vsan
        #
        # Get the active zoneset for a vsan from controller ids for fc
        #
        # @example returned data
        #    {"vsan"=>[String], "active_zoneset"=>[String]}
        #
        # @note Only supported for Compellent
        # @param volume [ASM::Type::Volume]
        # @return [Hash]
        def active_zoneset(volume)
          raise("Cannot get the active zoneset for %s, only compellent volumes are supported" % volume.puppet_certname) unless volume.provider_name == "compellent"

          ASM::PrivateUtil.cisco_nexus_get_vsan_activezoneset(type.puppet_certname, volume.provider.controller_ids) || {}
        end

        # TODO: Support for LACP teaming
        def use_portchannel?(server, interface)
          false
        end
      end
    end
  end
end

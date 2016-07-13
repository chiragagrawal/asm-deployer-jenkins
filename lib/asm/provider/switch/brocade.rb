require "asm/provider/switch/base"

module ASM
  class Provider
    class Switch
      class Brocade < Base
        puppet_type "brocade::createzone"

        def self.handles_switch?(switch)
          !!(switch["refId"] =~ /^brocade_fos/)
        end

        def resource_creator!
          require "asm/provider/switch/brocade/generic"
          self.resource_creator = Generic.new(self)
        end

        # Determines the active zoneset for use when creating new zones
        #
        # When not set, like for a fresh switch, it will default to ASM_Zoneset
        #
        # @return [String]
        def active_zoneset
          active_fc_zone || "ASM_Zoneset"
        end

        # Determines the device alias for the associated storage unit
        #
        #
        # This calculates that by looking at a server, finding it's first
        # related volume and then digging into the brocade Nameserver fact
        # finding the zone that storage is on
        #
        # @note delegates to fault_domain method in the provider based on the provider type
        # @param server [Type::Server]
        # @return [String]
        # @raise [StandardError] when no related storage can be found
        def storage_alias(server)
          related_storage = server.related_volumes.first

          unless related_storage
            raise("Cannot find any related compellent unit for %s" % server.puppet_certname)
          end

          # only compellent,emc supported so provider access is fine public access on the type will be
          # added once more than it is supported
          related_storage.fault_domain(type)
        end

        def configure_server(server, staged)
          unless server.fc?
            logger.debug("Server %s requested configuration on %s but it is not a FC server, skipping" % [server.puppet_certname, type.puppet_certname])
            return
          end

          unless server.valid_fc_target?
            raise("Server %s is requesting FC config but it's not a valid FC target" % server.puppet_certname)
          end
          provision_server_networking(server)
          process! unless staged
        end

        # Configures the FC networking for a server
        #
        # @param server [Type::Server]
        # @return [void]
        # @raise [StandardError] when zones fail due to missing related volumes or incorrect cabling
        def provision_server_networking(server)
          logger.info("Configuring server %s SAN connectivity" % server.puppet_certname)

          storage_alias = storage_alias(server)
          zone_name = "ASM_%s" % server.cert2servicetag

          wwpns = server.fc_wwpns.select do |wwpn|
            find_mac(wwpn)
          end.join(";")

          logger.info("Adding zone %s for %s / %s" % [zone_name, server.puppet_certname, wwpns])

          resource_creator.createzone_resource(zone_name, storage_alias, wwpns, active_zoneset, server.teardown?)

          nil
        end

        def validate_network_config(server)
          Log.warn("Validating configuration of an unmanaged Brocade switch is not supported, skipping validation of %s" % server.puppet_certname)
          true
        end

        def json_facts
          super + [
            "Aliases_Members"
          ]
        end

        def rack_switch?
          true
        end

        def san_switch?
          true
        end

        def find_mac(mac)
          return nil unless facts && facts.include?("RemoteDeviceInfo")

          interface = facts["RemoteDeviceInfo"].find do |_, dets|
            dets["mac_address"].include?(mac.downcase)
          end

          interface ? interface.first : nil
        end

        def fc_zones(wwpn=nil)
          return facts["Zones"] unless wwpn

          facts["Zone_Members"].map do |zone, members|
            zone if members.map(&:downcase).include?(wwpn.downcase)
          end.compact
        end

        def normalize_facts!
          super

          if facts.include?("RemoteDeviceInfo ") && !facts["RemoteDeviceInfo "].empty?
            facts["RemoteDeviceInfo"] = facts.delete("RemoteDeviceInfo ")
          end

          # when blades connect through an IOA the one port will see many
          # connected servers but they are \n\t seperates are they are direct
          # from the switch output.  This just turns that into a array
          facts["RemoteDeviceInfo"].each do |_, remote|
            remote["mac_address"] = remote["mac_address"].split("\n\t") unless remote["mac_address"].is_a?(Array)
          end

          facts["Zones"] = facts.fetch("Zones", "").split(/,\s+/).sort.uniq unless facts.fetch("Zones", "").is_a?(Array)
          facts["Alias"] = facts.fetch("Alias", "").split(/,\s+/).sort.uniq unless facts.fetch("Alias", "").is_a?(Array)

          Array(facts["Alias"]).each do |switch_alias|
            parse_json_fact(switch_alias)
          end
        end
      end
    end
  end
end

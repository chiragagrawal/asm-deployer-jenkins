module ASM
  class Provider
    class Switch
      class Brocade
        class Generic
          attr_reader :logger
          attr_accessor :type, :provider, :sequence

          def initialize(provider, resources={})
            @resources = resources
            @provider = provider
            @logger = provider.logger
            @type = provider.type
            @sequence = nil
          end

          def reset!(start_sequence=nil)
            @resources.clear
            @sequence = start_sequence
          end

          def port_resources
            @resources
          end

          def to_puppet
            port_resources
          end

          # Adds a brocade::createzone resource to the list of additional resources
          #
          # By convention we plug a machine only once into any given switch so there may not be
          # dupes on name - where name is unique per Server and not Port
          #
          # @param name [String] the zone name
          # @param storage_alias [String] the storage alias to use, usually the fault domain for the compellent
          # @param wwpns [String] server WWPNs to add to the zone, can be ";" seperated list
          # @param zoneset [String] the active zone set
          # @param action_teardown [Boolean] serves to decide to remove or add zone.
          # @return [void]
          # @raise [StandardError] when a zone have already been created for a specific name or an invalid WWPN is given
          def createzone_resource(name, storage_alias, wwpns, zoneset, action_teardown)
            valid = wwpns.split(";").map { |wwpn| provider.valid_wwpn?(wwpn) }.all?

            raise("Invalid WWPN %s for zone %s on %s" % [wwpns, name, type.puppet_certname]) unless valid

            if action_teardown
              ensure_val = "absent"
            else
              ensure_val = "present"
            end
            port_resources["brocade::createzone"] ||= {}
            if port_resources["brocade::createzone"].include?(name)
              raise("Already have a brocade::createzone resources for %s on %s" % [name, type.puppet_certname])
            end

            port_resources["brocade::createzone"][name] = {
              "storage_alias" => storage_alias,
              "server_wwn" => wwpns,
              "zoneset" => zoneset,
              "ensure" => ensure_val
            }

            # the brocade::createzone have multiple resoures and brocade switches
            # have limitation in the number of ssh connections, grouping these correctly
            # improves the ssh session utilisation and avoid very hard to debug issues
            port_resources["brocade::createzone"][name]["require"] = sequence if sequence
            self.sequence = "Brocade::Createzone[%s]" % name
          end

          def prepare(action)
            action == :add
          end

          def configure_interface_vlan(*args)
            # only here to make Switch::Base happy
          end

          def initialize_ports!
            logger.warn("Initializing ports on a Brocade is not supported")
          end
        end
      end
    end
  end
end

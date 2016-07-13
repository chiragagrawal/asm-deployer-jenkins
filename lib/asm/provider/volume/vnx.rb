require "asm/private_util"
require "asm/cipher"

module ASM
  class Provider
    class Volume
      # Evaluate if we need same or separate classes for iSCSi, FC and FCoE implementation
      class Vnx < Provider::Base
        puppet_type "asm::volume::vnx"

        property :size,         :default => "100g",         :validation => /^\d+(k|m|t|KB|MB|GB|TB)$/i
        property :pool,         :default => "Pool 0",       :validation => String
        property :type,         :default => "nonthin",      :validation => String
        property :ensure,       :default => "present",      :validation => ["present", "absent"]
        property :folder,       :default => "asm",          :validation => String
        property :host_name,    :default => "",             :validation => String
        property :sgname,       :default => "",             :validation => String

        property :configuresan, :default => true,           :validation => :boolean, :tag => :extra
        property :porttype,     :default => "FibreChannel", :validation => String, :tag => :extra
        property :add_to_sdrs,  :default => "",             :validation => String, :tag => :extra

        def json_facts
          super + [
            "controllers_data",
            "disk_info_data",
            "disk_pools_data",
            "hbainfo_data",
            "pool_list",
            "pools_data",
            "raid_groups_data",
            "softwares_data",
            "storage_groups",
            "initiators"
          ]
        end

        # Gets the controllers from the storage facts
        #
        # Controllers contains information about wwpn in Hba_info
        #
        # @return [Array]
        # @raise [StandardError] when no related controllers_data are present
        def controllers
          facts["controllers_data"]["controllers"] || raise("No controllers found for %s" % type.puppet_certname)
        end

        # Checks if wwpn exists in storage facts
        #
        # Each controller contains HBA info that has ports that are connected to storage
        # tries to match the wwpn in HBAinfo
        #
        # @param wwpn [String] wwpn port value for the port
        # @return [String]
        def has_wwpn?(wwpn)
          logger.debug("Checking if wwpn %s is known on the HBA of %s" % [wwpn, type.puppet_certname])

          controllers.map { |c| return true if c["HBAInfo"] && c["HBAInfo"].include?(wwpn.upcase) }

          false
        end

        def fc?
          porttype == "FibreChannel" && configuresan
        end

        # Finds the device_alias for the storage
        #
        # Storage Alias should be configured manually in the brocade for the wwpn ports
        # tries to match with the emc storage ports and brocade_facts that contain wwpn to get device alias
        #
        # @note gets the first device_alias if there are multiple names to the same wwpn
        # @param switch [Type::Switch] facts data of brocade switch
        # @return [String]
        # @raise [StandardError] when no ports are found in the switch
        def fault_domain(switch)
          logger.debug("Trying to find ports that are related to volume %s on switch %s" % [type.puppet_certname, switch.puppet_certname])

          storage_ports = switch.nameserver_info.select do |_, info|
            info["port_info"].match(/CLARiiON.*SP\w.*FC/) && has_wwpn?(info["remote_wwpn"])
          end

          logger.debug("Found %d storage_ports entries for %s on switch %s" % [storage_ports.size, type.puppet_certname, switch.puppet_certname])

          if storage_ports.empty?
            raise("No storage alias found on switch %s for volume %s" % [switch.puppet_certname, type.puppet_certname])
          end

          storage_ports.sort_by { |_, v| v[:device_allias] }.first[1]["device_alias"].strip
        end

        def datastore_require(server)
          ["Asm::Fcdatastore[%s:%s]" % [server.hostname, uuid]]
        end

        def remove_server_from_volume!(server)
          server_object = vnx_server_resource(server)
          type.process_generic(type.puppet_certname, server_object, "apply", true, nil, type.guid)
        end

        def clean_access_rights!
          resources = {}

          type.related_servers.select(&:teardown?).each do |server|
            logger.warn("Cleaning access rights for server %s from volume %s" % [server.puppet_certname, type.puppet_certname])
            resource = vnx_server_resource(server)
            resources["asm::volume::vnx"] ||= {}
            resources["asm::volume::vnx"].merge!(resource["asm::volume::vnx"])
          end

          unless resources.empty?
            type.process_generic(type.puppet_certname, resources, "apply", true, nil, type.guid)
          end
        end

        # @todo port from ServiceDeployment
        def vnx_storage_group_info
          ASM::PrivateUtil.get_vnx_storage_group_info(type.puppet_certname)
        end

        # @todo port from ServiceDeployment
        def vnx_lun_id
          ASM::PrivateUtil.get_vnx_lun_id(type.puppet_certname, type.name, logger)
        end

        # @todo port from ServiceDeployment
        def host_lun_info(server)
          type.deployment.host_lun_info("ASM-#{server.deployment.id}", vnx_storage_group_info, vnx_lun_id)
        end

        def esx_datastore(server, _cluster, volume_ensure)
          datastore_name = "%s:%s" % [server.hostip, @uuid]

          unless debug?
            host_lun_number = host_lun_info(server)
            raise("Unable to find VNX LUN #{type.name} on the storage ") unless host_lun_number
          end

          {"esx_datastore" =>
            {datastore_name =>
              {"ensure" => volume_ensure,
               "datastore" => @uuid,
               "type" => "vmfs",
               "lun" => host_lun_number,
               "transport" => "Transport[vcenter]"
              }
            }
          }
        end

        def vnx_server_resource(server)
          sg_name = "ASM-#{type.deployment.id}"

          {"asm::volume::vnx" =>
            {sg_name =>
              {"ensure"       => "absent",
               "sgname"       => sg_name,
               "host_name"    => server.hostname
              }
            }
          }
        end
      end
    end
  end
end

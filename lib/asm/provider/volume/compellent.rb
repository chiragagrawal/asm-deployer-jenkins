require "asm/private_util"
require "asm/cipher"

module ASM
  class Provider
    class Volume
      # Evaluate if we need same or separate classes for iSCSi, FC and FCoE implementation
      class Compellent < Provider::Base
        puppet_type "asm::volume::compellent"

        property :size,            :default => "100g",             :validation => /^\d+(k|m|t|KB|MB|GB|TB)$/i
        property :boot,            :default => "false",            :validation => :boolean
        property :volumefolder,    :default => "",                 :validation => String
        property :purge,           :default => "yes",              :validation => ["yes", "no"]
        property :volume_notes,    :default => "",                 :validation => String
        property :server_notes,    :default => "",                 :validation => String
        property :replayprofile,   :default => "Sample",           :validation => String
        property :storageprofile,  :default => "Low Priority",     :validation => String
        property :servername,      :default => "",                 :validation => String
        property :operatingsystem, :default => "VMWare ESX 5.1",   :validation => String
        property :serverfolder,    :default => "",                 :validation => String
        property :wwn,             :default => "",                 :validation => String
        property :porttype,        :default => "FibreChannel",     :validation => String
        property :manual,          :default => "false",            :validation => :boolean
        property :force,           :default => "false",            :validation => :boolean
        property :readonly,        :default => "false",            :validation => :boolean
        property :singlepath,      :default => "false",            :validation => :boolean
        property :lun,             :default => "",                 :validation => String
        property :localport,       :default => "",                 :validation => String
        property :ensure,          :default => "present",          :validation => ["present", "absent"]

        property :configuresan,    :default => false,              :validation => :boolean, :tag => :extra
        property :add_to_sdrs,     :default => "",                 :validation => String,   :tag => :extra

        def json_facts
          super + [
            "controller_data",
            "diskfolder_data",
            "replayprofile_data",
            "server_data",
            "storageprofile_data",
            "system_data",
            "volume_data"
          ]
        end

        # Determines the device alias for the associated compellent unit
        #
        # Today we only support deployments with a single compellent unit
        # per deploy.  This determines the configured alias that the compellent
        # has on the brocade which maps to the redundant connections across
        # the brocade switches.  Compellents have multiple controllers and multiple
        # possible ports on each.  An alias represents a single name for a group
        # of ports.
        #
        # This calculates that by looking at a server, finding it's first
        # related volume and then digging into the brocade Nameserver fact
        # finding the zone that compellent is on
        #
        # @note ported from San_switch_information#get_fault_domain
        # @param switch [Type::Switch] Switch facts to compare with storage facts
        # @return [String]
        # @raise [StandardError] when no related compellent aliases can be found
        def fault_domain(switch)
          compellent_controllers = controllers_info.map do |info|
            info["ControllerIndex"]
          end.flatten.uniq

          port_info_matcher = Regexp.union(compellent_controllers)

          logger.debug("Attempting to find the fault domain based on compellent controller indexes %s from %s" %
                           [compellent_controllers, type.puppet_certname])

          compellent_ports = switch.nameserver_info.select do |_, info|
            if info["device_type"] == "NPIV Unknown(initiator/target)"
              info["port_info"].match(port_info_matcher) && info["port_info"].match(/compellent/i)
            end
          end

          logger.debug("Found %d nameserver entries for %s: %s" %
                           [compellent_ports.size, type.puppet_certname, compellent_ports.keys])

          if compellent_ports.empty?
            raise("Could not determine the fault domain for compellent %s" % type.puppet_certname)
          end

          # when compellent units are incorrectly cabled, like perhaps connected
          # twice to the same switch and on different aliases then sorting it here
          # by the nsid will ensure we get consistant results.  This is not technically
          # supported or the right cable setup etc, but we've found this in one of our
          # environments, so best handle that correctly
          compellent_ports = compellent_ports.to_a.sort_by { |p| p[0] }

          compellent_ports[0][1]["device_alias"].strip
        end

        # Parse the controller info facts into a more usable format
        #
        # There are facts like controller_1_ControllerIndex and controller_1_Name
        # this will parse those and return hashes made up of just the names
        #
        # @note Ported from ASM::PrivateUtil#find_compellent_controller_info
        #       see {#controller_ids} for a backward compatible version
        # @return [Array<Hash>]
        def controllers_info
          controller_count = facts.keys.grep(/controller_\d+_ControllerIndex/).size

          (1..controller_count).to_a.map do |idx|
            Hash[facts.keys.grep(/^controller_#{idx}/).map do |key|
              [$1, facts[key]] if key =~ /^controller_\d+_(.+)/
            end.compact]
          end
        end

        # Find related compellent controller ids
        #
        # @example returned data
        #
        #    {'controller1' => 'controller index', 'controller2' => 'controller index'}
        #
        # @note backward compatible implimentation of PrivateUtil#find_compellent_controller_info using this
        #       for anything except compatibility with stuff already in PrivateUtil is strongly discouraged
        # @return [Hash]
        def controller_ids
          Hash[controllers_info.each_with_index.map do |controller, idx|
            [
              "controller%d" % [idx + 1],
              controller["ControllerIndex"]
            ]
          end]
        end

        def fc?
          porttype == "FibreChannel" && configuresan
        end

        # @todo the old code short circuited the thing and only proccessed
        #       the first server object from the first related volume, this might
        #       be fine but I dont know how we'll get the same short circuit in here
        #       as the loop is happening in the Provider::Server#clean_related_volumes!.
        #       Perhaps the remove_server_from_volume! api could consider return value
        #       to mean something to indicate the short circuit
        def remove_server_from_volume!(server)
          server_object = compellent_server_resource(server)
          type.process_generic(type.puppet_certname, server_object, "apply", true, nil, type.guid)
        end

        def clean_access_rights!
          resources = {}

          type.related_servers.select(&:teardown?).each do |server|
            logger.warn("Cleaning access rights for server %s from volume %s" % [server.puppet_certname, type.puppet_certname])

            resource = compellent_server_resource(server)

            resources["compellent_server"] ||= {}
            resources["compellent_server"].merge!(resource["compellent_server"])
          end

          unless resources.empty?
            type.process_generic(type.puppet_certname, resources, "apply", true, nil, type.guid)
          end
        end

        def esx_datastore(server, _cluster, volume_ensure)
          datastore_name = "%s:%s" % [server.hostip, @uuid]

          unless debug?
            device_id = ASM::PrivateUtil.find_compellent_volume_info(type.guid, @uuid, self["volumefolder"], logger)
            decrypt_password = ASM::Cipher.decrypt_string(server.admin_password)
            lun_id = type.deployment.get_compellent_lunid(server.hostip, "root", decrypt_password, device_id)
          end

          {"esx_datastore" =>
            {datastore_name =>
              {"ensure" => volume_ensure,
               "datastore" => @uuid,
               "type" => "vmfs",
               "lun" => lun_id,
               "transport" => "Transport[vcenter]"
              }
            }
          }
        end

        def compellent_server_resource(server)
          server_object_name = "ASM_%s" % server.cert2serial

          {"compellent_server" =>
            {server_object_name =>
              {"ensure"       => "absent",
               "serverfolder" => ""
              }
            }
          }
        end

        def datastore_require(server)
          if fc?
            ["Asm::Fcdatastore[%s:%s]" % [server.hostname, uuid]]
          else
            ASM::PrivateUtil.find_compellent_iscsi_ip(type.puppet_certname, logger).map do |ip|
              "Asm::Datastore[%s:%s:datastore_%s]" % [server.hostip, uuid, ip]
            end
          end
        end
      end
    end
  end
end

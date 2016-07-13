module ASM
  class Provider
    class Controller
      class Idrac < Provider::Base
        puppet_type "asm::idrac"

        property :servicetag,              :default => nil,                            :validation => /^[a-z0-9]{7}$/i
        property :nfsipaddress,            :default => nil,                            :validation => :ipaddress
        property :model,                   :default => nil,                            :validation => String
        property :nfssharepath,            :default => "/var/nfs/idrac_config_xml",    :validation => String
        property :target_boot_device,      :default => nil,                            :validation => String
        property :enable_npar,             :default => false,                          :validation => :boolean
        property :config_xml,              :default => nil,                            :validation => String
        property :raid_configuration,      :default => {},                             :validation => Hash
        property :network_configuration,   :default => {},                             :validation => Hash
        property :bios_settings,           :default => {},                             :validation => Hash
        property :server_pool,             :default => nil,                            :validation => String
        property :target_ip,               :default => nil,                            :validation => :ipaddress
        property :target_iscsi,            :default => nil,                            :validation => String
        property :force_reboot,            :default => false,                          :validation => :boolean
        property :ensure,                  :default => "present",                      :validation => ["present", "absent", "teardown"]

        def configure_hook
          configure_force_reboot
        end

        def configure_force_reboot
          if type.service
            self.force_reboot = !type.service.retry?
          else
            logger.warn("Service is not set for %s, cannot determine force_reboot value" % type.puppet_certname)
          end
        end

        # Determines if a server is supported by iDRAC
        #
        # At the moment this only checks if the certname matches a Dell one
        # which is not enough as some Dell servers do not have iDRAC but we
        # do not currently have a way to check this
        #
        # @return [Boolean]
        def server_supported?(server)
          Util.dell_cert?(server.puppet_certname)
        end

        # (see Type::Controller#configure_for_server)
        def configure_for_server(server)
          unless network_config = server.network_config
            logger.warn("Could not configure iDRAC %s for server %s without network configuration for the server" % [type.puppet_certname, server.puppet_certname])
            return false
          end

          unless debug?
            unless server.device_config
              logger.warn("Could not configure iDRAC %s for server %s without device configuration for the server" % [type.puppet_certname, server.puppet_certname])
              return false
            end
          end

          self[:network_configuration] = network_config.to_hash
          self[:servicetag] = server.cert2servicetag
          self[:model] = server.model.split(" ").last.downcase
          self[:bios_settings].merge!(server.bios_settings)

          @uuid = server.uuid

          true
        end
      end
    end
  end
end

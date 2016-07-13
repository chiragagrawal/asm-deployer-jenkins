module ASM
  class Provider
    class Volume
      # Provider that is capable of handling basic creation and destruction of Equallogic
      # volumes based on the +asm::volume::equallogic+ puppet class
      class Equallogic < Provider::Base
        puppet_type "asm::volume::equallogic"

        property :size,              :default => nil,        :validation => /\d+(m|g|t|GB|MB|TB)/
        property :ensure,            :default => "present",  :validation => ["present", "absent"]
        property :auth_ensure,       :default => "present",  :validation => ["present", "absent"]
        property :thinprovision,     :default => "enable",   :validation => ["enable", "disable"]
        property :snapreserve,       :default => "100%",     :validation => /\d*%/
        property :thinminreserve,    :default => "10%",      :validation => /\d*%/
        property :thingrowthwarn,    :default => "60%",      :validation => /\d*%/
        property :thingrowthmax,     :default => "100%",     :validation => /\d*%/
        property :thinwarnsoftthres, :default => "60%",      :validation => /\d*%/
        property :thinwarnhardthres, :default => "90%",      :validation => /\d*%/
        property :multihostaccess,   :default => "enable",   :validation => ["enable", "disable"]
        property :decrypt,           :default => false,      :validation => :boolean
        property :poolname,          :default => "default",  :validation => /^\w+$/
        property :passwd,            :default => nil,        :validation => String
        property :iqnorip,           :default => nil,        :validation => String
        property :auth_type,         :default => nil,        :validation => String
        property :chap_user_name,    :default => nil,        :validation => String

        property :add_to_sdrs,       :default => "",         :validation => String, :tag => :extra

        def fc?
          false
        end

        def clean_access_rights!; end

        def remove_server_from_volume!(_server)
          # TODO: This is logic that should probably move into the provider
          #       but as it's in ServiceDeployment it's probably used in builds too
          if !debug?
            type.deployment.process_storage(type.component)
          else
            logger.info("Would have processed server using ServiceDeployment#process_storage in remove_server_from_volume!")
          end
        end

        def esx_datastore(server, _cluster, volume_ensure)
          datastore_name = "%s:%s" % [server.hostip, @uuid]

          {"esx_datastore" =>
            {datastore_name =>
              {"ensure" => volume_ensure,
               "datastore" => @uuid,
               "type" => "vmfs",
               "target_iqn" => ASM::PrivateUtil.get_eql_volume_iqn(type.guid, @uuid),
               "transport" => "Transport[vcenter]"
              }
            }
          }
        end

        def datastore_require(server)
          target_ip = ASM::PrivateUtil.find_equallogic_iscsi_ip(type.puppet_certname)
          ["Asm::Datastore[%s:%s:datastore_%s]" % [server.hostip, uuid, target_ip]]
        end
      end
    end
  end
end

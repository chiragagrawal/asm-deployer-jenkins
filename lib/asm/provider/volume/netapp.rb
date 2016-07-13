module ASM
  class Provider
    class Volume
      # Provider that is capable of handling basic creation and destruction of Equallogic
      # volumes based on the +asm::volume::equallogic+ puppet class
      class Netapp < Provider::Base
        puppet_type "netapp::create_nfs_export"
        puppet_run_type "device"

        DEFAULT_SNAP_SCHED = {"minutes" => 0, "hours" => 0, "days" => 0, "weeks" => 0, "which-hours" => 0, "which-minutes" => 0}.freeze
        DEFAULT_OPTIONS = {"convert_ucode" => "on", "no_atime_update" => "on", "try_first" => "volume_grow"}.freeze

        property :size,              :default => nil,                :validation => /^\d+(k|g|m|t|KB|GB|MB|TB)$/
        property :ensure,            :default => "present",          :validation => ["present", "absent"]
        property :aggr,              :default => "aggr1",            :validation => String
        property :spaceres,          :default => "none",             :validation => ["none", "file", "volume"]
        property :snapresv,          :default => 0,                  :validation => String
        property :autoincrement,     :default => true,               :validation => :boolean
        property :persistent,        :default => true,               :validation => :boolean
        property :readonly,          :default => "",                 :validation => Object       # string or array :(
        property :readwrite,         :default => ["all_hosts"],      :validation => Object       # string or array :(
        property :snapschedule,      :default => DEFAULT_SNAP_SCHED, :validation => Hash
        property :options,           :default => DEFAULT_OPTIONS,    :validation => Hash

        property :add_to_sdrs,       :default => "",                 :validation => String, :tag => :extra

        def configure_hook
          self[:size] ||= volume_bytes_formatter(configured_volume_size)
        end

        # Retrieves the current volume size from facter
        #
        # @return [Float] the configured volume size as reported by facts
        def configured_volume_size
          Float(volume_info["size-total"])
        end

        # @todo providers should always have facts like switches does with JSON fact support as default
        def volume_info
          ASM::PrivateUtil.find_netapp_volume_info(type.guid, @uuid, logger)
        end

        def size_update_munger(old, new)
          return new if new.nil?

          new.gsub(/KB/, "k").gsub(/GB/, "g").gsub(/MB/, "m").gsub(/TB/, "t")
        end

        # Formats volume sizes for use by the size parameter
        #
        # @param bytes [String,Fixnum,Float] bytes to format
        # @return [String] the formatted string
        # @raise [StandardError] when a invalid number is received
        def volume_bytes_formatter(bytes)
          bytes = Float(bytes)

          [[3, "g"], [2, "m"], [1, "k"]].each do |multiplier, unit|
            if bytes >= 1024**multiplier
              return "%d%s" % [bytes / 1024**multiplier, unit]
            end
          end

          raise("Invalid volume size received, has to be numeric and above 1024")
        end

        def fc?
          false
        end

        def cluster_supported?(cluster)
          cluster.provider_path == "cluster/vmware"
        end

        def clean_access_rights!; end

        def remove_server_from_volume!(server)
          logger.warn("Removing access for server %s from NetApp volume %s has not been implemented" % [server.puppet_certname, type.puppet_certname])
        end

        def esx_datastore(server, cluster, volume_ensure)
          dc_name = cluster.provider.datacenter
          cluster_name = cluster.provider.cluster

          path = "/%s/%s/" % [dc_name, cluster_name]
          datastore_name = "%s:%s" % [server.hostip, @uuid]

          {"esx_datastore" =>
            {datastore_name =>
              {"ensure" => volume_ensure,
               "path" => path,
               "type" => "nfs",
               "transport" => "Transport[vcenter]"
              }
            }
          }
        end

        def datastore_require(server)
          ["Asm::Nfsdatastore[%s:%s]" % [server.hostname, uuid]]
        end
      end
    end
  end
end

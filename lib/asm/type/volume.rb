require "asm/type"

module ASM
  class Type
    # A type that represents a volume to ASM
    #
    # For a worked example of a provider for this type see the {ASM::Provider::Volume::Equallogic}
    # class
    class Volume < Base
      # Determines if the storage requires fibre channel to be configured
      #
      # @return [Boolean]
      def fc?
        provider.fc?
      end

      # Removes the access rights for a server from a volume
      #
      # Typically this will be called from a server provider that is processing
      # a teardown.
      #
      # For example {Type::Server#clean_related_volumes!} will be called during server
      # teardown which would typically find all related volumes a server has mounted
      # and then ask those volumes to remove the access rules for the server being
      # torn down
      #
      # @note This method is required to exist on all Volume providers
      # @return [void]
      # @raise [StandardError] when the puppet run fails for any reason
      def remove_server_from_volume!(server)
        delegate(provider, :remove_server_from_volume!, server)
      end

      # Remove associated access rights for a volume
      #
      # When removing a volume there could be associated servers and some of them might not
      # be torn down so they'll be left with stale access, this method should be used to clean
      # that up
      #
      # Generally this would be a noop as access rights go away when the volume gets removed
      # but that does not seem to be the case for Compellent at least so this should be called
      # on teardown flow
      #
      # @note This method is required to exist on all Volume providers
      def clean_access_rights!
        delegate(provider, :clean_access_rights!)
      end

      # Construct a esx_datastore resource for volumes that support ESX
      #
      # When a particular volume provider can be used in ESX a esx_datastore resource
      # needs to be created that is specific to the volume hardware
      #
      # @return [Hash] a Puppet esx_datastore resource
      # @raise [StandardError] when a volume does not support ESX Clusters
      def esx_datastore(server, cluster, volume_ensure)
        delegate(provider, :esx_datastore, server, cluster, volume_ensure)
      end

      # Determines the device alias for the associated storage unit
      #
      # Today we only support deployments with a single compellent or vnx unit
      # per deploy.  This determines the configured alias that the compellent or vnx storage
      # has on the brocade which maps to the redundant connections across
      # the brocade switches.
      #
      # This calculates that by looking at a server, finding it's first
      # related volume and then digging into the brocade Nameserver fact
      # finding the zone that storage is on
      #
      # @note ported from San_switch_information#get_fault_domain
      # @param switch [Type::Switch] Switch facts to compare with storage facts
      # @return [String]
      # @raise [StandardError] when no related compellent aliases can be found
      def fault_domain(switch)
        delegate(provider, :fault_domain, switch)
      end

      # Leave any associated clusters
      #
      # When a volume belongs to a cluster get the related cluster to evict the volume
      # how that cluster does it is up to the cluster.
      #
      # For example in the case of vmware clusters every server needs to have associated
      # esx_datastore resources created and removed from them but that only applies to vmware
      # other clusters would have their own way to do this.  In the case of vmware the cluster
      # will use the esx_datastore method in this provider to construct the Equallogic specific
      # hash structure
      #
      # @note for now this seems generic and not hardware specific, might move to providers in future
      # @return [void]
      def leave_cluster!
        if cluster = related_cluster
          if !cluster.teardown?
            cluster.evict_volume!(self)
          else
            logger.debug("Volume %s skipping cluster eviction as the %s cluster is also being torn down" % [puppet_certname, cluster.puppet_certname])
          end
        else
          logger.debug("Did not find any cluster associated with volume %s" % puppet_certname)
        end
      end

      # Finds any related Clusters where a Volume is used
      #
      # Can return nil if no related resources are found
      #
      # @return [ASM::Type::Cluster]
      def related_cluster
        if server = related_server
          if cluster = server.related_cluster
            return cluster
          end
        end

        nil
      end

      # Get corresponding Datastore Resource require string
      #
      # @note This method is required to exist on all Volume providers
      # @param server [Type::Server] Server that datastore will exist on
      # @return [Array<String>]
      def datastore_require(server)
        delegate(provider, :datastore_require, server)
      end
    end
  end
end

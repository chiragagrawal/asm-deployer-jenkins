require "asm/type"

module ASM
  class Type
    class Cluster < Base
      # Evicts a server from the cluster
      #
      # Typically when a server that belongs to a cluster gets torn down
      # it will need to remove itself from any related cluster. This method
      # is a helper to facilitate that
      #
      # @api public
      # @raise [StandardError] when the server can not be evicted
      # @return [void]
      def evict_server!(server)
        delegate(provider, :evict_server!, server)
      end

      # Remove distributed switch information from the server
      #
      # @param server [ASM::Type::Server] the server to remove from the cluster
      # @return [void]
      def evict_vds!(server)
        delegate(provider, :evict_vds!, server)
      end

      # Remove Virtual SAN from server
      #
      # @param server [ASM::Type::Server] the server to remove from the cluster and nil when all servers needs to be removed from cluster
      # @return [void]
      def evict_vsan!(server=nil)
        delegate(provider, :evict_vsan!, server)
      end

      # Evicts a volume from the cluster
      #
      # Typically when a volume that belongs to a cluster gets torn down
      # it will need to remove itself from any related cluster.  This method
      # is a helper to facilitate that
      #
      # @api public
      # @raise [StandardError] when the volume can not be evicted
      # @return [void]
      def evict_volume!(volume)
        delegate(provider, :evict_volume!, volume)
      end

      # Return related volumes
      #
      # Volumes are not directly related to clusters so this will get the related_servers,
      # the the related volumes
      #
      # @return [Array<ASM::Type::Volume>]
      def related_volumes
        related_servers.map(&:related_volumes).flatten.uniq
      end
    end
  end
end

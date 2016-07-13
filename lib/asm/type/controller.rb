require "asm/type"

module ASM
  class Type
    # Type to handle Lifecycle Controllers like iDRAC
    class Controller < Base
      # Configures the controller resource for a given server
      #
      # This will do things like configure the network properties
      # of the Controller based on those found for the server, this
      # might be properties like Service Tag for example
      #
      # @return [Boolean] if configuration was successfull
      # @raise [StandardError] if the server is not supported by this controller
      def configure_for_server(server)
        unless server.supports_resource?(self)
          raise("Cannot configure the controller %s using Server %s as it's not one that support supported by it" % [provider_path, server.puppet_certname])
        end

        delegate(provider, :configure_for_server, server)
      end
    end
  end
end

require "asm/type"

module ASM
  class Type
    class Configuration < Base
      # Configures the networking of the switch using the desired configuration
      #
      # This will potentially do multiple puppet runs, first to set the switch IOM mode
      # and then one to configure quad ports, port channels and vlans
      #
      # @return [void]
      # @raise [StandardError] when a config file is provided, then {#configure_force10_settings!} should be used instead
      def configure_networking!
        delegate(provider, :configure_networking!)
      end

      # Configures the related switch based on the force10_settings in the component
      #
      # @return [Boolean] when true the switch was configured with a config file and further work is not needed
      def configure_force10_settings!
        delegate(provider, :configure_force10_settings!)
      end
    end
  end
end

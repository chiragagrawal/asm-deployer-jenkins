require "asm/type"

module ASM
  class Type
    class Application < Base
      def self.provider_name(resource_type_name)
        # ensures the providers were all loaded from disk
        Type.providers

        "Puppet"
      end
    end
  end
end

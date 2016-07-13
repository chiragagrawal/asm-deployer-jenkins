require "asm/type"

module ASM
  class Type
    class Virtualmachine < Base
      def agent_certname
        provider.agent_certname
      end
    end
  end
end

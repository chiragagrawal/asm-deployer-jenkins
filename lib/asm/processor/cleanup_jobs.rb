require 'asm/private_util'

module ASM
  module Processor
    class Cleanup_jobs

      def initialize(options = {})
        @options = options
        @timeout = false
      end

      def run
        ASM::PrivateUtil.clean_old_file('/opt/Dell/ASM/deployments/serverdata')
      end

      def on_timeout
        @timeout = true
      end

    end
  end
end

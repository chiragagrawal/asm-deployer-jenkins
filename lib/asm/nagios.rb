module ASM
  module Nagios
    OK = 0
    WARNING = 1
    CRITICAL = 2
    UNKNOWN = 3

    # Simple class to encapsulate the nagios code and message together as a pair ( 2 element Array )
    # Compatible with array representations ordered as [code,message]
    #
    class Status
      # @return [OK,WARNING,CRITICAL,UNKNOWN] the Nagios status code
      attr_reader :code
      # @return [String] the Nagios status message
      attr_reader :message

      # @param code [OK,WARNING,CRITICAL,UNKNOWN] the Nagios status code
      # @param message [String] the Nagios status message
      def initialize(code, message)
        @code = code
        @message = message
      end

      # Explicit cast to 2 element Array
      #
      # @return [[NAGIOS_CODE, String]]
      def to_a
        [@code, @message]
      end

      # Implicit cast to 2 element Array
      #
      # @return [[NAGIOS_CODE, String]]
      def to_ary
        [@code, @message]
      end

      # Comparison operator compatible with Status or 2 element Array.
      #
      # When comparing a Status with an Array the array ordering must be [NAGIOS_CODE,String]
      #
      # @param other [Status, [NAGIOS_CODE, String]]
      # @return [Boolean]
      def ==(other)
        [@code, @message] == other
      end

      # Select the most severe nagios status from a list.
      #
      # The list may include nil which is pruned, and if no status is remaining, assume OK
      #
      # @param codes [Array<OK,WARNING,CRITICAL,UNKNOWN,nil>]
      # @return [OK,WARNING,CRITICAL,UNKNOWN]
      def self.worst_case(*codes)
        codes.flatten!
        codes.compact!
        codes.empty? ? Nagios::OK : codes.max
      end
    end
  end
end

module ASM
  class RuleEngine
    class Result
      attr_accessor :name, :error, :out, :end_time
      attr_reader :rule, :start_time

      # @param rule [RuleEngine::Rule]
      def initialize(rule)
        @name = rule.name
        @rule = rule
        @error = nil
        @out = nil
        @start_time = Time.now
        @end_time = @start_time
      end

      # @note used in testing only
      def stub_start_time_for_tests(time)
        @start_time = time
      end

      # The time it took the rule to run
      #
      # This only works when the processor sets {#end_time} which the normal one does
      #
      # @return [Float] seconds elapsed
      def elapsed_time
        @end_time - @start_time
      end

      def inspect
        "#<%s:%s rule: %s @ %s>" % [self.class, object_id, @rule.name, @rule.file]
      end

      def to_s
        inspect
      end
    end
  end
end

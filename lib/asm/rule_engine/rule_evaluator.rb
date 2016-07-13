module ASM
  class RuleEngine
    class RuleEvaluator
      attr_reader :state

      def initialize(rule, state)
        @__rule = rule
        @state = state
      end

      def evaluate!
        instance_eval(&@__rule.conditional_logic)
      end

      def method_missing(method, *_)
        if @__rule.conditions.include?(method)
          result = !!@__rule.conditions[method].call
          @__rule.logger.debug("Condition %s evaluated to %s in %s" % [method, result, @__rule])
          result
        else
          raise(NameError, "undefined local variable or method `#{method}'")
        end
      end
    end
  end
end

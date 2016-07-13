module ASM
  class RuleEngine
    class Rule
      attr_reader :conditions, :priority, :conditional_logic, :state, :concurrent
      attr_accessor :name, :logger, :file

      # @param logger [Logger]
      def initialize(logger=nil)
        @priority = 50
        @conditions = {}
        @run_on_fail = false
        @required_state = {}
        @state = nil
        @logger = logger || ASM.logger
        @concurrent = false

        execute { raise("Rule without a execute block were run") }
        execute_when { true }
      end

      # Builds a rule from a generator block
      #
      # You generally need this to create many instances of the
      # same basic logic but that varies only in some cases like
      # priority or some variable.  see {ASM::Service::RuleGen}
      #
      # @example build 2 rules with the same logic
      #
      #   ASM::RuleEngine.new_rule(:cluster_lane_teardown) do
      #     build_from_generator(&ASM::Service::RuleGen.configure_lane_teardown("CLUSTER", 40))
      #   end
      #
      #   ASM::RuleEngine.new_rule(:server_lane_teardown) do
      #     build_from_generator(&ASM::Service::RuleGen.configure_lane_teardown("SERVER", 50))
      #   end
      #
      # @return [void]
      def build_from_generator(&blk)
        instance_eval(&blk)
      end

      def inspect
        "#<%s:%s priority: %d name: %s @ %s>" % [self.class, object_id, priority, name, file]
      end

      def to_s
        inspect
      end

      # Sets a requirement for a item to exist on the state
      #
      # Validation is done using {ASM::ItemValidator}
      #
      # @param name [String, Symbol]
      # @param type a validation
      def require_state(name, type)
        @required_state[name] = type
      end

      # Resets this rule so it can be used again in a later run
      #
      # @return [void]
      def reset!
        @state = nil
      end

      # Should this rule be run even if earlier rules failed
      #
      # @return [Boolean]
      def run_on_fail?
        !!@run_on_fail
      end

      # Set this rule to run even if earlier rules failed
      def run_on_fail
        @run_on_fail = true
      end

      # Is this a rule that might be executed concurrently
      #
      # @return [Boolean]
      def concurrent?
        !!@concurrent
      end

      # Sets this rule to be one executed concurrently
      #
      # Concurrent rules cannot mutate state using {RuleEngine::State#add} etc
      #
      # @return [Boolean]
      def set_concurrent
        @concurrent = true
      end

      # Sets the priority this rule will run at
      #
      # @param pri [Fixnum] not larger than 999
      def set_priority(pri) # rubocop:disable Style/AccessorMethodName
        raise("Priority should be an integer less than 1000") unless pri.is_a?(Fixnum) && pri < 1000
        @priority = pri
      end

      # Creates a named condition that can be used in {#execute_when}
      #
      # @example create a condition and use it
      #
      #     condition(:blue_sky?) { state[:sky].color == :blue }
      #
      #     execute_when { blue_sky? }
      #
      # @param condition_name [Symbol]
      # @return [void]
      def condition(condition_name, &blk)
        raise("A block is required for a condition") unless block_given?
        @conditions[condition_name] = blk
      end

      # Defines what circumstances will result in a rule being run
      #
      # The block must return a boolean value or nil and may reference the state
      # directly or use named conditionals created with {#condition}
      #
      # @example create a condition and use it
      #
      #     condition(:blue_sky?) { state[:sky].color == :blue }
      #
      #     execute_when { blue_sky? }
      #
      # @return [void]
      def execute_when(&blk)
        raise("A block is required for the execute_when logic") unless block_given?
        @conditional_logic = blk
      end

      # Logic to be ran
      #
      # @example process a asm resource
      #
      #    condition(:teardown?) { state[:resource].teardown? }
      #    condition(:bfs?) { state[:resource].boot_from_san? }
      #
      #    execute_when { teardown? || bfs? }
      #
      #    execute do
      #      state[:resource].process!
      #    end
      #
      # @return [void]
      def execute(&blk)
        raise("A block is required for the execution logic") unless block_given?
        @execution_logic = blk
      end

      # Sets the state before running a rule
      #
      # @api private
      # @param state [RuleEngine::State]
      # @return [void]
      def set_state(state) # rubocop:disable Style/AccessorMethodName
        @state = state
      end

      # Checks the state against requirements
      #
      # Requirements are set using {#require_state}
      #
      # @return [Boolean] false when the state does not apply to this rule
      def check_state
        raise("Cannot check state when no state is set or supplied") unless state

        @required_state.each do |k, v|
          if state.has?(k)
            passed, fail_message = ItemValidator.validate!(state[k], v)

            unless passed
              @logger.debug("%s state has %s but it failed validation: %s" % [inspect, k, fail_message])
              return false
            end
          else
            @logger.debug("%s state does not contain item %s" % [inspect, k])
            return false
          end
        end

        true
      end

      # Checks the state and run the rule
      #
      # Will only run when {#run_on_fail} is set and or no failures were recorded
      # on the state
      #
      # @return [void]
      def run
        raise("Cannot run without a state set") unless state

        if !(@state.had_failures? && !@run_on_fail)
          check_state && @execution_logic.call
        else
          @logger.debug("Rule processing for rule %s skipped on failed state" % name)
        end
      end

      # Checks if the rule should run
      #
      # This include checking the state using {#check_state} and conditions set
      # with {#condition}
      #
      # @return [Boolean]
      def should_run?
        check_state && RuleEvaluator.new(self, state).evaluate!
      end

      # Runs the rule within state
      #
      # @param state [RuleEngine::State] the state to run in
      # @return [RuleEngine::Result]
      def process_state(state)
        set_state(state)
        result = nil

        if should_run?
          @logger.info("Running rule %s" % self)

          state.record_actor(self)
          result = Result.new(self)

          begin
            result.out = run
          rescue StandardError
            result.error = $!
            @logger.warn("Rule %s failed to run: %s" % [self, $!.to_s])
            state.had_failures!
          rescue Exception # rubocop:disable Lint/RescueException
            @logger.error("Encountered a critical unrecoverable error while processing %s: %s: %s" % [self, $!.class, $!.to_s])
            raise
          ensure
            result.end_time = Time.now
          end
        else
          @logger.debug("Skipping rule %s due to state checks" % self)
        end

        result
      ensure
        reset!
      end
    end
  end
end

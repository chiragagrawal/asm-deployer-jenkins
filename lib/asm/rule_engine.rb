require "asm/rule_engine/state"
require "asm/rule_engine/rule"
require "asm/rule_engine/rule_evaluator"
require "asm/item_validator"
require "asm/rule_engine/rules"
require "asm/rule_engine/result"

module ASM
  class RuleEngine
    # Creates a new ASM::RuleEngine::Rule instance
    #
    # The supplied options are set prior to parsing the main rule
    # body.  This means options set here can be overriden in the rule
    # body
    #
    # @param name [Symbol, String] a name for the rule
    # @param options [Hash] optional options for creating a rule
    # @option options [Boolean] :run_on_fail true to always run this rule
    # @option options [Fixnum] :priority the priority to run the rule at
    # @option options [Logger] :logger a logger to use
    # @option options [Boolean] :concurrent allow a rule to run concurrently with others
    # @return [RuleEngine::Rule]
    def self.new_rule(name, options={}, &blk)
      raise("Rules can only be created from a block") unless block_given?

      rule = Rule.new(options[:logger])
      rule.name = name

      rule.run_on_fail if options[:run_on_fail]
      rule.set_priority(options[:priority]) if options[:priority]
      rule.set_concurrent if options[:concurrent]

      rule.instance_eval(&blk)
      rule
    end

    attr_reader :logger, :path

    # Create a new instance of the rule engine
    #
    # @param path [String] a File::PATH_SEPARATOR seperated list of directories to load rules from
    # @param logger [Logger]
    def initialize(path, logger=ASM.logger)
      @logger = logger
      @path = path.split(File::PATH_SEPARATOR)
    end

    # A colletion of loaded rules
    #
    # @return [RuleEngine::Rules]
    def rules
      @rules ||= Rules.new(path, logger)
    end

    # Creates a new state that relates to this engine
    #
    # @return [RuleEngine::State]
    def new_state
      State.new(self, logger)
    end

    # (see RuleEngine::Rules#size)
    def size
      rules.size
    end

    # (see RuleEngine::Rules#empty?)
    def empty?
      rules.empty?
    end

    # (see RuleEngine::Rules#by_priority)
    def rules_by_priority(&blk)
      rules.by_priority(&blk)
    end

    # Process all loaded rules within a given state
    #
    # @param state [RuleEngine::State] to process rules in
    # @return [Array<RuleEngine::Result>]
    def process_rules(state)
      raise("No rules have been loaded into engine %s" % self) if empty?

      rules_by_priority do |rule|
        state.mutable = !rule.concurrent?
        result = rule.process_state(state)
        state.mutable = true

        state.store_result(result) if result
      end

      state.results
    end

    # @return [String]
    def inspect
      "#<%s:%s %d rules from %s>" % [self.class, object_id, size, path.inspect]
    end
  end
end

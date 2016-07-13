module ASM
  class RuleEngine
    class Rules
      # @param rules_dir [Array<string>] list of directories to look for rules
      # @param logger [Logger]
      def initialize(rules_dir, logger)
        @rules = []
        @logger = logger
        @rulesdir = Array(rules_dir)

        load_rules!

        @initialized = true
      end

      # Retrieves a frozen copy of the rules list
      #
      # @return [Array<Rule>]
      def rules
        @rules.dup.freeze
      end

      # @api private
      def locked?
        !!@initialized
      end

      # @api private
      def validate_lock!
        raise("Cannot add any rules once initialized") if locked?
      end

      # Look up a rule by name
      #
      # @param rule [String, Symbol] the rule name specified in {ASM::RuleEngine.new_rule}
      # @return [RuleEngine::Rule]
      def [](rule)
        rules[rule]
      end

      # Amount of rules loaded
      #
      # @return [Fixnum] rule count
      def size
        rules.size
      end

      # Whether there are no rules loaded
      #
      # @return [Boolean] true if there are no rules loaded, false otherwise
      def empty?
        rules.empty?
      end

      # Add a rule to the collection
      #
      # @api private
      # @param rule [RuleEngine::Rule] rule to add
      # @raise [StandardError] when the rules have already been loaded
      # @return [RuleEngine::Rule]
      def add_rule(rule)
        validate_lock!

        @rules << rule
      end

      # yields each loaded rule in order of priority
      #
      # @yield [RuleEngine::Rule] each rule
      # @return [void]
      def by_priority
        rules.sort_by(&:priority).each do |rule|
          yield(rule)
        end
      end

      # Load a rule from dis
      #
      # @api private
      # @param file [String] a file to read the rule from
      # @raise [StandardError] when the rules have already been loaded
      # @raise [StandardError] when the file cannot be found or read
      # @raise [StandardError] if rule creation fails for any reason
      # @return [void]
      def load_rule(file)
        validate_lock!

        raise("Cannot read file %s to load a rule from" % file) unless File.readable?(file)

        rule_body = File.read(file)

        cleanroom = Object.new
        rule = cleanroom.instance_eval(rule_body, file, 1)
        rule.file = file
        rule.logger = @logger

        add_rule(rule)

        @logger.debug("Loaded rule %s from %s" % [rule.name, file])
      end

      # Find correctly named rule files in a directory
      #
      # Valid rule files are named +something_rule.rb+
      #
      # @api private
      # @return [Array<String>] list of found rule file names without the directory part
      def find_rules(dir)
        if File.directory?(dir)
          Dir.entries(dir).grep(/_rule.rb$/)
        else
          @logger.debug("The argument %s is not a directory while looking for rules" % dir)
          []
        end
      end

      # Load all rules found in any of the directories specified in {#initialize}
      #
      # @raise [StandardError] when the rules have already been loaded
      # @return [void]
      def load_rules!
        validate_lock!

        @rulesdir.each do |dir|
          find_rules(dir).each do |rule|
            load_rule(File.join(dir, rule))
          end
        end
      end
    end
  end
end

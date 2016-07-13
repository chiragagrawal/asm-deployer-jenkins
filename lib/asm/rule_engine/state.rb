module ASM
  class RuleEngine
    class State
      attr_writer :mutable

      # @param engine [RuleEngine]
      # @param logger [Logger]
      def initialize(engine=nil, logger=ASM.logger)
        @logger = logger
        @had_failures = false
        @engine = engine
        @mutable = true

        @items = {}
        @items_mutex = Mutex.new

        @results = []
        @results_mutex = Mutex.new

        @acted_on_by = []
        @acted_on_by_mutex = Mutex.new
      end

      # Determines if the state is mutable
      #
      # methods like {#add} and {#add_or_set} will fail when not mutable
      #
      # @return [Boolean]
      def mutable?
        !!@mutable
      end

      # Inform the state that there were failures in some rules
      #
      # @return [Boolean]
      def had_failures!
        @had_failures = true
      end

      # Checks if the state had any failured rules
      #
      # @return [Boolean]
      def had_failures?
        !!@had_failures
      end
      alias_method :has_failures?, :had_failures?

      # List of rules that acted on this state
      #
      # @note the returned array is a frozen duplicate of the real list for thread safety
      # @return [Array<RuleEngine::Rule>]
      def acted_on_by
        @acted_on_by_mutex.synchronize { @acted_on_by.dup.freeze }
      end

      # Records the fact that a rule acted on this state
      #
      # @param actor [RuleEngine::Rule]
      # @return [void]
      def record_actor(actor)
        @acted_on_by_mutex.synchronize { @acted_on_by << actor }
      end

      # Stores a result from a rule
      #
      # @param result [Result]
      # @return [Result]
      def store_result(result)
        @results_mutex.synchronize { @results << result }
      end

      # Get the list of results
      #
      # @note the returned array is a frozen duplicate of the real list for thread safety
      # @return [Array<RuleEngine::Result>]
      def results
        @results_mutex.synchronize { @results.dup.freeze }
      end

      # Iterate the results
      #
      # @yield [RuleEngine::Result] each result
      def each_result
        results.each do |result|
          yield(result)
        end
      end

      # Process a state within a Rule Engine
      #
      # @param engine [RuleEngine] the engine to operate in and find rules
      # @return [Array<RuleEngine::Result>]
      def process_rules(engine=nil)
        engine ||= @engine
        engine.process_rules(self)
      end

      # Add or set a item on the state
      #
      # If the item does not exist it will add it, else it will set it
      #
      # @param item [String, Symbol] item name
      # @param value value to store
      # @raise [StandardError] when the state is not mutable
      # @return the value stored
      def add_or_set(item, value)
        raise("State is not mustable") unless mutable?

        if has?(item)
          @items_mutex.synchronize { @items[item] = value }
        else
          add(item, value)
        end
      end

      # Checks if the state has a certain item
      #
      # @return [Boolean]
      def has?(item)
        @items_mutex.synchronize { @items.include?(item) }
      end

      # Removes an item
      #
      # @raise [StandardError] when the state is not mutable
      # @return the item that was deleted
      def delete(item)
        raise("State is not mustable") unless mutable?
        @items_mutex.synchronize { @items.delete(item) }
      end

      # Add an item to the state
      #
      # @param item [String, Symbol] the item name
      # @param value the value to store
      # @raise [StandardError] when the state is not mutable
      # @raise [StandardError] if the item already exist
      # @return the value saved
      def add(item, value)
        raise("State is not mustable") unless mutable?

        if has?(item)
          raise("Already have an item called %s" % item)
        else
          @items_mutex.synchronize { @items[item] = value }
        end
      end
      alias_method :[]=, :add

      # Gets an item from state
      #
      # @param item [String, Symbol] the item name
      # @return the item stored
      def get(item)
        @items_mutex.synchronize { @items[item] }
      end
      alias_method :[], :get
    end
  end
end

require "asm/rule_engine"
require "asm/type"
require "asm/service"

module ASM
  class Service
    # @note this is currently unused code and part of a larger effort related to building services
    class Processor
      attr_reader :logger, :rule_repositories
      attr_writer :decrypt
      attr_accessor :deployment

      def initialize(raw_service, rule_repositories=nil, logger=ASM.logger)
        @logger = logger
        @raw_service = raw_service
        @decrypt = true

        @rule_repositories = repositories(rule_repositories)
      end

      def repositories(repos)
        (repos || ASM.config.rule_repositories || "/etc/asm-deployer/rules").split(File::PATH_SEPARATOR)
      end

      def debug?
        return false unless deployment

        deployment.debug?
      end

      def write_exception(base_name, error)
        if !debug?
          deployment.write_exception(base_name, error)
        else
          require "pp"
          logger.error("Exception during processing of %s: %s: %s" % [base_name, error.class, error.to_s])
          logger.error(error.backtrace.pretty_inspect)
        end
      end

      def process_state(component, engine, state)
        logger.debug("Processing state on engine %s" % [engine.inspect])
        engine.process_rules(state)

        {:component => component.puppet_certname, :component_s => component.to_s, :results => state.results}
      end

      def process_state_threaded(component, engine, state)
        Thread.new do
          begin
            Thread.current[:outcome] = process_state(component, engine, state)
          rescue Exception # rubocop:disable Lint/RescueException
            @logger.error("Encountered a critical unrecoverable error while processing the service: %s: %s" % [$!.class, $!.to_s])
            raise
          end
        end
      end

      def process_state_unthreaded(component, engine, state)
        {:outcome => process_state(component, engine, state)}
      end

      def process_lane(components, ruleset, threaded=true)
        threads = components.map do |component|
          process_component(component, ruleset, threaded)
        end

        threads.map do |thread|
          thread.join if thread.is_a?(Thread)

          thread[:outcome]
        end
      end

      def process_component(component, ruleset, threaded=true)
        engine = create_engine([ruleset, "component_common"])

        state = engine.new_state
        state.add(:processor, self)
        state.add(:service, component.service)
        state.add(:component, component)
        state.add(:resource, component.to_resource(deployment, logger))

        if threaded
          process_state_threaded(component, engine, state)
        else
          process_state_unthreaded(component, engine, state)
        end
      end

      def rule_paths(ruleset)
        @rule_repositories.map do |repo|
          Array(ruleset).map do |set|
            File.join(repo, set)
          end.join(File::PATH_SEPARATOR)
        end.join(File::PATH_SEPARATOR)
      end

      def create_engine(set)
        paths = rule_paths(set)
        logger.debug("Creating Rule Engine for rule set %s" % paths)

        RuleEngine.new(paths, logger)
      end

      def decrypt?
        !!@decrypt
      end

      # Process a service using the services ruleset
      #
      # A Rule Engine instance is created for the *service* ruleset
      # and ran, on completion the first error found is raised back
      # to the caller
      #
      # @param ruleset [String] optional service rule set to use
      # @raise [StandardErrror] if any rules failed to process
      def process_service(ruleset="service")
        engine = create_engine(ruleset)

        state = engine.new_state
        state.add(:processor, self)
        state.add(:service, Service.new(@raw_service, :deployment => deployment, :decrypt => decrypt?))
        state.add(:component_outcomes, [])

        engine.process_rules(state)

        state.results.each do |result|
          raise result.error if result.error
        end
      end
    end
  end
end

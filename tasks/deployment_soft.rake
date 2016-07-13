namespace :deployment do
  desc "Run rule based service processing with debug output accepts DEPLOYMENT, RULES, PROFILE, DEBUG and CONFIG"

  # DEPLOYMENT - the JSON file to run the teardown for
  # CONFIG - use a custom config.yaml
  # RULES - sets of rules to use, defaults to rules:rules/debug
  # PROFILE - run the teardown under ruby-prof and dump profiling data at the end
  # DEBUG - enable debug level logs
  task :soft_process do
    require 'asm'
    require 'asm/service'

    class ServiceRunner
      class DB
        def execution_id
          12345
        end

        def set_component_status(id, status)
          ASM.logger.info("Setting component status of %s to %s" % [id, status])
        end
      end

      def initialize
        options = parse_options

        ASM.config(YAML.load_file(options[:config]))
        ASM.config.debug_service_deployments = true

        configure_logger(options[:debug])

        @raw_service = JSON.parse(File.read(options[:deployment]), :max_nesting => 100)
        @processor = ASM::Service::Processor.new(@raw_service, options[:rules])
        @processor.deployment = self
        @profile = options[:profile]
      end

      def db
        DB.new
      end

      def parse_options
        options = {}

        options[:deployment] = File.expand_path(ENV["DEPLOYMENT"] || "deployment.json")
        options[:rules] = ENV["RULES"] || "rules:rules/debug"
        options[:profile] = !!ENV["PROFILE"]
        options[:debug] = !!ENV["DEBUG"]
        options[:config] = ENV["CONFIG"] || File.expand_path(File.join(File.dirname(__FILE__), "..", "config.yaml"))

        options
      end

      # fake out some stuff from ServiceDeployment the new code still depends on
      def decrypt?;true;end
      def debug?;true;end
      def id;"1234";end

      def logger
        ASM.logger
      end

      def configure_logger(debug)
        require 'logger/colors' if STDOUT.tty?

        (ASM.logger = Logger.new(ENV["ASMLOG"] || STDOUT)).level = debug ? Logger::DEBUG : Logger::INFO
      end

      def do_profiled
        require 'ruby-prof'

        RubyProf.start
        yield
        result = RubyProf.stop
        RubyProf::FlatPrinter.new(result).print(STDOUT)
      end

      def process!
        process = -> { @processor.process_service }

        @profile ? do_profiled { process.call } : process.call
      end
    end

    deployment = ServiceRunner.new
    deployment.process!
  end
end

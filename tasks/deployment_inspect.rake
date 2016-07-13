namespace :deployment do
  desc "View the contents of a deployment JSON set with DEPLOYMENT=deployment.json, set PRY to enter debugging"
  task :inspect do
    require 'asm/service'
    require 'json'
    require 'logger'
    require 'logger/colors'
    require 'mocha/api'

    include Mocha::API

    def enable_trace(options={})
      options = ({:match => /^ASM/, :exclude=> /Provider::Phash/, :events => "call"}).merge(options)

      events = Array(options[:events])

      set_trace_func proc {|event, file, line, id, binding, classname|
        next unless events.include?(event)
        next unless classname.to_s.match(options[:match])

        if options[:exclude]
          next if classname.to_s.match(options[:exclude])
        end

        puts("%8s %s:%-2d %10s %8s" % [event, file, line, id, classname])
      }
    end

    def disable_trace
      set_trace_func nil
    end

    def color
      Pry.config.color = !Pry.config.color
    end

    def inspect_service
      puts "Deployment file %s" % PATH
      puts
      puts "    Deployment Name: %s" % SERVICE.deployment_name
      puts "                 ID: %s" % SERVICE.id
      puts "           Teardown: %s" % SERVICE.teardown?
      puts "              Retry: %s" % SERVICE.retry?
      puts "          Migration: %s" % SERVICE.migration?
      puts
      puts "Components:"

      SERVICE.components.each do |component|
        puts
        puts "    %s" % component
        puts "           Name: %s" % component.name
        puts "           GUID: %s" % component.guid
        puts "       Teardown: %s" % component.teardown?
        puts "           Type: %s" % component.type
        puts "             ID: %s" % component.component_id
        puts "      Cert Name: %s" % component.puppet_certname
        puts "      Resources: %s" % component.resource_ids.inspect
        begin
          resource = component.to_resource(nil, Logger.new(nil))
          puts "       Provider: %s" % resource.provider_path
        rescue LoadError, StandardError
          puts "       Provider: unknown component type"
        end
      end

      puts
    end

    def view_components(component_match=".")
      SERVICE.components.sort_by{|c| c.puppet_certname}.each do |component|
        if component.puppet_certname.match(component_match)
          puts "%s:" % component.puppet_certname
          puts "*" * component.puppet_certname.length
          pp component.configuration
          puts
        end
      end

      nil
    end

    logger = Logger.new(ENV["ASMLOG"] || STDOUT)

    PATH = File.expand_path(ENV["DEPLOYMENT"] || "deployment.json")
    DEPLOYMENT = stub(:id => "1234", :debug? => false, :process_generic => false, :logger => logger)
    SERVICE = ASM::Service.new(JSON.parse(File.read(PATH), :max_nesting => 100), :deployment => DEPLOYMENT)

    inspect_service

    if ENV["PRY"]
      require 'pry'

      RESOURCES = SERVICE.components.map do |component|
        begin
          type = component.to_resource(DEPLOYMENT, logger)
        rescue LoadError, StandardError
          logger.warn("Cannot create a type instance for component %s: %s: %s" % [component.puppet_certname, $!.class, $!.to_s])
        end

        type
      end.compact

      puts
      puts "Starting pry session for captured deployment: %s" % PATH
      puts
      puts "   DEPLOYMENT   - mocked deployment"
      puts "   SERVICE      - ASM::Service loaded with the deployment.json"
      puts "   RESOURCES    - List of component resources"
      puts
      puts "Helper methods:"
      puts
      puts "   inspect_service - re-display the service contents"
      puts "   view_components - show the hashes found in the JSON per component with regex matching on certname"
      puts "   color           - toggle PRY colors"
      puts
      puts "Trace methods:"
      puts
      puts "   enable_trace    - enables code tracing, takes :match and :exclude as patterns against class names and an array of event filters in :events"
      puts "   disable_trace   - stops tracing"
      puts
      binding.pry(:quiet => true) if ENV["PRY"]
    end
  end
end

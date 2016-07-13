# This can be run from anywhere that has output from the capture_hardware task
#
# It will load the deployment with the servers, switches, storage, and networking information
# inventory mocked out.
namespace :deployment do
  desc "Debug a service deployment using captured hardware"
  task :debug_service do
    require "mocha/api"
    require "json"
    require "pry"
    require "logger/colors"
    require "asm/service"
    require "pry-debugger" unless RUBY_PLATFORM == "java"

    PATH = File.expand_path(ENV["DEPLOYMENT"] || "spec/fixtures/switch_providers")

    include Mocha::API

    def find_fixtures(directory, pattern)
      Dir.glob(File.join(directory, "*.json")).grep(pattern).each do |fixture|
        next if File.basename(fixture) == "switch_inventory.json"
        if File.basename(fixture) =~ /(.+)_(inventory|device_config|facts|fc_interfaces).json/
          yield(fixture, $1)
        end
      end
    end

    def enable_trace(options={})
      options = ({:match => /^ASM/, :exclude=> /Provider::Phash/, :events => "call", :output => STDOUT}).merge(options)

      events = Array(options[:events])

      if options[:output].is_a?(String)
        outfile = File.open(options[:output], "a")
        outfile.sync = true
      else
        outfile = STDOUT
      end

      set_trace_func proc {|event, file, line, id, binding, classname|
        next unless events.include?(event)
        next unless classname.to_s.match(options[:match])

        if options[:exclude]
          next if classname.to_s.match(options[:exclude])
        end

        outfile.puts("%8s %s:%-2d id: %10s %-10s" % [event, file, line, classname, id])
      }
    end

    def create_captured_service(directory)
      switch_inventory_json = File.join(directory, "switch_inventory.json")
      deployment_json = File.join(directory, "deployment.json")
      asm_networks_json = File.join(directory, "asm_networks.json")

      logger = Logger.new(ENV["ASMLOG"] || STDOUT)
      logger.level = Logger::DEBUG
      logger.formatter = ASM::LoggerFormat.new

      ASM.stubs(:logger).returns(logger)
      ASM.init_data_and_mutexes
      ASM::DeviceManagement.stubs(:run_puppet_device!)

      puppetdb = stub(:replace_facts_blocking! => nil)
      db = stub(:log => nil)
      raw_deployment = JSON.parse(File.read(deployment_json), :max_nesting => 100)
      deployment = stub(:id => raw_deployment["id"], :debug? => true, :process_generic => false, :puppetdb => puppetdb, :logger => logger, :db => db)
      service = ASM::Service.new(raw_deployment, :deployment => deployment)

      raw_switches = JSON.parse(File.read(switch_inventory_json), :max_nesting => 100)
      switch_collection = service.switch_collection
      switch_collection.stubs(:managed_inventory).returns(raw_switches)
      switch_collection.each {|s| s.stubs(:update_inventory!)}
      ASM::Service::SwitchCollection.stubs(:new).returns(switch_collection)

      service.stubs(:switch_collection).returns(switch_collection)

      if File.readable?(asm_networks_json)
        logger.info("Stubbing ASM Networks with %s" % asm_networks_json)
        ASM::PrivateUtil.stubs(:get_network_info).returns(JSON.parse(File.read(asm_networks_json)))
      else
        logger.warn("No ASM Networks stub found in %s" % asm_networks_json)
      end

      find_fixtures(directory, /inventory/) do |fixture, certname|
        logger.info("Stubbing inventory for %s using %s" % [certname, fixture])
        data = JSON.parse(File.read(fixture))
        ASM::PrivateUtil.stubs(:fetch_server_inventory).with(certname).returns(data)
        ASM::PrivateUtil.stubs(:fetch_managed_device_inventory).with(certname).returns([data])
      end

      find_fixtures(directory, /device_config/) do |fixture, certname|
        logger.info("Stubbing device_config for %s using %s" % [certname, fixture])
        data = Hashie::Mash.new(JSON.parse(File.read(fixture)))
        ASM::DeviceManagement.stubs(:parse_device_config).with(certname).returns(data)
      end

      find_fixtures(directory, /facts/) do |fixture, certname|
        data = JSON.parse(File.read(fixture))
        logger.info("Stubbing facts for %s with %s" % [certname, fixture])
        ASM::PrivateUtil.stubs(:facts_find).with(certname).returns(data)
      end

      servers = service.resources_by_type("SERVER").each do |server|
        fixture = File.join(directory, "%s_network_config.json" % server.puppet_certname)
        logger.info("Stubbing network config for server %s with %s" % [server.puppet_certname, fixture])
        network_config = ASM::NetworkConfiguration.new(JSON.parse(File.read(fixture)))
        server.stubs(:network_config).returns(network_config)
        server.stubs(:enable_switch_inventory!).returns(network_config)

        # unfortunately mocha doesnt let me pass a block else I'd have liked to log something here
        server.stubs(:power_off!)
        server.stubs(:power_on!)

        fixture = File.join(directory, "%s_fc_interfaces.json" % server.puppet_certname)
        if File.exist?(fixture)
          logger.info("Stubbing FC interfaces for server %s with %s" % [server.puppet_certname, fixture])
          fc_views = JSON.parse(File.read(fixture), :symbolize_names => true)
          server.provider.stubs(:fc_views).returns(fc_views)
        else
          server.provider.stubs(:fc_views).returns([])
        end

        fixture = File.join(directory, "%s_fcoe_wwpns.json" % server.puppet_certname)
        if File.exist?(fixture)
          logger.info("Stubbing FCoE wwpns for server %s with %s" % [server.puppet_certname, fixture])
          fcoe_wwpns = JSON.parse(File.read(fixture))
          ASM::WsMan.stubs(:get_fcoe_wwpn).with(server.device_config, anything).returns(fcoe_wwpns)
        else
          server.provider.stubs(:fcoe_wwpns).returns([])
        end

      end

      processor = service.create_processor("rules")
      processor.deployment = deployment

      service.resources.each {|r| r.deployment = deployment}

      [deployment, service, servers, processor]
    end

    def list_servers
      puts "Found %d server(s):" % SERVERS.size

      SERVERS.each do |server|
        server.network_topology

        puts "  %s" % server.puppet_certname

        puts "    Network Topology: %d connections" % [server.network_topology.size]

        server.network_topology.each do |interface|
          if interface[:switch]
            if interface[:interface_type] == "ethernet"
              puts "      %s => %s port %s" % [interface[:interface].name, interface[:switch].puppet_certname, interface[:port]]
            elsif interface[:interface_type] == "fc"
              puts "      %s => %s port %s" % [interface[:interface].fqdd, interface[:switch].puppet_certname, interface[:port]]
            end
          else
            if interface[:interface_type] == "ethernet"
              puts "      %s => unknown switch" % interface[:interface].name
            elsif interface[:interface_type] == "fc"
              puts "      %s => unknown switch" % interface[:interface].fqdd
            end
          end
        end

        puts
      end

      nil
    end

    def color
      Pry.config.color = !Pry.config.color
    end

    DEPLOYMENT, SERVICE, SERVERS, PROCESSOR = create_captured_service(PATH)

    puts
    puts "Starting pry session for captured deployment: %s" % PATH
    puts
    puts "   DEPLOYMENT    - mocked deployment"
    puts "   SERVICE       - ASM::Service loaded with the deployment.json"
    puts "   PROCESSOR     - ASM::Service::Processor set for rules in %s" % File.expand_path("rules")
    puts "   SERVERS       - list of servers in the deployment with network configuration stubbed"
    puts
    puts "Helper methods:"
    puts
    puts "   list_servers  - list all servers and their switches"
    puts "   color         - toggle PRY colors"
    puts "   enable_trace  - enables process call tracing with options"
    puts "                   :match => /^ASM/, :exclude=> /Provider::Phash/, :events => 'call'"
    puts "   disable_trace - disables process call tracing"
    puts

    binding.pry :quiet => true
  end
end

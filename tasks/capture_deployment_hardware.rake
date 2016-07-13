# This has to be run on an appliance where the deployment exist and all it's related
# hardware are still in the inventory
#
# It will load the deployment, find all servers and switches and dump their relevant
# network configs, device configs, facts and inventory to files and copy the deployment.json
# into that directory
#
# If there is a deployment.log in the same directory as the deployment.json it will copy
# the entire directory into outdir/service_id/deployment, this is ideal for getting reports
# of problem deployments from QA
#
# An example of the output is in spec/fixtures/switch_providers
namespace :deployment do
  desc "Capture hardware inventories and deployment.json for a deployment"
  task :capture_hardware do
    require 'asm'
    require 'asm/service'
    require 'json'
    require 'logger'
    require 'fileutils'
    require 'logger/colors'

    ASM.init

    deployment_file = File.expand_path(ENV["DEPLOYMENT"] || "deployment.json")
    deployment_log = File.join(File.dirname(deployment_file), "deployment.log")

    service = ASM::Service.new(JSON.parse(File.read(deployment_file), :max_nesting => 100))

    outdir = File.join(File.expand_path(ENV["OUT"] || "/tmp"), service.id)
    deploymentdir = File.join(outdir, "deployment")

    puts "Capturing deployment %s into %s" % [service.id, outdir]

    FileUtils.mkdir_p(deploymentdir)

    if File.exist?(deployment_log)
      puts "Copying deployment logs and resources to %s" % deploymentdir
      FileUtils.cp_r(Dir.glob("%s/*" % File.dirname(deployment_file)), deploymentdir)
    end

    logger = Logger.new(ENV["ASMLOG"] || STDOUT)

    resources = service.components.map do |c|
      c.to_resource(OpenStruct.new(:id => service.id), logger)
    end

    switches = ASM::Service::SwitchCollection.new(logger)
    resources.concat(switches.to_a)

    puts "Capturing ASM Networks"
    File.open(File.join(outdir, "asm_networks.json"), "w") {|f| f.puts ASM::PrivateUtil.get_network_info.to_json}

    puts "About to capture:"
    resources.each do |resource|
      puts "    %s" % resource.to_s
    end

    resources.each do |resource|
      puts
      puts "Capturing %s %s" % [resource.class, resource.puppet_certname]
      puts

      begin
        puts "...updating inventory"
        resource.update_inventory

        puts "...getting inventory"
        inventory = resource.retrieve_inventory!

        puts "...getting facts"
        facts = resource.facts_find # doing it this way avoids all the fact normalization
                                    # in the providers so we get raw facts without providers
                                    # potentially introducing bugs

        puts "...getting device config"
        device = resource.device_config

        if resource.is_a?(ASM::Type::Server)
          puts "...getting network config"
          network_config = resource.network_config

          puts "...getting FC interfaces"
          fc_interfaces = resource.fc_interfaces

          puts "...getting FCoE wwpns"
          if resource.fcoe?
            fcoe_wwpns = ASM::WsMan.get_fcoe_wwpn(device, logger)
          else
            fcoe_wwpns = nil
          end
        else
          network_config = fc_interfaces = nil
        end

        File.open(File.join(outdir, "%s_inventory.json" % resource.puppet_certname), "w") do |f|
          if inventory.nil?
            f.puts "{}"
          else
            f.puts inventory.to_hash.to_json
          end
        end

        File.open(File.join(outdir, "%s_facts.json" % resource.puppet_certname), "w") do |f|
          f.puts facts.to_hash.to_json
        end

        if device
          File.open(File.join(outdir, "%s_device_config.json" % resource.puppet_certname), "w") do |f|
            f.puts device.to_hash.to_json
          end
        end

        if network_config
          File.open(File.join(outdir, "%s_network_config.json" % resource.puppet_certname), "w") do |f|
            f.puts network_config.to_hash.to_json
          end
        end

        if fc_interfaces
          File.open(File.join(outdir, "%s_fc_interfaces.json" % resource.puppet_certname), "w") do |f|
            f.puts fc_interfaces.to_json
          end
        end

        if fcoe_wwpns
          File.open(File.join(outdir, "%s_fcoe_wwpns.json" % resource.puppet_certname), "w") do |f|
            f.puts fcoe_wwpns.to_json
          end
        end

      rescue StandardError, LoadError
        STDERR.puts "Could not dump resource %s: %s: %s" % [resource.puppet_certname, $!.class, $!.to_s]
        STDERR.puts $!.backtrace.join("\n\t")
      end
    end

    # Populate the switch collection with the new facts we just collected
    switches.populate!

    File.open(File.join(outdir, "switch_inventory.json"), "w") do |f|
      f.puts switches.switch_inventories.to_json
    end

    FileUtils.cp(deployment_file, outdir)
  end
end

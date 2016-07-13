require "rest_client"
require "net/http"
require "json"
require "hashie"
require "asm/private_util"
require "shellwords"

module ASM
  module Facts
    class ReplaceFactsError < StandardError
    end
    class FactScriptError < StandardError
    end

    def self.run_script(device_config, options={})
      options[:logger] ||= ASM.logger
      options[:output_file] ||= ("/opt/Dell/ASM/cache/%s.json" % device_config[:cert_name])

      path = device_config[:path]
      script_path = "%s%s" % [Util::DEVICE_MODULE_PATH, path]
      if !File.exist?(script_path) || !File.executable?(script_path)
        raise(DeviceManagement::FactRetrieveError, "Unable to retrieve facts for %s, no executable script to run" % device_config[:provider])
      end

      facts = {
        "device_type" => "script",
        "certname" => device_config[:cert_name]
      }

      begin
        args = build_command(device_config)

        args << "--output"
        args << options[:output_file]

        masked_args = [script_path] + args.dup
        masked_args[masked_args.find_index {|x| x == "--password"} + 1] = "*******"
        masked_cmd = masked_args.join(" ")
        password_index = args.find_index { |x| x == "--password" }
        password = args[password_index + 1]

        # Password as environment variable
        args.slice!(password_index..password_index + 1)
        options[:logger].info("Executing inventory command: %s" % masked_cmd)

        result = nil

        # Would prefer to use run_command_streaming here but that
        # hits a jruby 1.7 bug where back-slashes in the command get doubled,
        # which plays havoc with domain\username arguments. Using
        # run_command_with args and printing all stderr last instead.
        3.times do
          result = Util.run_with_clean_env(script_path, false, *args, "PASSWORD".to_sym => password)

          break if result.exit_status != 1

          options[:logger].info("Inventory command returned exit code 1. sleeping for 5 sec. then retry to execute")
          sleep(5)
        end

        File.open(options[:log_file], "w+") do |f|
          f.puts(result.stdout)
          f.puts(result.stderr)
        end

        unless result && result.exit_status == 0
          raise(FactScriptError, "Inventory command returned exit code %s. Output at: %s" % [result.exit_status, options[:log_file]])
        end

        unless File.exist?(options[:output_file])
          raise(DeviceManagement::FactRetrieveError, "Error, missing fact discovery file %s" % options[:output_file])
        end

        data = JSON.parse(File.read(options[:output_file]))

        # until we are on the new puppetdb if we detect we are getting structured data
        # store the data as a JSON encoded string into the 'json_facts' fact
        if data.reject { |_, v| v.is_a?(String) }.empty?
          facts.merge!(data)
        else
          facts["json_facts"] = JSON.dump(data)
        end
      end
      facts
    end

    def self.build_command(device_config)
      args = []
      [[:user, "username"], :password, :port, [:host, "server"]].each do |k, name|
        next unless device_config[k]
        name ||= k.to_s
        args << "--%s" % name
        args << device_config[k].to_s
      end

      # Add all device_config[:arguments]
      device_config[:arguments].each do |k, v|
        args << "--%s" % k.tr("_", "-")
        args << v
      end
      args
    end

    def self.can_write_to_file?(script_path)
      `#{script_path} --help`.include?("--file")
    end
  end
end

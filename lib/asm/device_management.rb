require "asm"
require "asm/errors"
require "asm/private_util"
require "asm/deployment_teardown"
require "asm/cipher"
require "asm/facts"

require "fileutils"
require "cgi"
require "json"

module ASM
  module DeviceManagement
    class SyncException < StandardError; end
    class DuplicateDevice < StandardError; end
    class FactRetrieveError < StandardError; end

    DEVICE_CONF_DIR = ASM::Util::DEVICE_CONF_DIR
    NODE_DATA_DIR = ASM::Util::NODE_DATA_DIR
    DEVICE_MODULE_PATH = ASM::Util::DEVICE_MODULE_PATH
    DEVICE_LOG_PATH = ASM::Util::DEVICE_LOG_PATH
    DEVICE_SSL_DIR = ASM::Util::DEVICE_SSL_DIR

    @state_mutex = Mutex.new
    @discovery_state = {}

    def self.get_device_state(cert_name)
      @state_mutex.synchronize { @discovery_state[cert_name] || :unknown }
    end

    def self.set_device_state(cert_name, state)
      raise("Unsupported state %s for node %s" % [state, cert_name]) unless [:requested, :in_progress, :success, :failed].include?(state)

      @state_mutex.synchronize { @discovery_state[cert_name] = state }
    end

    def self.clean_device_log_dir(cert_name, keep=10)
      dir = File.join(DEVICE_LOG_PATH, cert_name)

      return unless File.directory?(dir)

      entries = Dir.entries(dir).grep(/^\d+.log/).sort.reverse

      Array(entries[keep..-1]).each do |entry|
        File.unlink(File.join(dir, entry))
      end
    end

    def self.device_log_file(cert_name)
      dir = File.join(DEVICE_LOG_PATH, cert_name)
      file = File.join(dir, "%d.log" % Time.now.to_i)

      if File.directory?(dir)
        clean_device_log_dir(cert_name, 9)
      else
        FileUtils.mkdir(dir)
      end

      FileUtils.touch(file)
      # WARNING: do not use FileUtils.chown, there is a java segfault issue! See ASM-3387
      system("chown", "razor:pe-puppet", file)
      FileUtils.chmod(0o0664, file)

      file
    end

    def self.device_state_dir(cert_name)
      File.join(DEVICE_SSL_DIR, cert_name, "state")
    end

    def self.device_summary_file(cert_name)
      File.join(device_state_dir(cert_name), "last_run_summary.yaml")
    end

    # returns the mtime or epoch time if the file does not exist
    def self.last_run_summary_mtime(cert_name, summary_file=nil)
      summary_file ||= device_summary_file(cert_name)

      return Time.at(0) unless File.exist?(summary_file)
      File.mtime(summary_file)
    end

    def self.last_run_summary(cert_name, summary_file=nil)
      summary_file ||= device_summary_file(cert_name)

      YAML.load(File.read(summary_file))
    end

    def self.log_has_pluginsync_errors?(logfile)
      return false unless logfile
      return false unless File.exist?(logfile)

      File.open(logfile).each_line do |line|
        return true if line.encode("UTF-8", "binary", :invalid => :replace, :undef => :replace, :replace => "?") =~ /^Error: Could not retrieve plugin/
      end

      false
    end

    def self.puppet_run_success?(cert_name, result, start_time, logfile=nil, summary_file=nil)
      sf = summary_file || device_summary_file(cert_name)

      if result.is_a?(Fixnum)
        exit_status = result
      else
        exit_status = result.exit_status
      end

      return [false, "puppet exit code was %d" % exit_status] unless exit_status == 0
      return [false, "%s has not been updated in this run" % sf] unless last_run_summary_mtime(cert_name, summary_file) > start_time

      begin
        summary = last_run_summary(cert_name, summary_file)
      rescue
        return [false, "Could not parse %s as YAML: %s" % [sf, $!.inspect]]
      end

      # empty files, files with no content in the hash
      return [false, "%s was not a hash" % sf] unless summary.is_a?(Hash)
      return [false, "%s is empty" % sf] if summary.is_a?(Hash) && summary.empty?

      # for some failure scenarios it does update the last_run_summary.yaml but config version is empty, it can be string
      # nil or Fixnum it seems so need to to_s it always
      return [false, "%s has an invalid config version" % sf] if summary["version"]["config"].to_s.empty?

      # other times it will update that but fail in another way and wont have resources key in the hash
      return [false, "%s has no resources section" % sf] unless summary.include?("resources")

      # pluginsync fails in a transaction that is not reported anywhere but the logs
      return [false, "pluginsync failed based on logfile %s" % logfile] if log_has_pluginsync_errors?(logfile)

      return [true, "last_run_summary.yaml and exit code checks pass"]
    rescue
      [false, "Failed to determine puppet run success: %s at %s" % [$!.to_s, $!.backtrace.first]]
    end

    def self.pooled_inventory_runner(cert_name, options={})
      logger = options[:logger] || ASM.logger
      work_queue = TorqueBox.fetch("/queues/asm_jobs")

      msg = {:action => "inventory", :cert_name => cert_name}

      logger.debug("Sending inventory request to %s: %s" % [work_queue, msg.to_json])
      props = {:action => "inventory", :version => 1}
      body = work_queue.publish_and_receive(msg,
                                            :properties => props,
                                            :timeout => 30 * 60 * 1000)

      return [false, "timed out waiting for pool worker", ""] unless body

      unless cert_name == body[:cert_name]
        # shouldn't be possible, but worth a check..
        raise("Got a reply for cert_name %s but expected cert_name %s and " %
                  [body[:cert_name], cert_name])
      end

      logger.debug("Got reply for %s: success: %s msg: %s" %
                       [body[:cert_name], body[:success], body[:msg]])

      [body[:success], body[:msg], body[:log]]
    rescue
      logger.debug("pooled puppet request failed: %s" % $!.inspect)
      logger.debug($!.backtrace.inspect)
      raise
    end

    def self.init_device_state(cert_name, logger=nil, fail_for_in_progress=true)
      starting_state = get_device_state(cert_name)

      if [:requested, :in_progress].include?(starting_state)
        msg = "Discovery for device %s is already in progress - state is %s" % [cert_name, starting_state]
        if fail_for_in_progress
          logger.info(msg) if logger
          raise(SyncException, msg)
        end
      else
        set_device_state(cert_name, :requested)
      end
    end

    def self.run_puppet_device_sync!(cert_name, logger=nil)
      device_config = parse_device_config(cert_name)
      PrivateUtil.wait_until_available(cert_name, PrivateUtil.large_process_max_runtime, logger) do
        set_device_state(cert_name, :in_progress)

        logfile = device_log_file(cert_name)
        if device_config[:provider] == "script" && ASM.config.work_method == :queue
          success, msg, log = pooled_inventory_runner(cert_name, :logger => logger)
          File.open(logfile, "w") { |f| f.puts log }
          logger.info("Script fact collection for node %s %s: %s" %
                          [cert_name, success ? "succeeded" : "failed", msg]) if logger
          set_device_state(cert_name, success ? :success : :failed)
        elsif device_config[:provider] == "script"
          logger.info("Script fact collection for node %s started" % cert_name) if logger
          gather_facts(device_config, :logger => logger, :log_file => logfile)
          logger.info("Script fact collection for node %s succeeded" % cert_name) if logger
          set_device_state(cert_name, :success)
        else
          configfile = device_config_name(cert_name)

          start_time = Time.now

          logger.info("Puppet device run for node %s started, logging to %s" % [cert_name, logfile]) if logger
          result = Util.run_command_simple("sudo puppet device --verbose --debug --trace --deviceconfig %s --modulepath %s --logdest %s >/dev/null 2>&1" %
                                               [configfile, DEVICE_MODULE_PATH, logfile])

          success, reason = puppet_run_success?(cert_name, result, start_time, logfile)

          if success
            logger.info("Puppet device run for node %s succeeded" % cert_name) if logger
            set_device_state(cert_name, :success)
          else
            logger.info("Puppet device run for node %s failed: %s" % [cert_name, reason]) if logger
            set_device_state(cert_name, :failed)
          end
        end
      end
    rescue SyncException => e
      logger.info(e.to_s) if logger
      raise
    rescue => e
      logger.info("Puppet device run for node %s caught exception: %s" % [cert_name, e.to_s]) if logger
      set_device_state(cert_name, :failed)
      raise
    end

    def self.run_puppet_device_async!(cert_name, logger=nil, fail_for_in_progress=true)
      # First we set the state which needs to happen in the sync thread
      init_device_state(cert_name, logger, fail_for_in_progress)
      ASM.execute_async(logger) do
        run_puppet_device_sync!(cert_name, logger)
      end
    end

    # TODO: Seems all current calls of run_puppet_device! pass in logger, should it have a default value nil?
    # TODO: fail_for_in_progress could be default false, but leaving as true to keep things working the same for now
    def self.run_puppet_device!(cert_name, logger=nil, fail_for_in_progress=true)
      init_device_state(cert_name, logger, fail_for_in_progress)
      run_puppet_device_sync!(cert_name, logger)
    end

    def self.remove_device(cert_name, certs=ASM::PrivateUtil.get_puppet_certs)
      # under assumption hash will have at least {"ref_id":"....", "device_type":"...", "service_tag":"...."}, modeled from database entry
      if certs.include?(cert_name)
        PrivateUtil.wait_until_available(cert_name, PrivateUtil.large_process_max_runtime, logger) do
          clean_cert(cert_name)
          deactivate_node(cert_name)
          remove_node_data(cert_name)
          remove_device_conf(cert_name)
          remove_device_ssl_dir(cert_name)
        end
      else
        raise(ASM::NotFoundException, "Couldn't find certificate by the name of #{cert_name}.  No files being cleaned.")
      end
    end

    def self.clean_cert(cert_name)
      result = ASM::Util.run_command_simple("sudo puppet cert clean #{cert_name}")
      if result.exit_status == 0
        logger.info("Cleaned certificate for device #{cert_name}")
      else
        logger.warn("Failed to clean certificate #{cert_name}: #{result.stderr}")
      end
    end

    def self.deactivate_node(cert_name)
      result = ASM::Util.run_command_simple("sudo puppet node deactivate --terminus=puppetdb #{cert_name}")
      if result.exit_status == 0
        logger.info("Deactivated node #{cert_name}")
      else
        logger.warn("Failed to deactivate node #{cert_name}: #{result.stderr}")
      end
    end

    def self.remove_node_data(cert_name)
      node_data_file = node_data_name(cert_name)
      if File.exist?(node_data_file)
        FileUtils.rm(node_data_file)
        logger.info("Removed device node data file for #{cert_name}")
      end
    end

    def self.remove_device_conf(cert_name)
      conf_file = device_config_name(cert_name)
      if File.exist?(conf_file)
        FileUtils.rm(conf_file)
        logger.info("Removed device config file for #{cert_name}")
      else
        logger.warn("Device configuration file #{conf_file} not found")
      end
    end

    def self.remove_device_ssl_dir(device_name)
      # Calling this script is a work around, since the folder to delete is a root:root owned folder, and the call will be made by the razor user
      ASM::Util.run_command_simple("sudo /opt/Dell/scripts/rm-device-ssl.sh #{device_name}")

      logger.info("Cleaned Puppet devices ssl files for #{device_name}")
    end

    def self.url_for_device(device)
      encoded_arguments = (device["arguments"] || {}).map {|k, v| "%s=%s" % [URI.escape(k), URI.escape(v)]}.join("&")

      url = "%s://" % device["scheme"]
      url = "%s%s:%s@" % [url, CGI.escape(device["user"]), CGI.escape(device["pass"])] if device["user"] && device["pass"]
      url = "%s%s" % [url, device["host"]]
      url = "%s:%s" % [url, device["port"]] if device["port"]
      url = "%s/%s" % [url, device["path"]] if device["path"]
      url = "%s?%s" % [url, encoded_arguments] unless encoded_arguments.empty?

      url
    end

    def self.write_device_config(device, overwrite=false, device_file=nil)
      missing_params = ["cert_name", "host", "provider", "scheme"].reject {|k| device.include?(k)}
      raise("Devices need %s parameters" % missing_params.join(", ")) unless missing_params.empty?

      device_file = device_config_name(device["cert_name"]) unless device_file

      raise(DuplicateDevice, "Device file %s already exist and overwrite is false, not replacing existing file" % device_file) if !overwrite && File.exist?(device_file)

      contents = StringIO.new
      contents.puts "[%s]" % device["cert_name"]
      if device["scheme"] == "script"
        contents.puts "  type script"
      else
        contents.puts "  type %s" % device["provider"]
      end
      contents.puts "  url %s" % url_for_device(device)

      File.open(device_file, "w") {|f| f.puts contents.string}
      contents.string
    end

    def self.gather_facts(device_config, options={})
      options[:logger] ||= logger
      facts = ASM::Facts.run_script(device_config, options)
      Client::Puppetdb.new(:logger => logger).replace_facts_blocking!(device_config[:cert_name], facts)
    end

    def self.write_device_config!(device, device_file=nil)
      write_device_config(device, true, device_file)
    end

    def self.parse_device_config(cert_name)
      ASM.secrets.device_config(cert_name)
    end

    def self.parse_device_config_local(cert_name)
      conf_file = device_config_name(cert_name)

      return nil unless File.exist?(conf_file)

      conf_file_data = parse_device_config_file(conf_file)

      uri = URI.parse(conf_file_data[cert_name].url)
      params = CGI.parse(uri.query || "")
      arguments = params.keys.inject({}) do |result, key|
        result[key] = params[key].first
        result
      end
      provider = conf_file_data[cert_name].provider

      enc_password = nil
      password = nil
      user = nil

      user = URI.decode(uri.user) if uri.user
      password = URI.decode(uri.password) if uri.password

      # Optionally use ASM credential_id. Overrides all other credentials
      unless params["credential_id"].empty?
        begin
          cred = ASM::Cipher.decrypt_credential(params["credential_id"].first)
          user = cred.username
          user = "#{cred.domain}\\#{user}" if cred.domain && !cred.domain.empty?
          password = cred.password
          if cred.snmp_community_string && !cred.snmp_community_string.empty?
            arguments["community_string"] = cred.snmp_community_string
          end
        rescue ASM::NotFoundException => ex
          # It is possible the credential_id passed is an encrypted string. Try to decrypt the string
          user = "root" if user.nil? || user.empty?
          begin
            password = ASM::Cipher.decrypt_string(params["credential_id"].first)
          rescue ASM::NotFoundException
            # Re-raise previous exception
            raise ex
          end
        end
      end

      Hashie::Mash.new(:cert_name => cert_name,
                       :host => uri.host,
                       :port => uri.port,
                       :path => uri.path,
                       :scheme => uri.scheme,
                       :arguments => arguments,
                       :user => user,
                       :enc_password => enc_password,
                       :password => password,
                       :url => uri,
                       :provider => provider,
                       :conf_file_data => conf_file_data)
    end

    def self.parse_device_config_file(file)
      devices = {}
      device = nil

      File.open(file) do |f|
        f.each_with_index do |line, count|
          next if line =~ /^\s*(#|$)/

          case line
          when /^\[([\w.-]+)\]\s*$/ # [device.fqdn]
            name = $1
            name.chomp!

            raise(ArgumentError, "Duplicate device found at line #{count}, already found at #{device.line}") if devices.include?(name)

            device = OpenStruct.new
            device.name = name
            device.line = count + 1
            device.options = {:debug => false}
            devices[name] = device
          when /^\s*(type|url|debug)(\s+(.+))*$/
            parse_device_config_directive(device, $1, $3, count + 1)
          else
            raise(ArgumentError, "Invalid line #{count + 1}: #{line}")
          end
        end
      end

      devices
    end

    def self.parse_device_config_directive(device, var, value, count)
      case var
      when "type"
        device.provider = value
      when "url"
        device.url = value
      when "debug"
        device.options[:debug] = true
      else
        raise(ArgumentError, "Invalid argument '#{var}' at line #{count}")
      end
    end

    def self.get_device(cert_name, include_facts=true)
      raise(ASM::NotFoundException, "Device %s is unknown" % cert_name) unless has_config_for_device?(cert_name)

      device_data = parse_device_config(cert_name)

      ["conf_file_data", "url", "password", "enc_password"].each {|k| device_data.delete(k)}

      device_data["facts"] = {}
      device_data["discovery_status"] = get_device_state(cert_name)

      if include_facts
        begin
          device_data["facts"] = Client::Puppetdb.new.facts(cert_name)

          if !device_data["facts"].empty? && device_data["discovery_status"] == :unknown
            device_data["discovery_status"] = :success
          end
        rescue => e
          logger.info("Could not get facts for %s from puppetdb: %s" % [cert_name, e.to_s])
        end
      end

      device_data.to_hash
    end

    def self.has_config_for_device?(cert_name)
      File.exist?(device_config_name(cert_name))
    end

    def self.device_config_name(cert_name)
      File.join(DEVICE_CONF_DIR, "#{cert_name}.conf")
    end

    def self.node_data_name(cert_name)
      File.join(NODE_DATA_DIR, "#{cert_name}.yaml")
    end

    def self.logger
      @logger ||= ASM.logger
    end
  end
end

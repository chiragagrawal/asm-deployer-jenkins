require 'asm'
require 'asm/messaging'
require 'asm/device_management'
require 'logger'
require 'socket'

module ASM
  module Messaging
    class JobProcessor < TorqueBox::Messaging::MessageProcessor
      def logger
        ASM.logger
      end

      # Creates a job-specific logger
      def create_logger(body)
        missing_params = [:job_dir, :job_id, :action].reject { |k| body.include?(k) }
        raise("Job logger need %s parameters" % missing_params.join(", ")) unless missing_params.empty?
        log_file = File.join(body[:job_dir], "%s-%s.log" % [body[:job_id], body[:action]])
        Logger.new(log_file)
      end

      def out_file(body)
        File.join(body[:job_dir], "%s-%s.out" % [body[:job_id], body[:action]])
      end

      def exception_file(body)
        File.join(body[:job_dir], "%s-%s_exception.log" % [body[:job_id], body[:action]])
      end

      def resource_file(body)
        File.join(body[:job_dir], "%s-%s.yaml" % [body[:job_id], body[:action]])
      end

      def cache_file(body)
        File.join(body[:job_dir], "%s-%s-cache.json" % [body[:job_id], body[:action]])
      end

      def write_exception(body, exception)
        backtrace = (exception.backtrace || []).join("\n")
        File.write(exception_file(body), "#{exception.inspect}\n\n#{backtrace}")
      end

      def create_execution_environment(cert_name, base_dir = ASM.config.jobs_dir, keep = 30)
        dir = File.join(base_dir, cert_name)
        if File.directory?(dir)
          # Rotate out old entries
          entries = Dir.entries(dir).grep(/^\d+-.*[.].*$/).sort.reverse
          Array(entries[keep..-1]).each do |entry|
            File.unlink(File.join(dir, entry))
          end
        else
          FileUtils.mkdir_p(dir)
        end
        dir
      end

      def on_puppet_apply(body)
        missing_params = [:action, :cert_name, :resources, :job_dir, :job_id].reject { |k| body.include?(k) }
        raise("Puppet apply jobs need %s parameters" % missing_params.join(", ")) unless missing_params.empty?

        File.open(resource_file(body), "w") { |f| f.puts body[:resources] }
        # TODO: it should no longer be necessary to run puppet with sudo, but
        # right now it gets the user-specific puppet config if we don't
        command = "sudo puppet asm process_node --debug --trace --run_type apply --always-override --filename %s --statedir %s %s" %
            [resource_file(body), body[:job_dir], body[:cert_name]]
        summary_file = File.join(body[:job_dir], 'state', body[:cert_name], 'last_run_summary.yaml')

        out_file = out_file(body)
        logger.info("Running '%s' logging to '%s'" % [command, out_file])

        success = true
        msg = "OK"
        start_time = Time.now

        begin
          ASM::Util.run_command_streaming(command, out_file)
          success, msg = ASM::DeviceManagement.puppet_run_success?(body[:cert_name], 0, start_time, out_file, summary_file)
        rescue => e
          write_exception(body, e)
          success = false
          msg = $!.message
        end

        {:id => body[:id],
         :cert_name => body[:cert_name],
         :msg => msg,
         :success => success,
         :log => File.exists?(out_file) ? File.read(out_file) : nil}
      end

      def on_inventory(body)
        missing_params = [:action, :cert_name, :job_dir, :job_id].reject { |k| body.include?(k) }
        raise("Inventory jobs need %s parameters" % missing_params.join(", ")) unless missing_params.empty?

        out_file = out_file(body)
        cache_file = cache_file(body)

        begin
          device_config = ASM::DeviceManagement.parse_device_config(body[:cert_name])
          facts = ASM::DeviceManagement.gather_facts(device_config,
                                                     :logger => create_logger(body),
                                                     :output_file => cache_file,
                                                     :log_file => out_file)
          success = true
          msg = "Successfully ran inventory for %s" % body[:cert_name]
        rescue => e
          write_exception(body, e)
          success = false
          msg = $!.message
        end

        {:id => body[:id],
         :cert_name => body[:cert_name],
         :msg => msg,
         :success => success,
         :facts => facts,
         :log => File.exists?(out_file) ? File.read(out_file) : nil}
      end

      def on_test(body)
        create_logger(body).info("Received test queue message: #{body}")
        body[:success] = true
        body[:msg] = "Test processing completed"
        body[:thread] = Thread.current.to_s
        body
      end

      def on_message(body)
        missing_params = [:action, :cert_name].reject { |k| body.include?(k) }
        raise("Jobs need %s parameters" % missing_params.join(", ")) unless missing_params.empty?
        action_method = "on_%s" % body[:action]

        raise("Unrecognized action %s" % body[:action]) unless respond_to?(action_method)

        logger.info("Doing %s %s for cert_name %s" %
                        [body[:action], body[:id], body[:cert_name]])

        body[:job_id] = Time.now.to_i.to_s
        body[:job_dir] = create_execution_environment(body[:cert_name])

        # Always log message payload
        msg_file = File.join(body[:job_dir], "%s-%s-message.json" % [body[:job_id], body[:action]])
        File.open(msg_file, "w") { |f| f.puts body.to_json }

        ret = send(action_method, body)
        ret[:job_host] = Socket.gethostname
        ret.merge([:id, :cert_name, :job_id, :job_dir].inject({}) { |h, k| h[k] = body[k]; h })
      rescue
        logger.info "%s failed: %s" % [body[:action], $!.inspect]
        logger.info $!.backtrace.inspect

        {:msg => "%s failed: %s" % [body[:action], $!.inspect],
         :success => false,
         :job_host => Socket.gethostname,
         :log => nil}.merge([:id, :cert_name, :job_id, :job_dir].inject({}) { |h, k| h[k] = body[k]; h })
      end

    end
  end
end

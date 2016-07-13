=begin
  initiate discovery for the switches
=end

require 'pathname'
require 'asm/private_util'
require 'asm/translatable'

class Discoverswitch
  include ASM::Translatable

  def initialize (switchinfo,service_deployment)
    @switchinformation = switchinfo
    @service_deployment = service_deployment
  end

  def discoverswitch(logger,db=nil)
    db.log(:info, t(:ASM031, "Refreshing switch inventory data")) if db
    threads = []
    max_retry_count = 10

    @switchinformation.each do |nodename,devicehash|
      threads << ASM.execute_async(logger) do
        retry_count = 0
        logger.debug "Initiating puppet discovery for node #{nodename}"
        begin
          ASM::DeviceManagement.run_puppet_device!(nodename, logger)
          logger.debug("Discovery completed for #{nodename}")
        rescue ASM::DeviceManagement::SyncException => e
          retry_count += 1
          logger.debug("Received sync error for #{nodename}, will retry #{retry_count} after 60 seconds")
          sleep(60)
          retry if retry_count < max_retry_count
        rescue => e
          logger.error("Discovery failed for #{nodename}: #{e.inspect}")
        end
      end
    end

    # wait for all the threads to complete
    threads.each { |thr| thr.join }
    return true
  end
end

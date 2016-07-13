require 'logger'
require 'fileutils'
require 'i18n'
require 'asm/translatable'
require 'asm/service_deployment'
require 'asm/service_migration_deployment'
require 'asm/deployment_teardown'
require 'asm/update_deployment'
require 'asm/config'
require 'asm/errors'
require 'asm/data/deployment'
require 'asm/appliance_setup/dhcp'
require 'asm/device_metrics'
require 'asm/secrets'
require 'sequel'
require 'asm/cipher'
require 'asm/graphite'
require 'asm/cache'
require 'asm/port_view'
require 'asm/logger_format'

module ASM

  # TODO these methods should be initialized from sinatra b/c their first invocation
  # is not thread safe

  class UninitializedException < StandardError; end

  extend Translatable

  # Whether the ASM module has been initialized
  #
  # @return [Boolean]
  def self.initialized?
    if @initialized
      true
    else
      nil
    end
  end

  # Initialize the ASM module.
  #
  # Must be called exactly once before any multi-threaded operations are
  # performed to ensure that various mutexes are initialized safely.
  #
  # All options are considered configuration options. See the top-level
  # config.yaml file for possible configuration options. If options is empty the
  # configuration options will be loaded from {ASM::Config.default_config_file}.
  #
  # @param (see ASM::Config#initialize)
  # @raise [StandardError] if the ASM module has already been initialized
  def self.init(options = {})
    if ASM.initialized?
      raise("Can not initialize ASM class twice")
    else
      init_data_and_mutexes
      config(options)

      if config.database_url
        # This is optional because worker nodes won't have a db
        @database = Sequel.connect(config.database_url, :loggers => [logger],
                                   :pool_timeout => 10, :max_connections => 8)
      end

      I18n.load_path = Dir[File.expand_path(File.join(File.dirname(__FILE__), "..", "locales", "*.yml"))]
      #I18n.config.enforce_available_locales = true
      I18n.locale = config.fetch("locale", :en).intern

      @initialized = true
    end
  end

  def self.init_data_and_mutexes
    @running_cert_list = []
    @running_certs     = {}
    @global_counter    = {}
    @cache             = ASM::Cache.new
    @certname_mutex    = Mutex.new
    @deployment_mutex  = Mutex.new
    @hostlist_mutex    = Mutex.new
    @counter_mutex     = Mutex.new
  end

  # Returns an instance of {ASM::Cache}
  #
  # @return [ASM::Cache]
  def self.cache
    @cache
  end

  # Returns the {ASM::Config}
  #
  # If the config has not already been initialized, it will be created from the
  # specified options. If options is empty the configuration options will be
  # loaded from {ASM::Config.default_config_file}.
  #
  # @param (see ASM::Config#initialize)
  def self.config(options = {})
    @config ||= begin
      ASM::Config.new(options)
    end
  end

  def self.secrets
    @secrets ||= ASM::Secrets.create(config)
  end

  # Returns API signing information for ASM REST API. The return value is a hash
  #
  # @example returned data
  #   {:apikey => key, :api_secret => api_secret}
  #
  # @return Hash
  def self.api_info
    @api_info ||= secrets.api_auth
  end

  def self.base_dir
    @base_dir ||= begin
      dir = config.base_dir
      FileUtils.mkdir_p(dir)
      dir
    end
  end

  def self.logger=(logger)
    @logger = logger
    @logger.formatter = ASM::LoggerFormat.new
    @logger
  end

  def self.logger
    @logger ||= begin
      # NOTE: using eval to build the logger. Anyone with write access to our
      # config file can do code injection. Do not do this with user-provided input!
      lgr = eval(config.logger)
      lgr.formatter = ASM::LoggerFormat.new
      lgr
    end
  end

  def self.database
    @database or raise(UninitializedException)
  end

  # Serves as a single place to execute deployments and ensure that the same
  # deployment is not executed more than once concurrently.
  #
  # setup_block will be executed within the exclusion so that it is not
  # executed concurrently either.
  def self.process_deployment(data, deployment_db, &setup_block)
    id = data['id']
    service_deployment = nil
    unless @deployment_mutex
      raise("Must call ASM.init to initialize mutex")
    end
    unless track_service_deployments(id)
      raise(ArgumentError, "Already processing id #{id}. Cannot handle simultaneous requests " +
            "of the same service deployment at the same")
    end
    begin
      yield setup_block

      service_deployment = ASM::ServiceDeployment.new(id, deployment_db)
      service_deployment.debug = ASM::Util.to_boolean(data['debug']) || config.debug_service_deployments
      service_deployment.noop = ASM::Util.to_boolean(data['noop'])
      service_deployment.is_retry = ASM::Util.to_boolean(data['retry'])
      service_deployment.is_teardown = ASM::Util.to_boolean(data['teardown'])
      service_deployment.is_individual_teardown = ASM::Util.to_boolean(data['individualTeardown'])

      deployment_db.create_execution(data)

      Thread.new do
        begin
          service_deployment.process(data)
        ensure
          complete_deployment(id)
        end
        service_deployment.log('Deployment has completed')
      end
    rescue => e
      # If we get here then then thread executing the service deployment hasn't
      # been properly scheduled and we must release the deployment mutex here
      complete_deployment(id)
      raise e
    end
  end

  def self.process_deployment_migration(request)
    payload = request.body.read
    deployment = JSON.parse(payload)

    data = ASM::Data::Deployment.new(database)
    ASM.process_deployment(deployment, data) do
      ASM::ServiceMigrationDeployment.prep_deployment_dir(deployment)

      ASM.logger.info('Initiating the server migration')
      deployment['migration'] = 'true'
      deployment['retry'] = 'true'
      data.load(deployment['id'])
    end
    data.get_execution
  end

  def self.process_deployment_request(request)
    payload = request.body.read
    deployment = JSON.parse(payload)
    data = ASM::Data::Deployment.new(database)
    ASM.process_deployment(deployment, data) do
      data.create(deployment['id'], deployment['deploymentName'])
    end
    data.get_execution
  end

  # TODO: 404 on not found

  def self.clean_deployment(id)
    ASM.execute_async(ASM.logger) do
      ASM::DeploymentTeardown.clean_deployment(id)
      deployment = ASM::DeploymentTeardown.deployment_data(id)
      data = ASM::Data::Deployment.new(database)
      data.load(deployment['id'])
      data.delete
    end
  end

  def self.retry_deployment(id, deployment)
    data = ASM::Data::Deployment.new(database)
    ASM.process_deployment(deployment, data) do
      ASM::UpdateDeployment.backup_deployment_dirs(id,deployment)

      ASM.logger.info("Re-running deployment; this will take awhile ...")
      data.load(deployment['id'])
    end
    data.get_execution
  end

  def self.get_deployment_status(asm_guid)
    deployment_data = ASM::Data::Deployment.new(database)
    deployment_data.load(asm_guid)
    deployment_data.get_execution(0)
  end

  def self.get_deployment_log(asm_guid)
    deployment_data = ASM::Data::Deployment.new(database)
    deployment_data.load(asm_guid)
    deployment_data.get_logs
  end

  def self.process_deployment_request_migration(request)
    payload = request.body.read
    data = JSON.parse(payload)
    deployment = data
    ASM.process_deployment_migration(deployment)
  end

  def self.track_service_deployments(id)
    @deployment_mutex.synchronize do
      @running_deployments ||= {}
      track_service_deployments_locked(id)
    end
  end

  def self.complete_deployment(id)
    @deployment_mutex.synchronize do
      @running_deployments.delete(id)
    end
  end

  def self.active_deployments
    @deployment_mutex.synchronize do
      @running_deployments ||= {}
      @running_deployments.keys
    end
  end

  def self.running_certname_count
    @certname_mutex.synchronize do
      return @running_certs.size
    end
  end

  def self.running_certnames
    @certname_mutex.synchronize do
      return @running_certs.keys.clone
    end
  end

  def self.block_certname(certname)
    @certname_mutex.synchronize do
      @running_certs ||= {}
      return false if @running_certs[certname]
      @running_certs[certname] = true
    end
  end

  def self.unblock_certname(certname)
    @certname_mutex.synchronize do
      @running_certs.delete(certname)
    end
  end

  def self.block_hostlist(hostlist)
    raise(UninitializedException) unless self.initialized?
    @hostlist_mutex.synchronize do
      dup_certs = @running_cert_list & hostlist
      if dup_certs.empty?
        @running_cert_list |= hostlist
      end
      return dup_certs
    end
  end

  def self.unblock_hostlist(hostlist)
    @hostlist_mutex.synchronize do
      @running_cert_list -= hostlist
    end
  end

  def self.counter
    counter_incr(:old_asm)
  end

  def self.counter_incr(name = :global)
    @counter_mutex.synchronize do
      @global_counter[name] ||= 0
      @global_counter[name] += 1
    end
  end

  def self.counter_decr(name = :global)
    @counter_mutex.synchronize do
      @global_counter[name] ||= 0
      unless @global_counter[name] == 0
        @global_counter[name] -= 1
      end

      @global_counter[name]
    end
  end

  def self.get_counter(name = :global)
    @counter_mutex.synchronize do
      @global_counter[name] ||= 0
      @global_counter[name]
    end
  end

  def self.increment_counter_if_less_than(max, name)
    @counter_mutex.synchronize do
      @global_counter[name] ||= 0

      if @global_counter[name] < max
        return @global_counter[name] += 1
      else
        return false
      end
    end
  end

  def self.wait_on_counter_threshold(max, timeout, name = :global, logger = nil)
    under_threshold = false
    start = Time.now
    tries = 0
    result = nil
    logger ||= ASM.logger

    until(under_threshold)
      if Time.now - start >= timeout
        raise("Timed out waiting on global counter %s to be < %d after %d seconds but it is still %d" % [name, max, timeout, get_counter(name)])
      end

      if under_threshold = increment_counter_if_less_than(max, name)
        begin
          result = yield
        ensure
          counter_decr(name)
        end
      else
        tries += 1

        if logger && tries % 10 == 0
          logger.debug("Still waiting on counter %s to go below %d, it's currently %d" % [name, max, get_counter(name)])
        end

        sleep 0.1
      end
    end

    result
  end

  def self.get_metrics(ref_id, from, units, required)
    JSON.dump(ASM::DeviceMetrics.new(ref_id).metrics(from, units, required))
  rescue
    raise ASM::NotFoundException
  end

  private

  def self.reset
    @cache = nil
    @certname_mutex   = nil
    @deployment_mutex = nil
    @hostlist_mutex   = nil
    @running_cert_list = nil
    @running_certs = {}
    @global_counter = {}
    @logger = nil
    @config = nil
    @database.disconnect if @database
    @database = nil
    @base_dir = nil
    @initialized = false
  end

  def self.track_service_deployments_locked(id)
    if @running_deployments[id]
      return false
    end
    @running_deployments[id] = true
  end

  def self.process_dhcp_request(request)
    payload = request.body.read
    data = JSON.parse(payload)
    ASM::ApplianceSetup::DHCP.set_dhcp(data);
  end

  def self.process_monitoring_data(request)
    @monitoring ||= ASM::Monitoring.new
    @monitoring.update_service_status(JSON.parse(request.body.read))
  end

  def self.nagios_export(type, request)
    req = JSON.parse(request.body.read)
    @monitoring ||= ASM::Monitoring.new
    case type
      when 'get_inventory'
        @monitoring.get_resources
      when 'get_chassis'
        @monitoring.get_chassis(req['svc_tag'])
      when 'idrac_eight_inventory'
        @monitoring.idrac_eight_inventory
      else
        nil
    end
  end

  def self.submit_graphite_metrics(request)
    metrics = JSON.parse(request.body.read)
    response = {}
    @graphite ||= ASM::Graphite.new
    response[:submitted], response[:graphite_time] = @graphite.submit_metrics(metrics)
    response
  end

  #portview main method
  def self.get_server_info(id, server_puppet_certname)
    ASM::PortView.get_server_info(id, server_puppet_certname)
  end
end

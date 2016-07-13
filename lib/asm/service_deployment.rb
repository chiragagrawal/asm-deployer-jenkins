require 'asm'
require 'asm/device_management'
require 'asm/private_util'
require 'asm/network_configuration'
require 'asm/processor/server'
require 'asm/processor/win_post_os'
require 'asm/processor/linux_post_os'
require 'asm/processor/linux_vm_post_os'
require 'asm/processor/windows_vm_post_os'
require 'asm/razor'
require 'asm/client/puppetdb'
require 'fileutils'
require 'json'
require 'logger'
require 'open3'
require 'rest_client'
require 'timeout'
require 'securerandom'
require 'yaml'
require 'asm/wsman'
require 'asm/ipmi'
require 'fileutils'
require 'uri'
require 'asm/discoverswitch'
require 'asm/cipher'
require 'asm/resource'
require 'base64'
require 'asm/messaging'
require 'concurrent'
require 'rbvmomi'

class ASM::ServiceDeployment

  ESXI_ADMIN_USER = 'root'

  class SyncException < StandardError; end

  class PuppetEventException < StandardError; end
  class MigrateFailure < StandardError; end
  class MigrationSwitchException < StandardError; end

  include ASM::Translatable

  attr_reader :id
  attr_reader :db

  attr_accessor :service_hash

  def initialize(id, db)
    unless id
      raise(ArgumentError, "Service deployment must have an id")
    end
    @id = id
    @db = db
    @unconnected_servers_mutex = Mutex.new

    # NOTE: if this changes update Type::Server#can_post_install? too
    @supported_os_postinstall = ['vmware_esxi', 'hyperv']
  end

  def id
    @id
  end

  def logger
    @logger ||= create_logger
  end

  def log(msg)
    logger.info(msg)
  end

  def debug=(debug)
    @debug = debug
  end

  def debug?
    @debug
  end

  def noop=(noop)
    @noop = noop
  end

  def decrypt?
    true
  end

  def razor
    @razor ||= ASM::Razor.new(:logger => logger)
  end

  def puppetdb
    @puppetdb ||= ASM::Client::Puppetdb.new(:logger => logger)
  end

  def is_teardown=(is_teardown)
    @is_teardown = is_teardown
  end

  def is_teardown?
    @is_teardown
  end

  def is_individual_teardown=(is_individual_teardown)
    @is_individual_teardown = is_individual_teardown
  end

  def is_individual_teardown?
    @is_individual_teardown
  end

  def is_retry=(is_retry)
    @is_retry = is_retry
  end

  def is_retry?
    @is_retry
  end

  def failed_components
    @failed_components ||= Concurrent::Array.new
  end

  def write_exception(base_name, e)
    backtrace = (e.backtrace || []).join("\n")
    File.write(
        deployment_file("#{base_name}.log"),
        "#{e.inspect}\n\n#{backtrace}"
    )
  end

  def process(service_deployment)
    @service_hash = service_deployment
    begin
      log("Status: Started")
      components(service_deployment)

      ASM.logger.info("Deploying #{service_deployment['deploymentName']} with id #{service_deployment['id']}")

      if is_teardown? && is_individual_teardown?
        msg = t(:ASM069, "Service scale-down action started for %{deploymentName}", :deploymentName => service_deployment['deploymentName'])
      elsif is_teardown? && !is_individual_teardown?
        msg = t(:ASM068, "Deleting deployment %{deploymentName}", :deploymentName => service_deployment['deploymentName'])
      else
        msg = t(:ASM001, "Starting deployment %{deploymentName}", :deploymentName => service_deployment['deploymentName'], :deploymentId => service_deployment['id'])
      end
      log(msg)
      db.log(:info, msg)

      logger.debug("Deployment running on %s" % ASM::PrivateUtil.appliance_ip_address)

      # Write the deployment to filesystem for ease of debugging / reuse
      write_deployment_json(service_deployment)
      hostlist = ASM::DeploymentTeardown.get_deployment_certs(service_deployment)
      dup_servers = hostlist.select{|element| hostlist.count(element) > 1 }
      unless dup_servers.empty?
        msg = t(:ASM002, "Duplicate host names found in deployment %{dup_servers}", :dup_servers => dup_servers.inspect)
        logger.error(msg)
        db.log(:error, msg)
        db.set_status(:error)
        raise(msg)
      end
      if is_retry?
        hostlist = hostlist - ASM::DeploymentTeardown.get_previous_deployment_certs(service_deployment['id'])
      end

      if !is_teardown?
        ds = ASM::PrivateUtil.check_host_list_against_previous_deployments(hostlist)
        unless ds.empty?
          msg = t(:ASM003, "The listed hosts are already in use %{ds}", :ds => ds.inspect)
          logger.error(msg)
          db.log(:error, msg)
          db.set_status(:error)
          raise(msg)
        end

        if service_deployment['migration']
          logger.debug("Processing the service deployment migration")
          process_service_with_rules(service_deployment)
        end

        server_ids = server_component_ids(false)
        logger.debug("Server component_ids: #{server_ids}")
        logger.debug("Already deployed servers #{deployed_server_certs}")
        logger.debug("Already deployed server ids: #{deployed_server_ids}")
        logger.debug("Server Ids not deployed: #{server_ids_not_deployed}")

        fcoe_deployment = false

        # this will process switches first with the new code which will
        # currently do TOR switch processing for any rack servers.
        #
        # Can unfortunately not do fine grained short circuiting in the current
        # code due to it's structure so this will unfortunately introduce some
        # additional inventories during TOR switch processing which would later
        # be done again.
        #
        # This is a temporary situation that will hopefully improve as more switch
        # processing moves to the new code
        process_switches_via_types(service_deployment)

        # Variable will return true if the OS Image type is HyperV and Compellent is used as Storage Component
        # For HyperV Compellent Storage access needs be configured after OS installation to take care of
        # WinPE dual path error
        logger.debug("hyperv deployment with compellent: %s" % is_hyperv_deployment_with_compellent?)
        logger.debug("hyperv deployment with EMC VNX: %s" % is_hyperv_deployment_with_emc?)

        # Check if the deployment contains Compellent Storage component with port-type as iSCSI
        # This variable will be used to control the sequence of operation for each component
        # Variable '@iscsi_compellent_vmware' is added to maintain the compatibility between
        # iSCSI Compellent VMware and HyperV deployments
        logger.debug("Value of iscsi_compellent : %s " % is_iscsi_compellent_deployment?)

        # Initiate rule based deployment early on, ordering and so are handled there on it's
        # own and any components/swimlanes we migrate to the new code will not be processed anymore
        # by the code below, so I think doing this here should be sufficient for a while but right
        # now all we support provisioning with rules is the CONFIGURATION swimlane where this is fine
        #
        # When moving this later be sure to study the rules in rules/service and ensure nothing unexpected
        # is going to called as a result
        process_service_with_rules(service_deployment)

        process_components(true) unless boot_from_san_deployment?
        # Changing the ordering of SAN and LAN configuration
        # To ensure that the server boots with razor image

        fcoe_deployment ? deploy_vm_flag = 'no' : deploy_vm_flag = 'yes'

        @cluster_execution_count = 1
        process_components(false, true, deploy_vm_flag)

        # Remove PXE VLAN where appropriate
        process_switches_via_types(service_deployment)

        # Post cluster processing.  We want to skip for components that are "brownfield only" components
        server_components = components_by_type("SERVER")
                                .reject{|comp| comp["brownfield"] || failed_components.include?(comp["id"])}
        cluster_components = components_by_type("CLUSTER")
                                 .reject{|comp| comp["brownfield"] || failed_components.include?(comp["id"])}
        if is_iscsi_compellent_deployment? && !is_hyperv_deployment_with_compellent?
          cluster_components.each do |cluster_component|
            iscsi_compellent_cluster_processing(cluster_component)
          end
          process_components(false, true, 'only') unless cluster_components.empty?
        end
      else
        # disregard any exception during teardown/scaledown and continue
        begin
          process_service_with_rules(service_deployment)
        rescue => te
          log("Encountered an error while processing scaledown/teardown (this will be disregarded) - %s: %s: %s" % [te, te.class, te.to_s])
        end
      end
      update_vcenters
    rescue => e
      if e.class == ASM::UserException
        logger.error(e.to_s)
        db.log(:error, t(:ASM004, "%{e}", :e => e.to_s))
      end
      write_exception('exception', e)
      log("Status: Error")
      db.set_status(:error)
      raise(e)
    end
    finalize_deployment
  end

  # removes torn down components from db and sets deployment state based on remaining components
  #
  # @return [void]
  def finalize_deployment
    components.find_all {|comp| comp["teardown"]}.each { |comp| db.remove_component(comp["id"]) }
    component_statuses = components.reject {|comp| comp["teardown"]}.collect{ |comp| db.get_component_status(comp["id"])[:status] }
    if component_statuses.all? { |status| status == "complete" }
      db.log(:info, t(:ASM005, "Deployment %{deploymentName} completed", :deploymentName => service_hash["deploymentName"]))
      db.set_status(:complete)
      log("Status: Completed")
    else
      db.log(:error, t(:ASM009, "%{name} deployment failed", :name => service_hash["deploymentName"]))
      db.set_status(:error)
      log("Status: Error")
    end
  end

  def write_deployment_json(data)
    json_file = iterate_file(deployment_file("deployment.json"))
    File.open(json_file, "w") {|f| f.puts JSON.pretty_generate(data, :max_nesting=>25)}
  end

  def server_component_ids(include_brownfield=true)
    servers = components_by_type("SERVER")
    servers.reject! { |server| server["brownfield"] } unless include_brownfield
    servers.map { |s| s["id"] }
  end

  def deployed_servers
    @deployed_servers ||= components_by_type('SERVER').map { |c| c if server_already_deployed(c, nil) }.compact
  end

  def deployed_server_ids
    @deployment_server_ids ||= deployed_servers.map {|c| c['id']}.compact
  end

  def deployed_server_certs
    @deployment_server_certs ||= deployed_servers.map {|c| c['puppetCertName']}.compact
  end

  def server_ids_not_deployed
    @not_deployed ||= server_component_ids -  deployed_server_ids
  end

  def boot_from_san_deployment?
    components_by_type('SERVER').each do |component|
      return true if is_server_bfs(component)
    end
    false
  end

  def is_hyperv_deployment_with_compellent?
    return @hyperv_deployment_with_compellent unless @hyperv_deployment_with_compellent.nil?
    retval = false
    components_by_type('SERVER').each do |component|
      cert_name = component['puppetCertName']

      # In the case of Dell servers the cert_name should contain
      # the service tag and we retrieve it here
      is_dell_server = ASM::Util.dell_cert?(cert_name)

      # No need to check for non-dell servers
      return false if !is_dell_server                                                                                  # NOTE: Type::Server#dell_server?

      resource_hash = {}
      os_host_name = nil
      os_image_type = ''
      resource_hash = ASM::PrivateUtil.build_component_configuration(component, :decrypt => decrypt?)
      #Flag an iSCSI / FC boot for san deployment
      if is_dell_server && resource_hash['asm::idrac']                                                                 # NOTE: Type::Server#boot_from_iscsi? and boot_from_san?
        target_boot_device = resource_hash['asm::idrac'][resource_hash['asm::idrac'].keys[0]]['target_boot_device']
        return false if ASM::PrivateUtil.is_target_boot_device_none?(target_boot_device)
        if is_dell_server and (target_boot_device == 'iSCSI' or target_boot_device == 'FC')
          return retval
        end
      end

      if resource_hash['asm::server']
        server = ASM::Resource::Server.create(resource_hash).first
        title = server.title
        os_image_type = server.os_image_type
        os_host_name = server.os_host_name
        os_image_version = server.os_image_version
        params = resource_hash['asm::server'][title]
      else                                                                                                             # NOTE: how would this even happen?
        return retval
      end

      # Check if related storage device contains compellent
      logger.debug("OS Image Type: #{os_image_type}")
      if os_image_type && os_image_type.downcase == "hyperv"                                                           # NOTE: Type::Server#is_hyperv?
        storage_devices = (find_related_components('STORAGE', component) || [] )                                       # NOTE: Type::Switch#related_compellent_volumes? probably move to Server
        storage_devices.each do |storage_device|
          retval = true if storage_device['puppetCertName'].match(/compellent/i)
        end
      end
    end
    @hyperv_deployment_with_compellent = retval
  end


  def is_hyperv_deployment_with_emc?
    return @hyperv_deployment_with_emc_vnx if @hyperv_deployment_with_emc_vnx
    retval = false
    components_by_type('SERVER').each do |component|
      cert_name = component['puppetCertName']

      # No need to check for non-dell servers
      return false unless ASM::Util.dell_cert?(cert_name)                                                               # NOTE: Type::Server#dell_server?

      resource_hash = ASM::PrivateUtil.build_component_configuration(component, :decrypt => decrypt?)
      #Flag an iSCSI / FC boot for san deployment
      if resource_hash['asm::idrac']                                                                 # NOTE: Type::Server#boot_from_iscsi? and boot_from_san?
        target_boot_device = resource_hash['asm::idrac'][resource_hash['asm::idrac'].keys[0]]['target_boot_device']
        return false if ASM::PrivateUtil.is_target_boot_device_none?(target_boot_device)
        return false if ['iSCSI', 'FC'].include?(target_boot_device)
      end

      if resource_hash['asm::server']
        server = ASM::Resource::Server.create(resource_hash).first
        os_image_type = server.os_image_type
      else                                                                                                             # NOTE: how would this even happen?
        return false
      end

      # Check if related storage device contains EMC VNX
      logger.debug("OS Image Type: #{os_image_type}")
      if os_image_type && os_image_type.downcase == "hyperv"                                                           # NOTE: Type::Server#is_hyperv?
        break retval = true unless vnx_components.empty?
      end
    end
    @hyperv_deployment_with_emc_vnx = retval
  end

  def asm_server_component
    asm_servers = []
    components_by_type('SERVER').each do |component|
      cert_name = component['puppetCertName']
      is_dell_server = ASM::Util.dell_cert?(cert_name)
      next if !is_dell_server
      next if is_server_bfs(component)
      resource_hash = ASM::PrivateUtil.build_component_configuration(component, :decrypt => decrypt?)
      asm_servers.push(component) if resource_hash['asm::server']
    end
    logger.debug("ASM Server components #{asm_servers.size}")
    asm_servers
  end

  # Method will return true if the deployment contains Compellent Storage
  # and iSCSI port-type is selected as iSCSI
  # Check will be performed only for the OS Image for which post-installation is supported
  # i.e. VMware and HyperV
  def is_iscsi_compellent_deployment?
    return @iscsi_compellent unless @iscsi_compellent.nil?
    retval = false
    asm_server_component.each do |component|
      resource_hash = ASM::PrivateUtil.build_component_configuration(component, :decrypt => decrypt?)
      server = ASM::Resource::Server.create(resource_hash).first
      os_image_type = server.os_image_type || ''

      # Check if related storage device contains compellent
      next unless @supported_os_postinstall.include?(os_image_type.downcase)
      storage_devices = (find_related_components('STORAGE', component) || [] )
      storage_devices.each do |storage_device|
        if storage_device['puppetCertName'].match(/compellent/i) and
            compellent_component_port_type(storage_device).downcase == 'iscsi'
          retval = true
          break
        end
      end
    end
    logger.debug("Deployment is using compellent with iscsi #{retval}")
    @iscsi_compellent = retval
  end

  def compellent_component_port_type(storage_component)
    port_type = 'FibreChannel'
    resource_hash = ASM::PrivateUtil.build_component_configuration(storage_component, :decrypt => decrypt?)
    (resource_hash['asm::volume::compellent'] || {}).each do |title, params|
      port_type = params['porttype']
    end
    port_type
  end

  def components(service_deployment = nil)
    if service_deployment
      @components = Concurrent::Array.new
      if service_deployment['serviceTemplate']
        template_components = ASM::Util.asm_json_array((service_deployment['serviceTemplate'] || {})['components'] || [])
        if template_components.empty?
          logger.warn("service deployment data has no components")
        else
          logger.debug("Found #{template_components.length} components")
        end
        template_components.each do |component|
          @components.push(component)
        end
      else
        logger.warn("Service deployment data has no serviceTemplate defined")
      end
    end
    @components
  end

  def components_by_type(type, components_to_search = components)
    components.find_all{|component| component["type"] == type }
  end

  def update_component(id, new_data)
    new_template_components = ASM::Util.asm_json_array((new_data['serviceTemplate'] || {})['components'] || [])
    new_component = new_template_components.find{ |component| component["id"] == id }
    components.map! do |component|
      component["id"] == id ? new_component : component
    end
    new_component
  end

  def is_vnx?
    components_by_type("STORAGE").any?{|storage| storage["name"] == 'VNX'}
  end

  def process_components(pre_process_server=false,compellent_mapping=true,deploy_vm='yes')
    component_sequence = %w(STORAGE SERVER CLUSTER VIRTUALMACHINE TEST)
    component_sequence = %w(STORAGE SERVER CLUSTER) if deploy_vm == 'no'
    if is_iscsi_compellent_deployment? && !is_hyperv_deployment_with_compellent?
      component_sequence = %w(SERVER CLUSTER STORAGE)
    elsif is_iscsi_compellent_deployment? && is_hyperv_deployment_with_compellent?
      component_sequence = %w(SERVER STORAGE CLUSTER VIRTUALMACHINE TEST)
    end

    if is_vnx?
      component_sequence = %w(SERVER STORAGE CLUSTER VIRTUALMACHINE TEST)
    end

    component_sequence = %w(VIRTUALMACHINE) if deploy_vm == 'only'
    component_sequence = ['SERVER'] if  pre_process_server
    component_sequence = ['STORAGE'] if !compellent_mapping

    logger.debug("Component sequence that needs to be processed: #{component_sequence}")
    exceptions = []
    #We organize the components to process so we can take a look at if there are components following in the sequence
    components_to_process = component_sequence.map do |type|
      unless components_by_type(type).empty?
        {:type => type, :components => components_by_type(type)}
      end
    end.compact
    components_to_process.each_with_index do |components_hash, index|
      type = components_hash[:type]
      components = components_hash[:components]
      next if components.nil?
      if pre_process_server
        log("Initial processing components of type #{type}")
        log("Status: Initial_Processing_#{type.downcase}")
        db.log(:info, t(:ASM056, "Initial processing %{type} components", :type => type.downcase))
      else
        log("Processing components of type #{type}")
        log("Status: Processing_#{type.downcase}")
        db.log(:info, t(:ASM006, "Processing %{type} components", :type => type.downcase))
      end

      current_failed = Array.new(failed_components)
      threads = components.collect do |comp|
        # If server fails at the pre_process state, we just want it to error out
        # instead of making another thread for it again (which may not fail in
        # the normal process stage)

        # WARNING: because we are in components.collect and components is a
        # Concurrent::Array we hold its lock here. We can't access failed_components
        # directly because it is also a Concurrent::Array and that would acquire
        # its lock as well leading to deadlocks. Thus we access a copy here.
        next if current_failed.include?(comp["id"])

        create_component_thread(comp, type, pre_process_server, compellent_mapping)
      end.compact
      threads.each do |thrd|
        thrd.join
        if thrd[:exception]
          # We don't push the exception if we're processing a server that doesn't have any components after it to process
          # This means we wont' fail on an exception from the server, and instead will fail at the cluster component from lacking servers
          # The exceptions will still be logged, though, so debugging will still be possible on why servers failed
          exceptions.push(thrd[:exception]) if push_component_exception?(thrd[:component])
          failed_components << thrd[:component_id]
        end
      end

      if exceptions.empty?
        if pre_process_server
          log("Finished initial processing for components of type #{type}")
          db.log(:info, t(:ASM058, "Finished initial processing %{type} components", :type => type.downcase))
        else
          log("Finished components of type #{type}")
          db.log(:info, t(:ASM010, "Finished processing %{type} components", :type => type.downcase))
        end
      else
        msg = t(:ASM011, "Error while processing %{type} components", :type => type.downcase)
        log(msg)
        db.log(:error, msg)
        # Failing by raising *one of* the exceptions thrown in the process thread
        # Other failures will be captured in exception log files.
        raise exceptions.first
      end
    end
  end

  def push_component_exception?(component)
    type = component["type"]
    return true unless type == "SERVER"
    # Can only have 1 cluster per server/VM, so we just take first in the list
    related_cluster = find_related_components("CLUSTER", component).first
    # find_related_components should only return components that haven't failed, and we remove the current component we're looking at
    # If it's empty, either this component is the only server/VM to be configured, or all the other ones have failed as well, so we should throw exception.
    others = find_related_components(type, related_cluster).reject { |comp| comp == component}
    others.empty?
  end

  #
  # TODO: this is some pretty primitive thread management, we need to use
  # something smarter that actually uses a thread pool
  #
  def create_component_thread(component, type, pre_process_server, compellent_mapping)
    Thread.new do
      log("Processing component #{component['name']}")
      raise("Component has no certname") unless component["puppetCertName"]
      thrd = Thread.current
      thrd[:component] = component
      thrd[:component_id] = component["id"]
      thrd[:component_name] = component["name"]
      thrd[:attempts] ||= 1
      begin
        unless thrd[:component]["brownfield"]
          # We want exceptions from migrating to be caught here.  If we can't get connectivity from switches/server, we need to try again.
          if thrd[:migrate]
            new_server, new_deployment_data = migrate(thrd[:component])
            thrd[:component] = new_server
            old_certname = thrd[:certname]
            thrd[:certname] = new_server["puppetCertName"]
            # Reset the exception we store since we found a new server try with
            thrd[:exception] = nil
            process_migrated_server(new_deployment_data, old_certname, new_server["puppetCertName"])
          end
          thrd[:certname] = thrd[:component]["puppetCertName"]
          if unconnected_servers.include?(thrd[:certname])
            # This is the same exception thrown in switch_collection#poll_for_switch_inventory! when switch connectivity cannot be found
            # We catch it above in the first call (process_switches_by_types) and throw it here, so we can migrate in case of failure
            raise(ASM::UserException, t(:ASM061, "Failed to determine switch connectivity for %{server_certs}",
                                        :server_certs => thrd[:certname]))
          end
          db.set_component_status(thrd[:component_id], :in_progress)
          if pre_process_server
            send("process_#{type.downcase}_pre_os", thrd[:component])
            log("Status: Completed_component_#{type.downcase}/#{thrd[:certname]}")
            db.log(:info, t(:ASM057, "%{component_name} initial configuration complete", :component_name => thrd[:component_name]), :component_id => thrd[:component_id])
          else
            if type == "STORAGE"
              send("process_#{type.downcase}", thrd[:component], compellent_mapping)
            else
              send("process_#{type.downcase}", thrd[:component])
            end
            log("Status: Completed_component_#{type.downcase}/#{thrd[:certname]}")
            db.log(:info, t(:ASM008, "%{component_name} deployment complete", :component_name => thrd[:component_name]), :component_id => thrd[:component_id])
          end
        end
        # Services/apps are no longer their own swimlane, so we just set status
        # to "complete" if the parent component succeeded. Otherwise, deployment
        # status will return error, since the service component status is not
        # considered complete
        find_related_components("SERVICE", thrd[:component], true).each do |c|
          db.set_component_status(c["id"], :complete)
        end
        db.set_component_status(thrd[:component_id], :complete)
      rescue => e
        log("Status: Failed_component_#{type.downcase}/#{thrd[:certname]}")
        # We don't want to log the exception if it's just a failure to migrate
        thrd[:exception] = e unless e.is_a?(MigrateFailure)
        write_exception("#{thrd[:certname]}_exception", thrd[:exception])
        if !e.is_a?(MigrateFailure) && should_attempt_migrate?(thrd[:component], thrd[:attempts]) && pre_process_server
          thrd[:migrate] = true
          thrd[:attempts] += 1
          retry
        else
          db.set_component_status(thrd[:component_id], :error)
          if thrd[:exception].class == ASM::UserException
            db.log(:error, t(:ASM004, "%{e}", :e => thrd[:exception].to_s,), :component_id => thrd[:component_id])
          else
            db.log(:error, t(:ASM009, "%{name} deployment failed", :name => thrd[:component_name], :id => thrd[:component_id]), :component_id => thrd[:component_id])
          end
        end
      end
    end
  end

  def pooled_puppet_runner(resource_file, cert_name)
    work_queue = TorqueBox.fetch('/queues/asm_jobs')

    msg = {:id => @id, :action => "puppet_apply",
           :cert_name => cert_name, :resources => File.read(resource_file)}

    logger.debug("Sending apply request to %s: %s" % [work_queue, msg.to_json])
    props = { :action => 'puppet_apply', :version => 1 }
    body = work_queue.publish_and_receive(msg,
                                          :properties => props,
                                          :timeout => 30 * 60 * 1000)

    return([@id, cert_name, false, "timed out waiting for pool worker", ""]) unless body

    unless @id == body[:id] && cert_name == body[:cert_name]
      # shouldn't be possible, but worth a check..
      raise("Got a reply for cert_name %s and id %s but expected cert_name %s and id %s" %
                [body[:cert_name], body[:id], cert_name, @id])
    end

    logger.debug("Got reply for %s: %s: success: %s msg: %s" %
                     [ body[:id], body[:cert_name], body[:success], body[:msg] ])

    [body[:id], body[:cert_name], body[:success], body[:msg], body[:log]]
  rescue
    logger.debug("pooled puppet request failed: %s" % $!.inspect)
    logger.debug($!.backtrace.inspect)
    raise
  end

  # Run process_generic on the deployment and surpress running inventories
  #
  # Updating of inventories are to be done in a rule
  #
  # @param cert_name [String] the certificate name to process
  # @param config [Hash] a set of puppet resource asm process_node will accept
  # @param puppet_run_type ["device", "apply"] the way puppet should be run
  # @param override [Boolean] override config file settings
  # @param server_cert_name [String] allow customization of log file names for shared devices
  # @param asm_guid [String] internal ASM inventory GUID
  # @param update_inventory [Boolean] allow inventory update to be skipped at the end of processing
  # @return [Hash] the results from the puppet run
  def process_generic(
    cert_name,
    config,
    puppet_run_type,
    override = true,
    server_cert_name = nil,
    asm_guid=nil,
    update_inventory=true
  )
    raise( 'Component has no certname') unless cert_name
    log("Starting processing resources for endpoint #{cert_name}")
    log("RUN TYPE:" + puppet_run_type)

    summary_file = File.join(resources_dir, "state", cert_name, "last_run_summary.yaml")
    if server_cert_name != nil
      resource_file = File.join(resources_dir, "#{cert_name}-#{server_cert_name}.yaml")
    else
      resource_file = File.join(resources_dir, "#{cert_name}.yaml")
    end

    puppet_out = iterate_file(deployment_file("#{cert_name}.out"))

    ASM::PrivateUtil.wait_until_available(cert_name, ASM::PrivateUtil.large_process_max_runtime, logger) do
      # synchronize creation of file counter
      resource_file = iterate_file(resource_file)
      start_time = Time.now

      File.open(resource_file, 'w') do |fh|
        fh.write(config.to_yaml)
      end

      args = %w(sudo puppet asm process_node --debug --trace --filename)
      args += [ resource_file, '--run_type', puppet_run_type, '--statedir', resources_dir]
      args.push('--always-override') if override
      args.push('--noop') if @noop
      args.push(cert_name)
      cmd = args.join(' ')
      logger.debug "Executing the command #{cmd}"

      if @debug
        logger.info("[DEBUG MODE] puppet execution skipped")
      elsif puppet_run_type == 'apply' && ASM.config.work_method == :queue
        logger.debug("Starting pool based apply for certname %s using resource_file %s" % [cert_name, resource_file])

        begin
          id, cert_name, success, reason, log = pooled_puppet_runner(resource_file, cert_name)
        rescue
          logger.debug("Pooled puppet runner failed: %s" % $!.inspect)
          logger.debug($!.backtrace.inspect)
          raise
        end

        File.open(puppet_out, "w") {|f| f.puts log}

        raise("puppet asm process_node for %s failed: %s" % [cert_name, reason]) unless success
      else
        ASM::Util.run_command_streaming(cmd, puppet_out)

        success, reason = ASM::DeviceManagement.puppet_run_success?(cert_name, 0, start_time, puppet_out, summary_file)

        raise("puppet asm process_node for %s failed: %s" % [cert_name, reason]) unless success
      end
    end

    results = {}
    unless @debug
      # Check results from output of puppet run
      found_result_line = false
      File.readlines(puppet_out).each do |line|
        if ! line.valid_encoding?
          line = line.encode('UTF-8', 'binary', :invalid => :replace, :undef => :replace, :replace => "?")
        end
        if line =~ /Results: For (\d+) resources\. (\d+) from our run failed\. (\d+) not from our run failed\. (\d+) updated successfully\./
          results = {'num_resources' => $1, 'num_failures' => $2, 'other_failures' => $3, 'num_updates' => $4}
          found_result_line = true
          break
          if line =~ /Puppet catalog compile failed/
            raise("Could not compile catalog")
          end
        end
      end
      unless puppet_run_type == 'agent'
        raise("Did not find result line in file #{puppet_out}") unless found_result_line
      end
    end

    # note if new inventory behaviours are added you'll need to make similar updates to the type and provider system
    #
    # see {Type::Base#should_inventory?}, {Type::Base#update_inventory} and their per provider counterparts
    if update_inventory
      # Update puppet device facts
      device_config = ASM::DeviceManagement.parse_device_config(cert_name)
      update_facts = true if puppet_run_type == 'device'
      update_facts = true if puppet_run_type == 'apply' && device_config && device_config[:provider] == 'script'
      update_facts = false if @debug
      begin
        logger.info("Updating inventory data for #{cert_name}")
        ASM::DeviceManagement.run_puppet_device!(cert_name, logger) if update_facts
        ASM::DeviceManagement.run_puppet_device!(asm_guid, logger) if update_facts && asm_guid && asm_guid != cert_name
      rescue ASM::DeviceManagement::SyncException => e
        logger.info("Inventory run already in progress for #{cert_name}")
      end
    end

    results
  end

  #
  # occassionally, the same certificate is re-used by multiple
  # components in the same service deployment. This code checks
  # if a given filename already exists, and creates a different
  # resource file by appending a counter to the end of the
  # resource file name.
  #
  # NOTE : This method is not thread safe. I expects it's calling
  # method to invoke it in a way that is thread safe
  #
  def iterate_file(file)
    if File.exists?(file)
      file_ext = file.split('.').last
      # search for all files that match our pattern, increment us!
      base_name = File.basename(file, ".#{file_ext}")
      dir       = File.dirname(file)
      matching_files = File.join(dir, "#{base_name}___*")
      i = 1
      Dir[matching_files].each do |f|
        f_split   = File.basename(f, ".#{file_ext}").split('___')
        num = Integer(f_split.last)
        i = num > i ? num : i
      end
      file = File.join(dir, "#{base_name}___#{i + 1}.#{file_ext}")
    else
      file
    end
  end

  #
  # This method is used for collecting server wwpn to
  # provide to compellent for it's processing
  #
  def get_dell_server_wwpns
    log("Processing server component for compellent")
    if server_components = components_by_type('SERVER')
      server_components.collect do |comp|
        cert_name = comp['puppetCertName']
        if ASM::Util.dell_cert?(cert_name)
          deviceconf = ASM::DeviceManagement.parse_device_config(cert_name)
          ASM::WsMan.get_wwpns(deviceconf,logger)
        end
      end.compact.flatten.uniq
    end
  end

  def get_specific_dell_server_wwpns(comp)
    # For FCoE enabled caes, the format of getting WWPN is different
    if is_fcoe_enabled(comp)
      return get_specific_dell_server_fcoe_wwpns(comp)
    end
    if is_iscsi_compellent_deployment? && !is_hyperv_deployment_with_compellent? && !is_hyperv_deployment_with_emc?
      logger.debug("Getting IQN for VMware iSCSI Compellent for server #{comp['puppetCertName']}")
      return get_esxi_server_iqn(comp)
    elsif is_iscsi_compellent_deployment? && is_hyperv_deployment_with_compellent? && is_hyperv_deployment_with_emc?
      logger.debug("Getting IQN for HyperV iSCSI Compellent for server #{comp['puppetCertName']}")
      return get_hyperv_server_iqn(comp)
    end

    wwpninfo=nil
    cert_name   = comp['puppetCertName']
    return unless ASM::Util.dell_cert?(cert_name)
    deviceconf = ASM::DeviceManagement.parse_device_config(cert_name)
    ASM::WsMan.get_wwpns(deviceconf,logger)
  end

  def is_fcoe_enabled(server_component)
    false
  end

  def get_pxe_vlan(server_component)
    pxe_vlan = ''
    network_configs = build_network_config(server_component)
    pxe_network = network_configs.get_networks('PXE')
    if !pxe_network.empty?
      raise('One PXE network needs to be mapped to the server') if pxe_network.length > 1
      pxe_vlan = pxe_network.first['vlanId'].to_s
    end
    pxe_vlan
  end

  def get_specific_dell_server_fcoe_wwpns(comp)
    wwpninfo=nil
    wwpn = []

    puppetcertName=comp['puppetCertName']
    return unless ASM::Util.dell_cert?(puppetcertName)

    net_config=build_network_config(comp)
    device_conf = ASM::DeviceManagement.parse_device_config(puppetcertName)
    options = { :add_partitions => true }
    net_config.add_nics!(device_conf, options)
    fcoe_partitions = net_config.get_partitions('STORAGE_FCOE_SAN')
    logger.debug("fcoe_partions info #{fcoe_partitions.inspect}")
    fcoe_fqdd = []
    fcoe_partitions.each do |fcoe_patition|
      fcoe_fqdd.push(fcoe_patition['fqdd'])
    end
    logger.debug("FCoE FQDDs: #{fcoe_fqdd}")

    fcoe_info = ASM::WsMan.get_fcoe_wwpn(device_conf,logger)
    logger.debug("FCoE Info inside deployer: #{fcoe_info}")
    if fcoe_info
      logger.debug("FCoE Info exists")
      fcoe_info.keys.each do |interface|
        if fcoe_fqdd.include?(interface)
          logger.debug("Interface for which value is retreived: #{interface}")
          wwpn.push(fcoe_info[interface]['virt_wwpn'])
        end
      end
    end
    wwpn.uniq.compact
  end


  def get_esxi_server_iqn(comp)
    wwpn = []
    return wwpn unless ASM::Util.dell_cert?(comp['puppetCertName'])
    esxi_endpoint = get_esx_endpoint(comp)
    server_conf = ASM::PrivateUtil.build_component_configuration(comp, :decrypt => decrypt?)
    server_params = (server_conf["asm::server"] || [])[comp["puppetCertName"]]
    if server_params && server_params["iscsi_initiator"] == "software"
      hba_list = parse_software_hbas(esxi_endpoint)
    else
      hba_list = parse_hbas(esxi_endpoint, get_iscsi_macs(comp))
    end
    esxi_iscsi_iqns(hba_list,esxi_endpoint).uniq.compact
  end

  def get_hyperv_server_iqn(comp)
    os_host_name = get_asm_server_params(comp)['os_host_name'].downcase
    fqdn = get_asm_server_params(comp)['fqdn'].downcase
    ["iqn.1991-05.com.microsoft:#{os_host_name}",
     "iqn.1991-05.com.microsoft:#{os_host_name}.#{fqdn}"]
  end

  def esxi_iscsi_iqns(hba_list,esxi_endpoint)
    iqns = []
    (hba_list || []).each do |hba|
      logger.debug("hba : #{hba}")
      cmd = %w(iscsi adapter get --adapter ).push(hba)
      ASM::Util.esxcli(cmd, esxi_endpoint, logger, true, 1200).lines.collect do |line|
        if line.match(/Name:\s+(iqn.*)/)
          iqns.push($1.chomp)
        end
      end
    end
    logger.debug ("IQNs: #{iqns}")
    iqns
  end

  def get_iscsi_macs(comp)
    net_config=build_network_config(comp)
    device_conf = ASM::DeviceManagement.parse_device_config(comp['puppetCertName'])
    options = { :add_partitions => true }
    net_config.add_nics!(device_conf, options)

    iscsi_partitions = net_config.get_partitions('STORAGE_ISCSI_SAN')
    iscsi_macs = iscsi_partitions.collect { |p| p.mac_address }.compact
    if iscsi_macs.length < 2
      raise(ASM::UserException, t(:ASM012, "Two iSCSI NICs are required but configuration contains %{count}", :count => iscsi_macs.length))
    elsif iscsi_macs.length > 2
      logger.warn('More than two iSCSI NICs specified; only the first two will be configured')
    end
    iscsi_macs
  end

  def get_esx_endpoint(server_component)
    server_conf = ASM::PrivateUtil.build_component_configuration(server_component, :decrypt => decrypt?)
    server_cert = server_component['puppetCertName']
    network_params = (server_conf['asm::esxiscsiconfig'] || {})[server_cert]
    network_config = ASM::NetworkConfiguration.new(network_params['network_configuration'], logger)
    mgmt_network = network_config.get_network('HYPERVISOR_MANAGEMENT')
    static = mgmt_network['staticNetworkConfiguration']
    esx_endpoint = { :host => static['ipAddress'],
                     :user => ESXI_ADMIN_USER,
                     :password => get_asm_server_params(server_component)['admin_password'] }
    if decrypt?
      esx_endpoint[:password] = ASM::Cipher.decrypt_string(esx_endpoint[:password])
    end
    esx_endpoint
  end

  def get_asm_server_params(server_component)
    server_conf = ASM::PrivateUtil.build_component_configuration(server_component, :decrypt => decrypt?)
    server_conf['asm::server'].fetch(server_component['puppetCertName'], {})
  end
  public :get_asm_server_params

  def process_test(component)
    config = ASM::PrivateUtil.build_component_configuration(component, :decrypt => decrypt?)
    process_generic(component['puppetCertName'], config, 'apply', true)
  end

  def build_network_config(server_comp)
    server = ASM::PrivateUtil.build_component_configuration(server_comp, :decrypt => decrypt?)
    network_params = server['asm::esxiscsiconfig']
    if network_params && !network_params.empty?
      title = network_params.keys[0]
      config = network_params[title]['network_configuration']
      ASM::NetworkConfiguration.new(config, logger) if config
    end
  end

  def build_related_network_configs(comp)
    related_servers = find_related_components('SERVER', comp)
    related_servers.map do |server_comp|
      if !is_teardown?
        build_network_config(server_comp) unless server_comp['teardown']
      else
        build_network_config(server_comp) if server_comp['teardown']
      end
    end.compact
  end

  def process_storage(component, compellent_mapping=true)
    log("Processing storage component: #{component['id']}")

    if component['puppetCertName'].match(/vnx/i)
      return process_storage_vnx(component)
    end

    resource_hash ||= ASM::PrivateUtil.build_component_configuration(component, :decrypt => decrypt?)
    #TODO: Hack to remove no-op param until we use provider
    resource_hash.each do |resource, val|
      val.each do |title, params|
        params.delete("add_to_sdrs")
      end
    end

    process_storage = false
    (resource_hash['asm::volume::compellent'] || {}).each do |title, params|
      # Check if the volume has boot volume set to true
      related_servers = find_related_components('SERVER', component)
      boot_flag = resource_hash['asm::volume::compellent'][title]['boot']
      if boot_flag
        # There has to be only one related server, else raise error
        unless related_servers.size == 1
          raise("Expected to find only one related server, found #{related_servers.size}")
        end
      end
      configure_san = resource_hash['asm::volume::compellent'][title]['configuresan']
      resource_hash['asm::volume::compellent'][title].delete('configuresan')
      resource_hash['asm::volume::compellent'][title]['force'] = 'true'
      resource_hash['asm::volume::compellent'][title]['manual'] = 'true'

      # Standalone storage component is passed
      # Just create the volume
      if related_servers.empty?
        vol_size = resource_hash['asm::volume::compellent'][title]['size']
        if vol_size.nil?
          logger.debug("Processing existing compellent volume")
          resource_hash = ASM::PrivateUtil.update_compellent_resource_hash(component['asmGUID'],
          resource_hash,title,logger)
        end
        resource_hash['asm::volume::compellent'][title]['servername'] = ""

        process_generic(
        component['puppetCertName'],
        resource_hash,
        'apply',
        true,
        nil,
        component['asmGUID']
        )
      end

      related_servers.each do |server_comp|
        wwpns = nil
        wwpns ||= (get_specific_dell_server_wwpns(server_comp || []))
        new_wwns = wwpns.compact.map {|s| s.match(/^iqn.*/) ? s : s.gsub(/:/, '' )}
        resource_hash['asm::volume::compellent'][title]['wwn'] = new_wwns
        server_servicetag = ASM::Util.cert2serial(server_comp['puppetCertName'])

        vol_size = resource_hash['asm::volume::compellent'][title]['size']
        if vol_size.nil?
          logger.debug("Processing existing compellent volume")
          resource_hash = ASM::PrivateUtil.update_compellent_resource_hash(component['asmGUID'],
            resource_hash,title,logger)
          configure_san = true
        end

        if (is_fcoe_enabled(server_comp) ||
            (is_hyperv_deployment_with_compellent? &&
                !is_iscsi_compellent_deployment?) ) &&
            compellent_mapping

          configure_san = server_component_ids.size == deployed_servers.size
        end

        # For HyperV FC deployment with Compellent, need to skip configure san for the first attempt
        # Need to perform server object creation and mapping if the server is already configured and mapped
        if is_hyperv_deployment_with_compellent? &&
            compellent_mapping &&
            server_component_ids.size == deployed_servers.size
          configure_san = true
        end

        # For iscsi compellent deployment, configure san flag is not required
        # need to set the flag to true if the deployment is for iscsi compellent
        configure_san = true if is_iscsi_compellent_deployment?

        logger.debug("Configure SAN for compellent: #{configure_san}")

        if configure_san
          resource_hash['asm::volume::compellent'][title]['servername'] = "ASM_#{server_servicetag}"
        else
          resource_hash['asm::volume::compellent'][title]['servername'] = ""
        end

        process_generic(
        component['puppetCertName'],
        resource_hash,
        'apply',
        true,
        nil,
        component['asmGUID']
        )
      end
      process_storage = true
    end

    # Process EqualLogic manifest file in case auth_type is 'iqnip'
    network_configs = build_related_network_configs(component)
    (resource_hash['asm::volume::equallogic'] || {}).each do |title, params|
      if resource_hash['asm::volume::equallogic'][title]['auth_type'] == "iqnip"
        iscsi_ipaddresses = network_configs.map do |network_config|
          ips = network_config.get_static_ips('STORAGE_ISCSI_SAN')
          ips
        end.flatten.uniq
        logger.debug "iSCSI IP Address reserved for the deployment: #{iscsi_ipaddresses}"
        server_template_iqnorip = resource_hash['asm::volume::equallogic'][title]['iqnorip']
        logger.debug "server_template_iqnorip : #{server_template_iqnorip}"
        if !server_template_iqnorip.nil?
          logger.debug "Value of IP or IQN provided"
          new_iscsi_iporiqn = server_template_iqnorip.split(',') + iscsi_ipaddresses
        else
          logger.debug "Value of IP or IQN not provided in service template"
          new_iscsi_iporiqn = iscsi_ipaddresses
        end
        new_iscsi_iporiqn = new_iscsi_iporiqn.compact.map {|s| s.gsub(/ /, '')}
        resource_hash['asm::volume::equallogic'][title]['iqnorip'] = new_iscsi_iporiqn
      end
      resource_hash['asm::volume::equallogic'][title]['auth_ensure'] = 'absent' if is_teardown?
    end

    (resource_hash['netapp::create_nfs_export'] || {}).each do |title, params|
      # TODO: Why is the variable called management_ipaddress if it is a list including nfs ips?
      management_ipaddress = network_configs.map do |network_config|
        # WAS: if name == 'hypervisor_network' or name == 'converged_network' or name == 'nfs_network'
        # TODO: what network type is converged_network?
          network_config.get_static_ips('HYPERVISOR_MANAGEMENT', 'FILESHARE')
      end.flatten.uniq
      logger.debug "NFS IP Address in host processing: #{management_ipaddress}"
      if management_ipaddress.empty?
        management_ipaddress = ['all_hosts'] # TODO: is this a magic value?
        logger.debug "NFS IP Address list is empty: #{management_ipaddress}"
      end
      resource_hash['netapp::create_nfs_export'][title]['readwrite'] = management_ipaddress
      resource_hash['netapp::create_nfs_export'][title]['readonly'] = ''

      size_param = resource_hash['netapp::create_nfs_export'][title]['size']
      if !size_param.nil?
        if size_param.include?('GB')
          resource_hash['netapp::create_nfs_export'][title]['size'] = size_param.gsub(/GB/,'g')
        end
        if size_param.include?('MB')
          resource_hash['netapp::create_nfs_export'][title]['size'] = size_param.gsub(/MB/,'m')
        end
        if size_param.include?('TB')
          resource_hash['netapp::create_nfs_export'][title]['size'] = size_param.gsub(/TB/,'t')
        end
      else
        # default parameter which is not applicable if volume exists
        netapp_vol_info = ASM::PrivateUtil.find_netapp_volume_info(component['asmGUID'], title, logger)
        vol_size = netapp_vol_info['size-total'].to_f / (1024 * 1024 * 1024 )
        vol_unit = "g"

        if vol_size.to_i > 1
          vol_unit = "g"
        else
          vol_size = netapp_vol_info['size-total'].to_f / (1024 * 1024 )
          vol_unit = "m"
          if vol_size < 1
            vol_size = netapp_vol_info['size-total'].to_f / (1024 )
            vol_unit = "k"
          end
        end
        resource_hash['netapp::create_nfs_export'][title]['size'] = "#{vol_size.to_i}#{vol_unit}"
      end

      resource_hash['netapp::create_nfs_export'][title].delete('path')
      resource_hash['netapp::create_nfs_export'][title].delete('nfs_network')
      snapresv = resource_hash['netapp::create_nfs_export'][title]['snapresv']
      if !snapresv.nil?
        resource_hash['netapp::create_nfs_export'][title]['snapresv'] = snapresv.to_s
      else
        resource_hash['netapp::create_nfs_export'][title]['snapresv'] = '0'.to_s
        resource_hash['netapp::create_nfs_export'][title]['append_readwrite'] = 'true'
      end

      # handling anon
      resource_hash['netapp::create_nfs_export'][title].delete('anon')
    end

    component['puppetCertName'].include?('netapp') ? run_type = 'device' : run_type = 'apply'
    if !process_storage
      process_generic(
        component['puppetCertName'],
        resource_hash,
        run_type,
        true,
        nil,
        component['asmGUID']
      )
    end
  end


  # Configure EMC VNX storage component
  #
  # Following operations are performed
  #
  # * Create volumes on EMC VNX storage device.
  # * For HyperV create initiators using servers WWPN and WWNN values
  # * Create access configuration for each host and volume for end to end connectivity
  #
  # @param component [Hash] storage component hash extracted from service deployment
  # @return [void]
  def process_storage_vnx(component)
    return true unless first_vnx_component?(component)
    ASM::DeviceManagement.run_puppet_device!(component['asmGUID'], logger)
    sleep(10)
    vnx_create_volume(component)

    # In case volume is standalone, then no need to proceed further
    return true if vnx_standalone_volume?
    sleep(60)
    vnx_host_access_configuration(component)
  end

  # Returns hash for volume creation and HyperV inititor configuration
  #
  # @param component [Hash] storage component hash extracted from service deployment
  # @return [Hash]
  def vnx_create_volume(component)
    vnx_volume_hash = {}
    vnx_components.each do |vnx_component|
      # Create volume
      resource_hash ||= ASM::PrivateUtil.build_component_configuration(vnx_component, :decrypt => decrypt?)
      (resource_hash['asm::volume::vnx'] || {}).each do |title, params|
        params.delete("add_to_sdrs")
        related_servers = find_related_components('SERVER', vnx_component)
        vol_size = resource_hash['asm::volume::vnx'][title]['size']
        if vol_size.nil?
          # Updating hash
          resource_hash = ASM::PrivateUtil.update_vnx_resource_hash(vnx_component['asmGUID'], resource_hash, title, logger)
        end
        vnx_volume_hash = vnx_volume_hash.deep_merge(resource_hash)
        logger.debug("VNX Volume Hash with basic volume info: #{vnx_volume_hash}")

        # Create initiator before creating the storage group
        if @hyperv_deployment_with_emc_vnx && !related_servers.empty?
          vnx_initiator_hash = vnx_initiator(vnx_component, related_servers)
          vnx_volume_hash = vnx_volume_hash.deep_merge(vnx_initiator_hash)
          logger.debug("VNX Volume Hash with hyperv volume info: #{vnx_volume_hash}")
        end
      end
    end
    process_generic(
        component['puppetCertName'],
        vnx_volume_hash,
        'apply',
        true,
        nil,
        component['asmGUID']
    )
  end

  # Returns hash for volume access for all servers in the service.
  #
  # Hash will include information of storage group with volume and hosts that needs to be mapped
  # For each volume that needs to be mapped, ALU ID is retrieved from puppet facts and corresponding Host LUN ID is calculated
  #
  # @param storage_component [Hash] storage component hash extracted from service deployment
  # @return [Array<Hash>]
  def vnx_host_access_configuration(storage_component)
    storage_group_name = "ASM-#{@id}"

    #create storagegroup before adding LUNs and Hosts to storagegroup
    process_generic(
        storage_component['puppetCertName'],
        {'asm::volume::vnx' => {'createstoragegroup' => {'sgname' => storage_group_name}}},
        'apply',
        true,
        nil,
        storage_component['asmGUID']
    )
    storage_info = ASM::PrivateUtil.get_vnx_storage_group_info(storage_component['asmGUID'])
    host_lun_count = 0
    storage_group_hashes = []
    luns = []
    vnx_connectedhosts = []

    vnx_components.each do |vnx_component|
      resource_hash = ASM::PrivateUtil.build_component_configuration(vnx_component, :decrypt => decrypt?)
      (resource_hash['asm::volume::vnx'] || {}).each do |title, params|
        related_servers = find_related_components('SERVER', vnx_component)
        resource_hash['asm::volume::vnx'][title]['sgname'] = storage_group_name

        related_servers.each do |server_comp|
          server_hash = ASM::PrivateUtil.build_component_configuration(server_comp, :decrypt => true)
          host_name = ASM::Resource::Server.create(server_hash).first.os_host_name
          if ASM::PrivateUtil.is_host_connected_to_vnx(vnx_component["asmGUID"], host_name, logger)
            vnx_connectedhosts << host_name
          end
        end
        alu = ASM::PrivateUtil.get_vnx_lun_id(vnx_component["asmGUID"], title, logger)
        raise("Unable to find VNX LUN #{title} on the storage ") unless alu
        raise("Hosts are not connected to the storage, perhaps host are not added to brocade zone or alias") if vnx_connectedhosts.empty?

        host_lun_number = host_lun_info(storage_group_name, storage_info, alu)
        unless host_lun_number
          host_lun_number = host_lun_count
          host_lun_count += 1
        end
        luns << {"hlu" => host_lun_number, "alu" => alu}
      end
    end

    # adding luns and connecting hosts
    vnx_connectedhosts.sort.uniq.each do |host_name|
      resource_hash = ASM::PrivateUtil.build_component_configuration(storage_component, :decrypt => decrypt?)
      (resource_hash['asm::volume::vnx'] || {}).each do |title, params|
        params.delete("add_to_sdrs")
        resource_hash['asm::volume::vnx'][title]['host_name'] = host_name
        resource_hash['asm::volume::vnx'][title]['sgname'] = storage_group_name
        # alu is the LUN id you see on the navisphere, hlu is the LUN id that connected host can see
        resource_hash['asm::volume::vnx'][title]['luns'] = luns
        storage_group_hashes << resource_hash
      end
    end
    logger.debug("Storage group hashes: #{storage_group_hashes}")
    storage_group_hashes.each do |vnx_host_access_hash|
      process_generic(
          storage_component['puppetCertName'],
          vnx_host_access_hash,
          'apply',
          true,
          nil,
          storage_component['asmGUID']
      )
    end
  end

  # Returns EMC volume host lun number to be used for storage group configuration
  #
  # Host LUN number is LUN ID accessible to the physical server.
  # LUN ID on EMC is autonumber, but higher number of LUN ID cannot be access on operating systems
  # To address, this EMC has give option to specific used defined LUN ID.
  # Method will return:
  #
  # * existing host lun id, if LUN is already mapped
  # * nil value if storage group do not exists on EMC
  # * next available host lun id, if there are existing LUNs mapped to the storage group and input lun do not existing in storage group
  #
  # @param storage_group_name [String] Storage group name
  # @param storage_info [Array<Hash>] Storage group information retrieved from EMC puppet facts
  # @param alu [String] LUN Id for which look-up of host LUN Id needs to be performed
  # @return [Fixnum, nil]
  def host_lun_info(storage_group_name, storage_info, alu)
    host_lun = nil
    storage_group = storage_info.find  {|x| x["sg_name"] == storage_group_name }
    if storage_group
      luns = ( storage_group["luns"] || [] )
      lun = ( luns.find {|x| x["alu"].to_s == alu.to_s } || {} )
      if lun.empty?
        host_lun = ( luns.collect {|x| x['hlu']} || []).sort.last
        host_lun += 1 if host_lun
      else
        host_lun = lun['hlu']
      end
    end
    host_lun
  end

  # Check if EMC volume is standalone (not mapped to any server in ASM template)
  #
  # @return [Boolean] Returns true if standalone, false otherwise
  def vnx_standalone_volume?
    standalone_volume = false
    vnx_components.each do |vnx_component|
      resource_hash ||= ASM::PrivateUtil.build_component_configuration(vnx_component, :decrypt => decrypt?)
      (resource_hash['asm::volume::vnx'] || {}).each do |title, params|
        related_servers = find_related_components('SERVER', vnx_component)
        standalone_volume = true if related_servers.empty?
        break if standalone_volume
      end
    end
    standalone_volume
  end

  # Returns resource hash for configuring initiators required for HyperV servers
  #
  # @param storage_component [Hash] Storage component hash extracted from service deployment
  # @param related_servers [Array] All server components related to the storage component
  # returns [Hash]
  def vnx_initiator(storage_component, related_servers)
    storage_facts = ASM::PrivateUtil.facts_find(storage_component['asmGUID'])
    initiators =  JSON.parse(storage_facts["initiators"])
    resource_hash = {}
    related_servers.each do |server_comp|
      server_hash = ASM::PrivateUtil.build_component_configuration(server_comp, :decrypt => decrypt?)
      host_name = ASM::Resource::Server.create(server_hash).first.os_host_name
      server_end_point = ASM::DeviceManagement.parse_device_config(server_comp['puppetCertName'])
      wwpn_wwnns = ASM::WsMan.get_wwpns_wwnns(server_end_point)
      wwpn_wwnns.each_with_index do |val, index|
        hba_uid = "%s:%s" % [val[0], val[1]]

        resource_hash['vnx_initiator'] ||= {}
        resource_hash['vnx_initiator']["#{host_name}_#{index}"] = {
            'ensure' => 'present',
            'hba_uid' => hba_uid,
            'hostname' => host_name,
            'ports' => vnx_ports(initiators, hba_uid ),
            'transport' => 'Transport[vnx]'
        }
      end
    end
    resource_hash
  end

  # Identify initiators based on HBA UID  (commbination of WWPN and WWNN)
  #
  # @param [Array] Array of initiator information, extracted from EMC facts
  # @param [String] HBA UID
  #
  # returns [Array<Hash>]
  def vnx_ports(initiators, hba_uid )
    initiator = initiators.find { |x| x["hba_uid"] == hba_uid}
    initiator["ports"].map { |x| x.delete("storage_group_name") }
    initiator["ports"]
  end

  # Returns all EMC VNX oomponents in the deployment
  #
  # @returns [Array<Hash>] Array of all ENC storage components
  def vnx_components
    (components_by_type("STORAGE") || []).find_all {|x| x['puppetCertName'].match(/vnx/i)}
  end

  def first_vnx_component?(storage_component)
    vnx_components.first['id'] == storage_component['id']
  end

  def certname_to_var(certname)
    certname.gsub(/\./,'').gsub(/-/,'')
  end

  def get_server_inventory(certname)
    serverhash = {}
    serverpropertyhash = {}
    serverpropertyhash = Hash.new
    puts "******** In getServerInventory certname is #{certname} **********\n"
    resourcehash = {}
    inv = nil
    device_conf ||= ASM::DeviceManagement.parse_device_config(certname)
    inv  ||= ASM::PrivateUtil.fetch_server_inventory(certname)
    logger.debug "******** In getServerInventory device_conf is #{ASM::Util.sanitize(device_conf)}************\n"
    dracipaddress = device_conf[:host]
    dracusername = device_conf[:user]
    dracpassword = device_conf[:password]
    servicetag = inv['serviceTag']
    model = inv['model'].split(' ').last
    logger.debug "servicetag :: #{servicetag} model :: #{model}\n"
    server_type = inv['serverType']
    if server_type != 'BLADE'
      serverpropertyhash['bladetype'] = "rack"
    else
      serverpropertyhash['bladetype'] = "blade"
      chassis_conf ||= ASM::PrivateUtil.chassis_inventory(servicetag, logger)
      logger.debug "*********chassis_conf :#{ASM::Util.sanitize(chassis_conf)}"
      serverpropertyhash['chassis_ip'] = chassis_conf['chassis_ip']
      serverpropertyhash['chassis_username'] = chassis_conf['chassis_username']
      serverpropertyhash['chassis_password'] = chassis_conf['chassis_password']
      serverpropertyhash['slot_num'] = chassis_conf['slot_num']
      serverpropertyhash['ioaips'] = chassis_conf['ioaips']
      serverpropertyhash['ioaslots'] = chassis_conf['ioaslots']
      serverpropertyhash['ioa_models'] = chassis_conf['ioa_models']
      serverpropertyhash['ioa_service_tags'] = chassis_conf['ioa_service_tags']
    end
    serverpropertyhash['servermodel'] = model
    serverpropertyhash['idrac_ip'] = dracipaddress
    serverpropertyhash['idrac_username'] =  dracusername
    serverpropertyhash['idrac_password'] = dracpassword

    serverpropertyhash['mac_addresses'] = ASM::WsMan.get_mac_addresses(device_conf, logger) unless @debug
    logger.debug "******* In getServerInventory server property hash is #{ASM::Util.sanitize(serverpropertyhash)} ***********\n"
    serverhash["#{servicetag}"] = serverpropertyhash
    logger.debug "********* In getServerInventory server Hash is #{ASM::Util.sanitize(serverhash)}**************\n"
    return serverhash
  end

  def process_server_pre_os(component)
    log("Initial processing of server component: #{component['puppetCertName']}")
    cert_name = component['puppetCertName']

    # In the case of Dell servers the cert_name should contain
    # the service tag and we retrieve it here
    serial_number = ASM::Util.cert2serial(cert_name)
    is_dell_server = ASM::Util.dell_cert?(cert_name)
    logger.debug "#{cert_name} -> #{serial_number}"
    logger.debug "Is #{cert_name} a dell server? #{is_dell_server}"
    resource_hash = {}
    server_vlan_info = {}
    deviceconf = nil
    inventory = nil
    os_host_name = nil
    resource_hash = ASM::PrivateUtil.build_component_configuration(component, :decrypt => decrypt?)
    if !is_dell_server && resource_hash['asm::idrac']
      logger.debug "ASM-1588: Non-Dell server has an asm::idrac resource"
      logger.debug "ASM-1588: Stripping it out."
      resource_hash.delete('asm::idrac')
    end

    #Flag an iSCSI boot from san deployment
    if resource_hash['asm::idrac'] && is_dell_server
      target_boot_device = resource_hash['asm::idrac'][resource_hash['asm::idrac'].keys[0]]['target_boot_device']
    else
      target_boot_device = nil
    end

    if is_dell_server and  (target_boot_device == 'iSCSI' or target_boot_device == 'FC')
      @bfs = true
    else
      @bfs = false
    end

    static_ip = nil
    network_config = build_network_config(component)
    resource_hash.delete('asm::server')

    if is_dell_server && resource_hash['asm::idrac']
      if resource_hash['asm::idrac'].size != 1
        msg = "Only one iDrac configuration allowed per server; found #{resource_hash['asm::idrac'].size} for #{serial_number}"
        logger.error(msg)
        raise(msg)
      end

      title = resource_hash['asm::idrac'].keys[0]
      params = resource_hash['asm::idrac'][title]
      params.delete('migrate_on_failure')
      params.delete('attempted_servers')
      deviceconf = ASM::DeviceManagement.parse_device_config(cert_name)
      inventory = ASM::PrivateUtil.fetch_server_inventory(cert_name)
      params['nfssharepath'] = '/var/nfs/idrac_config_xml'
      params['servicetag'] = inventory['serviceTag']
      params['model'] = inventory['model'].split(' ').last.downcase
      params['force_reboot'] = !is_retry?
      if network_config
        params['network_configuration'] = network_config.to_hash
      end
      params['before'] = []

      if resource_hash['asm::server']
        params['before'].push("Asm::Server[#{cert_name}]")
      end

      if resource_hash['file']
        params['before'].push("File[#{cert_name}]")
      end

      #Process a BFS Server Component
      if params['target_boot_device'] == 'iSCSI'
        logger.debug "Processing iSCSI Boot From San configuration"
        #Flag Server Component as BFS
        @bfs = true
        #Find first related storage component
        storage_component = find_related_components('STORAGE',component)[0]
        #Identify Boot Volume
        boot_volume = storage_component['resources'].detect{|r|r['id']=='asm::volume::equallogic'}['parameters'].detect{|p|p['id']=='title'}['value']
        #Get Storage Facts
        ASM::DeviceManagement.run_puppet_device!(storage_component['puppetCertName'], logger, false)
        params['target_iscsi'] = ASM::PrivateUtil.find_equallogic_iscsi_volume(storage_component['asmGUID'],boot_volume)['TargetIscsiName']
        params['target_ip'] = ASM::PrivateUtil.find_equallogic_iscsi_ip(storage_component['puppetCertName'])
      end
      # Configure BIOS settings
      bios_settings = resource_hash['asm::bios'][title]
      if bios_settings
        db.log(:info, t(:ASM036, "Configuring BIOS for server: %{serial} %{ip}", :serial => serial_number, :ip => deviceconf[:host] || ""))
        bios_settings.delete('ensure')
        bios_settings.delete('bios_configuration')
        params['bios_settings'] = bios_settings
      end
    end

    server_deployed = server_already_deployed(component,nil)
    logger.debug("Server #{} deployed status #{server_deployed}")
    return true if server_deployed

    # The rest of the asm::esxiscsiconfig is used to configure vswitches
    # and portgroups on the esxi host and is done in the cluster swimlane
    resource_hash.delete('asm::esxiscsiconfig')
    resource_hash.delete('asm::baseserver')
    resource_hash.delete('asm::bios')
    process_generic(component['puppetCertName'], resource_hash, 'apply', 'true')

  end

  # ported to Type::Server#deployment_completed? if this change update that
  def server_already_deployed(component,resource_hash)
    cert_name = component['puppetCertName']
    log("Processing server component: #{cert_name}")

    # In the case of Dell servers the cert_name should contain
    # the service tag and we retrieve it here
    is_dell_server = ASM::Util.dell_cert?(cert_name)

    resource_hash = ASM::PrivateUtil.build_component_configuration(component, :decrypt => decrypt?) if resource_hash.nil?
    if is_dell_server and resource_hash['asm::idrac']
      target_boot_device = resource_hash['asm::idrac'][resource_hash['asm::idrac'].keys[0]]['target_boot_device']
    else
      target_boot_device = nil
    end

    # Check if the deployment is BFS, return deployed as false as there is no razor policy for them
    bfs = (target_boot_device == 'iSCSI' or target_boot_device == 'FC')
    # BFS and hardware only installs do not have a razor policy to check, so return false
    return false if bfs || hardware_only(cert_name, resource_hash['asm::server'])

    is_razor_policy_deployed(component)
  end

  # ported in parts to Type::Server#deployment_completed? and Type::Server#razor_status if this change update that
  def is_razor_policy_deployed(server_component)
    already_deployed = false
    # Check the razor policy status and return status
    cert_name = server_component['puppetCertName']
    serial_number = ASM::Util.cert2serial(cert_name)
    server_conf = ASM::PrivateUtil.build_component_configuration(server_component, :decrypt => decrypt?)
    server = ASM::Resource::Server.create(server_conf).first
    title = server.title
    params = server_conf['asm::server'][title]
    os_image_type = (server.os_image_type || '')
    logger.debug("OS Image type: #{os_image_type}")
    begin
      # Get razor task status for this node first
      host_name = params['os_host_name']
      policy_name = "policy-#{params['os_host_name']}-#{@id}".downcase
      node = razor.find_node(serial_number)
      razor_task_status = (razor.task_status(node['name'],policy_name) || '') if !node['name'].nil?
      logger.debug("Task status for cert #{cert_name} , node #{node} is : #{razor_task_status}")
      if ['boot_local_2','boot_local' ].include?(razor_task_status[:status].to_s)
        logger.debug("Server is already configured using razor")
        already_deployed = true
      end
    rescue => e
      logger.debug("Exception: #{e.to_s}")
      logger.debug("Server razor policy is not applied correctly on the server")
      already_deployed = false
    end
    already_deployed
  end

  def is_server_already_registered(certname, node, policy_name)
    logger.debug("Verifying that server checked in correctly with Puppet")
    # Using the bind event with the policy to tell if
    log_event = razor.get_latest_log_event(node, 'bind', 'policy'=>policy_name)
    return false if log_event.nil?
    timestamp = Time.parse(log_event['timestamp'])
    begin
      check_agent_checkin(certname, timestamp, :verbose => false)
    rescue => e
      logger.debug(e.message)
      return false
    end
  end

  # Check if migration should be attempted
  #
  # Uses a component and the number of attempts on that component to check if it's a server, we haven't attempted the max number of times, and migration option is enabled
  #
  # @param [Hash] component The component we are checking to see if we should migrate
  # @param [Fixnum] attempts The number of times we've tried deploying this component
  # @return [Boolean] Whether or not we should attempt to migrate the server
  def should_attempt_migrate?(component, attempts)
    return false if component.nil? || component["type"] != "SERVER" || attempts >= 5
    resources = ASM::PrivateUtil.build_component_configuration(component, :decrypt => decrypt?)
    return false unless resources["asm::idrac"]

    title = resources["asm::idrac"].keys[0]
    !!resources["asm::idrac"][title]["migrate_on_failure"]
  end

  # Migrates a server to a new one chosen by AsmManager
  #
  # @param component [Hash] component to migrate
  # @raise [ASM::MigrateFailure] on failure to find new server to mgirate to
  # @return [Array] new server component as well as the new deployment data to be used
  def migrate(component)
    component_id = component["id"]
    old_certname = component["puppetCertName"]
    logger.info("Migrating server component: %s" % old_certname )
    new_deployment_data = ASM::PrivateUtil.migrate_server(component_id, id)
    if new_deployment_data.nil?
      msg = "%s failed, and could not find a new server to migrate to" % old_certname
      db.log(:info, t(:ASM071, "%{certname} failed, and could not find a new server to migrate to", :certname => old_certname ))
      logger.info(msg)
      raise(MigrateFailure, msg)
    end
    write_deployment_json(new_deployment_data)
    new_server = update_component(component_id, new_deployment_data)
    db.update_component_asm_guid(component_id, new_server["asmGUID"])
    failed_components.delete(component_id)
    [new_server, new_deployment_data]
  end

  # Tears down the server migrated from, as well as configures switches for new server
  #
  # @param [Hash] new_deployment_data the deployment data with the new server in it
  # @param [Hash] old_certname the certname of the server that needs to be migrated
  # @param [Hash] new_certname the certname of the server that was chosen for migration to
  # @raise [ASM::MigrationSwitchException] if switch configuration fails on the new server
  # @return [void]
  def process_migrated_server(new_deployment_data, old_certname, new_certname)
    # Currently, we rely on 'migration' in the deployment data hash to be true for the teardown to work.
    new_deployment_data["migration"] = true
    # If process_service_with_rules is changed to do more than just teardown the server, this might have to be updated.
    # The assumption is only teardown will happen here because of the asm::baseserver resource
    logger.info("Tearing down #{old_certname}...")
    process_service_with_rules(new_deployment_data)
    logger.info("Failed server #{old_certname} has been migrated to #{new_certname}")
    begin
      process_switches_via_types(new_deployment_data,  :server => new_certname)
    rescue => e
      msg = "Migrated to %s, but exception during switch configuration: %s" % [new_certname, e.message]
      logger.error(msg)
      raise(MigrationSwitchException, msg)
    end
  end

  # Create a razor node and issue a check-in for the specified serial_number
  #
  # If a razor node for the specified serial_number does not exist one will be
  # registered for it. Subsequently a check-in will be created for the node.
  #
  # If a razor policy already exists for the specified serial_number, after this
  # method is called the server will boot directly into the policy OS installer
  # the next time it PXE boots.
  #
  # @param serial_number [String] the server serial number
  # @param network_config [ASM::NetworkConfiguration] the server network configuration. {ASM::NetworkConfiguration#add_nics!} should have been called on it.
  # @return [void]
  def enable_razor_boot(serial_number, network_config)
    pxe_partitions = network_config.get_partitions("PXE")
    raise("No OS Installation networks available") if pxe_partitions.empty?

    node = razor.find_node(serial_number)
    unless node
      resp = razor.register_node(:mac_addresses => pxe_partitions.map(&:mac_address),
                                 :serial => serial_number,
                                 :installed => false)
      node = razor.get("nodes", resp["name"]) || raise("Failed to register node for %s. Register_node response was: %s" % [serial_number, resp])
    end

    pxe_macs = pxe_partitions.map(&:mac_address)
    razor.checkin_node(node["name"], pxe_macs, node["facts"] || {:serialnumber => serial_number})
    nil
  end

  # Configures the server to PXE boot
  #
  # After calling this method the server will be configured to PXE boot.
  #
  # For servers with Intel NICs a custom iPXE ISO will be created to match the
  # desired network configuration. That ISO will be mounted as a virtual CD
  # and set first in the boot order.
  #
  # For servers with other NICs the first PXE network interface will be set
  # first in the boot order. This is because the iPXE ISO does not have drivers
  # for many NIC cards.
  #
  # @param network_config [ASM::NetworkConfiguration] the server network configuration. {ASM::NetworkConfiguration#add_nics!} should have been called on it.
  # @param wsman [ASM::WsMan] the WS-Man client object
  # @return [void]
  def enable_pxe(network_config, wsman)
     return if debug?
    pxe_partitions = network_config.get_partitions("PXE")
    raise("No PXE partition found for O/S installation") if pxe_partitions.empty?

    # The iPXE ISO image only has drivers for Intel NICs. Use standard PXE otherwise
    #
    # NOTE: using :power_cycle in jobs below because we are going to blow away
    # the operating system anyway (so it doesn't matter if we disrupt the currently
    # running O/S) and it is potentially much faster depending what is running.
    cards = ASM::NetworkConfiguration::NicInfo.fetch(wsman.client.endpoint, logger)
    enabled_cards = cards.reject(&:disabled?)
    static_boot_eligible = enabled_cards.all? { |c| c.ports.first.vendor == :intel }

    pxe_network = network_config.get_network("PXE")
    if pxe_network.static && !static_boot_eligible
      raise("Static OS installation is only supported on servers with all Intel NICs")
    end

    if static_boot_eligible
      require "asm/ipxe_builder"
      iso_name = "ipxe-%s.iso" % wsman.host
      iso_path = File.join(ASM.config.generated_iso_dir, iso_name)
      iso_uri = File.join(ASM.config.generated_iso_dir_uri, iso_name)
      logger.info("Building custom iPXE ISO %s" % iso_path)
      ASM::IpxeBuilder.build(network_config, wsman.nic_views.size, iso_path)
      logger.info("Booting from custom iPXE ISO %s" % iso_uri)
      wsman.boot_rfs_iso_image(:uri => iso_uri, :reboot_job_type => :power_cycle)
    elsif network_config
      tries = 0
      begin
        logger.info("Setting PXE partition %s to first in boot order for %s" % [pxe_partitions.first.fqdd, wsman.host])
        wsman.set_boot_order(pxe_partitions.first.fqdd, :reboot_job_type => :power_cycle)
      rescue
        raise if (tries += 1) > 1
        logger.warn("Failed due to time out for %s" % wsman.host)
        sleep(30)
        logger.info("Retrying to set the boot order for %s" % wsman.host)
        retry
      end
    end
  end
  # Removes PXE boot options from the boot order
  #
  # After calling this method the server will have the hard disk set first in
  # the boot order. If a virtual CD was previously mounted it will be disconnected.
  #
  #
  # @note ported to Provider::Server::Server#disable_pxe via Type::Server#disable_pxe
  # @param wsman [ASM::WsMan] the WS-Man client object
  # @return [void]
  def disable_pxe(wsman)
    return if debug?

    tries ||= 0
    logger.info("Removing PXE from the boot order for %s" % wsman.client.host)
    wsman.set_boot_order(:hdd, :reboot_job_type => :graceful_with_forced_shutdown)
    if wsman.rfs_iso_image_connection_info[:return_value] == "0"
      wsman.disconnect_rfs_iso_image
    end
  rescue
    raise if (tries += 1) > 1

    logger.warn("Failed to remove PXE from boot order for %s" % wsman.client.host)
    sleep(30)
    logger.info("Retrying to remove PXE from boot order for %s" % wsman.client.host)
    retry
  end

  def process_server(component)
    cert_name = component['puppetCertName']
    log("Processing server component: #{cert_name}")
    # In the case of Dell servers the cert_name should contain
    # the service tag and we retrieve it here
    serial_number = ASM::Util.cert2serial(cert_name)
    is_dell_server = ASM::Util.dell_cert?(cert_name)
    logger.debug "#{cert_name} -> #{serial_number}"
    logger.debug "Is #{cert_name} a dell server? #{is_dell_server}"
    resource_hash = {}
    server_vlan_info = {}
    deviceconf = ASM::DeviceManagement.parse_device_config(cert_name)
    # For PXE booted server, server conf information is not available
    is_dell_server ? server_ip = deviceconf[:host] : server_ip = ""
    inventory = nil
    os_host_name = nil
    db.log(:info, t(:ASM007, "Processing server: %{serial} %{ip}", :serial => serial_number, :ip => server_ip))
    resource_hash = ASM::PrivateUtil.build_component_configuration(component, :decrypt => decrypt?)
    if !is_dell_server && resource_hash['asm::idrac']
      logger.debug "ASM-1588: Non-Dell server has an asm::idrac resource"
      logger.debug "ASM-1588: Stripping it out."
      resource_hash.delete('asm::idrac')
    end

    if resource_hash['asm::idrac'] && resource_hash['asm::idrac'][cert_name]
      resource_hash['asm::idrac'][cert_name].delete('migrate_on_failure')
      resource_hash['asm::idrac'][cert_name].delete('attempted_servers')
    end

    #Flag an iSCSI boot from san deployment
    if is_dell_server && resource_hash['asm::idrac']
      target_boot_device = resource_hash['asm::idrac'][resource_hash['asm::idrac'].keys[0]]['target_boot_device']
    else
      target_boot_device = nil
    end
    if is_dell_server and  (target_boot_device == 'iSCSI' or target_boot_device == 'FC')
      @bfs = true
    else
      @bfs = false
    end

    if resource_hash['asm::server'] &&
        !@bfs &&
        !ASM::PrivateUtil.is_target_boot_device_none?(target_boot_device) &&
        !hardware_only(cert_name, resource_hash['asm::server'])
      if resource_hash['asm::server'].size != 1
        msg = "Only one O/S configuration allowed per server; found #{resource_hash['asm::server'].size} for #{serial_number}"
        logger.error(msg)
        raise(msg)
      end

      resource_hash['asm::server'].delete('local_storage_vsan_type')
      server = ASM::Resource::Server.create(resource_hash).first

      title = server.title
      os_image_type = server.os_image_type
      os_host_name = server.os_host_name
      os_image_version = server.os_image_version

      params = resource_hash['asm::server'][title]
      # Setting the default value of the node_data modification
      # Will validate the puppet agent run based on this time
      pre_process_time = Time.now
      logger.debug("Preprocess time: #{pre_process_time}")
      agent_cert_name = ASM::Util.hostname_to_certname(os_host_name)
      if write_post_install_config(component, agent_cert_name)
        node_data_modify_time = ASM::PrivateUtil.node_data_update_time(agent_cert_name)
      end


      server.process!(serial_number, @id)

      # Teardown should remove old policies, but delete them here just in case
      razor.delete_stale_policy!(serial_number, server.policy_name)                                    # Type::Server#delete_stale_policy!

      resource_hash['asm::server'] = server.to_puppet
    else
      resource_hash.delete('asm::server')
    end

    # Skip server deployment if this is a replacement run and server is already deployed
    #return true if server_already_deployed(component,resource_hash)
    server_deployed = server_already_deployed(component,nil)
    logger.debug("Server #{os_host_name} deployed status: #{server_deployed}")

    # For BM deployment, post-installation scripts can be added for post installation
    if @bfs
      logger.info("#{title}: Node data information is not available, indicating non-baremetal deployment")
      return true if server_deployed
    elsif node_data_modify_time.to_i < pre_process_time.to_i
      logger.info ("#{title}: Node classification data is old")
      return true if server_deployed
    end

    # Create a vmware ks.cfg include file containing esxcli command line
    # calls to create a static management network that will be executed
    # from the vmware ks.cfg
    static_ip = nil
    network_config = nil
    if resource_hash['asm::esxiscsiconfig']
      if resource_hash['asm::esxiscsiconfig'].size != 1
        msg = "Only one ESXi networking configuration allowed per server; found #{resource_hash['asm::esxiscsiconfig'].size} for #{serial_number}"
        logger.error(msg)
        raise(msg)
      end

      title = resource_hash['asm::esxiscsiconfig'].keys[0]
      network_params = resource_hash['asm::esxiscsiconfig'][title]
      if(network_params['network_configuration'])
        network_config = ASM::NetworkConfiguration.new(network_params['network_configuration'], logger)
        network_config.add_nics!(deviceconf)
      end
      if !os_image_type.nil? && os_image_type.downcase == "vmware_esxi"
        if network_config
          db.log(:info, t(:ASM035, "Configuring NIC for server: %{serial} %{ip}", :serial => serial_number, :ip => server_ip))
          mgmt_network = network_config.get_network('HYPERVISOR_MANAGEMENT')
        else
          network_object = resource_hash['asm::esxiscsiconfig'][title]['hypervisor_network']
          mgmt_network = network_object.first
        end
        static = mgmt_network['staticNetworkConfiguration']
        unless static
          # This should have already been checked previously
          msg = "Static network is required for hypervisor network"
          logger.error(msg)
          raise(msg)
        end

        if is_dell_server && network_config && !@debug
          network_config.add_nics!(deviceconf, :add_partitions => true)
          mac_address = network_config.get_partitions('HYPERVISOR_MANAGEMENT').collect do |partition|
            partition.mac_address
          end.compact.first
            logger.debug("Found mac address for hypervisor management nic: #{mac_address}") if mac_address
        end

        static_ip = static['ipAddress']
        installer_options = resource_hash['asm::server'][cert_name]['installer_options']
        installer_options['static_ip'] = static_ip
        installer_options['netmask'] = static['subnet']
        installer_options['gateway'] = static['gateway']
        installer_options['vlanId'] = mgmt_network['vlanId'] if mgmt_network['vlanId']
        nameservers = [static['primaryDns'], static['secondaryDns']].select { |x| !x.nil? && !x.empty? }
        installer_options['nameserver'] = nameservers.join(',') if nameservers.size > 0
        installer_options['hostname'] = os_host_name if os_host_name
        installer_options['mac_address'] = mac_address if mac_address
        installer_options['target_boot_device'] = target_boot_device
      end
    end

    if is_dell_server && resource_hash['asm::idrac']
      if resource_hash['asm::idrac'].size != 1

        msg = "Only one iDrac configuration allowed per server; found #{resource_hash['asm::idrac'].size} for #{serial_number}"
        logger.error(msg)
        raise(msg)
      end

      title = resource_hash['asm::idrac'].keys[0]
      params = resource_hash['asm::idrac'][title]
      inventory = ASM::PrivateUtil.fetch_server_inventory(cert_name)
      params['nfssharepath'] = '/var/nfs/idrac_config_xml'
      params['servicetag'] = inventory['serviceTag']
      params['model'] = inventory['model'].split(' ').last.downcase
      params['force_reboot'] = !is_retry?
      if network_config
        params['network_configuration'] = network_config.to_hash
      end
      bios_settings = resource_hash['asm::bios'][title]
      if bios_settings
        db.log(:info, t(:ASM036, "Configuring BIOS for server: %{serial} %{ip}", :serial => serial_number, :ip => server_ip))
        bios_settings.delete('ensure')
        bios_settings.delete('bios_configuration')
        params['bios_settings'] = bios_settings
      end
      params['before'] = []

      if resource_hash['asm::server']
        params['before'].push("Asm::Server[#{cert_name}]")
      end

      if resource_hash['file']
        params['before'].push("File[#{cert_name}]")
      end
      #Process a BFS Server Component
      if params['target_boot_device'] == 'iSCSI'
        logger.debug "Processing iSCSI Boot From San configuration"
        #Flag Server Component as BFS
        @bfs = true
        #Find first related storage component
        storage_component = find_related_components('STORAGE',component)[0]
        #Identify Boot Volume
        boot_volume = storage_component['resources'].detect{|r|r['id']=='asm::volume::equallogic'}['parameters'].detect{|p|p['id']=='title'}['value']
        #Get Storage Facts
        ASM::DeviceManagement.run_puppet_device!(storage_component['puppetCertName'], logger, false)
        params['target_iscsi'] = ASM::PrivateUtil.find_equallogic_iscsi_volume(storage_component['asmGUID'],boot_volume)['TargetIscsiName']
        params['target_ip'] = ASM::PrivateUtil.find_equallogic_iscsi_ip(storage_component['puppetCertName'])
      end
    end

    if os_image_type == 'hyperv'
      storage = ASM::Util.asm_json_array(
                  find_related_components('STORAGE', component)
                )
      target_devices = []
      vol_names      = []
      storage_type = 'iscsi'
      storage_model = ''
      iscsi_fabric = 'A'
      iscsi_macs = []
      target_ip = ''
      storage.each do |c|
        target_devices.push(c['asmGUID'])
        ASM::Util.asm_json_array(c['resources']).each do |r|
          if r['id'] == 'asm::volume::equallogic'
            storage_model = 'equallogic'
            r['parameters'].each do |param|
              if param['id'] == 'title'
                vol_names.push(param['value'])
              end
            end
          end
          # For supporting Compellent FC storage access with HyperV deployment
          if r['id'] == 'asm::volume::compellent'
            storage_model = 'compellent'
            storage_type = 'fc'
            r['parameters'].each do |param|
              if param['id'] == 'title'
                vol_names.push(param['value'])
              end
              storage_type = 'iscsi' if (param['id'] == 'porttype' && param['value'] == "iSCSI")
            end
          end

          # For supporting EMC VNX FC storage access with HyperV deployment
          if r['id'] == 'asm::volume::vnx'
            storage_model = 'vnx'
            storage_type = 'fc'
            r['parameters'].each do |param|
              if param['id'] == 'title'
                vol_names.push(param['value'])
              end
            end
          end
        end
      end
      unless target_devices.uniq.size == 1
        raise("Expected to find only one target ip, found #{target_devices.uniq.size}")
      end
      if vol_names.size < 2
        raise("Expected to find atleast two volumes, found #{vol_names.size}")
      end
      logger.debug ("Storage_Type: #{storage_type}, Storage_Model: #{storage_model}")
      if storage_type == 'iscsi' && storage_model == 'equallogic'
        target_ip = ASM::PrivateUtil.find_equallogic_iscsi_ip(target_devices.first)
      elsif storage_type == 'iscsi' && storage_model == 'compellent'
        target_ip = ASM::PrivateUtil.find_compellent_iscsi_ip(target_devices.first,logger).join(',')
      end
      iscsi_fabric = get_iscsi_fabric(component) if storage_type == 'iscsi'
      iscsi_macs = hyperv_iscsi_macs(component) if storage_type == 'iscsi'

      resource_hash = ASM::Processor::Server.munge_hyperv_server(
                        title,
                        resource_hash,
                        target_ip,
                        vol_names,
                        logger,
                        get_disk_part_flag(component),
                        storage_type,
                        storage_model,
                        iscsi_fabric,
                        iscsi_macs
                      )

      # Originally puppet classification data was a parameter to asm::server
      # resource which handled writing the /etc/puppetlabs/puppet/node_data yaml
      # file with agent configuration. This was changed to have asm-deployer
      # write that file directly in order to accommodate the case where no asm::server
      # resource is required at all -- VM clones. The hyperv config however
      # is handled by ASM::Processor::Server and adds required hyperv config
      # to this field. For now, we just pull that out of the resource hash
      # here and write the file, this should be cleaned up at some point.
      agent_cert_name = ASM::Util.hostname_to_certname(os_host_name)
      if !resource_hash['asm::server'] || !resource_hash['asm::server'][title]
        logger.error("No asm::server resource found for hyperv server #{title}")
      else
        server_resource = resource_hash["asm::server"][title]
        puppet_classification_data = server_resource.delete("puppet_classification_data")
        config = {agent_cert_name => {"classes" => puppet_classification_data}}
        ASM::PrivateUtil.write_node_data(agent_cert_name, config)
      end
    end

    # The rest of the asm::esxiscsiconfig is used to configure vswitches
    # and portgroups on the esxi host and is done in the cluster swimlane
    resource_hash.delete('asm::esxiscsiconfig')
    resource_hash.delete('asm::baseserver')
    resource_hash.delete('asm::bios')

    # For O/S installs, the iDrac config was already done in process_server_pre_os
    resource_hash.delete("asm::idrac") if server

    wsman = ASM::WsMan.new(deviceconf, :logger => logger) if is_dell_server

    begin
      if server && network_config
        installer_options = resource_hash["asm::server"][cert_name]["installer_options"] ||= {}
        installer_options["network_configuration"] = network_config.to_hash.to_json

        # ASM-6335 Ensure the server is off so that we have better control over
        # the order of the razor OS install boot process.
        wsman.power_off if !server_deployed && !debug? && wsman
      end
      resource_hash['asm::server'][cert_name].delete('local_storage_vsan_type') if resource_hash['asm::server']
      process_generic(cert_name, resource_hash, 'apply')
      if server && !server_deployed && network_config
        enable_razor_boot(serial_number, network_config)
        enable_pxe(network_config, wsman)
      end
    rescue
      db.log(:error, t(:ASM054, "BIOS configuration failed on %{serial} %{ip}. See \"View Logs\" for more details", :ip => server_ip, :serial => serial_number))
      raise
    end

    if server
      reboot_required = !@debug
      version = server.os_image_version || os_image_type
      hyperv_cert_name = ASM::Util.hostname_to_certname(os_host_name)
      if os_image_type == 'hyperv' and is_retry? and ASM::PrivateUtil.get_puppet_certs.include?(hyperv_cert_name)
        logger.debug("Server #{os_host_name} is configured correctly.")
        reboot_required = false
      end

      begin
        logger.info("Waiting for razor to get reboot event...")
        db.log(:info, t(:ASM029, "Waiting for razor to get reboot event..."))
        razor.block_until_task_complete(serial_number, server_ip, server.policy_name, version, :bind, db) unless @debug
      rescue
        if is_dell_server
          logger.info("Server #{cert_name} never rebooted.  An old OS may be installed.  Manually rebooting to kick off razor install...")
          db.log(:info, t(:ASM030, "Server %{serial} %{ip} never rebooted.  An old OS may be installed.  Manually rebooting to kick off razor install...", :serial => serial_number, :ip => server_ip))
          wsman.reboot if reboot_required
        else
          begin
            # Using IPMI interface to reboot the server
            ASM::Ipmi.reboot(deviceconf, logger) if reboot_required
            logger.info "Server #{cert_name} rebooted using IPMI interface"
          rescue => e
            logger.info "Failed to reboot the server #{cert_name} using IPMI device, deployment may fail. #{e.inspect}"
          end
        end
      end
      razor_result = razor.block_until_task_complete(serial_number, server_ip, server.policy_name, version, nil, db) unless @debug

      # ASM-6001 - seeing intermittent failures on ESXi where razor thinks the OS is installed
      # but no OS seems to be on the hard drive. Adding a special wait for the ESXi
      # management interface to come up here to ensure that the subsequent disable_pxe
      # call doesn't reboot the server while the installer is still running.
      if os_image_type == 'vmware_esxi'
        raise("Static management IP address was not specified for #{serial_number}") unless static_ip
        block_until_esxi_ready(cert_name, server, static_ip, timeout = 900) unless @debug
      end

      # Remove PXE from the boot order. O/S install is done and PXE is no longer needed.
      # This is done for Hyper-V within hyperv_post_installation. Note this will
      # reboot the server.
      disable_pxe(wsman) unless server_deployed || !network_config || os_image_type == "hyperv"

      if os_image_type == 'vmware_esxi'
        raise("Static management IP address was not specified for #{serial_number}") unless static_ip
        block_until_esxi_ready(cert_name, server, static_ip, timeout = 900) unless @debug
      else
        # for retry case, if the agent is already there, no need to wait again for this step
        if reboot_required
          logger.debug("Non HyperV deployment which already exists")
          server_timestamp = node_data_modify_time || razor_result[:timestamp]
          unless @debug
            begin
              deployment_status = await_agent_run_completion(agent_cert_name, server_timestamp)
            rescue Timeout::Error
              msg = t(:ASM051, "Puppet Agent failed to check in for %{serial} %{ip}", :serial => serial_number, :ip => server_ip)
              db.log(:error, msg)
              raise(ASM::UserException, msg)
            rescue PuppetEventException => puppet_exception
              logger.debug("Puppet Agent failed to check in for #{serial_number} #{server_ip}")
            end
          end
        else
          logger.debug("HyperV deployment for retry case and server already exists. Skipping wait for agent check")
          deployment_status = nil
        end
        # Performing the SAN configuration and storage configuratio
        # for HyperV FC configruation to avoid WinPE hang
        # due to multi-path access error
        if (is_hyperv_deployment_with_compellent? || is_hyperv_deployment_with_emc?) &&
            !is_iscsi_compellent_deployment?
          # Need to run the process for only one server which has highest component id
          comp_id = component['id']
          logger.debug("Server component id: #{comp_id}")
          logger.debug("Server componnets no deployed: #{server_ids_not_deployed}")

          if server_ids_not_deployed.sort.last == comp_id
            process_switches_via_types(@service_hash,  :server => component['puppetCertName'])

            # For compellent, we process all servers. The new server may be still processing.
            # This will succeed for the last server in the deployment
            begin
              process_components(false, false)
            rescue
              logger.debug("For compellent, we process all servers. The new server may be still processing")
            end
          end
        end
        if (deployment_status and os_image_type == 'hyperv')
          hyperv_post_installation(ASM::Util.hostname_to_certname(os_host_name), cert_name, timeout=3600)
        end
      end
    end
    update_inventory_through_controller(component['asmGUID'])
  end

  def hardware_only(server_cert, asm_resource_hash)                                                   # Provider::Server::Server#os_only?
    logger.debug("ASM Resource : #{asm_resource_hash}")
    asm_resource_hash[server_cert]['os_image'].nil? &&
        asm_resource_hash[server_cert]['os_host_name'].nil?
  end

  def mark_vcenter_as_needs_update(vcenter_guid)
    (@vcenter_to_refresh ||= []).push(vcenter_guid)
  end

  def update_vcenters
    (@vcenter_to_refresh || []).uniq.each do |vc_guid|
      update_inventory_through_controller(vc_guid)
    end
  end

  # calls the Java controller to update the inventory service
  def update_inventory_through_controller(asm_guid)
    unless @debug
      if asm_guid.nil?
        # TODO: this clause should never be hit, but currently switch
        # devices which do not have asm guids are making it to this
        # section of code from the device section of
        # process_generic. We should change the update to only happen
        # in a method that specific swim lanes (e.g. process_storage)
        # can call, but for now we just skip inventory for them
        logger.debug("Skipping inventory because asm_guid is empty")
      else
        begin
          logger.debug("Updating inventory for #{asm_guid}")
          ASM::PrivateUtil.update_asm_inventory(asm_guid)
        rescue => e
          # If we have failed then inventory may not be updated in ASM. It seems
          # better not to just log that info rather than fail the deployment.
          logger.warn("Failed to update inventory for #{asm_guid}: #{e}")
        end
      end
    end
  end

  # Find components of the given type which are related to component
  def find_related_components(type, component_to_relate, include_failed=false)
    return [] if component_to_relate.nil?
    related_hash = component_to_relate["relatedComponents"] || {}
    related = components_by_type(type).select {|component| related_hash.keys.include?(component['id'])}
    related.reject!{ |component| failed_components.include?(component["id"]) } unless include_failed
    related
  end

  def build_dvportgroup( portgroup_name, type, esx_version, network, uplink_name, vds_require)
    default_port_config = {
      "vlan" => {
        "typeVmwareDistributedVirtualSwitchVlanIdSpec" => {
            "inherited" => false,
            "vlanId" => network["vlanId"],
        },
      }
    }
    if type == :storage
      default_port_config["uplinkTeamingPolicy"] = {
          "inherited" => false,
          "uplinkPortOrder" => {
              "inherited" => false,
              "activeUplinkPort" => uplink_name
          }
      }
      default_port_config["uplinkTeamingPolicy"]["policy"] = {"value" => "loadbalance_ip", "inherited" => false} if esx_version == '5.1.0'
    end
    {
      "require" => vds_require,
      "name" => portgroup_name,
      "ensure" => "present",
      "spec" => {
        "type" => "earlyBinding",
        "autoExpand" => true,
        "numPorts" => 16,
        "numStandalonePorts" => 8,
        "defaultPortConfig" => default_port_config,
        "portNameFormat" => "<dvsName>.<portgroupName>.<portIndex>",
      },
        "transport" => "Transport[vcenter]",
    }
  end

  def build_dv_vmknic(vds_name, vds_path, host, portgroup_name,
                        network, type)
    if (static = network['staticNetworkConfiguration']) && !static.empty?
      ip = static['ipAddress'] || raise(ArgumentError, "ipAddress not set")
      raise(ArgumentError, "Subnet not found in configuration #{static.inspect}") unless static['subnet']
    else
      ip = nil
    end
    ret = {
        'require' => "Vcenter::Dvportgroup[#{vds_path}/#{vds_name}:#{portgroup_name}]",
        'ensure' => 'present',
        'hostVirtualNicSpec' => {
            'distributedVirtualPort' => {
                'switchUuid'   => vds_name,
                'portgroupKey' => portgroup_name,
            },
            'mtu'              => 9000,
        },
        'transport' => 'Transport[vcenter]',
    }
    if ip
      ret = ret.deep_merge({"hostVirtualNicSpec" => { "ip" => { "dhcp" => false, "ipAddress" => ip, "subnetMask" => static["subnet"]}}})
    else
      ret = ret.deep_merge({"hostVirtualNicSpec" => { "ip" => {"dhcp" => true}}})
    end
    ret
  end

  # Get the VDS name specified from the template
  #
  # @param networks [Array] list of network_ids to find vds_names for
  # @param existing_vds [Hash] Hash of asm::cluster::vds having VDS and DV Portgroup anme
  # @param cluster_cert [String] Cert name of the cluster component
  # @return [String] VDS name provided in the deployment
  def vds_name(networks, existing_vds, cluster_cert)
    network_ids = networks.collect { |network| network["id"] }.flatten
    vds_id = existing_vds[cluster_cert].keys.find do |id, value|
      #vds name will be of the form vds_name::network_id1:network_id2:...::1
      id.start_with?("vds_name:") && network_ids.all? { |network_id| id.include?(network_id)}
    end
    existing_vds[cluster_cert][vds_id]
  end

  # Get the DV Portgroup names from the template
  #
  # @param cluster_cert [String] Cluster component cert name
  # @param existing_vds [Hash] Hash of asm::cluster::vds having VDS and DV Portgroup name
  # @param networks [Array] Networks associated with portgroup
  #
  # @return [Array] List of VDS name provided in the deployment
  def vds_portgroup_names(cluster_cert, existing_vds, networks=[])
    portgroup_names = []
    # these network ids should only be the ones for this particular type of portgroup
    network_ids = networks.collect{ |n| n.id }
    cluster_vds = existing_vds[cluster_cert]
    if cluster_vds
      pg_ids = cluster_vds.keys.find_all do |id, _value|
        #vds name will be of the form vds_name::network_id1:network_id2:...network_id_pg_is_for::1
        if id.start_with?("vds_pg::")
          # second from last member in split array will be the network id the portgroup belongs to
          pg_owner = id.split("::")[-2]
          network_ids.include?(pg_owner)
        end
      end
      portgroup_names = pg_ids.collect {|id| existing_vds[cluster_cert][id]}
    end
    portgroup_names
  end

  def build_vswitch_resources(vswitches, params, hostname, host_require)
    vswitch_names = {}
    management_vswitch = vswitches.find{|x| x[:management] }
    vswitch_index = 0
    ret = { "esx_vswitch" => {}, "esx_portgroup" => {}, "storage_network_info" => {}}
    # We start at vmk_index -1 because there will always be a management network at vmk0
    vmk_index = -1
    next_require = host_require
    iscsi_vswitch_count = 0

    vswitches.each do |vswitch|
      vswitch_name = "vSwitch#{vswitch_index}"
      vswitch_index += 1
      path = "/#{params["datacenter"]}/#{params["cluster"]}"

      vswitch_vmnics = vswitch.collect { |type, info| info[:vmnics] }.flatten.uniq
      vswitch_title = "#{hostname}:#{vswitch_name}"
      ret["esx_vswitch"][vswitch_title] = {
          "ensure" => "present",
          "num_ports" => 512,
          "nics" => vswitch_vmnics,
          "nicorderpolicy" => {
              "activenic" => vswitch_vmnics,
              "standbynic" => [],
          },
          "path" => path,
          "mtu" => 9000,
          "checkbeacon" => false,
          "transport" => "Transport[vcenter]",
          "require" => next_require
      }
      next_require = "Esx_vswitch[#{vswitch_title}]"

      vswitch.each do |network_type, network_info|
        networks = network_info[:networks]
        vmnics = network_info[:vmnics]
        portgroup_type = network_type == :workload ? "VirtualMachine" : "VMkernel"
        is_iscsi = network_type == :storage && networks.first.type == "STORAGE_ISCSI_SAN"
        portgroup_names = if network_type == :storage && is_iscsi
                            # iSCSI network
                            # NOTE: We have to make sure the ISCSI1 requires ISCSI0 so that
                            # they are created in the "right" order -- the order that will
                            # give ISCSI0 vmk2 and ISCSI1 vmk3 vmknics. The datastore
                            # configuration relies on that.
                            networks.size == 2 ? ["ISCSI0", "ISCSI1"] : ["ISCSI#{iscsi_vswitch_count}"]
                          elsif network_type == :management
                            # Hypervisor network. Currently the static management ip is
                            # set in the esxi kickstart and has a name of "Management
                            # Network". We have to match that name in order to be able to
                            # change the settings for that portgroup since they are
                            # configured by name.
                            raise(ArgumentError, "Exactly one network expected for management network") unless networks.size == 1
                            ["Management Network"]
                          else
                            networks.map { |network| network["name"] }
                          end
        iscsi_vswitch_count += 1 if is_iscsi
        portgroup_names.each_with_index do |portgroup_name, index|
          network = networks[index]
          portgroup_title = "#{hostname}:#{portgroup_name}"
          # Workload network is not a VMkernel, so we don't increase the index in that case
          vmk_index += 1 unless network_type == :workload
          if network_type == :storage
            ret["storage_network_info"]["require"] ||= []
            ret["storage_network_info"]["require"].push("Esx_portgroup[#{portgroup_title}]")
            ret["storage_network_info"]["vmk_index"] ||= vmk_index
            ret["storage_network_info"]["vswitch"] = vswitch_title
          end
          if is_iscsi
            # Current index nic is active, remainder are unused
            active_nics = [vmnics[index]]
            standby_nics = []
          elsif network_type == :management
            # First nic is active, remaining are standby per best practices
            standby_nics = vmnics.dup
            active_nics = [standby_nics.shift]
          else
            # active/active to increase throughput
            active_nics = vmnics
            standby_nics = []
          end
          portgroup = build_portgroup(vswitch_name, path, hostname, portgroup_name,
                                      network, portgroup_type, active_nics, network_type, standby_nics)
          ret["esx_portgroup"][portgroup_title] = portgroup
          # Enforce very strict ordering of each vswitch,
          # its portgroups, then the next vswitch, etc.
          # This is necessary to guess what vmk the portgroups
          # end up on so that the datastore can be configured.
          portgroup["require"] = next_require
          next_require = "Esx_portgroup[#{portgroup_title}]"
        end
      end
    end
    ret
  end

  def build_portgroup(vswitch, path, hostname, portgroup_name, network,
                      portgrouptype, active_nics, network_type, standby_nics)
    portgroup = {
        "name" => "#{hostname}:#{portgroup_name}",
        "ensure" => "present",
        "portgrouptype" => portgrouptype,
        "overridefailoverorder" => "enabled",
        "failback" => true,
        "mtu" => [:storage, :migration].include?(network_type) ? 9000 : 1500,
        "nicorderpolicy" => {
            "activenic" => active_nics,
            "standbynic" => standby_nics,
        },
        "overridecheckbeacon" => "enabled",
        "checkbeacon" => false,
        "traffic_shaping_policy" => "disabled",
        "averagebandwidth" => 1000,
        "peakbandwidth" => 1000,
        "burstsize" => 1024,
        "vswitch" => vswitch,
        "vmotion" => network_type == :migration ? "enabled" : "disabled",
        "path" => path,
        "host" => hostname,
        "vlanid" => network["vlanId"],
        "transport" => "Transport[vcenter]"
    }


    if (static = network["staticNetworkConfiguration"]) && !static.empty? && static["ipAddress"]
      ip = static["ipAddress"]
      raise(ArgumentError, "Subnet not found in configuration #{static.inspect}") unless static["subnet"]
      portgroup["ipsettings"] = "static"
      portgroup["ipaddress"] = ip
      portgroup["subnetmask"] = static["subnet"]
    else
      portgroup["ipsettings"] = "dhcp"
      portgroup["ipaddress"] = ""
      portgroup["subnetmask"] = ""
    end
    portgroup
  end

  # Sample output
  #    Product: VMware ESXi
  #    Version: 5.1.0
  #    Build: Releasebuild-2323236
  #    Update: 3
  #
  def esx_version(esx_endpoint)
    esx_version_info = ASM::Util.esxcli('system version get'.split, esx_endpoint, logger, true)
    esx_version = ( esx_version_info.scan(/^\s*Version:\s*(\S+)/).flatten || [] ).first
    logger.debug("ESXi Version: #{esx_version}")
    esx_version
  end

  def esx_existing_vds(esx_endpoint)
    vds_info = ASM::Util.esxcli('network vswitch dvs vmware  list'.split, esx_endpoint, logger, true)
    vds_switch_names = ( vds_info.scan(/^\s*Name:\s*(\S+)/).flatten || [] )
    logger.debug("Existing VDS names: #{vds_switch_names}")
    vds_switch_names
  end

  def esx_existing_vswitch(esx_endpoint)
    vswitch_info = ASM::Util.esxcli('network vswitch standard list'.split, esx_endpoint, logger, true)
    vswitch_switch_names = ( vswitch_info.scan(/^\s*Name:\s*(\S+)/).flatten || [] )
    logger.debug("Existing vswitch names: #{vswitch_switch_names}")
    vswitch_switch_names
  end

  def vswitch_info(esx_endpoint)
    v_info = {}
    esx_existing_vswitch(esx_endpoint).each do |vswitch|
      v_info[vswitch] = ASM::Util.esxcli("network vswitch standard list --vswitch-name #{vswitch}".split, esx_endpoint, logger, true)
    end
    logger.debug("Existing vSwitch information: #{v_info} ")
    v_info
  end

  def vds_host_spec(vds_name, nic_team, esx_endpoint, host)
    dvs_uplink = "#{vds_name}-uplink-pg"
    # Management vSwitch is created during the PXE installation
    # And vmnic0 is already added to it. For first iteration we need to skip the
    # already added vmnic
    has_management_team = !!nic_team[:management]
    vmnics = nic_team.collect { |type, info| info[:vmnics] }.flatten.uniq


    if has_management_team
      vswitch_vmnics = ( (vswitch_info(esx_endpoint)['vSwitch0'] || '').scan(/Uplinks:\s*(.*?)$/).flatten.first || '').split(',')
      logger.debug("VM NICs already added to vswitch0: #{vswitch_vmnics}")
      vswitch_vmnics.each {|x| vmnics.delete(x.strip) if vmnics.include?(x.strip)}
      logger.debug("VM NICs that needs to be added to VDS : #{vmnics}")
    end
    esx_existing_vds(esx_endpoint).include?(vds_name) ? operation = 'edit' : operation = 'add'
    vmnic_info = []
    vmnics.each do |vmnics|
      vmnic_info.push({'pnicDevice' => vmnics, 'uplinkPortgroupKey' => dvs_uplink})
    end
    {
       'host' => host,
       'operation' => operation,
       'backing' => {
           'pnicSpec' => vmnic_info,
       },
       'maxProxySwitchPorts' => 128,
     }
  end

  def build_vds_resources(esx_networks, cluster_cert_name, existing_vds,
                          esx_endpoint, host, server_cert,
                          esx_version, params, host_require, existing_resources = {})
    datacenter = params["datacenter"]
    vds_path = "/#{datacenter}"
    next_require = host_require

    vmk_id = 0

    ret = {"asm::vcenter::vds" => {},
           "vcenter::dvportgroup" => {},
           "vcenter::vmknic" => {} ,
           "esx_vmknic_type" => {} ,
           "vc_dvswitch_migrate" => {}
    }.merge(existing_resources)
    esx_networks.each do |group|
      networks = group.collect { |_type, info| info[:networks] }.flatten
      vds_name = vds_name(networks, existing_vds, cluster_cert_name)

      ret["asm::vcenter::vds"][vds_name] ||= {
          "ensure" => "present",
          "require" => host_require,
          "datacenter" => datacenter,
          "cluster" => params["cluster"],
          "dvswitch_name" => vds_name,
          "dvswitch_version" => esx_version,
          "host_spec" => []
      }
      ret["asm::vcenter::vds"][vds_name]["host_spec"].push(vds_host_spec(vds_name, group, esx_endpoint, host))
      vds_require = "Asm::Vcenter::Vds[#{vds_name}]"
      has_management_team = !!group[:management]
      group.each do |type, info|
        vmnics = info[:vmnics]
        networks = info[:networks]
        is_iscsi = type == :storage && networks.first.type == "STORAGE_ISCSI_SAN"
        portgroup_names = vds_portgroup_names(cluster_cert_name, existing_vds, networks )
        portgroup_names.each_with_index do |portgroup_name, index|
          next if portgroup_name.strip.length == 0
          network = networks[index]
          portgroup_title = "#{vds_path}/#{vds_name}:#{portgroup_name}"
          if is_iscsi
            # vmk and uplinks will be configured differently if iscsi is on the same team as management host
            # vmhba that shares with management host will be configured last, since we have to wait until vswitch0 can be disconnected
            if has_management_team
              vmnics = vmnics.rotate(1)
            end
            # Current index nic is active, remainder are unused
            active_nics = [vmnics[index]]
            standby_nics = []
            uplink_name = "uplink#{index.to_i + 1}"
          elsif type == :management
            # First nic is active, remaining are standby per best practices
            standby_nics = vmnics.dup
            active_nics = [standby_nics.shift]
          else
            # active/active to increase throughput
            active_nics = vmnics
            standby_nics = []
          end
          portgroup = build_dvportgroup( portgroup_name, type, esx_version, network, uplink_name, vds_require)
          ret["vcenter::dvportgroup"][portgroup_title] = portgroup
          next_require = "Vcenter::Dvportgroup[#{portgroup_title}]"
        end
        portgroup_names.each_with_index do |portgroup_name, index|
          next if portgroup_name.strip.length == 0
          # vmknic is not required for workload network
          next if type == :workload
          vmk_id += 1 unless type == :management
          network = networks[index]
          portgroup_title = "#{host}:vmk#{vmk_id}"
          vmknic = build_dv_vmknic(vds_name, vds_path, host, portgroup_name,
                                      network, type)

          if vmk_id > 1
            vmknic_require = []
            vmknic_require.push("Vcenter::Vmknic[#{host}:vmk#{vmk_id.to_i - 1}]")
            vmknic_require.push("Vcenter::Dvportgroup[#{vds_path}/#{vds_name}:#{portgroup_name}]")
            vmknic["require"] = vmknic_require
          else
            vmknic["require"] = next_require
          end

          ret["vcenter::vmknic"][portgroup_title] = vmknic
          next_require = "Vcenter::Vmknic[#{portgroup_title}]"

          if type == :migration
            ret["esx_vmknic_type"]["#{host}:vmk#{vmk_id}"] = {
                    "require" => next_require,
                    "nic_type" => ["vmotion"],
                    "transport" => "Transport[vcenter]"
                }
          elsif type == :management
            ret["esx_vmknic_type"]["#{host}:vmk#{vmk_id}"] =  {
                    "nic_type" => ["management"],
                    "transport" => "Transport[vcenter]",
                    "require" => "Asm::Host[#{server_cert}]"
                }
            ret["management_vds"] = {
                "name" => vds_name,
                "portgroup_name" => portgroup_name,
                "path" => vds_path
            }
          elsif type == :storage
            ret["storage_network"] ||= {
              "vmk_index" => vmk_id,
              "require" => [],
              "vds_name" => vds_name
            }
            ret["storage_network"]["require"].push(next_require)
          end
        end
      end
    end
    ret
  end

  def build_pxe_portgroup(pxe_name, path, hostip, remove=false, fcoe=nil)
    hash = {
        "name"          => "#{hostip}:#{pxe_name}",
        "ensure"        => "present",
        "failback"      => "true",
        "traffic_shaping_policy" => "disabled",
        "vswitch"   => "vSwitch0",
        "vmotion"   => "disabled",
        "path"      => path,
        "host"      => hostip,
        "transport" => "Transport[vcenter]",

    }
    hash["require"] = "Esx_portgroup[#{hostip}:VM Network_remove]" if remove && !fcoe
    if fcoe
      hash["vlanid"] = fcoe
    else
      hash["before"] = "Esx_portgroup[#{hostip}:Management Network]"
    end
    hash["portgrouptype"] = "VirtualMachine" if !fcoe
    hash
  end

  def build_pxe_dvportgroup(vds_path, vds_name, portgroup_name, fcoe=nil)
    hash = { 'vcenter::dvportgroup' => {
        "#{vds_path}/#{vds_name}:#{portgroup_name}" => {
            'require' => "Asm::Vcenter::Vds[#{vds_name}]",
            'name' => portgroup_name,
            'ensure' => 'present',
            'spec' => {
                'type' => 'earlyBinding',
                'autoExpand' => true,
                'numPorts' => 16,
                'numStandalonePorts' => 8,
                'portNameFormat' => '<dvsName>.<portgroupName>.<portIndex>',
            },
            'transport' => 'Transport[vcenter]',
        }
      }
    }

    if fcoe
      default_port_config = {
          'vlan' => {
              'typeVmwareDistributedVirtualSwitchVlanIdSpec' => {
                  'inherited' => false,
                  'vlanId' => fcoe,
              },
          },
      }
      hash['vcenter::dvportgroup']["#{vds_path}/#{vds_name}:#{portgroup_name}"]['spec']['defaultPortConfig'] = default_port_config
    end
    hash
  end

  def build_vmportgroup_remove(path, hostip)
    {
      "portgrp" => "VM Network",
      "ensure" => "absent",
      "portgrouptype" => "VirtualMachine",
      "vswitch" => "vSwitch0",
      "path" => path,
      "host" => hostip,
      "transport" => "Transport[vcenter]",
      "require"   => "Esx_vswitch[#{hostip}:vSwitch0]",
      "before"    => "Esx_portgroup[#{hostip}:Management Network]",
    }
  end

  def copy_endpoint(endpoint, ip)
    ret = endpoint.dup
    ret[:host] = ip
    ret
  end

  # Returns the fully qualified hostname if it can be resolved from the static
  # network configuration data and it matches the static network configuration
  # IP address. Otherwise returns the static IP address.
  # Params:
  # +hostname+:: the desired hostname
  # +static+:: hash of static network configuration data from the network data
  def lookup_hostname(hostname, static)
    suffix = static['dnsSuffix']
    static_ip = static['ipAddress']

    ns = ['primaryDns', 'secondaryDns'].collect { |k| static[k] }
    ns.reject! { |n| n.nil? || n.empty? }
    unless ns.empty?
      begin
        spec = {:nameserver => ns, :search => Array(suffix), :ndots => 1}
        resolved_ip = Resolv::DNS.open(spec) { |r| r.getaddress(hostname)} unless @debug
        if resolved_ip == Resolv::IPv4.create(static_ip)
          # Specified static IP and hostname match, so use correct fqdn
          if hostname.match(/\./)
            return hostname
          else
            return [hostname, suffix].compact.join(".")
          end
        else
          logger.debug("Got #{resolved_ip} instead of #{static_ip} for hostname #{hostname}")
        end
      rescue StandardError => e
        logger.debug("No DNS entry for #{hostname} will refer to host by ip: #{e.message}")
      end
    end

    # Unable to look up hostname, or result does not match static IP; fall back to IP
    static_ip
  end

  def deployment_hosts(cluster)
    deployment_host_info = {}
    (find_related_components('SERVER', cluster) || []).each do |server_component|
      server_conf = ASM::PrivateUtil.build_component_configuration(server_component, :decrypt => decrypt?)
      server_cert = server_component['puppetCertName']
      network_params = (server_conf['asm::esxiscsiconfig'] || {})[server_cert]
      network_config = ASM::NetworkConfiguration.new(network_params['network_configuration'], logger)
      mgmt_network = network_config.get_network('HYPERVISOR_MANAGEMENT')
      static = mgmt_network['staticNetworkConfiguration']
      unless static
        # This should have already been checked previously
        msg = "Static network is required for hypervisor network"
        logger.error(msg)
        raise(msg)
      end
      host_name = lookup_hostname(get_asm_server_params(server_component)['os_host_name'], static).downcase
      deployment_host_info[host_name] = get_esx_endpoint(server_component)
    end
    deployment_host_info
  end

  def vswitch_exists(cluster_component)
    ret_val = false
    deployment_hosts(cluster_component).each do |host,esx_endpoint|
      ret_val = true if esx_existing_vswitch(esx_endpoint).size > 0
    end
    ret_val
  end


  def deployment_hosts_certs(cluster)
    deployment_servers = []
    (find_related_components('SERVER', cluster) || []).each do |server_component|
      deployment_servers.push(server_component['puppetCertName'])
    end
    deployment_servers
  end

  def esx_vmnic_info(cluster_component)
    @esx_vmnic_info_hash ||= {}
    @esx_vmnic_info_hash[cluster_component['puppetCertName']] ||= begin
      (find_related_components('SERVER', cluster_component) || []).each do |server_component|
        retry_count = 1
        begin
          logger.debug("Found vmnic information in attempt: #{retry_count}")
          server_cert = server_component['puppetCertName']
          esx_endpoint = get_esx_endpoint(server_component)
          serverdeviceconf = ASM::DeviceManagement.parse_device_config(server_cert)
          network_config = build_network_config(server_component)
          vswitches = get_vmnics_and_networks(esx_endpoint, serverdeviceconf, network_config)
          mgmt_network = network_config.get_network('HYPERVISOR_MANAGEMENT')
          static = mgmt_network['staticNetworkConfiguration']
          unless static
            # This should have already been checked previously
            msg = 'Static network is required for hypervisor network'
            logger.error(msg)
            raise(msg)
          end
          server_conf = ASM::PrivateUtil.build_component_configuration(server_component, :decrypt => decrypt?)
          logger.debug("Invoking hostname lookup for #{server_conf['os_host_name']}")
          host_name = lookup_hostname(get_asm_server_params(server_component)['os_host_name'], static).downcase
          @esx_vmnic_info_hash[host_name] = vswitches
          logger.debug("NIC info in loop: #{@esx_vmnic_info_hash}")
        rescue => e
          logger.debug "Got Exception, need to retry: #{retry_count}"
          retry_count = retry_count.to_i.succ
          if retry_count <= 10
            sleep 60
            retry
          else
            raise e
          end
        end
      end
      @esx_vmnic_info_hash
    end
  end

  def process_cluster(component)
    cert_name = component["puppetCertName"]
    raise(ArgumentError, "Component has no certname") unless cert_name
    related_servers = find_related_components("SERVER", component, true)
    deployed_servers_ids = related_servers.collect{|server| server["id"]}.reject{|id| failed_components.include?(id)}
    raise("Cluster component for #{cert_name} does not have a successful server to build with") if !related_servers.empty? && deployed_servers_ids.empty?
    hadrs_clusters = {}
    fcoe_cluster = false
    iscsi_compellent_esxi_servers = []
    log("Processing cluster component: #{cert_name}")

    resource_hash = ASM::PrivateUtil.build_component_configuration(component, :decrypt => decrypt?)

    # Assuming there is a parameters to categorized the cluster type
    (resource_hash['asm::cluster::scvmm'] || {}).each do |title,params|
      configure_hyperv_cluster(component,resource_hash,title)
      # Reusing vcenter discovery for SCVMM
      mark_vcenter_as_needs_update(component['asmGUID'])
    end

    existing_vds = ( resource_hash.delete('asm::cluster::vds') || {} )
    # getting vmnics info for all hosts, so that it can be used for VDS configuration
    (resource_hash['asm::cluster'] || {}).each do |title, params|
      resource_hash['asm::cluster'][title]['vcenter_options'] = { 'insecure' => true }
      resource_hash['asm::cluster'][title]['ensure'] = 'present'

      # remove ha and drs configs from the cluster hash
      ha_config = resource_hash['asm::cluster'][title].delete 'ha_config'
      drs_config = resource_hash['asm::cluster'][title].delete 'drs_config'
      vds_enabled = resource_hash['asm::cluster'][title].delete 'vds_enabled'
      vsan_enabled = ( resource_hash['asm::cluster'][title]['vsan_enabled'] || false )
      if vsan_enabled
        ha_config = true
        drs_config = true
      end
      resource_hash['asm::cluster'][title].delete('vsan')

      compression_enabled = resource_hash['asm::cluster'][title].delete('compression_enabled')
      failure_tolerance_method = resource_hash['asm::cluster'][title].delete('failure_tolerance_method')
      failures_number = resource_hash['asm::cluster'][title].delete('failures_number')

      hadrs_clusters[title] ||= {}
      cluster_path = "/#{params['datacenter']}/#{params['cluster']}"
      if ASM::Util.to_boolean ha_config
        hadrs_clusters[title][cluster_path] ||= {}
        hadrs_clusters[title][cluster_path]['ha_config'] = true
      end
      if ASM::Util.to_boolean drs_config
        hadrs_clusters[title][cluster_path] ||= {}
        hadrs_clusters[title][cluster_path]['drs_config'] = true
      end

      deployment_hosts = deployment_hosts(component)

      # Add ESXi hosts and creds as separte resources
      related_servers.each do |server_component|
        #We only target servers that successfully installed here
        next unless deployed_servers_ids.include?(server_component['id'])
        server_conf = ASM::PrivateUtil.build_component_configuration(server_component, :decrypt => decrypt?)

        (server_conf['asm::server'] || []).each do |server_cert, server_params|
          if server_params['os_image_type'] == 'vmware_esxi'
            razor_image = server_params['razor_image']
            install_mem = ASM::Util.to_boolean(server_params['esx_mem'])
            serial_number = ASM::Util.cert2serial(server_cert)
            db.log(:info, t(:ASM038, "Processing vCenter network for server: %{serial}", :serial => serial_number))

            # Determine host IP
            log("Finding host ip for serial number #{serial_number}")
            network_params = (server_conf['asm::esxiscsiconfig'] || {})[server_cert]
            network_config = ASM::NetworkConfiguration.new(network_params['network_configuration'], logger)
            pxe_vlan = pxe_name = nil
            pxe_network = network_config.get_network('PXE')
            pxe_name  = pxe_network.name if pxe_network
            pxe_vlan = pxe_network.vlanId if pxe_network
            mgmt_network = network_config.get_network('HYPERVISOR_MANAGEMENT')
            static = mgmt_network['staticNetworkConfiguration']
            unless static
              # This should have already been checked previously
              msg = "Static network is required for hypervisor network"
              logger.error(msg)
              raise(msg)
            end

            raise(ArgumentError, "Could not find host ip for #{server_cert}") unless static['ipAddress']
            hostname = lookup_hostname(server_params['os_host_name'], static).downcase

            serverdeviceconf = ASM::DeviceManagement.parse_device_config(server_cert)

            # Add esx hosts to cluster
            host_params = {
                'datacenter' => params['datacenter'],
                'cluster' => params['cluster'],
                'hostname' => hostname,
                'username' => ESXI_ADMIN_USER,
                'password' => server_params['admin_password'],
                'decrypt'  => decrypt?,
                'timeout'  => 90,
                'require' => "Asm::Cluster[#{title}]"
            }

            ntp_server = (server_params['ntp_server'] || '').split(',').map { |x| x.strip }
            host_params['ntp_server'] = ntp_server unless ntp_server.empty?

            resource_hash['asm::host'] ||= {}
            resource_hash['asm::host'][server_cert] = host_params

            esx_endpoint = { :host => static['ipAddress'],
                             :user => ESXI_ADMIN_USER,
                             :password => server_params['admin_password'] }
            if decrypt?
              esx_endpoint[:password] = ASM::Cipher.decrypt_string(esx_endpoint[:password])
            end

            #TODO: This section could be moved out to the server swimlane
            if network_params
              # Add vswitch config to esx host
              next_require = "Asm::Host[#{server_cert}]"
              host_require = next_require
              storage_network_require = nil
              storage_network_vmk_index = nil
              storage_network_vswitch = nil

              # TODO: append_resources! should do this automatically
              network_config = ASM::NetworkConfiguration.new(network_params['network_configuration'], logger)
              network_config.cards.each do |card|
                logger.debug("Found card: #{card.name}")
                card.interfaces.each do |port|
                  logger.debug("** Found interface: #{port.name}")
                  port.partitions.each do |partition|
                    logger.debug("**** Found partition: #{partition.name} #{partition.fqdd} #{partition.mac_address} #{partition.networkObjects}")
                  end
                end
              end

              retry_count = 1
              begin
                esx_networks = get_vmnics_and_networks(esx_endpoint, serverdeviceconf, network_config)
                logger.debug("Found vmnic information in attempt: #{retry_count}")
              rescue => e
                logger.debug "Got Exception, need to retry: #{retry_count}"
                retry_count = retry_count.to_i.succ
                if retry_count <= 10
                  sleep 60
                  retry
                else
                  raise e
                end
              end

              if vds_enabled == "standard"
                vswitch_resources = build_vswitch_resources(esx_networks, params, hostname, host_require)
                storage_info = vswitch_resources.delete("storage_network_info") || {}
                storage_network_require = storage_info["require"]
                storage_network_vmk_index = storage_info["vmk_index"]
                storage_network_vswitch = storage_info["vswitch"]
                resource_hash = resource_hash.deep_merge(vswitch_resources)
                if pxe_name
                  path = "/#{params["datacenter"]}/#{params["cluster"]}"
                  if pxe_name != "VM Network"
                    remove_hash = build_vmportgroup_remove(path, hostname)
                    resource_hash["esx_portgroup"] = (resource_hash["esx_portgroup"] || {}).merge("#{hostname}:VM Network_remove" => remove_hash)
                    pxe_portgroup = build_pxe_portgroup(pxe_name, path, hostname, true)
                  else
                    pxe_portgroup = build_pxe_portgroup(pxe_name, path, hostname)
                  end
                  resource_hash["esx_portgroup"] = (resource_hash["esx_portgroup"] || {}).merge("#{hostname}:#{pxe_name}" => pxe_portgroup)
                end
              else
                management_vds_name = ''
                management_vds_portgroup_name = ''
                management_vds_path = ''
                # VDS Configuration needs to be configured after adding all the hosts to vCenter
                #existing_vds = resource_hash.delete('asm::cluster::vds') if resource_hash['asm::cluster::vds']
                logger.debug("Existing VDS inside process cluster: #{existing_vds}")
                vds_host_require = []
                esx_version = esx_version(esx_endpoint)
                deployment_hosts_certs(component).each do |deployment_server_cert|
                  vds_host_require.push("Asm::Host[#{deployment_server_cert}]")
                end
                logger.debug("esx_networks: #{esx_networks}, cert_name:#{cert_name}, existing_vds:#{existing_vds}, esx_endpoint: #{esx_endpoint}, hostname: #{hostname}, server_cert:#{server_cert}, esx_version:#{esx_version}, params:#{params}, vds_host_require:#{vds_host_require},  resource_hash:#{resource_hash}")
                vds_resources = build_vds_resources(esx_networks, cert_name, existing_vds,
                                                    esx_endpoint, hostname, server_cert,
                                                    esx_version, params, vds_host_require, resource_hash)
                logger.debug("VDS Resource: #{vds_resources}")

                if management_vds = vds_resources.delete("management_vds")
                  management_vds_name = management_vds["name"]
                  management_vds_portgroup_name = management_vds["portgroup_name"]
                  management_vds_path = management_vds["path"]
                end

                if storage_network = vds_resources.delete("storage_network")
                  storage_network_require = storage_network["require"]
                  storage_network_vmk_index = storage_network["vmk_index"]
                  storage_network_vswitch = storage_network["vds_name"]
                end
                resource_hash = vds_resources

                if pxe_name
                  management_vmk_next_require = []
                  ( resource_hash['esx_vmknic_type'] || {} ).keys.each do |key|
                    management_vmk_next_require.push("Esx_vmknic_type[#{key}]")
                  end
                  (resource_hash['vcenter::vmknic'] || {}).keys.each do |key|
                    management_vmk_next_require.push("Vcenter::Vmknic[#{key}]") unless key == "#{hostname}:vmk0"
                  end
                  management_vmk_next_require.push("Asm::Vcenter::Vds[#{management_vds_name}]")
                  management_vmk_next_require.push("Vcenter::Dvportgroup[/#{params['datacenter']}/#{management_vds_name}:#{management_vds_portgroup_name}]")

                  management_vmk = {'vcenter::vmknic'=> {
                      "#{hostname}:vmk0" => {
                          'require' => management_vmk_next_require,
                          'ensure' => 'present',
                          'hostVirtualNicSpec' => {
                              'distributedVirtualPort' => {
                                  'switchUuid'   => management_vds_name,
                                  'portgroupKey' => management_vds_portgroup_name,
                              },
                              'mtu'                    => 9000,
                          },
                          'transport' => 'Transport[vcenter]',
                      }
                  }}
                  resource_hash['vcenter::vmknic'] = (resource_hash['vcenter::vmknic'] || {}).merge(management_vmk['vcenter::vmknic'])


                  fcoe_network = network_config.get_networks('STORAGE_FCOE_SAN')
                  (fcoe_network.nil? || fcoe_network.empty?) ? pxe_dvgroup_tag = nil : pxe_dvgroup_tag = pxe_vlan

                  # Skip creating PXE DV-PortGroup if name is not supplied
                  pxe_dv_name = vds_portgroup_names(cert_name, existing_vds, network_config.get_networks("PXE")).first
                  pxe_dv_name = pxe_name if ( pxe_dv_name.nil? || pxe_dv_name.empty? )
                  unless pxe_dv_name.empty?
                    pxe_portgroup = build_pxe_dvportgroup(
                        management_vds_path,
                        management_vds_name,
                        pxe_dv_name,
                        pxe_dvgroup_tag)
                    resource_hash['vcenter::dvportgroup'] =
                        (resource_hash['vcenter::dvportgroup'] || {})
                            .merge(pxe_portgroup['vcenter::dvportgroup'])
                  end

                  management_vmk_next_require = []
                  ( resource_hash['esx_vmknic_type'] || {}).keys.each do |key|
                    management_vmk_next_require.push("Esx_vmknic_type[#{key}]")
                  end
                  ( resource_hash['vcenter::vmknic'] || {}).keys.each do |key|
                    management_vmk_next_require.push("Vcenter::Vmknic[#{key}]")
                  end
                  # Need to remove the uplink from vSwitch0 before deleting vSwitch
                  # In certain cases we are getting FCoE busy error when NIC NPAR is disabled
                  vswitch_remove = { 'esx_vswitch' => {
                      "#{hostname}:vSwitch0" => {
                          'ensure' => 'present',
                          'nics'   => [],
                          'transport' => 'Transport[vcenter]'
                      }
                  }}
                  unless management_vmk_next_require.empty?
                    vswitch_remove['esx_vswitch']["#{hostname}:vSwitch0"]['require'] = management_vmk_next_require
                  end

                  resource_hash['esx_vswitch'] = (resource_hash['esx_vswitch'] || {}).merge(vswitch_remove['esx_vswitch'])
                end
              end

              logger.debug('Configuring the storage manifest')
              storage_titles = Array.new # we will store storage_titles here - esx_syslog requires one
              opt_vmk_index_inc = 0
              iscsi_type = server_params["iscsi_initiator"]

              host_lun_count = 0
              related_storage_components = (find_related_components('STORAGE', server_component) || [])
              related_storage_components.each_with_index do |storage_component,storage_index|
                storage_cert = storage_component['puppetCertName']
                storage_creds = ASM::DeviceManagement.parse_device_config(storage_cert)
                storage_hash = ASM::PrivateUtil.build_component_configuration(storage_component, :decrypt => decrypt?)

                if (storage_hash['asm::volume::equallogic'] ||
                    is_iscsi_compellent_deployment?) &&
                        storage_network_vmk_index

                  if iscsi_type && iscsi_type == "software"
                    logger.debug("Software iscsi type detected. Software iscsi initiator will be enabled")
                    enable_software_iscsi(get_esx_endpoint(server_component))

                    # Configure multipath for software iscsi by vmknic index offset
                    logger.debug("Configuring the optional vmk index offset for software iscsi")
                    num_vmnics = esx_networks.find{ |team| team[:storage] }[:storage][:networks].size
                    opt_vmk_index_inc = storage_index % num_vmnics
                  end

                  iscsi_resource_hash = (vmware_iscsi_resource_hash(resource_hash,
                                                                    storage_component, server_component,
                                                                    storage_network_vmk_index, opt_vmk_index_inc,
                                                                    storage_network_vswitch,
                                                                    serverdeviceconf,
                                                                    network_config,
                                                                    hostname, params,static,storage_network_require, vds_enabled))
                  storage_hash_component = (storage_hash['asm::volume::compellent'] ||
                      storage_hash['asm::volume::equallogic'])
                  storage_hash_component.each do |storage_title,storage_params|
                    storage_titles.push storage_title
                  end
                  resource_hash = resource_hash.deep_merge(iscsi_resource_hash)
                  iscsi_compellent_esxi_servers.push(esx_endpoint) if storage_index == 0 && is_iscsi_compellent_deployment?
                end

                if storage_hash['asm::volume::compellent'] and !is_iscsi_compellent_deployment?
                  if !is_fcoe_enabled(server_component)
                    storage_hash['asm::volume::compellent'].each do |volume, storage_params|
                      storage_titles.push volume
                      folder = storage_params['volumefolder']
                      asm_guid = storage_component['asmGUID']

                      if @debug
                        lun_id = 0
                      else
                        device_id = ASM::PrivateUtil.find_compellent_volume_info(asm_guid, volume, folder, logger)
                        logger.debug("Compellent Volume info: #{device_id}")
                        decrypt_password=server_params['admin_password']
                        if decrypt?
                          decrypt_password = ASM::Cipher.decrypt_string(server_params['admin_password'])
                        end
                        lun_id = get_compellent_lunid(static['ipAddress'], 'root', decrypt_password, device_id)
                      end

                      logger.debug("Volume's LUN ID: #{lun_id}")

                      resource_hash['asm::fcdatastore'] ||= {}
                      resource_hash['asm::fcdatastore']["#{hostname}:#{volume}"] = {
                        'data_center' => params['datacenter'],
                        'datastore' => volume,
                        'cluster' => params['cluster'],
                        'ensure' => 'present',
                        'esxhost' => hostname,
                        'lun' => lun_id,
                        'require' => host_require
                      }
                    end
                  end

                end

                if storage_hash['asm::volume::vnx']
                  storage_hash['asm::volume::vnx'].each do |volume, storage_params|
                  # While adding lun to storage group we need to pass alu, hlu. I gave both values same.
                  storage_info = ASM::PrivateUtil.get_vnx_storage_group_info(storage_cert)
                  lun_id=ASM::PrivateUtil.get_vnx_lun_id(storage_cert, volume, logger)
                  host_lun_number = host_lun_info("ASM-#{@id}", storage_info, lun_id)
                  unless host_lun_number
                    host_lun_number = host_lun_count
                    host_lun_count += 1
                  end
                  raise("Unable to find VNX LUN #{volume} on the storage ") unless lun_id
                  resource_hash['asm::fcdatastore'] ||= {}
                  resource_hash['asm::fcdatastore']["#{hostname}:#{volume}"] = {
                    'data_center' => params['datacenter'],
                    'datastore' => volume,
                    'cluster' => params['cluster'],
                    'ensure' => 'present',
                    'lun' => host_lun_number,
                    'esxhost' => hostname,
                    'require' => host_require
                  }
                  end
                end

                # Configure NFS Datastore
                if storage_hash['netapp::create_nfs_export']
                  storage_hash['netapp::create_nfs_export'].each do |volume, storage_params|
                    remote_host = get_netapp_ip()
                    remote_path = "/vol/#{volume}"
                    logger.debug "Remote Path: #{remote_path}"
                    logger.debug "Remote host: #{remote_host}"
                    logger.debug "#{hostname}:#{volume}"
                    resource_hash['asm::nfsdatastore'] ||= {}
                    resource_hash['asm::nfsdatastore']["#{hostname}:#{volume}"] = {
                      'data_center' => params['datacenter'],
                      'datastore' => volume,
                      'cluster' => params['cluster'],
                      'ensure' => 'present',
                      'esxhost' => hostname,
                      'remote_host' => remote_host,
                      'remote_path' => remote_path,
                      'require' => host_require
                    }
                  end
                end

              end

              if iscsi_type && iscsi_type == "software" && related_storage_components.size > 0
                logger.debug("Configuring software iscsi adapter bindings and rescan")
                hba_name = parse_software_hbas(esx_endpoint).first
                required_res = []
                resource_hash["asm::datastore"].keys.each do |datastore_res_name|
                  required_res << "Asm::Datastore[#{datastore_res_name}]"
                end
                software_hba = {
                  "#{esx_endpoint[:host]}:#{hba_name}" => {
                    "ensure" => "present",
                    "datacenter" => params["datacenter"],
                    "cluster" => params["cluster"],
                    "software_hba" => hba_name,
                    "vmknics" => "vmk#{storage_network_vmk_index} vmk#{storage_network_vmk_index + 1}",
                    "esxhost" => esx_endpoint[:host],
                    "esxusername" => ESXI_ADMIN_USER,
                    "esxpassword" => server_params["admin_password"],
                    "decrypt" => decrypt?,
                    "require" => required_res
                  }
                }
                resource_hash["asm::datastore::software_hba"] = software_hba
              end

              logger.debug('Configuring persistent storage for logs')
              if !storage_titles.empty? && !is_iscsi_compellent_deployment?
                syslog_volume = storage_titles[0]
                resource_hash['esx_syslog'] ||= {}
                resource_hash['esx_syslog'][hostname] = {
                  'log_dir_unique' => true,
                  'transport' => 'Transport[vcenter]',
                  'log_dir' => "[#{syslog_volume}] logs"
                }
              end
            end
          end
          resource_hash = resource_hash.deep_merge(vsan_advance_config(hostname, host_require)) if vsan_enabled
        end

      end
      # TODO:  This is a hack until we process cluster using provider
      require "asm/service"
      service = ASM::Service.new(@service_hash, :deployment => self)
      cluster_component = service.component_by_id(component["id"])
      resource_hash = resource_hash.merge(cluster_component.to_resource.to_puppet)
      resource_hash.delete('asm::cluster::vds')
      # Moving the code inside the loop to ensure it do not conflict with HyperV Cluster
      begin
        # if management network is on same nic as vmhba, the firs trun will fail to bind vmk to vmhba, since the vmnic0 is still used
        process_generic(cert_name, resource_hash, "apply", true, nil, component["asmGUID"])
      rescue => e
        logger.debug("First cluster run failed.  Retrying...")
      end

      # Running into issues with hosts not coming out of maint mode
      # Try it again for good measure.

      # While adding nodes to an existing HA cluster, connections to the host is getting lost during
      # esx_service configuration of TSH and NTPD.
      # Adding a failback retry of the cluster configuration
      begin
        if vds_enabled == "distributed" && @cluster_execution_count == 1 && server_component_ids.length > 0
          logger.debug('VDS is enabled, need to run the cluster configuration twice')
          @cluster_execution_count += 1
          return(process_cluster(component))
        end
        process_generic(cert_name, resource_hash, "apply", true, nil, component["asmGUID"])
      rescue => e
        logger.debug('Process vCenter cluster has failed, performing one retry')
        sleep 60
        process_generic(cert_name, resource_hash, "apply", true, nil, component["asmGUID"])
      end


      # VSAN configurations
      if vsan_enabled
        all_flash_cluster = is_all_flash_vsan_cluster?(component)
        vsan_port_group_name_info = vsan_port_group_name(component)
        datacenter = resource_hash['asm::cluster'][title]['datacenter']
        cluster_name = resource_hash['asm::cluster'][title]['cluster']
        vsan_resource_hash = {}
        vsan_next_require = nil

        storage_policy_name = "ASM VSAN VM Storage Policy"
        if all_flash_cluster
          # All Flash Cluster Storage policy
          if failure_tolerance_method
            vsan_resource_hash['vc_spbm'] = {}
            vsan_resource_hash['vc_spbm'][storage_policy_name] = {
                'ensure' => 'present',
                'cluster' => cluster_name,
                'datacenter' => datacenter,
                'failure_tolerance_method' => failure_tolerance_method,
                'host_failures_to_tolerate' => failures_number,
                'stripe_width' => '1',
                'force_provisioning' => 'No',
                'proportional_capacity' => '0',
                'cache_reservation' => '0',
                'transport' => "Transport[vcenter]",
            }
            vsan_next_require = "Vc_spbm[#{storage_policy_name}]"
          end
        else
          # Hybrid VSAN cluster policy
          vsan_resource_hash['vc_spbm'] = {}
          vsan_resource_hash['vc_spbm'][storage_policy_name] = {
              'ensure' => 'present',
              'cluster' => cluster_name,
              'datacenter' => datacenter,
              'host_failures_to_tolerate' => '1',
              'stripe_width' => '1',
              'force_provisioning' => 'No',
              'proportional_capacity' => '0',
              'cache_reservation' => '0',
              'transport' => "Transport[vcenter]",
          }
          vsan_next_require = "Vc_spbm[#{storage_policy_name}]"
        end

        vsan_resource_hash['vc_vsan'] = {}

        vsan_resource_hash['vc_vsan'][title] = {
            'ensure' => 'present',
            'auto_claim' => 'false',
            'cluster' => cluster_name,
            'datacenter' => datacenter,
            'transport' => "Transport[vcenter]"
        }
        vsan_resource_hash['vc_vsan'][title]['require'] = vsan_next_require if vsan_next_require

        vsan_resource_hash['vc_vsan_network'] = {}
        vsan_resource_hash['vc_vsan_network'][title] = {
            'ensure' => 'present',
            'cluster' => cluster_name,
            'datacenter' => datacenter,
            'vsan_port_group_name' => vsan_port_group_name_info,
            'transport' => "Transport[vcenter]",
            'require' => "Vc_vsan[#{title}]"
        }
        if vds_enabled == "distributed"
          vsan_resource_hash['vc_vsan_network'][title].delete('vsan_port_group_name')
          vsan_resource_hash['vc_vsan_network'][title]['vsan_dv_switch_name'] = vsan_port_group_name_info[0]
          vsan_resource_hash['vc_vsan_network'][title]['vsan_dv_port_group_name'] = vsan_port_group_name_info[1]
        end

        vsan_resource_hash['vc_vsan_disk_initialize'] = {}
        vsan_resource_hash['vc_vsan_disk_initialize'][title] = {
            'ensure' => 'present',
            'cluster' => cluster_name,
            'datacenter' => datacenter,
            'vsan_trace_volume' => find_external_volume_with_most_servers,
            'vsan_disk_group_creation_type' => all_flash_cluster ? 'allFlash' : 'hybrid',
            'transport' => "Transport[vcenter]",
            'require' => "Vc_vsan_network[#{title}]"
        }

        vsan_resource_hash = vmware_cluster_transport(component).merge(vsan_resource_hash)
        process_generic(cert_name, vsan_resource_hash, "apply", true, nil, component["asmGUID"])

        if compression_enabled
          logger.debug("Wait for 1 minute before invoking de-deduplication configuration")
          sleep(60)
          vsan_resource_hash['vc_vsan']["#{title}_dedup"] = {
              'ensure' => 'present',
              'auto_claim' => 'false',
              'dedup' => 'true',
              'cluster' => cluster_name,
              'datacenter' => datacenter,
              'transport' => "Transport[vcenter]"
          }
          vsan_resource_hash['vc_vsan']["#{title}_dedup"]['require'] = vsan_next_require if vsan_next_require
          vsan_next_require = "Vc_vsan[#{title}_dedup]"
          process_generic(cert_name, vsan_resource_hash, "apply", true, nil, component["asmGUID"])
        end
      end


      mark_vcenter_as_needs_update(component['asmGUID'])

      # Running configuration for HA and DRS well after the clusters and their datastores are setup
      hadrs_hash = {}
      hadrs_clusters.each do |title, clusters|
        clusters.each do |cluster_path,flags|
          hadrs_hash['asm::cluster::vcenter_hadrs'] ||= {}
          hadrs_hash['asm::cluster::vcenter_hadrs'][title] ||= {}
          hadrs_hash['asm::cluster::vcenter_hadrs'][title]['cluster_path'] = cluster_path
          hadrs_hash['asm::cluster::vcenter_hadrs'][title]['vcenter_options'] = { 'insecure' => true }
          if flags.has_key? 'ha_config'
            hadrs_hash['asm::cluster::vcenter_hadrs'][title]['ha_config'] = true
          end
          if flags.has_key? 'drs_config'
            hadrs_hash['asm::cluster::vcenter_hadrs'][title]['drs_config'] = true
          end
        end
      end
      if not hadrs_hash.empty? and !fcoe_cluster
        # Need to skip the HA DRS configuration for FCoE Cluster
        # It needs to be configured along with FCoE Storage
        ha_reconfigure(component,hadrs_hash)
      end
      #reconfigure_ha_for_clusters(cert_name, ha_clusters)
    end

    # For ESXi iSCSI compellent deployments, rescan needs to be initiated once for each server
    # This has to be be only of the iscsi target is configured on the server
    iscsi_compellent_esxi_servers.each do |iscsi_compellent_esxi_server|
      if is_iscsi_compellent_deployment?
        # Initiate rescan of the storage adapter
        # iSCSI connection cannot be established without explicit iSCSI rescan from the initiator
        begin
          ASM::Util.rescan_vmware_esxi(iscsi_compellent_esxi_server,logger)
          sleep(10)
        rescue
          logger.debug("Rescan could be progress, continue with the operation")
        end
      end
    end

  end

  def vsan_advance_config(hostname, host_require)
    {
        "esx_advanced_options" => {
            hostname => {
                "options" => {
                    "LSOM.diskIoTimeout" => 100000,
                    "LSOM.diskIoRetryFactor" => 4
                },
                "transport" => "Transport[vcenter]",
                "require"   => host_require
            }
        }
    }
  end

  def vmware_cluster_transport(component)
    name ||= component['puppetCertName']

    {"transport" =>
         {"vcenter" =>
              {"name" => name,
               "options" => {"insecure" => true},
               "provider" => "device_file"
              }
         }
    }
  end

  def vsan_port_group_name(component)
    cert_name = component["puppetCertName"]
    resource_hash = ASM::PrivateUtil.build_component_configuration(component, :decrypt => decrypt?)
    existing_vds = ( resource_hash.delete("asm::cluster::vds") || {} )
    server = find_related_components("SERVER", component, true).first
    network_config = build_network_config(server)
    vsan_network = network_config.get_networks("VSAN").first
    raise("VSAN Network not associated with the server #{server['puppetCertName']}") if vsan_network.nil?
    vds_enabled = resource_hash["asm::cluster"][cert_name]["vds_enabled"] || "standard"
    if vds_enabled == "distributed"
      title = component["puppetCertName"]
      vds_name = vds_name([vsan_network], existing_vds, title)
      vds_portgroup = vds_portgroup_names(title, existing_vds, [vsan_network]).first
      [ ( vds_name || ''), ( vds_portgroup || '')]
    else
      return vsan_network.name
    end
  end

  def is_all_flash_vsan_cluster?(component)
    find_related_components('SERVER', component, true).each do |server_component|
      vsan_type = ( get_asm_server_params(server_component)['local_storage_vsan_type'] || '' )
      return true if vsan_type == "flash"
    end
    false
  end

  def ha_reconfigure(component,hadrs_hash)
    vcenter_cert_name = component['puppetCertName']
    resource_hash = hadrs_hash
    vcenter_resource_hash = ASM::PrivateUtil.build_component_configuration(component, :decrypt => decrypt?)
    existing_vds = resource_hash.delete('asm::cluster::vds')

    (vcenter_resource_hash['asm::cluster'] || {}).each do |title, params|
      (find_related_components('SERVER', component) || []).each do |server_component|
        server_conf = ASM::PrivateUtil.build_component_configuration(server_component, :decrypt => decrypt?)

        (server_conf['asm::server'] || []).each do |server_cert, server_params|
          if server_params['os_image_type'] == 'vmware_esxi' and
              hadrs_hash['asm::cluster::vcenter_hadrs'][title]['ha_config'] == true
            network_params = (server_conf['asm::esxiscsiconfig'] || {})[server_cert]
            network_config = ASM::NetworkConfiguration.new(network_params['network_configuration'], logger)
            mgmt_network = network_config.get_network('HYPERVISOR_MANAGEMENT')
            static = mgmt_network['staticNetworkConfiguration']
            hostname = lookup_hostname(server_params['os_host_name'], static).downcase

            resource_hash['esx_reconfigureha'] ||= {}
            resource_hash['esx_reconfigureha']["Reconfigure#{hostname}"] = {
                'host'      => "#{hostname}",
                'ensure'    => 'present',
                'path'      => "/#{params['datacenter']}/#{params['cluster']}",
                'transport' => "Transport[vcenter]",
                'require' =>  "Asm::Cluster::Vcenter_hadrs[#{vcenter_cert_name}]"
            }

            # Ask this to run before Esx reconfigure resource
            resource_hash['esx_maintmode'] ||= {}
            resource_hash['esx_maintmode']["Disable#{hostname}"] = {
              'ensure' => "absent",
              'timeout' => "600",
              'transport' => "Transport[vcenter]",
              'host' => hostname,
              'before' => "Esx_reconfigureha[Reconfigure#{hostname}]"
            }

          end
        end
      end
      process_generic(vcenter_cert_name, resource_hash, "apply", true, nil, component["asmGUID"])
    end
  end

  def post_vmware_cluster_processing(component)
    begin
      log('Status: Post processing VMware cluster')
      db.log(:info, t(:ASM006, "Processing %{type} components", :type => 'CLUSTER'))
      db.set_component_status(component['id'], :in_progress)

      #fcoe_cluster_processing(component)
      esxi_clear_alarms(component)

      log("Status: Completed_component_CLUSTER/#{component['puppetCertName']}")
      db.log(:info, t(:ASM008, "%{component_name} deployment complete", :component_name => component['puppetCertName']), :component_id => component['id'])
      db.set_component_status(component['id'], :complete)
    rescue => e
      log("Status: Failed_component_CLUSTER/#{component['puppetCertName']}")
      if e.is_a?(ASM::UserException)
        db.log(:error, t(:ASM004, "%{e}", :e => e.to_s), :component_id => component['id'])
      else
        db.log(:error, t(:ASM009, "%{name} deployment failed", :name => component['puppetCertName'], :id => component['id']), :component_id => component['id'])
      end
      db.set_component_status(component['id'], :error)
      write_exception("#{component['puppetCertName']}_exception", e)
      raise e
    end
  end

  def esxi_clear_alarms(cluster_component)
    cert_name = cluster_component['puppetCertName']
    resource_hash = ASM::PrivateUtil.build_component_configuration(cluster_component, :decrypt => decrypt?)
    resource_hash.delete('asm::cluster::vds')

    (resource_hash['asm::cluster'] || {}).each do |title, params|
      resource_hash['asm::cluster'][title].delete 'ha_config'
      resource_hash['asm::cluster'][title].delete 'drs_config'
      resource_hash['asm::cluster'][title].delete 'vds_enabled'
      resource_hash['asm::cluster'][title].delete 'sdrs_config'

      resource_hash['asm::cluster'][title]['vcenter_options'] = { 'insecure' => true }
      resource_hash['asm::cluster'][title]['ensure'] = 'present'
      resource_hash['esx_alarm'] ||= {}

      (find_related_components('SERVER', cluster_component) || []).each_with_index do |server_component,index|
        server_conf = ASM::PrivateUtil.build_component_configuration(server_component, :decrypt => decrypt?)

        (server_conf['asm::server'] || []).each do |server_cert, server_params|
          resource_hash['esx_alarm'][server_component['puppetCertName']] = {
              'ensure' => 'absent',
              'host' => esxi_server_ip(server_component),
              'datacenter' => params['datacenter'],
              'transport' => 'Transport[vcenter]'
          }
        end
      end
    end
    process_generic(cert_name, resource_hash, 'apply')
  end

  def esxi_server_ip(server_component)
    hostname = ''
    server_conf = ASM::PrivateUtil.build_component_configuration(server_component, :decrypt => decrypt?)
    (server_conf['asm::server'] || []).each do |server_cert, server_params|
      if server_params['os_image_type'] == 'vmware_esxi'
        serial_number = ASM::Util.cert2serial(server_cert)
        # Determine host IP
        network_params = (server_conf['asm::esxiscsiconfig'] || {})[server_cert]
        network_config = ASM::NetworkConfiguration.new(network_params['network_configuration'], logger)
        mgmt_network = network_config.get_network('HYPERVISOR_MANAGEMENT')
        static = mgmt_network['staticNetworkConfiguration']
        raise(ArgumentError, "Could not find host ip for #{server_cert}") unless static['ipAddress']
        hostname = lookup_hostname(server_params['os_host_name'], static).downcase
      end
    end
    hostname
  end


  def iscsi_compellent_cluster_processing(component)
    cert_name = component['puppetCertName']
    log("Processing Post Compellent iSCSI cluster component: #{cert_name}")

    resource_hash = ASM::PrivateUtil.build_component_configuration(component, :decrypt => decrypt?)

    post_vmware_cluster_processing(component) if resource_hash['asm::cluster']
    iscsi_scvmm_compellent_cluster_processing(component) if resource_hash['asm::cluster::scvmm']

  end

  def iscsi_scvmm_compellent_cluster_processing(component)
    logger.debug("iSCSI Compellent support needs to be added")
    return true
  end

  # Returns an array, where each element represents an esx network (vswitch or vds), and the network objects/vmnics that go with it
  #
  # @example result
  #   [ { :vmnics => [vmnicn, ...], :networks => [net1, ...]}, {...}, ...]
  #
  # @return [Array]
  def get_vmnics_and_networks(esx_endpoint, server_device_conf, network_config)
    vswitches = []
    unless @debug
      network_config.add_nics!(server_device_conf)
      service_tag = ASM::Util.cert2serial(server_device_conf[:cert_name])
      is_dell_server = ASM::Util.dell_cert?(server_device_conf[:cert_name])
      partitions = network_config.get_all_partitions
      if is_dell_server
        vmnic_macs = parse_vmnics(esx_endpoint)
      else
        vmnic_macs = Hash[partitions.map{ |p| [p.mac_address, "vmnic#{p.partition_index}"]}]
      end
      mac_addresses = partitions.map { |partition| partition.mac_address }
      mac_matches = vmnic_macs.keys.find_all{ |mac| mac_addresses.include?(mac) }
      logger.debug("Found mac addresses for vswitch: #{mac_addresses}")
      unless mac_matches.size == mac_addresses.size
        logger.debug("Only #{mac_matches} vmnics found for mac addresses #{mac_addresses}")

        msg = t(:ASM013, "Only found %{actual_count} ESXi vmnics for server %{serial_number};expected %{expected_count}. Check your network configuration and retry.", :actual_count => mac_matches.size, :serial_number => service_tag, :expected_count => mac_addresses.size)
        raise(ASM::UserException, msg)
      end
      vswitches = gather_vswitch_info(network_config, vmnic_macs)
    end
    vswitches
  end

  # TODO: validate that:
  #  - only one type of storage network used
  def gather_vswitch_info(network_config, vmnic_macs=nil)
    portgroup_order = [:management, :migration, :workload, :storage, :vsan]
    network_types_map = {
        "HYPERVISOR_MANAGEMENT" => :management,
        "HYPERVISOR_MIGRATION" => :migration,
        "PRIVATE_LAN" => :workload,
        "PUBLIC_LAN" => :workload,
        "STORAGE_ISCSI_SAN" => :storage,
        "FILESHARE" => :storage,
        "VSAN" => :vsan
    }
    vswitches = []
    nic_teams = esxi_merge_iscsi_teams(network_config.teams)
    nic_teams = esxi_merge_team_mac(nic_teams)
    nic_teams.reject! { |x| x[:networks].empty?}
    logger.debug("VM NIC MACs: #{vmnic_macs}")
    nic_teams.each do |team|
      portgroups = {}
      team[:networks].reject! { |x| [ "STORAGE_FCOE_SAN", "FIP_SNOOPING"].include?(x.type)}
      # Sorting by the index of the network from the portgroup_order hash ensures we keep the expected portgroup ordering
      networks = team[:networks].sort_by{ |network| portgroup_order.index(network_types_map[network.type]) }
      macs = team[:mac_addresses]
      networks.each do |network|
        type = network_types_map[network.type]
        # Type being nil means we don't support vswitch/VDS construction for that network type, e.g. fcoe/fip
        next if type.nil?
        portgroups[type] ||= {:networks => [], :vmnics => []}
        portgroups[type][:networks].push(network)
        portgroups[type][:vmnics].concat(macs.map{ |mac| vmnic_macs[mac]}).uniq! if vmnic_macs
      end
      vswitches.push(portgroups)
    end
    # Old hosts created vswitches (and portgroups) in a specific order. Though networking is more flexible now,
    # This method ensures we keep the portgroup creation in the same order to ensure old hosts can still be used.
    # We figure out the priority of the vswitch based on what portgroups are in it.
    # The issue of reusing old hosts should only be an issue for hosts that had different networks on different
    # partitions that weren't in our hardcoded order.
    vswitches.reject! { |x| x.empty? }
    vswitches.sort_by! do |vswitch|
      vswitch.keys.map{ |type| portgroup_order.index(type) }.sort.first
    end
    vswitches
  end

  def esxi_merge_iscsi_teams(nic_teams)
    net_type = "STORAGE_ISCSI_SAN"
    iscsi_net = []
    iscsi_mac = []
    iscsi_teams = nic_teams.find_all{|x| x[:networks].find{|y| y.type == net_type}}.flatten

    iscsi_team = {}
    iscsi_teams.each do |iscsi_team|
      iscsi_net.push(*iscsi_team[:networks])
      iscsi_mac.push(*iscsi_team[:mac_addresses])
    end

    iscsi_net.uniq!
    iscsi_team = {:networks => iscsi_net, :mac_addresses => iscsi_mac}

    nic_teams.reject!{|x| x[:networks].find{|y| y[:type] == net_type}}
    nic_teams << iscsi_team
  end

  # Update NIC Team information in case MAC Addresses of iSCSI Network is common to Management Network
  #
  # For iSCSI Compellent converged scenario, network configuation is provided as:
  # Interface 1 (No NPAR) - Hypervisor Management + vMotion + Workload + iSCSI1
  # Interface 2 (No NPAR) - Hypervisor Management + vMotion + Workload + iSCSI2
  # Here we need to create single vSS or vDS so that all common port-groups can be created
  # and iSCSI port-groups can be binding toe specific interface
  #
  # @param nic_teams [ASM::NetworkConfiguration#nic_teams] network hash
  # @return [ASM::NetworkConfiguration#nic_teams] network hash
  def esxi_merge_team_mac(nic_teams)
    hy_mgmt_team = nic_teams.find_all { |x| x[:networks].find{|y| y.type == "HYPERVISOR_MANAGEMENT" }}.first
    return nic_teams unless hy_mgmt_team
    hy_mgmt_mac = hy_mgmt_team[:mac_addresses]
    return nic_teams unless hy_mgmt_mac

    matching_teams = nic_teams.find_all do |x|
      hy_mgmt_mac.include?((x[:mac_addresses] || []).first)
    end

    networks = []
    matching_teams.each do |team|
      networks.push(*team[:networks])
    end
    networks.uniq!
    nic_teams.reject!{|x| (hy_mgmt_mac.include?((x[:mac_addresses] || []).first) && x != hy_mgmt_team)}
    hy_index = nic_teams.find_index { |x| x[:networks].find{|y| y.type == "HYPERVISOR_MANAGEMENT" }}
    nic_teams[hy_index][:networks].push(*networks)
    nic_teams[hy_index][:networks].uniq!
    nic_teams
  end

  def parse_software_hbas(endpoint)
    hostip = endpoint[:host]
    log("getting hba information for #{hostip}")
    h_list = ASM::Util.esxcli(%w(iscsi adapter list), endpoint, logger)
    if h_list.nil? or h_list.empty?
      msg = "Did not find any software iSCSI adapter for #{hostip}"
      logger.error(msg)
      raise(msg)
    end

    hba_list = h_list.select do |hba|
      hba['Description'].match(/iSCSI Software Adapter/)
    end.map { |hba| hba['Adapter'] }

    if hba_list.empty?
      msg = "The software iSCSI adapter has not been enabled for #{hostip}"
      logger.error(msg)
      raise(msg)
    end

    hba_list
  end

  def parse_hbas(endpoint, iscsi_macs)
    hostip = endpoint[:host]
    log("getting hba information for #{hostip}")
    h_list = ASM::Util.esxcli(%w(iscsi adapter list), endpoint, logger)
    if h_list.nil? or h_list.empty?
      msg = "Did not find any iSCSI adapters for #{hostip}"
      logger.error(msg)
      raise(msg)
    end

    hba_list = h_list.sort_by { |hba| hba['Adapter'][/[0-9]+/].to_i }.select do |hba|
      hba['Description'].match(/Broadcom iSCSI Adapter|QLogic 57|QLogic QLE84xx/)
    end.map { |hba| hba['Adapter'] }

    if iscsi_macs.nil?
      # This section is really for "support" or non-Dell servers
      logger.warn("No iSCSI mac addresses provided; defaulting to first two HBAs")
      if hba_list.count > 2
        log("Found iSCSI adapters #{hba_list.join(', ')} for #{hostip}; using #{hba_list[0]} and #{hba_list[1]} for datastore")
      elsif hba_list.count < 2
        raise "At least 2 iSCSI adapters are required."
      else
        log("Found iSCSI adapters #{hba_list[0]} and #{hba_list[1]} for #{hostip}")
      end
      hba_list.slice(0, 2)
    else
      hbas = hba_list.collect do |hba|
        cmd = %w(iscsi adapter get --adapter).push(hba)
        # Find line like "Serial Number: 001018c3d97c"
        mac_address = ASM::Util.esxcli(cmd, endpoint, logger, true).lines.collect do |line|
          if line =~ /Serial Number: ([0-9a-f]+)/
            # Serial number corresponds to mac address without ':' separators
            if $1.length == 12
              # Create mac address
              $1.chars.each_slice(2).collect { |x| x.join('') }.join(':').upcase
            else
              logger.warn("HBA #{hba} serial number does not seem to be a mac address: #{line}")
            end
          end
        end.compact.first

        if mac_address && iscsi_macs.include?(mac_address)
          hba
        else
          logger.warn("No mac address found for HBA #{hba}")
          nil
        end
      end.compact

      if hbas.length != iscsi_macs.length
        msg = t(:ASM014, "Expected %{expected_count} storage HBAs but found %{actual_count}", :expected_count => iscsi_macs.length, :actual_count => hbas.length)
        raise(ASM::UserException, msg)
      else
        hbas
      end
    end
  end

  def parse_vmnics(esx_endpoint)
    vmnic_info = ASM::Util.esxcli(%w(network nic list), esx_endpoint, logger)
    Hash[vmnic_info.map{ |info| [info["MAC Address"].upcase, info["Name"]] }]
  end

  def process_virtualmachine(component)
    log("Processing virtualmachine component: #{component["puppetCertName"]}")
    resource_hash = ASM::PrivateUtil.build_component_configuration(component, :decrypt => decrypt?)

    # For simplicity we require that there is exactly one asm::vm
    # and optionally one asm::server resource
    vms = ASM::Resource::VM.create(resource_hash)
    raise("Expect one set of VM configuration #{vm.size} configuration recieved.") unless vms.size == 1
    vm = vms.first

    servers = ASM::Resource::Server.create(resource_hash)
    raise("Expect zero or one set of Server configuration: #{servers.size} were passed") if servers.size > 1
    server = servers.first

    clusters = find_related_components("CLUSTER", component)
    cluster = clusters.first || {}
    certname = cluster["puppetCertName"]
    raise("Expect one cluster for #{certname}: #{clusters.size} was passed") unless clusters.size == 1

    cluster_deviceconf = ASM::DeviceManagement.parse_device_config(certname)
    cluster_resource = ASM::PrivateUtil.build_component_configuration(cluster, :decrypt => decrypt?)
    clusters = ASM::Resource::Cluster.create(cluster_resource)
    title, cluster_params = clusters.first.shift
    cluster_params.title = title
    cluster_params.ref_id = cluster["asmGUID"]
    cluster_params.vds_info = clusters[1] if clusters[1]
    existing_vds = cluster_resource["asm::cluster::vds"] || {}

    # TODO: does there need to be a better way to match up the VM to a specific server? We just choose first server's PXE network
    # This pxe assigning code will only be relevant for VMware VM case
    network_inventory = ASM::PrivateUtil.get_network_info
    server_net_config = build_related_network_configs(cluster).first
    if !server.nil?
      if server_net_config
        pxe_networks = server_net_config.get_networks("PXE")
        logger.info("Assigning PXE network #{pxe_networks.first["name"]} to VM #{server.os_host_name}")
        if cluster_params.vds_enabled == "standard"
          vm.pxe_name = pxe_networks.first["name"]
        else
          vm.vds_pxe_info = {:vds => vds_name(pxe_networks, existing_vds, title),
                             :portgroup => vds_portgroup_names(title, existing_vds, pxe_networks).first}
        end
      else
        vm.pxe_network_names = network_inventory.find_all { |x| x["type"] == "PXE" }.collect { |x| x["name"] }
      end
    end

    vds_workload_info = {}
    if cluster_params.vds_enabled == "distributed"
      workload_networks = vm.network_interfaces
      # Different workload networks might be on different vds. Need to find vds for each one individually
      logger.debug("Workload networks: #{workload_networks}")
      workload_networks.each do |net|
        vds = vds_name(workload_networks, existing_vds, title)
        vds_pg = vds_portgroup_names(title, existing_vds, workload_networks).first
        vds_workload_info[net.name] = {:vds => vds, :portgroup => vds_pg}
      end
      vm.vds_workload_info = vds_workload_info
      logger.debug("VDS Workload Info: #{vds_workload_info}")
    end


    # Check if VM is already deployed.
    # For create VMware create VM needs to skip adding default network
    # If VM is already deployed, to avoid reset

    vm.process!(certname, server, cluster_params, @id, logger)
    hostname = vm.hostname || server.os_host_name
    unless hostname
      raise(ArgumentError, "VM hostname not specified, missing server os_host_name value")
    end

    resource_hash = vm.to_puppet
    vm_resource = resource_hash[resource_hash.keys[0]]
    vm_title = vm_resource.keys[0]
    requested_networks = vm_resource[vm_title]["requested_network_interfaces"]
    vm_resource[vm_title].delete("requested_network_interfaces")
    resource_hash[resource_hash.keys[0]][vm_title].delete("requested_network_interfaces")
    vm_resource[vm_title].delete("default_gateway")

    log("Creating VM #{hostname}")
    certname = "vm-#{hostname.downcase}"
    process_generic(certname, resource_hash, "apply")

    if server
      uuid = @debug ? "DEBUG-MODE-UUID" : ASM::PrivateUtil.find_vm_uuid(cluster_deviceconf, hostname,cluster_params.datacenter)
      log("Found UUID #{uuid} for #{hostname}")
      log("Initiating O/S install for VM #{hostname}")

      serial_number = @debug ? "vmware_debug_serial_no" : ASM::Util.vm_uuid_to_serial_number(uuid)
      server.process!(serial_number, @id)
      server.title = vm_title # TODO: clean this up
      resource_hash['asm::server'] = server.to_puppet

      # Teardown should remove old policies, but delete them here just in case
      razor.delete_stale_policy!(serial_number, server.policy_name)

      process_generic(certname, resource_hash, 'apply')

      unless @debug
        # First time we write the post os config helps us configure networks if we need to switch dellasm IP in host file
        vm.vds_workload_info = vds_workload_info
        post_install_written = write_post_install_config(component, vm.certname, vm, cluster_params)
        vm.delete("vds_workload_info")
        # Unlike in bare-metal installs we only wait for the :boot_install
        # log event in razor. At that point the O/S installer has just been
        # launched, it is not complete. This is done because our VMs have hard
        # disk earlier in the boot order than PXE. Therefore the nodes do not
        # check in with razor at all once they have an O/S laid down on hard
        # disk and we will not see any :boot_local events
        begin
          razor.block_until_task_complete(serial_number, nil, server['policy_name'], nil, :bind, db)
        rescue
          logger.info("VM was not able to PXE boot.  Resetting VM.")
          db.log(:info, t(:ASM026, "VM %{certname} not able to PXE boot.  Resetting VM", :certname => certname))
          vm.reset
        end
        razor_result = razor.block_until_task_complete(serial_number, nil, server['policy_name'],
                                                       nil, :boot_install, db)
        timestamp = razor_result.nil? ? Time.now : razor_result[:timestamp]
        begin
          await_agent_run_completion(vm.certname, timestamp)
        rescue Timeout::Error
          msg = t(:ASM055, "Puppet agent failed to check in for VM %{hostname} after the OS installation", :hostname => hostname)
          db.log(:error, msg)
          raise(ASM::UserException, msg)
        end
      end
      # This post install config will be under assumption PXE network has been removed
      vm.vds_workload_info = vds_workload_info
      write_post_install_config(component, vm.certname, vm, cluster_params)
      vm.delete("vds_workload_info")
      if requested_networks && !requested_networks.empty?
        logger.info("Running puppet on VM #{vm_title} one more time to reconfigure networks.")
        db.log(:info, t(:ASM044, "Running puppet on VM %{vmTitle} again to reconfigure networks", :vmTitle => vm_title))
        vm_resource[vm_title]['network_interfaces'] ||= []
        vm_resource[vm_title]['network_interfaces'].delete_if{|item| item['portgroup']=="VM Network"} if !vm_resource[vm_title]['network_interfaces'].nil?

        # Check if there are requested networks
        vm_resource[vm_title]['network_interfaces'] = requested_networks
        logger.debug("VM network interfaces: #{vm.network_interfaces}")
        #Rerun one more time to remove PXE network.
        process_generic(certname, resource_hash, 'apply')
      end
    else
      # Clone VM Scenarios
      vm.vds_workload_info = vds_workload_info
      write_post_install_config(component, vm.certname, vm, cluster_params)
      vm.delete("vds_workload_info")
    end
    unless debug?
      if post_install_written
        timestamp = ASM::PrivateUtil.node_data_update_time(vm.certname)
        begin
          await_agent_run_completion(vm.certname, timestamp)
        rescue Timeout::Error
          msg = t(:ASM055, "Puppet agent failed to check in for VM %{hostname} post OS processes", :hostname => hostname)
          db.log(:error, msg)
          raise(ASM::UserException, msg)
        end
      end
    end
  end

  def await_agent_run_completion(certname, timestamp=Time.now, timeout = 5400)
    db.log(:info, t(:ASM039, "Waiting for puppet agent to check in for %{certname}", :certname => certname))
    ASM::Util.block_and_retry_until_ready(timeout, ASM::CommandException, 60) do
      check_agent_checkin(certname, timestamp)
    end
  end

  # ported to Type::Server#write_post_install_config!
  def write_post_install_config(component, agent_cert_name, vm=nil, cluster_params=nil)
    puppet_config = get_post_installation_config(component, vm, cluster_params)
    return false if puppet_config.empty?
    config = {agent_cert_name => puppet_config}
    logger.debug("puppet_config: #{puppet_config}")
    ASM::PrivateUtil.write_node_data(agent_cert_name, config)
    true
  end

  def check_agent_checkin(certname, timestamp, options = {})
    options = {
        :verbose => true
    }.merge(options)

    unless puppetdb.successful_report_after?(certname, timestamp, options)
      db.log(:error, t(:ASM049, "A recent Puppet event for the node %{certName} has failed. Node may not be correctly configured", :certName => certname)) if options[:verbose]
      raise(PuppetEventException, "A recent Puppet event for the node #{certname} has failed.  Node may not be correctly configured.")
    end

    log("Agent #{certname} has checked in with Puppet master") if options[:verbose]
    db.log(:info, t(:ASM043, "Agent %{certname} has checked in with Puppet master", :certname => certname)) if options[:verbose]
    true
  end

  def hyperv_post_installation(os_host_name,certname,timeout = 3600)
    # Reboot the server
    serverhash = get_server_inventory(certname)
    endpoint = {}
    serverhash.each do |nodename,sinfo|
      endpoint = {
        :host => sinfo['idrac_ip'],
        :user => sinfo['idrac_username'],
        :password => sinfo['idrac_password']
      }
    end

    wsman = ASM::WsMan.new(endpoint, :logger => logger)

    # ASM-6175 Ensure the server is on. It should be, but we have seen a few cases
    # where a Windows kernel panic forced it to shut down during the OS install
    wsman.power_on

    # Need to reboot the server to initiate the Hyper-V postinstall scripts. Also
    # need to remove PXE from boot order. That has the side-effect of rebooting
    # the server so we kill two birds with one stone here.
    disable_pxe(wsman)

    log("Agent #{certname} has been rebooted to initiate post-installation")
    db.log(:info, t(:ASM041, "Agent %{certname} has been rebooted to initate post-installation", :certname => certname))
    log("Agent #{certname} - waiting for 10 minutes before validating the post-installation status")
    sleep(600)
    # Wait for the server to go to power-off state
    ASM::Util.block_and_retry_until_ready(timeout, ASM::CommandException, 60) do
      if wsman.power_state != :off
        log("Post installation for Server #{certname} still in progress .  Retrying...")
        raise(ASM::CommandException, "Post installation for Server #{certname} still in progress .  Retrying...")
      end
    end
    log("Post installation for Server #{certname} is completed")
    db.log(:info, t(:ASM042, "Post installation for Server %{hostName} is completed", :hostName => os_host_name))

    # Power-on the server
    log("Rebooting server #{certname}")
    db.log(:info, t(:ASM040, "Rebooting server %{hostName}", :hostName => os_host_name))

    wsman.reboot

    # Wait puppet agent to respond
    log("Agent #{certname} Waiting for puppet agent to respond after reboot")
    begin
      await_agent_run_completion(os_host_name)
    rescue Timeout::Error
      raise(ASM::UserException, t(:ASM051, "Puppet Agent failed to check in for %{serial} %{ip}",
                                  :serial => ASM::Util.cert2serial(certname), :ip => endpoint[:host]))
    end
    true
  end

  # converts from an ASM style server resource into
  # a method call to check if the esx host is up
  def block_until_esxi_ready(title, params, static_ip, timeout = 3600)
    serial_num = params['serial_number'] || raise("resource #{title} is missing required server attribute serial_number")
    password = params['admin_password'] || raise("resource #{title} is missing required server attribute admin_password")
    if decrypt?
      password = ASM::Cipher.decrypt_string(password)
    end
    hostname = params['os_host_name'] || raise("resource #{title} is missing required server attribute os_host_name")
    hostdisplayname = "#{serial_num} (#{hostname})"

    log("Waiting until ESXi management services available on #{hostdisplayname}")
    db.log(:info, t(:ASM029, "Waiting until ESXi management services available on %{hostDisplayName}", :hostDisplayName => hostdisplayname))
    start_time = Time.now
    ASM::Util.block_and_retry_until_ready(timeout, ASM::CommandException, 150) do
      esx_command =  "system uuid get"
      cmd = "esxcli --server=#{static_ip} --username=root --password=#{password} #{esx_command}"
      log("Checking for #{hostdisplayname} ESXi uuid on #{static_ip}")
      results = ASM::Util.run_command_simple(cmd)
      unless results['exit_status'] == 0 and results['stdout'] =~ /[1-9a-z-]+/
        raise(ASM::CommandException, results['stderr'])
      end
    end

    elapsed = Time.now - start_time
    if elapsed > 60
      # Still cases where ESXi is not available to be added to the cluster
      # in the process_cluster method even after the uuid has been
      # obtained above; trying a 5 minute sleep... Seems to happen more
      # frequently when only one ESXi host is in the deployment.
      #
      # NOTE: Only doing this additional sleep if it appears that the host was
      # not already online when this method was called, e.g. if it took more
      # than 60 seconds to complete.
      sleep_secs = 450
      logger.debug("Sleeping an additional #{sleep_secs} waiting for ESXi host #{hostdisplayname} to come online")
      sleep(sleep_secs)
    end

    log("ESXi server #{hostdisplayname} is available")
    db.log(:info, t(:ASM020, "ESXi server %{hostDisplayName} is now available", :hostDisplayName => hostdisplayname))
  end

  #Resets VirtualMac Addresses to permanent mac addresses
  def cleanup_server(server_component, old_server_cert)
    server_conf = ASM::PrivateUtil.build_component_configuration(server_component, :decrypt => decrypt?)
    server_cert = server_component['puppetCertName']
    network_params = (server_conf['asm::esxiscsiconfig'] || {})[server_cert]
    idrac_params = (server_conf['asm::idrac'] || {})[server_cert]
    # get fabric information
    if network_params
      net_config = ASM::NetworkConfiguration.new(network_params['network_configuration'])
      device_conf = ASM::DeviceManagement.parse_device_config(old_server_cert)
      inventory = ASM::PrivateUtil.fetch_server_inventory(old_server_cert)
      new_conf = {'asm::idrac' => {
          old_server_cert => {
            'servicetag'            => inventory['serviceTag'],
            'network_configuration' => net_config.to_hash,
            'raid_configuration'    => idrac_params['raid_configuration'],
            'ensure'                => 'teardown',
            'target_boot_device'    => idrac_params['target_boot_device']
          }}}
      new_conf['asm::idrac'][old_server_cert].delete('raid_configuration') if idrac_params['raid_configuration'].nil?
      process_generic(old_server_cert, new_conf, 'apply', 'true')
    end
  end

  def get_host_and_domain(fqdn)
    if fqdn =~ /^(.+?)\.(.+)$/
      [$1, $2]
    else
      raise("Cannot figure out the hostname and domain from fqdn '%s'" % fqdn)
    end
  end

  def get_compellent_lunid(hostip, username, password, compellent_deviceid, retry_get = false, rescan_storage = true)
    log("getting storage core path information for #{hostip}")
    endpoint = {
      :host => hostip,
      :user => username,
      :password => password,
    }

    if rescan_storage == true
      begin
        logger.debug("Invoke rescan before getting the LUN ID")
        cmd = "storage core adapter rescan --all".split
        ASM::Util.esxcli(cmd, endpoint, logger, true)
        sleep(60)
      rescue => e
        logger.debug("Exception observed during rescan. Ignoring")
      end
    end

    storage_info = []
    (1..15).each do |counter|
      cmd = 'storage core path list'.split
      storage_path = ASM::Util.esxcli(cmd, endpoint, logger, true)
      storage_info = storage_path.scan(/Device:\s+naa.#{compellent_deviceid}.*?LUN:\s+(\d+)/m)
      if storage_info.empty?
        logger.debug("Attempt:#{counter}: Failed to get storage information")
        sleep(60)
      else
        logger.debug("Got the response in attempt: #{counter}")
        break
      end
    end

    if storage_info.empty? and retry_get == false
      logger.debug("Compellent LUN ID is not accessible, retrying")
      return get_compellent_lunid(hostip, username, password, compellent_deviceid, retry_get=true, rescan_storage = true)
    end

    if storage_info.empty? and retry_get == true
      msg = "Compellent lunid not found for hostip = #{hostip}, deviceid = #{compellent_deviceid}"
      logger.error(msg)
      raise(msg)
    end
    storage_info[0][0]
  end

  # Process switches using the type and provider framework
  #
  # This is a stop gap that only acts on switch related rules, the intent is to
  # eventually move switch processing into {#process_service_with_rules} as well
  # as everything else but as we're busy extracting just switch processing before
  # any service processing for buildouts we're doing this seperate for now
  #
  # @param deployment [Hash] the deployment JSON already parsed to a hash
  # @raise [StandardError] on switch configuration failure
  def process_switches_via_types(deployment, options={})
    require "asm/service"
    service = ASM::Service.new(deployment, :deployment => self)
    begin
      service.switch_collection.configure_server_networking!(options)
    rescue ASM::UnconnectedServerException => e
      #We're catching the exception here and instead putting the failed servers in a list that can be processed in a block where migrate happens
      unconnected_servers(e.unconnected_servers)
    end
  end

  def unconnected_servers(servers=nil)
    @unconnected_servers_mutex.synchronize do
      @unconnected_servers ||= []
      @unconnected_servers.concat(servers) if servers
      @unconnected_servers
    end
  end

  def find_external_volume_with_most_servers
    storage_components = components_by_type("STORAGE")
    selected_volume = ""
    related_servers_selected_volume = 0
    if storage_components && !storage_components.empty?
      storage_components.each do |storage_component|
        related_servers = find_related_components("SERVER", storage_component)
        if related_servers && related_servers.length > related_servers_selected_volume
          volume_resource = storage_component["resources"].select {|res| res["id"].start_with?("asm::volume")}.first
          unless volume_resource.nil?
            volume_name_param = volume_resource["parameters"].select {|param| param["id"] == "title"}.first
            unless volume_name_param.nil?
              # We found a volume with more attached servers, hence select it
              selected_volume = volume_name_param["value"]
              related_servers_selected_volume = related_servers.length
            end
          end
        end
      end
    end
    if selected_volume && !selected_volume.empty?
      logger.debug("Found '#{selected_volume}' as external volume with most related servers")
    else
      logger.warn("No external volume found from template")
    end
    selected_volume
  end

  private

  def deployment_dir
    @deployment_dir ||= begin
      deployment_dir = File.join(ASM.base_dir, @id.to_s)
      create_dir(deployment_dir, true)
      deployment_dir
    end
  end

  def create_dir(dir, warning=false)
    if File.exists?(dir)
      ASM.logger.warn("Directory already exists: #{dir}") if warning
    else
      FileUtils.mkdir_p(dir)
    end
  end

  def deployment_file(*file)
    File.join(deployment_dir, *file)
  end

  def resources_dir
    dir = deployment_file('resources')
    create_dir(dir)
    dir
  end

  def create_logger
    id_log_file = deployment_file('deployment.log')
    File.open(id_log_file, 'a')
    Logger.new(id_log_file)
  end

  def empty_guid?(guid)
    !guid || guid.to_s.empty? || guid.to_s == '-1'
  end

  # For Bare-Metal deployment following rules are followed
  # 1- PXE VLAN will be untagged
  # 2- Workload VLAN will be tagged it there are more than one workload VLANs mapped to the server
  # 3- Workload VLAN will be tagged if same VLAN is marked as tagged on any other port
  def bm_tagged?(nc,network)
    if network.type == 'PXE'
      return false
    elsif workload_network_vlans(nc).size > 1 && ['PUBLIC_LAN','PRIVATE_LAN'].include?(network.type)
      return true
    elsif workload_network_count(nc,network) > 1
      return true
    elsif workload_with_pxe?(nc, network)
      true
    else
      return false
    end
  end
  public :bm_tagged?

  def workload_with_pxe?(nc, network)
    network_partitions = nc.get_partitions(network.type)
    return true if network_partitions.count > 1

    pxe_partitions = nc.get_partitions("PXE")
    return false if pxe_partitions.empty?

    pxe_mac = pxe_partitions[0].mac_address
    network_partitions[0]["mac_address"] == pxe_mac
  end

  def network_workload_networks(nc)
    nc.get_networks('PUBLIC_LAN', 'PRIVATE_LAN') || []
  end

  def workload_network_vlans(nc)
    network_workload_networks(nc).map {|x| x['vlanId']}.flatten
  end

  def workload_network_count(nc,network)
    workload_count = 1
    logger.debug("Team Info: #{nc.teams}")
    nc.teams.each do |teams|
      teams[:networks].each do |net|
        if net.vlanId == network.vlanId
          logger.debug("Network matched: #{net}")
          workload_count = teams[:mac_addresses].count
          break
        end
      end
    end
    logger.debug("Workload count: #{workload_count}")
    workload_count
  end

  def initiate_discovery(device_hash)
    unless device_hash.empty? || @debug
      discovery_obj = Discoverswitch.new(device_hash,self)
      discovery_obj.discoverswitch(logger,db)
    end
  end

  def reboot_all_servers
    reboot_count = 0
    components_by_type('SERVER').each do |server_component|
      server_cert_name = server_component['puppetCertName']
      deployed_status = server_already_deployed(server_component,nil)
      logger.debug("Server #{server_cert_name} not deployed status #{deployed_status}")
      device_conf = ASM::DeviceManagement.parse_device_config(server_cert_name)
      unless deployed_status
        logger.debug("Rebooting the server #{server_cert_name}")
        ASM::WsMan.reboot(device_conf, logger)
        ASM::WsMan.wait_for_lc_ready(device_conf, logger)
        reboot_count +=1
      end
    end
    if reboot_count > 0
      logger.debug "Some servers are rebooted, need to sleep for a minute"
      # Adding additional delay to take care of Brocade 5424 SAN IOM module
      sleep(300)
    else
      logger.debug "No server is rebooted, no need to sleep"
    end
  end

  def servers_wait_for_lc
    threads = []
    components_by_type('SERVER').each do |server_component|
      threads << ASM.execute_async(logger) do
        logger.debug "Check for LC State of server #{server_component['puppetCertName']}"
        server_wait_for_lc(server_component)
      end
    end
    threads.each do |thrd|
      thrd.join
    end
  end

  def server_wait_for_lc(server_component)
    return true if server_already_deployed(server_component,nil)
    server_cert_name = server_component['puppetCertName']
    device_conf ||= ASM::DeviceManagement.parse_device_config(server_cert_name)
    logger.debug("Waiting for LC state for server: #{server_cert_name}")
    ASM::WsMan.wait_for_lc_ready(device_conf, logger)
  end

  def hyperv_validate_agent_status(component, hyperv_hosts)
    cert_name = component['puppetCertName']
    exceptions = []
    threads = []
    (hyperv_hosts || []).each do |server_component|
      threads << ASM.execute_async(logger) do
        logger.debug "Validating puppet agent status for #{server_component['puppetCertName']}"
        resource_hash = ASM::PrivateUtil.build_component_configuration(server_component, :decrypt => decrypt?)
        server = ASM::Resource::Server.create(resource_hash).first
        os_host_name = server.os_host_name
        await_agent_run_completion(ASM::Util.hostname_to_certname(os_host_name), Time.at(Time.now.to_i - 60*10))
      end
    end
    threads.each do |thrd|
      thrd.join
      if thrd[:exception]
        exceptions.push(thrd[:exception])
      end
    end

    if exceptions.empty?
      log('Finished validation of puppet agent status')
      db.log(:info, t(:ASM010, 'Finished validation of puppet agent status'))
    else
      msg = t(:ASM011, 'Finished validation of puppet agent status')
      log(msg)
      db.log(:error, msg)

      # Failing by raising *one of* the exceptions thrown in the process thread
      # Other failures will be captured in exception log files.
      raise exceptions.first
    end
  end

  def hyperv_server_component(cluster_component, host_name)
    servers = find_related_components('SERVER', cluster_component)
    servers.find {|x| server_fqdd(x) == host_name}
  end

  def server_fqdd(server_component)
    asm_server = get_asm_server_params(server_component)
    "#{asm_server['os_host_name']}.#{asm_server['fqdn']}"
  end

  def configure_hyperv_cluster(component, cluster_resource_hash, title, puppet_ensure="present")

    cert_name = component['puppetCertName']
    db.log(:info, t(:ASM, "Configuring HyperV Cluster"))
    # Get all the hyperV hosts
    hyperv_hosts = find_related_components('SERVER', component)
    hyperv_vms = find_related_components('VIRTUALMACHINE', component)

    cluster_name = cluster_resource_hash['asm::cluster::scvmm'][title]['name']
    logger.debug "Cluster name: #{cluster_name}"

    if hyperv_hosts.size == 0 and hyperv_vms.size >= 0
      # Check if cluster already exists on SCVMM. If not then raise exception
      if hyperv_cluster_ip?(cert_name, cluster_name).nil?
        raise ("No Hyper-V hosts or VMs in the template. SCVMM cluster needs to used either with HyperV server or VM")
      else
        logger.debug("Hyper-V SCVMM already configured. Returning success")
        return true
      end
    end

    if hyperv_hosts.size == 0
      logger.debug("No Hyper-V hosts or VMs in the template, skipping cluster configuration")
      return true
    end

    is_teardown = puppet_ensure == 'absent'
    # TODO: puppet agent 3.3.2 is having issues with NIC teaming
    # Skipping the checking till we update the puppet agent
    #hyperv_validate_agent_status(component, hyperv_hosts) if puppet_ensure == 'present'

    hyperv_hostnames = get_hyperv_server_hostnames(hyperv_hosts, is_teardown)
    logger.debug "HyperV Host's hostname: #{hyperv_hostnames}"

    # Run-As-Account
    run_as_account_credentials = run_as_account_credentials(hyperv_hosts[0])
    logger.debug("Run-As Accounf credentials: #{run_as_account_credentials}")
    host_group = cluster_resource_hash['asm::cluster::scvmm'][title]['hostgroup']
    # hostgroup name is not in the template for existing cluster
    host_group = ASM::PrivateUtil.hyperv_cluster_hostgroup(cert_name,cluster_name) if host_group.nil?
    if !host_group.include?('All Hosts')
      logger.debug "Host-Group value do not contain All Hosts"
      host_group = "All Hosts\\#{host_group}"
    end
    logger.debug "Host-Group : '#{host_group}'"

    # if not then reserve one ip address from the converged net
    cluster_ip_address = cluster_resource_hash['asm::cluster::scvmm'][title]['ipaddress']
    logger.debug "Cluster IP Address in service template: #{cluster_ip_address}"
    if cluster_ip_address.nil? or cluster_ip_address.empty?
      #check for already existent cluster before reserving new cluster ip
      cluster_ip_address = (hyperv_cluster_ip?(cert_name, cluster_name) || get_hyperv_cluster_ip(hyperv_hosts[0]))
    end

    domain_username = "#{run_as_account_credentials['domain_name']}\\#{run_as_account_credentials['username']}"
    resource_hash = Hash.new

    # TODO: why do we only look at the first host? why only workload and pxe networks?
    # why the empty 'subnet' => '' part of the hash?
    network_config = build_network_config(hyperv_hosts[0])
    raise("Could not find network config for #{hyperv_hosts[0]}") unless network_config
    subnet_vlans = network_config.get_networks('PUBLIC_LAN', 'PRIVATE_LAN', 'PXE').collect do |network|
      {'vlan' => network['vlanId'], 'subnet' => ''}
    end

    if !is_teardown
      # For iSCSI Compellent, the volumes needs to be refreshed on the host
      #refresh_hyperv_storages(component,logger) if is_iscsi_compellent_deployment? && is_hyperv_deployment_with_compellent?
      refresh_hyperv_storages(component,logger)

      host_group_array = Array.new

      resource_hash['asm::cluster::scvmm'] = {
        "#{cluster_name}" => {
        'ensure'      => 'present',
        'host_group' => host_group,
        'ipaddress' => cluster_ip_address,
        'hosts' => hyperv_hostnames,
        'username' => domain_username,
        'password' => run_as_account_credentials['password'],
        'run_as_account_name' => run_as_account_credentials['username'],
        'logical_network_hostgroups' => host_group_array.push(host_group),
        'logical_network_subnet_vlans' => subnet_vlans,
        'fqdn' => run_as_account_credentials['fqdn'],
        'scvmm_server' => cert_name,
        }
      }

      process_generic(cert_name, resource_hash, 'apply')

      # Need to configure the live-migration and cluster vm adapter properties
      # These commands needs to be executed on the cluster-node instead of the SCVMM
      hyperv_hostnames.each_with_index do |hyperv_host,index|
        base_resources = {"transport" => {}}
        base_resources["transport"]["winrm"] =
            {"server" => hyperv_host,
             "username" => domain_username,
             "options" =>
                 {"crypt_string" => run_as_account_credentials['password']}}
        base_resources['transport']['winrm']['provider'] = 'asm_decrypt' if decrypt?

        adapter_resource = {}

        server_component = hyperv_server_component(component, hyperv_host)
        # For iSCSI Diverged configurations need to enable the iSCSI adapters disabled
        if is_hyperv_iscsi?(server_component) && !is_converged_hyperv_config?(server_component)
          adapter_resource["host_network_adapter"] = {}
          adapter_resource["host_network_adapter"][hyperv_host] =
              {"ensure" => "present",
               "transport" => "Transport[winrm]",
               "mac_addresses" => hyperv_iscsi_macs(server_component).join(','),
               "state" => 'Enabled'
              }
          adapter_resource["host_network_adapter"][hyperv_host]['provider'] = 'asm_decrypt' if decrypt?
        end


        adapter_resource["scvm_host_adapter"] = {}
        adapter_resource["scvm_host_adapter"][cluster_name] =
            {"ensure" => "present",
             "transport" => "Transport[winrm]",
             "username" => domain_username,
             "password" => run_as_account_credentials['password']
            }
        adapter_resource["scvm_host_adapter"][cluster_name]['provider'] = 'asm_decrypt' if decrypt?
        adapter_resource.merge!(base_resources)
        # From the cluster definition on the SCVMM, we cannot make out on which host these commands will.
        # To take of this we are iterating through all the cluster-nodes until we find a server where commands works.
        # Raise exception only when all the hosts fails.
        begin
          process_generic(cert_name, adapter_resource, 'apply')
          logger.debug("Successfully configured LiveMigration and Cluster Adapter settings")
          break
        rescue
          logger.debug("LiveMigration and Cluster Adapter settings failed for #{hyperv_host}")
        end
      end

    else
      mgmt_network = network_config.get_network('HYPERVISOR_MANAGEMENT')
      dns_server = mgmt_network["staticNetworkConfiguration"]["primaryDns"]

      base_resources = {"transport" => {}}
      base_resources["transport"][cert_name] = {"options" => {"timeout" => 600}, "provider" => "device_file"}
      base_resources["transport"]["winrm"] = {"server" => dns_server, "username" => domain_username, "provider" => "asm_decrypt", "options" => {"crypt_string" => run_as_account_credentials['password']}}

      if component['teardown']
        host_cluster_resources = {"scvm_host_cluster" => {cluster_name => {"ensure" => "absent",
                                                                           "hosts"  => hyperv_hostnames,
                                                                           "cluster_ipaddress" => cluster_ip_address,
                                                                           "path" => host_group,
                                                                           "username" => domain_username,
                                                                           "password" => run_as_account_credentials['password'],
                                                                           "fqdn" => run_as_account_credentials['fqdn'],
                                                                           "inclusive" => false,
                                                                           "transport" => "Transport[#{cert_name}]",
                                                                           "provider" => "asm_decrypt"}}}.merge!(base_resources)

        logger.info("Removing scvm_host_cluster[%s]" % cluster_name)
        process_generic(cert_name, host_cluster_resources, 'apply')

        cluster_storage_resources = {"scvm_cluster_storage" => {cluster_name => {"ensure" => "absent",
                                                                                 "host"   => hyperv_hostnames.first,
                                                                                 "path" => host_group,
                                                                                 "username" => domain_username,
                                                                                 "password" => run_as_account_credentials['password'],
                                                                                 "fqdn" => run_as_account_credentials['fqdn'],
                                                                                 "transport" => "Transport[#{cert_name}]",
                                                                                 "provider" => "asm_decrypt"}}}.merge!(base_resources)

        logger.info("Removing scvm_cluster_storage[%s]" % cluster_name)
        process_generic(cert_name, cluster_storage_resources, 'apply')

        # Skipping the deletion of SC Logical network definition as this is shared by all ASM deployed clusters
        logical_network_def = {"sc_logical_network_definition" => {"ConvergedNetSwitch" => {"ensure" => "absent",
                                                                                            "logical_network" => "ConvergedNetSwitch",
                                                                                            "host_groups" => [host_group],
                                                                                            "subnet_vlans" => subnet_vlans,
                                                                                            "inclusive" => false,
                                                                                            "skip_deletion" => true,
                                                                                            "transport" => "Transport[#{cert_name}]"}}}.merge!(base_resources)

        logger.info("Removing sc_logical_network_definition[ConvergedNetSwitch]")
        process_generic(cert_name, logical_network_def, 'apply')
      end

      # In case cluster is not destroyed, we need to try to remove the host from the scvmm cluster
      host_cluster_resources = {}
      if !component['teardown'] and hyperv_hostnames
        host_cluster_resources['scvm_host_cluster'] ||= {}
        host_cluster_resources = {"scvm_host_cluster" => {cluster_name => {"ensure" => "present",
                                                                           "remove_hosts"  => hyperv_hostnames,
                                                                           "cluster_ipaddress" => cluster_ip_address,
                                                                           "path" => host_group,
                                                                           "username" => domain_username,
                                                                           "password" => run_as_account_credentials['password'],
                                                                           "fqdn" => run_as_account_credentials['fqdn'],
                                                                           "inclusive" => false,
                                                                           "transport" => "Transport[#{cert_name}]",
                                                                           "provider" => "asm_decrypt"}}}.merge!(base_resources)
        begin
          logger.info("Removing hosts #{hyperv_hostnames} from the cluster #{cluster_name}")
          process_generic(cert_name, host_cluster_resources, 'apply')
        rescue => e
          logger.debug("Failed to remove the host from the cluster")
        end
      end

      hosts_resources = {"scvm_host" => {}, "dnsserver_resourcerecord" => {}, "computer_account" => {}}
      domainname = ''
      hyperv_hostnames.each do |host|
        logger.info("Removing scvm_host[%s]" % host)
        hosts_resources["scvm_host"][host] = {"ensure" => "absent",
                                              "path" => host_group,
                                              "management_account" => run_as_account_credentials['username'],
                                              "transport" => "Transport[#{cert_name}]",
                                              "provider" => "asm_decrypt",
                                              "username" => domain_username,
                                              "before" => "Scvm_host_group[#{host_group}]",
                                              "password" => run_as_account_credentials['password']}

        begin
          hostname, domainname = get_host_and_domain(host)

          logger.info("Removing DNS host %s from zone %s" % [hostname, domainname])
          hosts_resources["dnsserver_resourcerecord"][hostname] = {"ensure" => "absent", "zonename" => domainname, "transport" => "Transport[winrm]"}
          hosts_resources["computer_account"][hostname] = {"ensure" => "absent", "transport" => "Transport[winrm]", "require" => "Dnsserver_resourcerecord[#{hostname}]"}
        rescue => e
          logger.info("Could not remove DNS for host '%s': %s" % [host, e.to_s])
        end
      end

      logger.info("Removing scvm_host_group[%s]" % host_group)
      hosts_resources["scvm_host_group"] = {host_group => {"ensure" => "absent", "transport" => "Transport[#{cert_name}]"}}
      hosts_resources.merge!(base_resources)

      begin
        process_generic(cert_name, hosts_resources, 'apply')
      rescue Exception => ex
        logger.debug "Error while removing hosts from the cluster"
      ensure
        # Remove scvmm cluster hostname dns record
        if component['teardown']
          logger.info("Removing DNS entry of cluster %s from zone %s" % [cluster_name, domainname])
          cluster_resources = { "dnsserver_resourcerecord" => {}, "computer_account" => {} }
          cluster_resources["dnsserver_resourcerecord"][cluster_name] = {"ensure" => "absent", "zonename" => domainname, "transport" => "Transport[winrm]"}
          cluster_resources["computer_account"][cluster_name] = {"ensure" => "absent", "transport" => "Transport[winrm]", "require" => "Dnsserver_resourcerecord[#{cluster_name}]"}
          cluster_resources.merge!(base_resources)
          process_generic(cert_name, cluster_resources, 'apply')
        end
      end
    end
  end
  public :configure_hyperv_cluster

  def run_as_account_credentials(server_component)
    run_as_account = {}
    resource_hash = ASM::PrivateUtil.build_component_configuration(server_component, :decrypt => decrypt?)
    if resource_hash['asm::server']
      title = resource_hash['asm::server'].keys[0]
      params = resource_hash['asm::server'][title]
      run_as_account['username'] = params['domain_admin_user']
      run_as_account['password'] = params['domain_admin_password']
      run_as_account['domain_name'] = params['domain_name']
      run_as_account['fqdn'] = params['fqdn']
    end
    run_as_account
  end

  def get_hyperv_server_hostnames(server_components, for_teardown=true)
    hyperv_host_names = []
    server_components.each do |component|
      cert_name = component['puppetCertName']
      resource_hash = {}
      resource_hash = ASM::PrivateUtil.build_component_configuration(component, :decrypt => decrypt?)

      if resource_hash['asm::server']
        if resource_hash['asm::server'].size != 1
          msg = "Only one O/S configuration allowed per server; found #{resource_hash['asm::server'].size} for #{serial_number}"
          logger.error(msg)
          raise(msg)
        end

        title = resource_hash['asm::server'].keys[0]
        params = resource_hash['asm::server'][title]
        os_host_name  = params['os_host_name']
        fqdn  = params['fqdn']
        if (for_teardown && component['teardown']) || !for_teardown
          hyperv_host_names.push("#{os_host_name}.#{fqdn}")
        end
      end
    end
    hyperv_host_names.sort
  end

  def get_hyperv_cluster_ip(component)
    # Need to reserve a IP address from the converged network
    cluster_ip = ''
    cert_name = component['puppetCertName']
    server_conf = ASM::PrivateUtil.build_component_configuration(component, :decrypt => decrypt?)
    network_params = (server_conf['asm::esxiscsiconfig'] || {})[cert_name]
    network_config = ASM::NetworkConfiguration.new(network_params['network_configuration'], logger)
    management_network = network_config.get_network('HYPERVISOR_MANAGEMENT')
    log("Reserving cluster IP...")
    ip_address_accessible = true
    while ip_address_accessible
      cluster_ip = ASM::PrivateUtil.reserve_network_ips(management_network['id'], 1, @id)
      ip_address_accessible = ASM::Util.is_ip_address_accessible(cluster_ip[0])
      logger.debug("Skipping IP #{cluster_ip[0]} as it is already in use") if ip_address_accessible
    end
    cluster_ip[0]
  end
  public :get_hyperv_cluster_ip

  def hyperv_cluster_ip?(cert_name, cluster_name)
    #Check for existence of cluster ip, if found return ip, else return nil
    conf = ASM::DeviceManagement.parse_device_config(cert_name)
    domain, user = conf['user'].split('\\')
    cmd = File.join(File.dirname(__FILE__),'scvmm_cluster_ip.rb')
    result = ''
    cluster_ips = []
    require 'bundler'
    log("Looking up ip for cluster: #{cluster_name}")
    args = ['-u', user, '-d', domain, '-p', conf['password'], '-s', conf['host'], '-c', cluster_name]
    result = ASM::Util.run_with_clean_env(cmd, false, *args)
    result.stdout.split("\n").reject{|l|l.empty? || l == "\r"}.drop(2).each do |line|
      cluster_ips << $1 if line.strip.match(/IPAddressToString\s+:\s+(\S+)/)
    end
    log("Found Ip: #{cluster_ips.to_s}")
    logger.debug("Cluster IP: #{cluster_ips[0]}")
    cluster_ips[0]
  end
  public :hyperv_cluster_ip?

  # NOTE: if this updates, also udpate Type::Server#post_install_config
  def get_post_installation_config(component, vm=nil, cluster_obj=nil)
    logger.debug("Configuring post-installation data for %s" % component["puppetCertName"])
    component_conf = ASM::PrivateUtil.build_component_configuration(component, :decrypt => decrypt?)

    if component_conf["asm::server"]
      server_param = component_conf["asm::server"].fetch(component["puppetCertName"], {})
      logger.debug("server param for %s is %s" % [component["puppetCertName"], server_param])
      logger.debug("Component information : %s" % component_conf) if server_param.empty?
      os_image_type = server_param["os_image_type"]
      logger.debug("OS Image type for %s is %s" % [component["puppetCertName"], os_image_type])
      if os_image_type.nil? || @supported_os_postinstall.include?(os_image_type)
        return {}
      end
    else
      return {} unless vm.vm_os_type
    end

    # Need to diferentiate between Windows and Linux based installations
    #conf = ASM::PrivateUtil.build_component_configuration(component, :decrypt => decrypt?)
    if component["type"] == "VIRTUALMACHINE"
      logger.debug("OS Image Type: %s" % vm.vm_os_type)
      if ( os_image_type || vm.vm_os_type).match(/windows/i)
        logger.debug("Windows Post installation for %s" % component["puppetCertName"])
        post_os = ASM::Processor::WindowsVMPostOS.new(self, component, vm, cluster_obj)
      else
        post_os = ASM::Processor::LinuxVMPostOS.new(self,component, vm)
      end
    elsif component["type"] == "SERVER"
      if os_image_type.match(/windows/i)
        post_os = ASM::Processor::WinPostOS.new(self,component)
      else
        post_os = ASM::Processor::LinuxPostOS.new(self,component)
      end
    end

    result = {}
    if defined? post_os.post_os_config
      result = post_os.post_os_config
    else
      if defined? post_os.post_os_classes
        result["classes"] = post_os.post_os_classes
      end
      if defined? post_os.post_os_resources
        result["resources"] = post_os.post_os_resources
      end
    end
    # We don't want to install services until after the vm is "deployed"
    # Switching network interfaces can cause the VM to reboot, which we want to avoid in the middle of an app install
    if vm.nil? || vm.is_a?(ASM::Resource::VM::Scvmm) || vm.is_vm_already_deployed(id, logger)
      post_os_config = post_os.post_os_services
      post_os_config.each do |k,v|
        result[k] ||= {}
        result[k].merge!(v)
      end
    end
    logger.debug("Post install params: %s" % result.to_s)
    result
  end

  # Server first in the acending order will have the flag as true
  def get_disk_part_flag(server_component)
    disk_part_flag = false
    server_cert_names = []
    cert_name = server_component['puppetCertName']
    components_by_type('SERVER').each do |component|
      server_cert_names.push(component['puppetCertName'])
    end
    server_cert_names.compact.uniq.sort
    if (server_cert_names.compact.uniq.sort[0] == cert_name)
      disk_part_flag = true
    end
    disk_part_flag
  end

  def get_netapp_ip()
    netappip = ''
    components_by_type('STORAGE').each do |storage_component|
      storage_cert_name = storage_component['puppetCertName']
      logger.debug"Storage cert name: #{storage_cert_name}"
      if (storage_cert_name.downcase.match(/netapp/) != nil)
        netappip = storage_cert_name.gsub(/^netapp-/,'')
        deviceconf ||= ASM::DeviceManagement.parse_device_config(storage_cert_name)
        netappip = deviceconf[:host]

        resources = ASM::Util.asm_json_array(storage_component['resources']) || []
        resources.each do |resource|
          parameters=ASM::Util.asm_json_array(resource['parameters']) || []
          logger.debug"Resource info #{resource.inspect}"
          parameters.each do |param|
            if param['id'] == "nfs_network"
              nfsip=param['value']
              netappip = nfsip if !(nfsip.nil? || nfsip.length == 0)
              break
            end
          end
        end
      end
    end
    netappip
  end

  def get_iscsi_fabric(server_component)
    iscsi_card = hyperv_iscsi_fabric(server_component)
    raise("ISCSI network is expected to be requested on 1 card. Got on #{iscsi_card.size}") if iscsi_card.size != 1
    "Fabric #{('A'..'Z').entries[iscsi_card.first.to_i]}"
  end
  public :get_iscsi_fabric

  def hyperv_iscsi_fabric(server_component)
    iscsi_interfaces = []
    network_config = build_network_config(server_component)
    network_config.cards.each do |card|
      card.interfaces.each do |interface|
        iscsi_networks = []
        interface.partitions.each do |partition|
          iscsi_networks = begin
            (partition.networkObjects || []).collect {
                |network| network if network.type == 'STORAGE_ISCSI_SAN'
            }
          end.flatten.uniq.compact
          iscsi_interfaces.push(card.card_index) unless iscsi_networks.empty?
        end
      end
    end
    logger.debug("ISCSI Interfaces: #{iscsi_interfaces}")
    iscsi_interfaces.compact.uniq
  end
  public :hyperv_iscsi_fabric

  def hyperv_iscsi_macs(server_component)
    network_config = build_network_config(server_component)
    end_point = ASM::DeviceManagement.parse_device_config(server_component['puppetCertName'])
    network_config.add_nics!(end_point)
    iscsi_macs = network_config.get_partitions('STORAGE_ISCSI_SAN').collect do |partition|
      partition.mac_address
    end.compact
  end
  public :hyperv_iscsi_macs

  def process_service_with_rules(service)
    require 'asm/service'
    processor = ASM::Service::Processor.new(service, nil, logger)
    processor.deployment = self
    processor.process_service
  end

  def is_server_bfs(component)
    bfs = false
    resource_hash = ASM::PrivateUtil.build_component_configuration(component, :decrypt => decrypt?)
    cert_name = component['puppetCertName']
    is_dell_server = ASM::Util.dell_cert?(cert_name)
    #Flag an iSCSI boot from san deployment
    if is_dell_server && resource_hash['asm::idrac']
      target_boot_device = resource_hash['asm::idrac'][resource_hash['asm::idrac'].keys[0]]['target_boot_device']
    else
      target_boot_device = nil
    end
    (is_dell_server and  (target_boot_device == 'iSCSI' or target_boot_device == 'FC')) ? bfs = true : bfs = false
    bfs
  end

  def cleanup_compellent(component,old_cert_name)
    server_cert_name = component['puppetCertName']
    logger.debug("Cert name: #{server_cert_name}")
    related_storage_components = find_related_components('STORAGE', component)
    server_fc_cleanup_hash = {}
    service_tag=ASM::Util.cert2serial(old_cert_name)
    boot_server_object="ASM_#{service_tag}"

    related_storage_components.each do |related_storage_component|
      compellent_cert_name = related_storage_component['puppetCertName']
      resource_hash = ASM::PrivateUtil.build_component_configuration(related_storage_component, :decrypt => decrypt?)
      if resource_hash['asm::volume::compellent']
        volume_name = resource_hash['asm::volume::compellent'].keys[0]
        params = resource_hash['asm::volume::compellent'][volume_name]
        server_fc_cleanup_hash['compellent::volume_map'] ||= {}
        server_fc_cleanup_hash['compellent::volume_map'][volume_name] ||= {}
        server_fc_cleanup_hash['compellent::volume_map'][volume_name] = {
          'ensure' => 'absent',
          'volumefolder' => params['volumefolder'],
          'force' => 'true',
          'servername' => boot_server_object,
        }
      end
      logger.debug("ASM FC Cleanup resource hash: #{server_fc_cleanup_hash}")
      if server_fc_cleanup_hash
        process_generic(
        compellent_cert_name,
        server_fc_cleanup_hash,
        'apply',
        true,
        nil,
        component['asmGUID']
        )
      end
    end
  end

  def enable_software_iscsi(endpoint)
    ASM::Util.esxcli(%w(iscsi software set --enabled=true), endpoint, logger)
  end

  def reconfigure_ha_for_clusters(certname, clusters)
    vim = get_vim_connection(certname)
    clusters.each do |path|
      dc = vim.serviceInstance.find_datacenter(path.split('/').first)
      dc.hostFolder.childEntity.each do |cluster|
        if cluster.name == path.split('/').last
          cluster.host.each do |host|
            host.ReconfigureHostForDAS_Task
          end
        end
      end
    end
    vim.close
    # we must wait for these tasks to finish
    sleep (300)
  end

  # Given a vCenter certname, obtain a VIM connection to talk to vSphere APIs
  def get_vim_connection(certname)
    conf = ASM::DeviceManagement.parse_device_config(certname)
    options = {
        :host => conf.host,
        :user => conf.user,
        :password => conf.password,
        :insecure => true,
    }
    logger.debug("Opening VIM connection for #{conf.host}...")
    RbVmomi::VIM.connect(options)
  end

  def vmware_iscsi_resource_hash(existing_resource_hash,
                                 storage_component, server_component,
                                 storage_network_vmk_index,
                                 storage_network_vmk_index_offset,
                                 storage_network_vswitch,
                                 serverdeviceconf,
                                 network_config,
                                 hostname,params,static,storage_network_require, vds_enabled=false)
    resource_hash = {}
    storage_cert = storage_component['puppetCertName']
    storage_asmguid = storage_component['asmGUID']
    server_cert = server_component['puppetCertName']
    server_params = get_asm_server_params(server_component)
    raise(ArgumentError, "Network not setup for #{server_cert}") unless storage_network_vmk_index
    iscsi_type = server_params["iscsi_initiator"]

    storage_hash = ASM::PrivateUtil.build_component_configuration(storage_component, :decrypt => decrypt?)
    storage_hash_component = (storage_hash['asm::volume::compellent'] ||
        storage_hash['asm::volume::equallogic'])

    logger.debug("Storage hash keys: #{storage_hash.keys}")
    if storage_hash.keys.include?('asm::volume::equallogic')
      storage_type = 'equallogic'
    else
      storage_type = 'compellent'
    end
    logger.debug("Storage Type: #{storage_type}")
    logger.debug("storage_hash_component: #{storage_hash_component}")

    esx_endpoint = get_esx_endpoint(server_component)
    # Configure iscsi datastore
    if @debug
      hba_list = %w(vmhba33 vmhba34)
      vmnics = {}
    else
      if !ASM::Util.dell_cert?(serverdeviceconf[:cert_name])
        logger.debug("Attempting to parse hbas without knowing iscsi_macs..")
        hba_list = parse_hbas(get_esx_endpoint(server_component), nil)
      elsif iscsi_type == "software"
        logger.debug("Attempting to parse hbas to get software iscsi adapter...")
        hba_list = parse_software_hbas(get_esx_endpoint(server_component))
      else
        iscsi_partitions = network_config.get_partitions('STORAGE_ISCSI_SAN')
        iscsi_macs = iscsi_partitions.collect { |p| p.mac_address }.compact
        if iscsi_macs.length < 2
          raise(ASM::UserException, t(:ASM012, "Two iSCSI NICs are required but configuration contains %{count}", :count => iscsi_macs.length))
        elsif iscsi_macs.length > 2
          logger.warn("More than two iSCSI NICs specified; only the first two will be configured")
        end
        logger.debug("Attempting to parse hbas with a list of iscsi_macs..")
        hba_list = parse_hbas(esx_endpoint, iscsi_macs)
      end
    end
    # iSCSI Advanced configurations
    # Advanced Setting -
    # Using common for EqualLogic and Compellent
    resource_hash['esx_advanced_options'] ||= {}
    resource_hash['esx_advanced_options'][hostname] ||= {}
    resource_hash['esx_advanced_options'][hostname] = {
        'options' => {
            'Net.TcpipDefLROEnabled' => 0
        },
        'transport' => "Transport[vcenter]",
        'require' =>  "Asm::Host[#{server_cert}]"
    }

    # iSCSI Adapter settings
    hba_list.each do |hba|
      resource_hash['esx_iscsi_options'] ||= {}
      resource_hash['esx_iscsi_options']["#{hostname}:#{hba}"] ||= {}
      resource_hash['esx_iscsi_options']["#{hostname}:#{hba}"] = {
          'options' => {
              "LoginTimeout" => 60,
              "DelayedAck" => false
          },
          'transport' => "Transport[vcenter]",
          'require' => "Asm::Host[#{server_cert}]"
      }
    end

    storage_hash_component.each do |storage_title, storage_params|
      #storage_titles.push storage_title
      # WARNING: have to use IP instead of hostname for the datastore parameters because
      # internally the vmware iscsi_initiator_binding makes direct esxcli calls to
      # the esxi host and we are not guaranteed that the ASM appliance can resolve
      # the hostname.
      target_ips = []
      if storage_type == 'equallogic'
        target_ip = ASM::PrivateUtil.find_equallogic_iscsi_ip(storage_asmguid)
        target_ips.push(target_ip)
      elsif storage_type == 'compellent'
        target_ips = ASM::PrivateUtil.find_compellent_iscsi_ip(storage_asmguid,logger)
      else
        raise("Non supported storage type #{storage_type}")
      end

      target_ips.each_with_index do |target_ip, ti_index|
        asm_datastore = {
            'data_center' => params['datacenter'],
            'cluster' => params['cluster'],
            'datastore' => storage_title,
            'ensure' => 'present',
            'esxhost' => static['ipAddress'],
            'esxusername' => 'root',
            'esxpassword' => server_params['admin_password'],
            'hba_titles' => hba_list.collect { |hba| "#{static['ipAddress']}:#{hba}:#{storage_title}_#{target_ip}" },
            'hba_hash' => hba_list.each_with_index.inject({}) do |hbash, (hba,i)|
              name = "#{static['ipAddress']}:#{hba}:#{storage_title}_#{target_ip}"
              hbash[name] = {}
              hbash[name]['vmhba'] = hba_list[i]
              hbash[name]['vmknics'] = "vmk#{storage_network_vmk_index + storage_network_vmk_index_offset + i}"
              hbash
            end,
            'iscsi_target_ip' => target_ip,
            'decrypt' => decrypt?,
            'require' => storage_network_require,
        }
        if iscsi_type == "software"
          asm_datastore["software_iscsi"] = true
        end
        # We are not using IQN auth? Then add chapname and chapsecret
        if storage_params.has_key? 'chap_user_name' and not storage_params['chap_user_name'].empty?
          chap = {
              'chapname' => storage_params['chap_user_name'],
              'chapsecret' => storage_params['passwd']}
          asm_datastore.merge! chap
        end
        resource_hash['asm::datastore'] ||= {}
        resource_hash['asm::datastore']["#{hostname}:#{storage_title}:datastore_#{target_ip}"] = asm_datastore
      end

      if storage_type == 'equallogic'
        # HACK: process_generic kicks off asynchronous device
        # re-inventory through the java REST services. We expect that
        # would be complete by the time we get here. BUT, java side
        # uses asmGUID as the puppet certificate name, so we have to
        # use that here.
        if @debug
          target_iqn = "DEBUG-IQN-#{storage_title}"
        else
          target_iqn = ASM::PrivateUtil.get_eql_volume_iqn(storage_component['asmGUID'], storage_title)
        end

        raise("Unable to find the IQN for volume #{storage_title}") if target_iqn.length == 0

        resource_hash['esx_datastore'] ||= {}
        resource_hash['esx_datastore']["#{hostname}:#{storage_title}"] ={
            'ensure' => 'present',
            'datastore' => storage_title,
            'type' => 'vmfs',
            'target_iqn' => target_iqn,
            'require' => "Asm::Datastore[#{hostname}:#{storage_title}:datastore_#{target_ip}]",
            'transport' => 'Transport[vcenter]'
        }

        # Esx_mem configuration is below
        install_mem = ASM::Util.to_boolean(server_params['esx_mem'])
        if install_mem
          razor_image = server_params['razor_image']
          if razor_image == "esxi-5.1"
            # For bw compat with esx 5.1
            logger.debug('Using setup_1.1.pl for install of esx_mem')
            setup_script_filepath = 'setup_1.1.pl'
          else
            # otherwise the latest
            logger.debug('Using setup.pl for install of esx_mem')
            setup_script_filepath = 'setup.pl'
          end

          if existing_resource_hash['esx_vswitch']["#{storage_network_vswitch}"]
            vnics = existing_resource_hash['esx_vswitch']["#{storage_network_vswitch}"]['nics'].map do|n|
              n.strip
            end

            vnics_ipaddress = ['ISCSI0', 'ISCSI1'].map do |port|
              existing_resource_hash['esx_portgroup']["#{hostname}:#{port}"]['ipaddress'].strip
            end

            vnics_ipaddress = vnics_ipaddress.join(',')
            vnics = vnics.join(',')

            vinfo = gather_vswitch_info(network_config)
            iscsi_network_team = vinfo.find { |team| team[:storage] }
            iscsi_network = iscsi_network_team && iscsi_network_team[:storage][:networks].first
            unless iscsi_network && iscsi_network['staticNetworkConfiguration']
              raise("iSCSI Storage network required for esx_mem deployment; found #{vinfo}")
            end


            logger.debug "Server params: #{server_params}"
            esx_mem = {
                'require'                => [
                    "Esx_datastore[#{hostname}:#{storage_title}]",
                    "Esx_syslog[#{hostname}]"],
                'install_mem'            => true,
                'script_executable_path' => '/opt/Dell/scripts/EquallogicMEM',
                'setup_script_filepath'  => setup_script_filepath,
                'host_username'          => ESXI_ADMIN_USER,
                'host_password'          => server_params['admin_password'],
                'transport'              => "Transport[vcenter]",
                'storage_groupip'        => ASM::PrivateUtil.find_equallogic_iscsi_ip(storage_cert),
                'iscsi_netmask'          => iscsi_network['staticNetworkConfiguration']['subnet'],
                'iscsi_vswitch'          => storage_network_vswitch,
                'vnics'                  => vnics,
                'vnics_ipaddress'        => vnics_ipaddress
            }
          else
            esx_mem = {
                'require'                => [
                    "Esx_datastore[#{hostname}:#{storage_title}]",
                    "Esx_syslog[#{hostname}]"],
                'install_mem'            => true,
                'script_executable_path' => '/opt/Dell/scripts/EquallogicMEM',
                'setup_script_filepath'  => setup_script_filepath,
                'host_username'          => ESXI_ADMIN_USER,
                'host_password'          => server_params['admin_password'],
                'transport'              => "Transport[vcenter]",
            }

          end
          resource_hash['esx_mem'] ||= {}
          resource_hash['esx_mem'][hostname] = esx_mem
        else # We will set up round robin pathing here
          resource_hash['esx_iscsi_multiple_path_config'] ||= {}
          resource_hash['esx_iscsi_multiple_path_config'][hostname] = {
              'ensure'        => 'present',
              'host'          => hostname,
              'policyname'    => 'VMW_PSP_RR',
              'path'          => "/#{params['datacenter']}/#{params['cluster']}",
              'transport'     => 'Transport[vcenter]',
              'require'       => "Esx_datastore[#{hostname}:#{storage_title}]"
          }
        end
      end
    end
    resource_hash
  end

  def refresh_hyperv_storages(cluster_component,logger)
    server_components = find_related_components('SERVER',cluster_component)
    threads = []
    exceptions = []
    server_components.each do |server_component|
      threads << ASM.execute_async(logger) do
        begin
          refresh_hyperv_storage(cluster_component, server_component, logger)
          logger.debug("Refresh hyperv storage completed for #{server_component['puppetCertName']}")
        rescue => e
          logger.error("Storage refresh failed for #{server_component['puppetCertName']}: #{e.backtrace}")
          exceptions.push(e)
        end
      end
    end

    # wait for all the threads to complete
    threads.each { |thr| thr.join }
    logger.debug('Adding a sleep for a minute after initiating the refresh')
    sleep(120) if exceptions.empty?
    raise exceptions.first unless exceptions.empty?
  end

  def hyperv_nic_team_macs(server_component)
    network_config = build_network_config(server_component)
    end_point = ASM::DeviceManagement.parse_device_config(server_component['puppetCertName'])
    network_config.add_nics!(end_point)
    mac_address = network_config.get_partitions('HYPERVISOR_MANAGEMENT').collect do |partition|
      partition.mac_address
    end.compact
  end

  def is_hyperv_iscsi?(server_component)
    !hyperv_iscsi_macs(server_component).nil?
  end

  def is_converged_hyperv_config?(server_component)
    ( hyperv_iscsi_macs(server_component) || []).sort == hyperv_nic_team_macs(server_component).sort
  end

  def refresh_hyperv_storage(cluster_component, server_component, logger)
    # Sequence of operations
    # Initiate the storage rescan
    # For one of the host, configure the storage
    # - Bring it online
    # - Initiate the diskpart of the script
    cert_name = cluster_component['puppetCertName']
    server_params = get_asm_server_params(server_component)
    hyperv_host_name = "#{server_params['os_host_name']}.#{server_params['fqdn']}"
    domain_username = "#{server_params['domain_name']}\\#{server_params['domain_admin_user']}"

    base_resources = {"transport" => {}}
    base_resources["transport"]["winrm"] =
        {"server" => hyperv_host_name,
         "username" => domain_username,
         "options" =>
             {"crypt_string" => server_params['domain_admin_password']}}
    base_resources['transport']['winrm']['provider'] = 'asm_decrypt' if decrypt?

    server_resource = {}
    iscsi_target_ip = get_iscsi_target_ip(server_component)

    if iscsi_target_ip.nil? || iscsi_target_ip.empty?
      logger.debug('HyperV FC Compellent deployment ')
      server_resource['exec'] = {}
      server_resource['exec'][hyperv_host_name] =
          {"command"        => "\"Rescan\"|diskpart",
          'logoutput'       => "on_failure",
          'provider'        => 'winrm',
          'transport'       => "Transport[winrm]",
      }

      # Formating of the disk needs to be initiated only for a single server in the deployment
      if get_disk_part_flag(server_component)
        server_resource['format_storage'] = {}
        server_resource['format_storage'][hyperv_host_name] =
            {"ensure"      => 'present',
             'transport'   => "Transport[winrm]",
             'require' => "Exec[#{hyperv_host_name}]"
            }
        server_resource["format_storage"][hyperv_host_name]['provider'] = 'asm_decrypt' if decrypt?
      end
    else
      # Must be done in the host OS configuration, but to make sure initiator is configured correctly
      # Associate iSCSI targets to the iSCSI initiator ports
      server_resource['iscsi_target_portal'] = {}
      server_resource['iscsi_target_portal'][hyperv_host_name] =
          {"ensure" => 'present',
           'target_portal_address' => iscsi_target_ip,
           "transport" => "Transport[winrm]",
          }
      server_resource["iscsi_target_portal"][hyperv_host_name]['provider'] = 'asm_decrypt' if decrypt?

      # Connect the iSCSI Targets
      server_resource['iscsi_target'] = {}
      server_resource['iscsi_target'][hyperv_host_name] =
          {"ensure" => 'connected',
           'is_persistent'         => '$true',
           'is_multipath_enabled'  => '$true',
           'target_portal_address' => iscsi_target_ip,
           'transport'             => "Transport[winrm]",
           'require'               => "Iscsi_target_portal[#{hyperv_host_name}]"
          }
      server_resource["iscsi_target"][hyperv_host_name]['provider'] = 'asm_decrypt' if decrypt?

      # For EqualLogic we need to specify the pattern for the volumes that needs to be connected
      storage_match_pattern = get_storage_match_pattern(server_component)
      server_resource["iscsi_target"][hyperv_host_name]['storage_match_pattern'] = storage_match_pattern unless storage_match_pattern.empty?

      # Formating of the disk needs to be initiated only for a single server in the deployment
      if get_disk_part_flag(server_component)
        server_resource['format_storage'] = {}
        server_resource['format_storage'][hyperv_host_name] =
            {"ensure"      => 'present',
             'transport'   => "Transport[winrm]",
             'require' => "Iscsi_target[#{hyperv_host_name}]"
            }
        server_resource["format_storage"][hyperv_host_name]['provider'] = 'asm_decrypt' if decrypt?
      end

    end

    server_resource.merge!(base_resources)

    process_generic(cert_name, server_resource, 'apply')
  end

  def get_iscsi_target_ip(server_component)
    target_ip = ''
    storage_components = find_related_components('STORAGE',server_component)
    storage_certs = []
    storage_components.each do |storage_component|
      storage_certs.push(storage_component['asmGUID'])
    end
    storage_cert = storage_certs[0]

    storage_type = 'iscsi'
    storage_cert.match(/equallogic/) ? storage_model = 'equallogic' : storage_model = 'compellent'
    if storage_model == 'compellent'
      storage_type = compellent_component_port_type(storage_components[0])
    end

    logger.debug ("Storage_Type: #{storage_type}, Storage_Model: #{storage_model}")
    if storage_model == 'equallogic'
      target_ip = ASM::PrivateUtil.find_equallogic_iscsi_ip(storage_cert)
    elsif storage_type == 'iscsi' && storage_model == 'compellent'
      target_ip = ASM::PrivateUtil.find_compellent_iscsi_ip(storage_cert,logger).join(',')
    end
    logger.debug("iSCSI Target IP Address: #{target_ip}")
    target_ip
  end
  public :get_iscsi_target_ip

  def get_storage_match_pattern(server_component)
    storage_components = find_related_components('STORAGE',server_component)
    storage_certs = []
    storage_volumes = []
    storage_components.each do |storage_component|
      next if !storage_component['asmGUID'].match(/equallogic/)
      storage_certs.push(storage_component['asmGUID'])
      ASM::Util.asm_json_array(storage_component['resources']).each do |r|
        r['parameters'].each do |param|
          if param['id'] == 'title'
            storage_volumes.push(param['value'])
          end
        end
      end
    end
    storage_volumes.empty? ? '' : storage_volumes.join('|')
  end

  def compellent_iscsi_ipaddress(server_component)
    storage_components = find_related_components('STORAGE',server_component)
    storage_certs = []
    storage_components.each do |storage_component|
      storage_certs.push(storage_component['asmGUID'])
    end
    (ASM::PrivateUtil.find_compellent_iscsi_ip(storage_certs.uniq.first,logger) || []).join(',').to_s
  end

end

class Hash
   def keep_merge(hash)
      target = dup
      hash.keys.each do |key|
         if hash[key].is_a? Hash and self[key].is_a? Hash
            target[key] = target[key].keep_merge(hash[key])
            next
         end
         #target[key] = hash[key]
         target.update(hash) { |key, *values| values.flatten.uniq }
      end
      target
   end

   def deep_merge(second)
     merger = proc { |key, v1, v2| Hash === v1 && Hash === v2 ? v1.merge(v2, &merger) : v2 }
     self.merge(second, &merger)
   end
end

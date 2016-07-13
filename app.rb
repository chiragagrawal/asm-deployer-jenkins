require 'sinatra'
require 'json'
require 'logger'
require 'asm'
require 'asm/data/deployment'
require 'asm/service_deployment'
require 'asm/device_management'
require 'asm/appliance_setup/dhcp'
require 'asm/errors'
require 'asm/monitoring'

class ASM::App < Sinatra::Base

  configure do
    set :bind, '0.0.0.0'
    # only allow a single request to be processed at a time
    set :lock, true

    ASM.init
    if ASM.database
      # Since we have just started there can be no in-progress deployments.
      # This is optional because worker nodes won't have a db
      ASM::Data::Deployment.mark_in_progress_failed(ASM.database, ASM.logger)
    end
    ASM.logger.info('ASM deployment service initialized')
  end

  # Initiate migration of server
  post '/process_service_profile_migration' do
    content_type :json
    ASM.process_deployment_migration(request).to_json
  end

  get '/puppetreport/:id/:certname' do |id, certname|
    content_type :json
    report = ASM::PrivateUtil.get_report(id, certname)
    report.to_json
  end

  get '/puppetlog/:id/:certname' do |id, certname|
    content_type :json
    log = ASM::PrivateUtil.get_puppet_log(id, certname)
    log.to_json
  end

  get '/status' do
    content_type :json

    status = {"active_deployments" => ASM.active_deployments,
              "running_certnames" => ASM.running_certnames,
              "large_process_count" => ASM.get_counter(:large_child_procs)}

    status.to_json
  end

  # Execute deployment
  post '/deployment' do
    content_type :json
    ASM.process_deployment_request(request).to_json
  end

  get '/deployment/:id/status' do |id|
    begin
      content_type :json
      ASM.get_deployment_status(id).to_json
    rescue ASM::NotFoundException
      status 404
    end
  end

  get '/deployment/:id/log' do |id|
    begin
      content_type :json
      ASM.get_deployment_log(id).to_json
    rescue ASM::NotFoundException
      status 404
    end
  end

  get '/deployment/:id/puppet_logs/:certname' do |id,certname|
    begin
      content_type :json
      ASM::PrivateUtil.get_puppet_component_run(id,certname)
    rescue Errno::ENOENT
      status 404
    end
  end

  put '/deployment/:id' do |id|
    begin
      content_type :json
      ASM.retry_deployment(id, JSON.parse(request.body.read)).to_json
    rescue ASM::NotFoundException
      status 404
    end
  end

  delete '/deployment/:id' do | id |
    begin
      ASM.clean_deployment(id)
    rescue ASM::NotFoundException
      status 404
    end
  end

  delete '/device/:cert_name' do |cert_name|
    ASM.execute_async(ASM.logger) do
      ASM::DeviceManagement.remove_device(cert_name)
    end
  end

  post '/device' do
    content_type :json

    device = JSON.parse(request.body.read)

    begin
      ASM::DeviceManagement.write_device_config(device)
      ASM::DeviceManagement.run_puppet_device_async!(device["cert_name"], ASM.logger)
      status 202
      ASM::DeviceManagement.get_device(device["cert_name"]).to_json
    rescue ASM::DeviceManagement::DuplicateDevice, ASM::DeviceManagement::FactRetrieveError
      status 409
    end
  end

  get '/device/:cert_name' do |cert_name|
    content_type :json

    begin
      ASM::DeviceManagement.get_device(cert_name).to_json
    rescue ASM::NotFoundException
      status 404
    end
  end

  get '/metrics/:ref_id/?:from?/?:units?' do |ref_id, from, units|
    begin
      content_type :json
      required = (params[:required] || '').split(',')
      ASM.get_metrics(ref_id, from, units, required)
    rescue ASM::NotFoundException
      status 404
    end
  end

  put '/device/:cert_name' do |cert_name|
    content_type :json

    device = JSON.parse(request.body.read)
    ASM::DeviceManagement.write_device_config!(device)
    ASM::DeviceManagement.run_puppet_device_async!(device["cert_name"], ASM.logger)
    status 202
    ASM::DeviceManagement.get_device(cert_name).to_json
  end

  put '/dhcp' do
    result = ASM.process_dhcp_request(request)
    status result['status']
    result.to_json
  end

  put '/nagios/:action' do |action|
    case action
      when 'process_monitoring_data'
        ASM.process_monitoring_data(request)
        status 200
      when 'get_inventory','get_chassis','idrac_eight_inventory'
        result = ASM.nagios_export(action, request)
        status 200
        result.to_a.to_json
      else
        status 404
    end
  end

  put '/graphite/submit_metrics' do
    begin
      result = ASM.submit_graphite_metrics(request)
      raise ASM::GraphiteException unless result
      status 200
      result.to_json
    rescue ASM::GraphiteException
      status 400
    end
  end

  get '/secret/api/auth' do
    content_type :json
    ASM.secrets.api_auth.to_json
  end

  get '/secret/device/:cert_name' do |cert_name|
    begin
      content_type :json
      conf = ASM.secrets.device_config(cert_name)
      raise ASM::NotFoundException unless conf
      conf.to_json
    rescue ASM::NotFoundException
      status 404
    end
  end

  get '/secret/string/:id' do |id|
    begin
      content_type :json
      ASM.secrets.decrypt_string(id)
    rescue ASM::NotFoundException
      status 404
    end
  end

  get '/secret/credential/:id' do |id|
    begin
      content_type :json
      ASM.secrets.decrypt_credential(id).to_json
    rescue ASM::NotFoundException
      status 404
    end
  end

  get '/secret/tokencred/:id' do |id|
    begin
      content_type :json
      ASM.secrets.decrypt_token(id, request)
    rescue ASM::NotFoundException
      status 404
    end
  end

  # Not a general purpose API, only for testing synchronous queueing is working.
  # /queue/test is configured to echo back the payload with information on the
  # node where it is run.
  post '/queue/:id' do |id|
    content_type :json
    payload = request.body.read
    request = JSON.parse(payload).inject({}){|h, (k, v)| h[k.to_sym] = v; h} || {}
    queue = TorqueBox.fetch("/queues/#{id}")
    props = request.delete(:properties) || {}
    timeout = request.delete(:timeout) || 60 * 1000
    response = queue.publish_and_receive(request, :properties => props, :timeout => timeout)
    response.to_json
  end

  #portview - this REST call gets the server info we need for PortView in a json
  get '/deployment/:id/server/:server_puppet_certname' do |id, server_puppet_certname|
    server_puppet_certname.downcase!
    unless server_puppet_certname.include?("..")
      begin
        content_type :json
        ASM.get_server_info(id, server_puppet_certname).to_json
      rescue ASM::NotFoundException
        status 404
      end
    end
  end
end

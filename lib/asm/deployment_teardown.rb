require 'json'
require 'asm/private_util'

module ASM
  module DeploymentTeardown

    def self.clean_deployment(id)
      data = deployment_data(id)
      names = self.get_deployment_certs(data)
      if names !=[]
        ASM.unblock_hostlist(names)
        current_certs = ASM::PrivateUtil.get_puppet_certs
        names.each do |cert_name|
          begin
            ASM::DeviceManagement.remove_device(cert_name, current_certs)
          rescue => e
            logger.warn("Certificate cleanup for #{cert_name} failed: #{e}")
          end
        end
      end
    end

    def self.clean_deployment_certs(certs)
      certs_string = certs.join(' ')
      ASM.wait_on_counter_threshold(ASM::PrivateUtil.large_process_concurrency, ASM::PrivateUtil.large_process_max_runtime, :large_child_procs) do
        ASM::Util.run_command_success("sudo puppet cert clean #{certs_string}")
      end
    end

    def self.clean_puppetdb_nodes(names)
      names_string = names.join(' ')
      ASM.wait_on_counter_threshold(ASM::PrivateUtil.large_process_concurrency, ASM::PrivateUtil.large_process_max_runtime, :large_child_procs) do
        ASM::Util.run_command_success("sudo puppet node deactivate #{names_string}")
      end
    end

    def self.get_deployment_certs(data)
      agentless_image_types = ['vmware_esxi']
      cert_list = []
      comps = (data['serviceTemplate'] || {})['components'] || []
      ASM::Util.asm_json_array(comps).each do |c|
        if c['type'] == 'SERVER' or c['type'] == "VIRTUALMACHINE"
          ASM::Util.asm_json_array(c['resources'] || {}).each do |r|
            if r['id'] == 'asm::server'
              os_host_name = nil
              agent = true
              r['parameters'].each do |param|
                if param['id'] == 'os_host_name'
                  os_host_name = param['value'] if param['id'] == 'os_host_name'
                end
                if param['id'] == 'os_image_type'
                  if agentless_image_types.include?(param['value'])
                    agent = false
                  end
                end
              end
              cert_list.push(ASM::Util.hostname_to_certname(os_host_name)) if os_host_name and agent
            end
          end
        end
      end
      cert_list
    end

    def self.get_previous_deployment_certs(deployment_id)
      old_certs = []
      previous_dirs = Dir.entries(File.join(ASM.base_dir, deployment_id)).select{ |dir| dir.match(/^[0-9]+$/) }
      previous_dirs.each do |pd|
        old_deployment = deployment_data("#{deployment_id}/#{pd}")
        old_certs << get_deployment_certs(old_deployment)
      end
      old_certs.flatten.uniq
    end

    def self.deployment_data(id)
      file_name = File.join(ASM.base_dir, id.to_s, 'deployment.json')
      JSON.parse(File.read(file_name))
    end

    def self.logger
      @logger ||= ASM.logger
    end

  end
end

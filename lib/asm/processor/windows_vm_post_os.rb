require "asm/private_util"
require "asm/network_configuration"

module ASM
  module Processor
    class WindowsVMPostOS < ASM::Processor::WinPostOS

      def initialize(service_deployment, component, vm_resource_obj, cluster_obj)
        @vm_component = component
        @vm_config = ASM::PrivateUtil.build_component_configuration(component, :decrypt => service_deployment.decrypt?)
        @vm_cert = @vm_component["puppetCertName"]
        @vm_params = vm_params
        @vm = vm_resource_obj
        @cluster_obj = cluster_obj
        super(service_deployment,component)
      end

      def vm_params
        @vm_params ||= begin
          if @vm_config["asm::vm::vcenter"]
            (@vm_config["asm::vm::vcenter"] || {})[@vm_cert]
          elsif @vm_config["asm::vm::scvmm"]
            (@vm_config["asm::vm::scvmm"] || {})[@vm_cert]
          end
        end
      end

      def post_os_resources
       appliance_ip =  host_ip_config(vm_networks)
       {"host" => {"dellasm" => {"ensure" => "present", "ip" => appliance_ip}}}
      end

      def vm_networks
        logger.debug("VM Network info for puppet cert #{@vm_component['puppetCertName']} : #{@vm_params}")
        logger.debug("VM Config: #{@vm_config}")
        logger.debug("VM Cert: #{@vm_cert}")
        @networks = @vm_params["network_interfaces"] || {}
      end

      def default_gateway_network
        @vm_params.fetch("default_gateway", "")
      end

      def asm_server
        @asm_server ||= begin
          (@vm_config["asm::server"] || {}).fetch(@vm_component["puppetCertName"], {})
        end
      end

      def component_cert_name
        @vm.certname
      end

      def post_os_classes(puppet_hash={})
        # NIC IP Configuration
        puppet_hash = puppet_hash.merge(nic_ip_config(puppet_hash))
        logger.debug("Puppet hash after NIC IP Configuration: #{puppet_hash}")

        # Domain Configuration
        logger.debug("Puppet hash before domain config: #{puppet_hash}")
        puppet_hash = puppet_hash.merge(domain_config(puppet_hash))
        logger.debug("Domain Config: #{puppet_hash}")

        puppet_hash
      end

      def nic_ip_config(puppet_hash)
        adapter_ip_info = []
        non_team_nic_ip_hash = {}
        vm_networks.each do |workload_network|
          hash_network = Hashie::Mash.new(workload_network)
          logger.debug("VM Network workload network: #{hash_network}")
          vm_mac_address = @vm.vm_net_mac_address(hash_network, @cluster_obj)
          adapter_ip_info.push(network_ip_info(hash_network,
                                               hash_network.name ,
                                               vm_mac_address.gsub(/:/, "-"),
                                               @vm))
        end
        logger.debug("Network adapter info #{adapter_ip_info}")
        unless adapter_ip_info.empty?
          adapter_ip_info = adapter_ip_info.join(";") if windows_2008?
          non_team_nic_ip_hash["windows_postinstall::nic::adapter_nic_ip_settings"] = {}
          non_team_nic_ip_hash["windows_postinstall::nic::adapter_nic_ip_settings"] = {
              "ipaddress_info" => {"NICIPInfo" => adapter_ip_info}
          }
          unless puppet_hash.keys.empty?
            non_team_nic_ip_hash["windows_postinstall::nic::adapter_nic_ip_settings"]["require"] = capitalize(puppet_hash.keys)
          end
        end
        puppet_hash.merge(non_team_nic_ip_hash)
      end

      def windows_2008?
        logger.debug("Checking for Windows 2008 for Windows VM")
        unless os_image_version.empty?
          logger.debug("OS Image version #{os_image_version}")
          os_image_version.match(/2008/)
        else
          logger.debug("OS Image version not available. Check vm os type using native API #{@vm.vm_os_type}")
          @vm.vm_os_type.match(/windows7|2008/i)
        end
      end

      def os_image_version
        logger.debug("asm server info: #{asm_server}")
        asm_server["os_image_version"] || ""
      end

    end
  end
end

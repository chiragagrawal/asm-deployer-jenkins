require "asm/private_util"
require "asm/network_configuration"
require "asm/processor/linux_post_os"

module ASM
  module Processor
    class LinuxVMPostOS < ASM::Processor::LinuxPostOS
      def initialize(service_deployment, component, vm)
        @vm_component = component
        @sd = service_deployment
        @vm_config = ASM::PrivateUtil.build_component_configuration(component, :decrypt => service_deployment.decrypt?)
        @vm_cert = @vm_component["puppetCertName"]
        @vm_params = vm_params
        @vm = vm
        super(service_deployment, component)
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

      def vm_networks
        @networks = @vm_params["network_interfaces"] || {}
      end

      def logger
        @sd.logger
      end

      def default_gateway_network
        @vm_params.fetch("default_gateway", "")
      end

      def default_gateway_network_config
        logger.debug("Looking for network by the id, #{default_gateway_network}")
        def_network = vm_networks.find {|network| network["id"] == default_gateway_network}
        if def_network
          if supported_suse?(os)
            {"network::suse_routes" => {
              "gateway" => def_network["staticNetworkConfiguration"]["gateway"],
              "netmask" => def_network["staticNetworkConfiguration"]["subnet"]
            }}
          else
            {"network::global" => {"gateway" => def_network["staticNetworkConfiguration"]["gateway"]}}
          end
        else
          {}
        end
      end

      def post_os_config(puppet_hash={})
        logger.debug("Setting the default gateway if requested")
        puppet_hash["classes"] ||= {}
        puppet_hash["classes"].merge!(default_gateway_network_config)
        logger.debug("Starting to process puppet resources for VM static NIC")
        process_network_config(puppet_hash)
        unless puppet_hash["resources"].empty? && puppet_hash["classes"].empty?
          appliance_ip = host_ip_config(vm_networks)
          puppet_hash["resources"]["host"] = {"dellasm" => {"ensure" => "present", "ip" => appliance_ip}}
        end
        logger.debug("Linux Post OS puppet config: #{puppet_hash}")

        puppet_hash
      end

      def process_network_config(puppet_hash={})
        net_config = {}
        seq = 0

        # @vm resource object should have had process! called on it.
        # If vm hasn't been fully deployed yet, we still need 1 extra interface
        # to account for the PXE network. We need to have both interfaces up and
        # running at the same time so we can switch host file entry without
        # breaking the vm's networking
        unless @vm.is_vm_already_deployed(@sd.id)
          if supported_suse?(os)
            net_config["network::if::suse_dynamic"] ||= {}
            net_config["network::if::suse_dynamic"][seq] = {
              "ensure" => "up"
            }
          else
            net_config["network::if::dynamic"] ||= {}
            net_config["network::if::dynamic"][seq] = {
              "ensure" => "up"
            }
          end
          seq += 1
        end
        vm_networks.each do |network|
          logger.debug("Processing network, #{network}, into puppet config")
          if ("suse11" || "suse12").match(os)
            process_suse_network_config(net_config, network, puppet_hash, seq)
          else
            process_rhel_network_config(net_config, network, seq)
          end

          # the seq still has to be incremented to preserve the order of network interfaces on the VM
          seq += 1
        end
        puppet_hash["resources"] = net_config

        puppet_hash
      end

      def process_rhel_network_config(net_config, network, seq)
        if network["static"]
          net_config["network::if::static"] ||= {}
          net_config["network::if::static"][seq] = {
            "ensure" => "up",
            "ipaddress" => network["staticNetworkConfiguration"]["ipAddress"],
            "netmask" => network["staticNetworkConfiguration"]["subnet"],
            "gateway" => (network["staticNetworkConfiguration"]["gateway"] || ""),
            "domain" => (network["staticNetworkConfiguration"]["dnsSuffix"] || ""),
            "defroute" => "no"
          }
          if network["id"] == default_gateway_network
            net_config["network::if::static"][seq]["defroute"] = "yes"
          end
        else
          net_config["network::if::dynamic"] ||= {}
          net_config["network::if::dynamic"][seq] = {
            "ensure" => "up"
          }
        end
      end

      def process_suse_network_config(net_config, network, puppet_hash, seq)
        if network["static"]
          net_config["network::if::suse_static"] ||= {}
          net_config["network::if::suse_static"][seq] = {
            "ensure" => "up",
            "ipaddress" => network["staticNetworkConfiguration"]["ipAddress"],
            "netmask" => network["staticNetworkConfiguration"]["subnet"],
            "gateway" => (network["staticNetworkConfiguration"]["gateway"] || ""),
            "domain" => (network["staticNetworkConfiguration"]["dnsSuffix"] || "")
          }
          if network["id"] == default_gateway_network && puppet_hash["classes"]["network::suse_routes"]
            puppet_hash["classes"]["network::suse_routes"]["device"] = seq
          end
        else
          net_config["network::if::suse_dynamic"] ||= {}
          net_config["network::if::suse_dynamic"][seq] = {
            "ensure" => "up"
          }
        end
      end
    end
  end
end
# linux_vm_post_os.rb

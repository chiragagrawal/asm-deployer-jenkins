require "asm/private_util"
require "asm/network_configuration"
require "asm/processor/post_os"

module ASM
  module Processor
    class WinPostOS < ASM::Processor::PostOS

      include ASM::Translatable

      def post_os_classes(puppet_hash={})
        # NIC TEAM Configuration
        puppet_hash = puppet_hash.merge(nic_team_config(puppet_hash))
        logger.debug("NIC TEAM CONFIG: #{puppet_hash}")

        # NIC IP Configuration
        puppet_hash = puppet_hash.merge(nic_ip_config(puppet_hash))
        logger.debug("Puppet hash after NIC IP Configuration: #{puppet_hash}")

        # Domain Configuration
        logger.debug("Puppet hash before domain config: #{puppet_hash}")
        puppet_hash = puppet_hash.merge(domain_config(puppet_hash))
        logger.debug("Domain Config: #{puppet_hash}")

        puppet_hash
      end

      def post_os_resources
        all_networks = workload_networks.map {|networks, member| networks }.flatten
        appliance_ip = host_ip_config(all_networks)
        {"host" => {"dellasm" => {"ensure" => "present", "ip" => appliance_ip}}}
      end

      def domain_password
        if @sd.decrypt?
          "ASMCRED-#{asm_server["domain_admin_password"]}"
        else
          asm_server["domain_admin_password"]
        end
      end

      def domain_password_token
        token_string = domain_password
        token_data = ASM::Cipher.create_token(token_string)
        ASM::PrivateUtil.create_serverdata(component_cert_name, token_data.to_json)
        token_data['token']
      end

      def component_cert_name
        ASM::Util.hostname_to_certname(os_host_name)
      end

      def os_host_name
        asm_server["os_host_name"]
      end

      def domain_config(puppet_hash={})
        return {} if asm_server["domain_name"].nil? || asm_server["domain_name"].empty?
        logger.debug("Inside domain config when domain name is not null")
        domain_hash = {
          "windows_postinstall::domain::domain_config" => {
            "domainfqdd" => asm_server["domain_name"],
            "domainname" => domain_name(asm_server["domain_name"]),
            "username" => asm_server["domain_admin_user"],
            "password" => domain_password_token
          }
        }
        unless puppet_hash.empty?
          domain_hash["windows_postinstall::domain::domain_config"]["require"] = capitalize(puppet_hash.keys)
        end
        logger.debug("Returning domain hash : #{domain_hash}")
        domain_hash
      end

      def domain_name(domain_fqdd)
        domain_fqdd.split(".").first
      end

      def nic_team_config(puppet_hash={})
        return {} if workload_networks.empty?
        nic_team_info = []

        logger.debug("Workload networks: #{workload_networks}")
        workload_networks.each do |workload_network, members|
          logger.debug("Network: #{workload_network} , members: #{members}")
          nic_team_info.push("TeamName" => workload_network[0].name, "TeamMembers" => members.join(",")) if members.length > 1
        end

        if windows_2008? && !nic_team_info.empty?
          cert_name = @server_component["puppetCertName"]
          serial_number = ASM::Util.cert2serial(cert_name)
          server_ip = @server_device_conf.host
          raise(ASM::UserException, t(:ASM067, "NIC teaming requested for %{serial} %{ip} but it is not supported with Windows 2008",
                                      :serial => serial_number, :ip => server_ip))

        end

        return {} if nic_team_info.empty?
        logger.debug("Workload Networks: #{workload_networks}")

        nic_team_configuration ||= {}
        nic_team_configuration["windows_postinstall::nic::nic_team"] ||= {}
        nic_team_configuration["windows_postinstall::nic::nic_team"] = {
          "nic_team_info" => {"TeamInfo" => nic_team_info}
        }
        logger.debug("nic_team_config: #{nic_team_configuration}")
        unless puppet_hash.empty?
          nic_team_configuration["windows_postinstall::nic::nic_team"]["require"] = capitalize(puppet_hash.keys)
        end

        logger.debug("Returning nic_team_config: #{nic_team_configuration}")
        nic_team_configuration
      end

      def capitalize(strings)
        updated_string = []
        strings.each do |x|
          updated_string.push("Class[#{(x.split('::').collect {|y| (y.slice(0) || '').upcase + (y.slice(1..-1) || '')}).join('::')}]")
        end
        updated_string
      end

      def workload_networks
        return [] if network_config.nil?
        nic_team_info = (network_config.teams || [])
        logger.debug("Network_config.teams : #{nic_team_info}")
        network_info = {}
        nic_team_info.each do |team|
          network_info[team[:networks]] = team[:mac_addresses]
        end
        network_info
      end

      def nic_ip_config(puppet_hash)
        # For the NICs for which Team is created
        team_nic_ip_hash = puppet_hash.merge(nic_team_ip_config(puppet_hash))
        puppet_hash.merge(non_team_nic_ip_config(team_nic_ip_hash))
      end

      def nic_team_ip_config(puppet_hash)
        return puppet_hash unless puppet_hash["windows_postinstall::nic::nic_team"]
        ip_config_hash = {}
        adapter_ip_info = []
        nic_team_info = puppet_hash["windows_postinstall::nic::nic_team"]["nic_team_info"]["TeamInfo"]
        nic_team_info.each_with_index do |team_info, _team_index|
          member_mac_address = team_info["TeamMembers"].split(",")
          network = get_network(member_mac_address)
          logger.debug("Network info: #{network}")
          adapter_ip_info.push(network_ip_info(network, team_info["TeamName"]))

          logger.debug("Network adapter info #{adapter_ip_info}")
          next if adapter_ip_info.empty?
          ip_config_hash["windows_postinstall::nic::nic_ip_settings"] = {}
          ip_config_hash["windows_postinstall::nic::nic_ip_settings"] = {
            "ipaddress_info" => {"NICIPInfo" => adapter_ip_info}
          }
          ip_config_hash["windows_postinstall::nic::nic_ip_settings"]["require"] = capitalize(puppet_hash.keys)
        end
        ip_config_hash
      end

      def non_team_nic_ip_config(puppet_hash)
        adapter_ip_info = []
        non_team_nic_ip_hash = {}
        workload_networks.each do |workload_network, members|
          logger.debug("Network: #{workload_network} , members: #{members}")
          if members.length == 1
            adapter_ip_info.push(network_ip_info(workload_network[0], workload_network[0].name, members.first.gsub(/:/, "-")))
          end
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

      def network_ip_info(network, adapter_name, mac_address="", vm_obj=nil)
        ip_info = {}
        if network.static
          # Network has static IP Address configuration
          ip_info = {
            "adapter_name" => adapter_name,
            "ip_address" => network["staticNetworkConfiguration"]["ipAddress"],
            "subnet" => network["staticNetworkConfiguration"]["subnet"],
            "primaryDns" => (network["staticNetworkConfiguration"]["primaryDns"] || "")
          }
          # For VM networks we do not need to tag the server ports
          if vm_obj.nil? && @sd.bm_tagged?(network_config, network)
            ip_info["vlan_id"] = network["vlanId"]
          end
          ip_info["mac_address"] = mac_address unless mac_address.empty?

          # Default gateway information needs to be added only if the network is selected
          # explicitly in the template
          logger.debug("Default Gateway : #{default_gateway_network}")
          logger.debug("Network ID: #{network['id']}")
          if default_gateway_network == network["id"]
            ip_info["gateway"] = (network["staticNetworkConfiguration"]["gateway"] || "")
          end
        else
          ip_info = {
            "adapter_name" => adapter_name,
            "ip_address" => "dhcp",
            "subnet" => "",
            "gateway" => "",
            "primaryDns" => ""
          }
          if vm_obj.nil? && @sd.bm_tagged?(network_config, network)
            ip_info["vlan_id"] = network["vlanId"]
          end
          ip_info["mac_address"] = mac_address unless mac_address.empty?
        end

        unless vm_obj.nil?
          ip_info["adapter_type"] = "vm_network"
        end

        # handling for Windows 2008, where JSON format is not supported.
        if windows_2008?
          logger.info("OS Image associated with server %s is %s" % [@server_component["puppetCertName"], os_image_version])
          ip_info["gateway"].nil? ? gateway = "" : gateway = ip_info["gateway"]
          ip_info["mac_address"].nil? ? mac_address = "" : mac_address = ip_info["mac_address"]
          ip_info["vlan_id"].nil? ? vlan_id = "" : vlan_id = ip_info["vlan_id"]
          ip_info = [ip_info["adapter_name"],
                     ip_info["ip_address"],
                     ip_info["subnet"],
                     gateway,
                     ip_info["primaryDns"],
                     mac_address,
                     vlan_id].join(",")
        end
        
        ip_info
      end

      def get_network(member_mac_address)
        workload_networks.each do |workload_network, member|
          return workload_network[0] if member == member_mac_address
        end
      end

      def windows_2008?
        os_image_version.match(/2008/)
      end

      def os_image_version
        asm_server["os_image_version"] || ""
      end
    end
  end
end

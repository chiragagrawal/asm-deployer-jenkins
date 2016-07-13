require "asm/private_util"
require "asm/network_configuration"
require "asm/processor/post_os"

module ASM
  module Processor
    class LinuxPostOS < ASM::Processor::PostOS
      # Bonding option for LACP - valid for RHEL/CentOS/SLES
      def bonding_opts
        "miimon=100 mode=802.3ad xmit_hash_policy=layer2+3"
      end

      # Returns the os image type
      #
      # @return [String] os_image_type of the target server/vm
      def os
        @os_image_type ||= begin
          server_param = @server_config["asm::server"].fetch(@server_component["puppetCertName"], {})
          server_param["os_image_type"]
        end
      end

      def supported_suse?(os)
        ["suse11", "suse12"].include?(os.downcase)
      end


      # Maps the network id to the gateway IP address, and creates the global network class that contains the gateway setting.
      #
      # @param [String] def_gateway_network_id id of the static network
      # @return [Hash] puppet class hash that contains the gateway IP address of the network
      def default_gateway_config(def_gateway_network_id)
        networks = teams.map do |team|
          team[:networks][0]
        end
        def_network = networks.find {|network| network[:id] == def_gateway_network_id}
        if def_network && def_network[:static]
          if supported_suse?(os)
            {"network::suse_routes" => {
                "gateway" => def_network[:staticNetworkConfiguration][:gateway],
                "netmask" => def_network[:staticNetworkConfiguration][:subnet]
            }}
          else
            {"network::global" => {"gateway" => def_network[:staticNetworkConfiguration][:gateway]}}
          end
        else
          if def_gateway_network_id != ""
            logger.warn("Default gateway network, #{def_gateway_network_id}, could not be found in this deployment. Skipping...")
          else
            logger.debug("Network ID for default gateway exists, but the target network is DHCP. Skipping...")
          end
          {}
        end
      end

      # @note Placeholder method that is not used, but expected from Processor module
      def post_os_classes(puppet_hash={})
        puppet_hash
      end

      # @note Placeholder method that is not used, but expected from Processor module
      def post_os_resources(puppet_hash={})
        puppet_hash
      end

      def post_os_config(puppet_hash={})
        logger.debug("Network params: #{@network_params}")
        default_gateway_id = default_gateway_network
        logger.debug("Default gateway network ID: #{default_gateway_id}") unless default_gateway_id.empty?

        unless default_gateway_id.empty?
          gateway_hash = default_gateway_config(default_gateway_id)
          puppet_hash["classes"] = gateway_hash
        end

        process_network_config(default_gateway_id, puppet_hash)
        logger.debug("Linux post os network config puppet config: #{puppet_hash}")

        puppet_hash
      end

      # Add data to the puppet_hash and the static_net_config with a bonded static network configurations from other parameters. For the bonded
      # NICs, multiple interfaces are configured to support one network configuration. Typically the master configuration contains the network
      # configuration details such as the IP address, netmask, gateway, etc. while the slave configurations contain the hardware details and the
      # name of the bond / master they are mapped to. For tagged setting, two bond / master configurations exist - one that simply holds the name
      # that is configured with modprobe bonding module and another that contains the network details. This method does not return any object, but
      # puppet_hash and static_net_config objects are modified.
      #
      # @param nic [Hash] network interface object that has the network configuration details such as the IP address, netmask, gateway, etc.
      # @param macs [array] array of MAC addresses - for bonded setting, more than one MAC addresses are given
      # @param tagged [Object] boolean that indicates whether the NIC is tagged or untagged
      # @param puppet_hash [Hash] hash structure with puppet configuration details - this is used to configure gateway device when required
      # @param static_net_config [Hash] hash structure that contains puppet resources that represent the static network configurations
      # @param current_bond_seq [Integer] value to represent the current bond sequence that is to be configured
      # @param default_gateway_id [String] id of the NIC that should be configured as the gateway device
      # @return
      def bonded_static_nic_config(nic, macs, tagged, puppet_hash, static_net_config, current_bond_seq, default_gateway_id)
        logger.debug("Bonded static NIC Partition: #{nic}")
        logger.debug("Current bonded NIC sequence = #{current_bond_seq}")

        bond_name = "bond#{current_bond_seq}"
        default_gateway_dev = nil

        if !tagged
          static_net_config["network::bond::static"] ||= {}
          static_net_config["network::bond::static"][bond_name] = {
            "ensure" => "up",
            "ipaddress" => nic[:staticNetworkConfiguration][:ipAddress],
            "netmask" => nic[:staticNetworkConfiguration][:subnet],
            "gateway" => (nic[:staticNetworkConfiguration][:gateway] || ""),
            "bonding_opts" => bonding_opts,
            "mtu" => mtu
          }
          default_gateway_dev = bond_name
        else
          vlan_id = nic[:vlanId]
          static_net_config["network::bond::static"] ||= {}
          static_net_config["network::bond::static"][bond_name] = {
            "ensure" => "up",
            "bonding_opts" => bonding_opts,
            "mtu" => mtu
          }
          default_gateway_dev = "#{bond_name}.#{vlan_id}"
          static_net_config["network::bond::vlan"] ||= {}
          static_net_config["network::bond::vlan"][bond_name] = {
            "ensure" => "up",
            "ipaddress" => nic[:staticNetworkConfiguration][:ipAddress],
            "netmask" => nic[:staticNetworkConfiguration][:subnet],
            "gateway" => (nic[:staticNetworkConfiguration][:gateway] || ""),
            "vlanId" => vlan_id,
            "bonding_opts" => bonding_opts,
            "mtu" => mtu
          }
        end

        if default_gateway_id == nic[:id] && !default_gateway_dev.nil?
          if supported_suse?(os)
            puppet_hash["classes"]["network::suse_routes"]["device"] = default_gateway_dev
          else
            puppet_hash["classes"]["network::global"]["gatewaydev"] = default_gateway_dev
          end
        end

        macs.each do |macaddress|
          logger.debug("Bonded NIC Partition: #{nic}")
          logger.debug("Bonded slave for bond#{current_bond_seq} = #{macaddress}")
          static_net_config["network::bond::slave"] ||= {}
          static_net_config["network::bond::slave"][macaddress] = {
            "macaddress" => macaddress,
            "master" => "bond#{current_bond_seq}"
          }
        end
      end

      # Add data to the puppet_hash and the static_net_config with a non-bonded static network configurations from other parameters. Non-bonded
      # static network configuration may be tagged or untagged. For tagged settings, two configurations are created for each interface - one simple
      # interface configuration for the hardware mapping (via MAC address) and another one for the IP address, subnet, gateway, and domain configurations.
      # For untagged settings, both hardware and network related information is stored in a single configuration file. There is no return object in this
      # method, but puppet_hash and static_net_config are updated.
      #
      # @param nic [Hash] network interface object that has the network configuration details such as the IP address, netmask, gateway, etc.
      # @param macs [array] array of MAC addresses - for non-bonded setting, only one MAC address is supplied
      # @param tagged [Object] boolean that indicates whether the NIC is tagged or untagged
      # @param puppet_hash [Hash] hash structure with puppet configuration details - this is used to configure gateway device when required
      # @param static_net_config [Hash] hash structure that contains puppet resources that represent the static network configurations
      # @param default_gateway_id [String] id of the NIC that should be configured as the gateway device
      # @return
      def non_bonded_static_nic_config(nic, macs, tagged, puppet_hash, static_net_config, default_gateway_id)
        logger.debug("Standard static NIC Partition: #{nic}")
        if supported_suse?(os)
          if !tagged
            logger.debug("Creating resources for untagged NIC (SLES) for #{@server_component["puppetCertName"]}..")
            static_net_config["network::if::suse_static"] ||= {}
            static_net_config["network::if::suse_static"][macs[0]] = {
                "ensure" => "up",
                "ipaddress" => nic[:staticNetworkConfiguration][:ipAddress],
                "netmask" => nic[:staticNetworkConfiguration][:subnet],
                "gateway" => (nic[:staticNetworkConfiguration][:gateway] || ""),
                "macaddress" => macs[0],
                "domain" => (nic[:staticNetworkConfiguration][:dnsSuffix] || "")
            }
          else
            logger.debug("Creating resources for tagged NIC (SLES) for #{@server_component["puppetCertName"]}..")
            vlan_id = nic[:vlanId]
            logger.debug("VLAN tagging is required on the OS level for vlan #{vlan_id} configuring static NIC (no bonding)")
            static_net_config["network::if::suse_static"] ||= {}
            static_net_config["network::if::suse_static"][macs[0]] = {
                "ensure" => "up",
                "macaddress" => macs[0],
                "bootproto" => ""
            }
            static_net_config["network::if::suse_vlan"] ||= {}
            static_net_config["network::if::suse_vlan"][macs[0]] = {
                "ensure" => "up",
                "vlanId" => vlan_id,
                "ipaddress" => nic[:staticNetworkConfiguration][:ipAddress],
                "netmask" => nic[:staticNetworkConfiguration][:subnet],
                "gateway" => (nic[:staticNetworkConfiguration][:gateway] || ""),
                "domain" => (nic[:staticNetworkConfiguration][:dnsSuffix] || "")
            }
          end

          if default_gateway_id == nic[:id]
            puppet_hash["classes"]["network::suse_routes"]["device"] = tagged ? "vlan#{vlan_id}" : macs[0]
          end
        else
          if !tagged
            logger.debug("Creating resources for untagged NIC (RHEL) for #{@server_component["puppetCertName"]}..")
            static_net_config["network::if::static"] ||= {}
            static_net_config["network::if::static"][macs[0]] = {
                "ensure" => "up",
                "ipaddress" => nic[:staticNetworkConfiguration][:ipAddress],
                "netmask" => nic[:staticNetworkConfiguration][:subnet],
                "gateway" => (nic[:staticNetworkConfiguration][:gateway] || ""),
                "macaddress" => macs[0],
                "domain" => (nic[:staticNetworkConfiguration][:dnsSuffix] || "")
            }
          else
            logger.debug("Creating resources for tagged NIC (RHEL) for #{@server_component["puppetCertName"]}..")
            vlan_id = nic[:vlanId]
            logger.debug("VLAN tagging is required on the OS level for vlan #{vlan_id} configuring static NIC (no bonding)")
            static_net_config["network::if::static"] ||= {}
            static_net_config["network::if::static"][macs[0]] = {
                "ensure" => "up",
                "macaddress" => macs[0],
                "domain" => (nic[:staticNetworkConfiguration][:dnsSuffix] || "")
            }
            static_net_config["network::if::vlan"] ||= {}
            static_net_config["network::if::vlan"][macs[0]] = {
                "ensure" => "up",
                "vlanId" => vlan_id,
                "ipaddress" => nic[:staticNetworkConfiguration][:ipAddress],
                "netmask" => nic[:staticNetworkConfiguration][:subnet],
                "gateway" => (nic[:staticNetworkConfiguration][:gateway] || ""),
                "domain" => (nic[:staticNetworkConfiguration][:dnsSuffix] || "")
            }
          end

          if default_gateway_id == nic[:id]
            puppet_hash["classes"]["network::global"]["gatewaydev_macaddress"] = macs[0]
            puppet_hash["classes"]["network::global"]["vlanId"] = "#{vlan_id}" if vlan_id
          end
        end
      end

      # Add data to the dhcp_net_config with a bonded dhcp network configurations from other parameters. For the bonded
      # NICs, multiple interfaces are configured to support one network configuration. Typically the master configuration contains the network
      # configuration details such as the VLAN ID while the slave configurations contain the hardware details and the
      # name of the bond / master they are mapped to. For tagged setting, two (static bond and master bond with VLAN info) configurations exist -
      # one that simply holds the name that is configured with modprobe bonding module and another that contains the network details. This method
      # does not return any object, but the dhcp_net_config objects are modified. There is no untagged dhcp bond settings since bonding always
      # requires VLAN tagging.
      #
      # @param nic [Hash] network interface object that has the network configuration details such as the IP address, netmask, gateway, vlan id, etc.
      # @param macs [array] array of MAC addresses - for bonded setting, more than one MAC addresses are given
      # @param dhcp_net_config [Hash] hash structure that contains puppet resources to represent the dhcp bonding configurations
      # @param current_bond_seq [Integer] value to represent the current bond sequence that is to be configured
      # @return
      def bonded_dhcp_nic_config(nic, macs, dhcp_net_config, current_bond_seq)
        logger.debug("Bonded dhcp NIC Partition: #{nic}")
        logger.debug("Current bonded NIC sequence = #{current_bond_seq}")
        bond_name = "bond#{current_bond_seq}"

        vlan_id = nic[:vlanId]
        # using static network resource because bootproto for ifcfg-bond<current_bond_seq> must be "none"
        # the actual dhcp bootproto must be applied to the ifcfg-bond<current_bond_seq>.<vlan_id> file
        dhcp_net_config["network::bond::static"] ||= {}
        dhcp_net_config["network::bond::static"][bond_name] = {
          "ensure" => "up",
          "bonding_opts" => bonding_opts,
          "mtu" => mtu
        }
        dhcp_net_config["network::bond::vlan"] ||= {}
        dhcp_net_config["network::bond::vlan"][bond_name] = {
          "ensure" => "up",
          "bootproto" => "dhcp",
          "vlanId" => vlan_id,
          "bonding_opts" => bonding_opts,
          "mtu" => mtu
        }

        macs.each do |macaddress|
          logger.debug("Bonded NIC Partition: #{nic}")
          logger.debug("Bonded slave for bond#{current_bond_seq} = #{macaddress}")
          dhcp_net_config["network::bond::slave"] ||= {}
          dhcp_net_config["network::bond::slave"][macaddress] = {
            "macaddress" => macaddress,
            "master" => "bond#{current_bond_seq}"
          }
        end
      end

      # Add data to the dhcp_net_config with a non-bonded dhcp network configurations from other parameters. Non-bonded
      # dhcp network configuration may be tagged or untagged. For tagged settings, two configurations are created for each interface - one simple
      # interface configuration for the hardware mapping (via MAC address) and another one for the dhcp configurations.
      # For untagged settings, both hardware and network related information is stored in a single configuration file. There is no return object in this
      # method, but the dhcp_net_config are updated.
      #
      # @param nic [Hash] network interface object that has the network configuration details
      # @param macs [array] array of MAC addresses - for non-bonded setting, only one MAC address is supplied
      # @param tagged [Object] boolean that indicates whether the NIC is tagged or untagged
      # @param dhcp_net_config [Hash] hash structure that contains puppet resources to represent the dhcp bonding configurations
      # @return
      def non_bonded_dhcp_nic_config(nic, macs, tagged, dhcp_net_config)
        logger.debug("Standard dhcp NIC Partition: #{nic}")
        if supported_suse?(os)
          if !tagged
            logger.debug("Creating resources for untagged NIC (SLES) for #{@server_component["puppetCertName"]}..")
            dhcp_net_config["network::if::suse_dynamic"] ||= {}
            dhcp_net_config["network::if::suse_dynamic"][macs[0]] = {
                "ensure" => "up",
                "macaddress" => macs[0]
            }
          else
            logger.debug("Creating resources for tagged NIC (SLES) for #{@server_component["puppetCertName"]}..")
            vlan_id = nic[:vlanId]
            logger.debug("VLAN tagging is required on the OS level for vlan #{vlan_id} configuring dhcp NIC (no bonding)")
            dhcp_net_config["network::if::suse_dynamic"] ||= {}
            dhcp_net_config["network::if::suse_dynamic"][macs[0]] = {
                "ensure" => "up",
                "macaddress" => macs[0],
                "bootproto" => ""
            }
            dhcp_net_config["network::if::suse_vlan"] ||= {}
            dhcp_net_config["network::if::suse_vlan"][macs[0]] = {
                "ensure" => "up",
                "bootproto" => "dhcp",
                "vlanId" => vlan_id
            }
          end
        else
          if !tagged
            logger.debug("Creating resources for untagged NIC (RHEL) for #{@server_component["puppetCertName"]}..")
            dhcp_net_config["network::if::dynamic"] ||= {}
            dhcp_net_config["network::if::dynamic"][macs[0]] = {
                "ensure" => "up",
                "macaddress" => macs[0]
            }
          else
            logger.debug("Creating resources for tagged NIC (RHEL) for #{@server_component["puppetCertName"]}..")
            vlan_id = nic[:vlanId]
            logger.debug("VLAN tagging is required on the OS level for vlan #{vlan_id} configuring dhcp NIC (no bonding)")
            dhcp_net_config["network::if::static"] ||= {}
            dhcp_net_config["network::if::static"][macs[0]] = {
                "ensure" => "up",
                "macaddress" => macs[0]
            }
            dhcp_net_config["network::if::vlan"] ||= {}
            dhcp_net_config["network::if::vlan"][macs[0]] = {
                "ensure" => "up",
                "bootproto" => "dhcp",
                "vlanId" => vlan_id
            }
          end
        end
      end

      # Returns an array of hashes that contain the network details and MAC addresses.
      #
      # Returned data example:
      #
      #    [{:networks => [nic], :mac_addresses => [mac_addr0, mac_addr1, ...]}, ...]
      #
      # where nic is the Hash to contain the network configuration details (e.g., IP address) and mac_addr
      # is String object that represents the mac address of the interface. There should be only one NIC per team.
      #
      # @return [Array] array of hashes where each hash represents a team of network configuration and MAC addresses.
      def teams
        @teams ||= begin
          return [] unless network_config
          (network_config.teams || [])
        end
      end

      # Returns a puppet config hash that contains the MAC address(es) of the interfaces that are used solely for PXE network. Unless the interface is
      # shared with another network, the OS level network configuration(s) for PXE network(s) must be removed since the switch configuration removes
      # the untagging option for the PXE vlan(s).
      #
      # @return [Hash] hash that represents the puppet sub-resources for the PXE network cleanup request
      def pxe_nic_cleanup
        logger.debug("Determine if PXE NIC should be removed explicitly from the OS network config...")
        pxe_nics = network_config.get_partitions("PXE")
        logger.debug("PXE network interface(s) detail: #{pxe_nics}")

        cleanup_config = {}
        if pxe_nics && pxe_nics.size > 0
          pxe_nics.each do |pxe_nic|
            unless pxe_nic.networks.size > 1
              cleanup_config[pxe_nic["mac_address"]] = {
                  "ensure" => "clean"
              }
            end
          end
        end

        cleanup_config
      end

      # Takes existing puppet classes and resources and merge static network configurations to them. The classes are used to merge with any
      # global network settings that will be mapped to /etc/sysconfig/network file while the resources are mapped to individual interface configurations
      # in /etc/sysconfig/network-scripts directory.
      #
      # @param [Hash] puppet_hash existing puppet configuration represented as hash
      # @param [String] default_gateway_id id of the static network
      # @return [Hash] hash that represents the puppet classes and resources for the network configuration along with pre-existing configurations
      def process_network_config(default_gateway_id, puppet_hash={})
        return if network_config.nil?
        logger.debug("Network bonding data: #{teams}")
        network_resources = {}
        current_bond_seq = 0
        logger.debug("MTU setting for bonds: #{mtu}")

        teams.each do |team|
          networks = team[:networks]
          macs = team[:mac_addresses]
          # validate
          if networks.length != 1
            logger.error("More than one network configuration data found in #{team}")
          elsif macs.length < 1
            logger.error("No macaddress found for the interface that should be configured for #{team}")
          end
          network = networks[0]
          tagged = @sd.bm_tagged?(network_config, network)
          if network[:static]
            if macs.length > 1
              bonded_static_nic_config(network, macs, tagged, puppet_hash, network_resources, current_bond_seq, default_gateway_id)
              current_bond_seq += 1
            else
              non_bonded_static_nic_config(network, macs, tagged, puppet_hash, network_resources, default_gateway_id)
            end
          elsif macs.length > 1
            bonded_dhcp_nic_config(network, macs, network_resources, current_bond_seq)
            current_bond_seq += 1
          else
            non_bonded_dhcp_nic_config(network, macs, tagged, network_resources)
          end
        end

        unless network_resources.empty?
          puppet_hash["resources"] = network_resources
          all_networks = teams.map {|team| team[:networks] }.flatten
          appliance_ip = host_ip_config(all_networks)
          puppet_hash["resources"]["host"]= {"dellasm" => {"ensure" => "present", "ip" => appliance_ip}}
        end

        pxe_nic_cleanup_config = pxe_nic_cleanup
        unless pxe_nic_cleanup_config.empty?
          puppet_hash["resources"] ||= {}
          puppet_hash["resources"]["network::pxe_cleanup"] = pxe_nic_cleanup_config
        end

        logger.debug("Network config node_data for #{@server_component["puppetCertName"]}")
        puppet_hash
      end
    end
  end
end

# linux_post_os.rb
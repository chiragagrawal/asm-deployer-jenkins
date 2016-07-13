require 'asm/private_util'
require 'asm/network_configuration'

module ASM
  module Processor
    module Server

      #
      # takes a server hash and network hash from asm
      # and converts them into the expected asm::server
      # resource hash
      #
      def self.munge_hyperv_server(title, old_resources, target_ip,
          vol_names, logger, disk_part_flag,
          storage_type = 'iscsi', storage_model = 'equallogic',
          iscsi_fabric = "Fabric A",
          iscsi_macs = [])

        resources = old_resources.dup 

        idrac_params = (resources['asm::idrac'] || {})[title]

        # if hyperv is on idrac, make some customizations
        if idrac_params
          if idrac_params['target_boot_device'] == 'SD'
            raise(ArgumentError, 'HyperV does not work with target boot device SD')
          end
          idrac_params['enable_npar'] = false
        end

        # now munge some params!
        server_params = ((resources['asm::server'] || {})[title] || {}).dup
        puppet_classification_data = {'hyperv::config' => {}}

        installer_options = server_params['installer_options'] || {}
        [
	  'domain_name',
	  'fqdn',
	  'domain_admin_user',
	  'domain_admin_password',
	  'ntp_server'
	].each do |param|
          if param == 'ntp_server'
            puppet_classification_data['hyperv::config']['ntp'] = installer_options.delete('ntp_server')
          elsif param == 'domain_admin_password'
            puppet_classification_data['hyperv::config']['domain_admin_password'] =
                ASM::PrivateUtil.domain_password_token(
                    "ASMCRED-#{server_params['installer_options']['domain_admin_password']}",
                    server_params['os_host_name'])
            installer_options.delete(param)
          else
            puppet_classification_data['hyperv::config'][param] = installer_options.delete(param)
          end
        end
        server_params.delete('installer_options') if installer_options.empty?

        puppet_classification_data['hyperv::config']['iscsi_target_ip_address'] = target_ip
        puppet_classification_data['hyperv::config']['iscsi_volumes'] = vol_names

        # now merge in network parameters
        net_params   = (resources['asm::esxiscsiconfig'] || {})[title]

        # Get the MAC address of the partitions which are having management NICS mapped to it
        # So that we can use only these NICS for the NIC partition
        network_config = ASM::NetworkConfiguration.new(net_params['network_configuration'], logger)
        device_conf = ASM::DeviceManagement.parse_device_config(title)
        if !(device_conf['host'] == '127.0.0.1')
          network_config.add_nics!(device_conf, :add_partitions => true)

          mac_address = network_config.get_partitions('HYPERVISOR_MANAGEMENT').collect do |partition|
            partition.mac_address
          end.compact.join(',')
        end

        puppet_classification_data['hyperv::config']['nic_team_member_macs'] = mac_address
        management_network = network_config.get_network('HYPERVISOR_MANAGEMENT')
        migration_network = network_config.get_network('HYPERVISOR_MIGRATION')
        private_network = network_config.get_network('HYPERVISOR_CLUSTER_PRIVATE')

        net_mapper = {
          'ipAddress' => 'ip_address',
          'subnet'     => 'netmask',
          'gateway'    => 'gateway'
        }

        [management_network, migration_network, private_network].each do |network|

            param_prefix = name.sub(/_network$/, '')

            param_prefix = "converged_net" if network['type'] == 'HYPERVISOR_MANAGEMENT'
            param_prefix = "live_migration" if network['type'] == 'HYPERVISOR_MIGRATION'
            param_prefix = "private_cluster" if network['type'] == 'HYPERVISOR_CLUSTER_PRIVATE'

            puppet_classification_data['hyperv::config'][ "#{param_prefix}_vlan_id"] = network['vlanId']

            net_mapper.each do |attr, puppet_param|
              param = "#{param_prefix}_#{puppet_param}"
              puppet_classification_data['hyperv::config'][param] = network['staticNetworkConfiguration'][attr]
              puppet_classification_data['hyperv::config'][param] = '' if network['staticNetworkConfiguration'][attr].nil?
            end

            if network['type'] == 'HYPERVISOR_MANAGEMENT'
              puppet_classification_data['hyperv::config']['converged_net_dns_server'] = network['staticNetworkConfiguration']['primaryDns']
            end

        end
        
        storage_networks = network_config.get_networks('STORAGE_ISCSI_SAN')
        if storage_type == 'iscsi'
          first_net = storage_networks[0]
          second_net = storage_networks[1]
          puppet_classification_data['hyperv::config']['iscsi_netmask']     =  first_net['staticNetworkConfiguration']['subnet']
          puppet_classification_data['hyperv::config']['iscsi_vlan_id']           =  first_net['vlanId']
          puppet_classification_data['hyperv::config']['iscsi_ip_addresses'] = []
          puppet_classification_data['hyperv::config']['iscsi_ip_addresses'].push(first_net['staticNetworkConfiguration']['ipAddress'])
          puppet_classification_data['hyperv::config']['iscsi_ip_addresses'].push(second_net['staticNetworkConfiguration']['ipAddress'])
          puppet_classification_data['hyperv::config']['iscsi_fabric'] = iscsi_fabric
          puppet_classification_data['hyperv::config']['iscsi_macs'] = iscsi_macs.compact.join(',')
        end

        iscsi_networks = []
        storage_partitions = network_config.get_all_partitions
        storage_partitions.each do |storage_partition|
          storage_partition["networkObjects"].each do |network_object|
            if network_object['type'] == 'STORAGE_ISCSI_SAN'
                  iscsi_networks.push([ storage_partition['mac_address'],
                                        network_object['staticNetworkConfiguration']['subnet'],
                                        network_object['staticNetworkConfiguration']['ipAddress'],
                                        network_object['vlanId'] ].join(','))
            end
          end
        end
        puppet_classification_data['hyperv::config']['iscsi_networks'] = iscsi_networks.join(';')

        puppet_classification_data['hyperv::config']['hyperv_diskpart'] = disk_part_flag
        if storage_type == 'fc' && storage_model == 'compellent'
          puppet_classification_data['hyperv::config']['pod_type'] = 'AS1000'
        elsif storage_type == 'fc' && storage_model == 'vnx'
          puppet_classification_data['hyperv::config']['pod_type'] = 'EMCFC'
        elsif storage_type == 'iscsi' && storage_model == 'compellent'
          puppet_classification_data['hyperv::config']['pod_type'] = 'AS1000iSCSI'
        end



        # Get the appliance IP Address accessible from hypervisor managemen network
        puppet_classification_data['hyperv::config']['appliance_hypervior_management_ip'] =
            ASM::Util.get_preferred_ip(puppet_classification_data['hyperv::config']['converged_net_ip_address'])
        server_params['puppet_classification_data'] = puppet_classification_data

        server_params['os_image_type']  = server_params['os_image_type'] || 'windows'

        (resources['asm::server'] || {})[title] = server_params
        (resources['asm::idrac'] || {})[title]  = idrac_params

        resources
      end

    end
  end

end

require 'hashie'
require 'yaml'
require 'json'
require 'asm/device_management'
require 'asm/private_util'
require 'asm/razor'
require 'asm'
require 'asm/translatable'
require 'rbvmomi'

module ASM
  module Resource
    class Mash < Hashie::Mash
    end

    module VM
      def self.create(value)
        # TODO: need to migrate log
        # require 'asm/log'
        # log("Processing component: #{value['puppetCertName']}")
        vm_hash = value.select{|k| ['asm::vm', 'asm::vm::vcenter', 'asm::vm::scvmm'].include? k}
        vm_type, vm_config = vm_hash.shift
        vm_config ||= []

        case vm_type
        when 'asm::vm', 'asm::vm::vcenter'
          vm_config.collect{|uuid, vm| VMware.new(vm)}
        when 'asm::vm::scvmm'
          vm_config.collect{|uuid, vm| Scvmm.new(vm)}
        else
          raise ArgumentError, "Invalid VM resource type #{vm_type}"
        end
      end

      class VM_Mash < Hashie::Mash
        include ASM::Translatable
        def nil?
          !any?
        end

        # This is purely for testing:
        def conf(cert)
          @conf ||= ASM::DeviceManagement.parse_device_config(cert)
        end

        def to_puppet
          raise NotImplementedError, 'VM_Mash is a not a puppet resource'
        end
      end

      class VMware < VM_Mash
        def process!(cert, server, cluster, deployment_id, logger=nil)
          self.hostname = self.hostname || server.hostname || server.os_host_name
          raise(ArgumentError, 'VM hostname not specified and missing server hostname value') unless self.hostname

          server ||= {}
          case server['os_image_type']
          when /windows/
            self.os_type = 'windows'
            self.os_guest_id = 'windows8Server64Guest'
            self.scsi_controller_type = 'LSI Logic SAS'
          else
            self.os_type = 'linux'
            self.os_guest_id = 'rhel6_64Guest'
            self.scsi_controller_type = 'VMware Paravirtual'
          end
          conf(cluster.title)
          self.cluster = cluster.cluster
          self.datacenter = cluster.datacenter
          self.vcenter_id = cert
          self.vcenter_options = { 'insecure' => true }
          self.ensure ||= 'present'

          cluster_deviceconf = ASM::DeviceManagement.parse_device_config(cert)
          # Default VMware network:
          network = []
          requested_network = []
          # Get the PXE vLAN from the cluster
          if ASM.config.debug_service_deployments
            pxe_network_name = 'VM Network'
          elsif cluster.vds_enabled == "distributed"
            vds_title, vds_cluster_params = cluster.vds_info.shift
            pxe_vds_info = self.delete("vds_pxe_info")
            # pxe_vds_info existing means there's a server to get pxe information from, and template values for the pxe vds/pg
            if pxe_vds_info
              pxe_vds_name = pxe_vds_info[:vds]
              pxe_vds_pg = pxe_vds_info[:portgroup]
            else
              # This block means this is a deployment where vds name and portgroup were specified by user
              pxe_vds_name = vds_cluster_params["vds_name::pxe"]
              pxe_vds_pg = vds_cluster_params["vds_pg::pxe::pxe::1"]
            end
            self.delete("pxe_network_names")
            pxe_network_name = "#{pxe_vds_pg} (#{pxe_vds_name})"
          else
            # This block is for standard vswitch deployments, where we use the name of the network to create the portgroup
            if self.source
              self.delete("pxe_name")
              self.delete("pxe_network_names")
            else
              pxe_network_name = self.delete("pxe_name")

              if pxe_network_name.nil?
                pxe_network = get_pxe_network(self.delete("pxe_network_names"))
                if pxe_network
                  pxe_network_name = pxe_network.spec.name
                else
                  raise(ASM::UserException, t(:ASM070, "ASM must have an OS installation network that matches the exact name of a VM portgroup in target cluster"))
                end
              end
            end
          end
          cluster.vds_info = vds_cluster_params
          self.network_interfaces = [] if self.network_interfaces == ""
          vm_network = [
              { "portgroup" => pxe_network_name,
                "nic_type" => "vmxnet3"}
          ]
          self.network_interfaces.each do |net|
            requested_network << {
                "portgroup" => vm_network_name(cluster, net),
                "nic_type"  => "vmxnet3"
            }
          end
          self.delete("vds_workload_info")
          vm_network.concat(requested_network)

          vm_already_deployed = false
          if !self.is_vm_already_deployed(deployment_id, logger) and
              self.source.nil?
            network = vm_network
            vm_already_deployed = false
          else
            vm_already_deployed = true
          end

          self.requested_network_interfaces = requested_network
          self.network_interfaces = network

          self.network_interfaces = requested_network if network.empty? and !requested_network.empty?
          self.network_interfaces = vm_network if vm_already_deployed == true and self.network_interfaces.empty?
          self.requested_network_interfaces = vm_network if requested_network.empty?

          vm_storage_policy = vm_storage_policy(cluster)
          self.vm_storage_policy = vm_storage_policy unless vm_storage_policy.empty?
        end

        def vm_storage_policy(cluster)
          asm_storage_policy = "ASM VSAN VM Storage Policy"
          storage_profiles = cluster_inventory(cluster)['storage_profiles']
          if storage_profiles
            storage_policies = JSON.parse(cluster_inventory(cluster)['storage_profiles'])
            storage_policies.find {|x| x == asm_storage_policy} || ''
          else
            ''
          end
        end

        def cluster_inventory(cluster)
          @cluster_inventory ||= ASM::PrivateUtil.facts_find(cluster.ref_id)
        end

        def vm_network_name(cluster, net)
          return net['name'] if cluster.vds_enabled == "standard"
          if cluster.vds_info["vds_name::workload"]
            workload_vds_name = cluster.vds_info["vds_name::workload"]
          elsif self.vds_workload_info && self.vds_workload_info[net.name]
            workload_vds_name = self.vds_workload_info[net.name][:vds]
          end
          # For VDS Enabled workload network, get the information from the inventory
          cluster_inv_facts = JSON::parse(cluster_inventory(cluster)['inventory'])['children']
          dc_obj = cluster_inv_facts.select { |x| x['name'] == cluster.datacenter}.first['children']
          dv_objs = dc_obj.select {|x| x['type'] == 'VmwareDistributedVirtualSwitch'}

          dv_objs.each do |dv_obj|
            dv_obj['children'].each do |dv_port_group|
              if dv_port_group['attributes']['vlan_id'] == net['vlanId'] &&
                  dv_obj['name'] == workload_vds_name
                return "#{dv_port_group['name']} (#{dv_obj['name']})"
              end
            end
          end
          raise("Failed to find the portgroup / dvport-group")
        end

        def to_puppet
          @hostname = self.hostname
          hostname = self.delete 'hostname'
          { 'asm::vm::vcenter' => { hostname => self.to_hash }}
        end

        def certname
          if self.source
            "vm#{macaddress.downcase}"
          elsif @hostname
            ASM::Util.hostname_to_certname(@hostname)
          else
            raise(ArgumentError, "Unable to determine certname without source or hostname")
          end
        end

        def macaddress
          value = ASM::Util.block_and_retry_until_ready(300, NoMethodError, 10) do
            vm.guest.net.first.macAddress
          end
          value.gsub(':', '')
        end

        def vm_networks
          @vm_networks ||= begin
            ASM::Util.block_and_retry_until_ready(300, NoMethodError, 10) do
              vm.config.hardware.device.select { |x| x.class.to_s == 'VirtualVmxnet3' }
            end
          end
        end

        def reset_vim
          @vim = @vm = @dc = @vm_obj = nil
          vim
        end

        def vm_os_type
          ASM::Util.block_and_retry_until_ready(300, NoMethodError, 10) do
            begin
              vm.summary.config.guestId
            rescue
              reset_vim
              vm.summary.config.guestId
            end
          end
        end

        def vm_port_group_key(dv_port_group_name)
          pg =
              dc.networkFolder.children.select{|n|
                n.class == RbVmomi::VIM::DistributedVirtualPortgroup
              }
          pg.select { |x| x.name == dv_port_group_name }.first['key']
        end

        def vm_net_mac_address(network, cluster_obj)
          if cluster_obj.vds_enabled == "distributed"
            network_name = vm_network_name(cluster_obj, network).scan(/^(.*?)\(/).flatten.first.gsub(/\s*/,'')
            net = vm_networks.select { |x| x.backing.port.portgroupKey == vm_port_group_key(network_name)}
          else
            net = vm_networks.select { |x| x.backing.deviceName == network.name}
          end
          net[0].macAddress
        end

        def vm
          @vm ||= findvm(dc.vmFolder, (self.hostname||@hostname))
        end

        def reset
          vm.ResetVM_Task!
        end

        def get_pxe_network(pxe_network_names)
          return pxe_network_names if pxe_network_names.nil?
          cl = dc.hostFolder.childEntity.find { |x| x.name == self.cluster }
          cl.host.each do |host|
            networkSystem = host.configManager.networkSystem
            pg = networkSystem.networkInfo.portgroup
            network = pg.find do |port|
              pxe_network_names.include?(port.spec.name)
            end
            return network unless network.nil?
          end
          nil
        end

        def findvm(folder, name)
          folder.children.each do |subfolder|
            break if @vm_obj
            case subfolder
            when RbVmomi::VIM::Folder
              findvm(subfolder,name)
            when RbVmomi::VIM::VirtualMachine
              @vm_obj = subfolder if subfolder.name == name
            when RbVmomi::VIM::VirtualApp
              @vm_obj = subfolder.vm.find{|vm| vm.name == name }
            else
              raise(ArgumentError, "Unknown child type: #{subfolder.class}")
            end
          end
          @vm_obj
        end

        def dc
          @dc||= vim.serviceInstance.find_datacenter(self.datacenter)
        end

        def vim
          @vim ||= begin
            raise("Resource has not been processed.") unless @conf

            options = {
              :host => @conf.host,
              :user => @conf.user,
              :password => @conf.password,
              :insecure => true,
            }
            RbVmomi::VIM.connect(options)
          end
        end

        def is_vm_already_deployed(deployment_id, logger=nil)
          hostname = self.hostname || @hostname
          cluster_deviceconf = ASM::DeviceManagement.parse_device_config(self.vcenter_id)
          logger.debug("Checking if VM '%s' has been deployed" % hostname) if logger
          is_deployed = false

          begin
            if self.source
              logger.debug("VMware Clone scenario")
              is_deployed = true
            else
              uuid = ASM::PrivateUtil.find_vm_uuid(cluster_deviceconf, hostname, self.datacenter)
              logger.debug("%s UUID: %s" % [hostname, uuid]) if logger

              serial_number = ASM::Util.vm_uuid_to_serial_number(uuid)
              logger.debug("%s Serial number: %s" % [hostname, serial_number]) if logger

              policy_name = "policy-#{hostname}-#{deployment_id}".downcase
              logger.debug("%s Policy Name: %s" % [hostname, policy_name]) if logger

              razor = ASM::Razor.new(:logger => logger)
              node = razor.find_node(serial_number)
              logger.debug("%s Node Info: %s" % [hostname, node.inspect]) if logger

              if node['name']
                razor_task_status = razor.task_status(node['name'], policy_name)
              else
                razor_task_status = {}
              end

              # windows does multiple boots etc, redhat doesnt so need to accept both as successfully built vm
              if [:boot_local_2, :boot_install].include?(razor_task_status[:status])
                logger.debug("VM %s is already deployed and in state %s" % [hostname, razor_task_status[:status]]) if logger
                is_deployed = true
              else
                logger.debug("VM %s exists but is not completely deployed, status is '%s' but expected boot_local_2 or boot_install" % [hostname, razor_task_status[:status]]) if logger
              end
            end

          rescue => e
            logger.debug("Could not determine if VM '%s' is already deployed: %s" % [hostname, e.to_s]) if logger

            is_deployed = false
          end

          is_deployed
        end
      end

      class Scvmm < VM_Mash
        def process!(cert, server, cluster, deployment_id, logger)
          self.hostname ||= self.delete('name')
          raise(ArgumentError, 'VM hostname not specified, missing server os_host_name value') unless self.hostname

          conf(cluster.title)
          self.scvmm_server = cert
          self.vm_cluster = cluster.name
          self.ensure ||= 'present'

          network_default = {
            :ensure => 'present',
            :mac_address_type => 'static',
            :mac_address => '00:00:00:00:00:00',
            :ipv4_address_type => 'dynamic',
            :vlan_enabled => 'true',
            :transport => 'Transport[winrm]',
          }

          networks = {}

          self.network_interfaces = [] if self.network_interfaces == ""
          self.network_interfaces.each_with_index do |net, i|
            network = network_default.clone
            vlan_id = net['vlanId']
            raise(ArgumentError, "Missing VLAN id #{vlan}") unless vlan_id
            network['vlan_id'] = vlan_id
            network['require'] = "Sc_virtual_network_adapter[#{hostname}:#{i - 1}]" if i > 0
            networks["#{hostname}:#{i}"] = network
          end
          self.network_interfaces = networks
        end

        def to_puppet
          @hostname = self.hostname
          hostname = self.delete 'hostname'

          self.each do |key, val|
            self.delete key if val.nil? or val == ''
          end
          { 'asm::vm::scvmm' => { hostname => self.to_hash }}
        end

        def certname
          if self.template
            "vm#{macaddress.downcase}"
          elsif self.hostname
            ASM::Util.hostname_to_certname(self.hostname)
          else
            raise(ArgumentError, "Unable to determine certname without source or hostname")
          end
        end

        def macaddress
          raise("Resource has not been processed.") unless @conf
          cmd = File.join(File.dirname(__FILE__),'scvmm_macaddress.rb')
          domain, user = @conf.user.split('\\')
          args = ['-u', user, '-d', domain, '-p', @conf.password, '-s', @conf.host, '-v', (self.hostname || @hostname)]
          result = ASM::Util.run_with_clean_env(cmd, true, *args)
          result = result.stdout.each_line.collect{|line| line.chomp.rstrip.gsub(':', '')}
          macaddress = result.find{|x| x =~ /^MACAddress\s+[0-9a-fA-F]{12}$/}
          if macaddress.nil?
            # It seems MAC address is not available, wait for a minute before retrying
            sleep(60)
            result = ASM::Util.run_with_clean_env(cmd, true, *args)
            result = result.stdout.each_line.collect{|line| line.chomp.rstrip.gsub(':', '')}
            macaddress = result.find{|x| x =~ /^MACAddress\s+[0-9a-fA-F]{12}$/}
          end
          macaddress = macaddress.match(/MACAddress\s+(\S+)/)[1]
          raise('Virtual machine needs to power on first.') if macaddress == '00000000000000'
          macaddress
        end

        def vm_os_type
          raise("Resource has not been processed.") unless @conf
          begin
            cmd = File.join(File.dirname(__FILE__),'scvmm_vminfo.rb')
            domain, user = @conf.user.split('\\')
            args = ['-u', user, '-d', domain, '-p', @conf.password, '-s', @conf.host, '-v', (self.hostname || @hostname)]
            result = ASM::Util.run_with_clean_env(cmd, true, *args)
            os_name = JSON.parse(result.stdout)["OperatingSystem"]["Name"]
          rescue
            os_name = nil
          end
          os_name
        end

        def vm_net_mac_address(network, cluster_obj)
          raise("Resource has not been processed.") unless @conf
          begin
            cmd = File.join(File.dirname(__FILE__),'scvmm_vm_nic_info.rb')
            domain, user = @conf.user.split('\\')
            args = ['-u', user, '-d', domain, '-p', @conf.password, '-s', @conf.host, '-v', (self.hostname || @hostname)]
            result = ASM::Util.run_with_clean_env(cmd, true, *args)
            json_data = JSON.parse(result.stdout)
            if json_data.is_a?(Hash)
              net_mac = json_data['MACAddress']
            elsif json_data.is_a?(Array)
              net_mac = json_data.select { |x| x['VLanID'].to_i == network.vlanId.to_i}.first['MACAddress']
            end
          rescue
            net_mac = nil
          end
          net_mac
        end

        # For SCVMM we currently support only clone VM where PXE boot configruation is not supported
        def is_vm_already_deployed(deployment_id, logger=nil)
          return true
        end

      end
    end

    #TODO:  Extending Hashie::Mash is dangerous and flaky.  Should just explicitly create a new Hashie::Mash in initialize
    class Server_Mash < Hashie::Mash
      def initialize(server, default=nil, &blk)
        #hyperv_install is mostly used on the Java side.  os_image_type will be 'hyperv' from java if hyperv_install=true
        server.delete('hyperv_install')
        super(server, default, &blk)
      end

      def process!(serial_number, id)
        self.broker_type = 'noop'
        hostname = self.os_host_name

        self.serial_number = serial_number
        self.policy_name = "policy-#{hostname}-#{id}".downcase
        self.razor_api_options ||= ASM.config.http_client_options || {}
        self.razor_api_options['url'] = "%s/api" % ASM.config.url.razor unless self.razor_api_options['url']
        self.client_cert ||= ASM.config.client_cert if ASM.config.client_cert

        # Delete the migration parameters
        self.delete('migrate_on_failure')
        self.delete('attempted_servers')
      end

      def to_puppet
        title = self.delete 'title'

        # Remove confirm param that no one needs
        self.delete('domain_admin_password_confirm') if self.include?('domain_admin_password_confirm')

        installer_options = {}
        [
            # Hyper-V specific installer options
            'language',
            'keyboard',
            'product_key',
            'timezone',

            # Hyper-V options that get sucked into hyperv::config by munge_hyperv_server
            'domain_name',
            'fqdn',
            'domain_admin_user',
            'domain_admin_password',
            'ntp_server',

            # linux-specific installer options
            'ntp_server',
            'time_zone',
        ].each do |param|
          installer_options[param] = self.delete(param) if self.include?(param)
        end
        # I need to save the value from the GUI b/c I need to use it to pick the correct
        # unattended file
        installer_options['os_type'] = self.delete('os_image_type') if self.include?('os_image_type')
        installer_options['agent_certname'] = ASM::Util.hostname_to_certname(self.os_host_name)
        self.installer_options = installer_options unless installer_options.empty?

        {title => self.to_hash}
      end

      def certname
        ASM::Util.hostname_to_certname(self.os_host_name)
      end
      
    end

    class Server
      def self.create(value)
        if value.include? 'asm::server'
          value['asm::server'].collect do |title, server|
            server['title'] = title
            ASM::Resource::Server_Mash.new(server)
          end
        else
          []
        end
      end

      def self.cleanup(server, title)
        server['title'] = title
        if server.include? 'os_type'
          server['os_image_type'] = server.delete('os_type')
          # TODO: migrate logger
          #@logger.warn('Server configuration contains deprecated param name os_type')
        end
        server
      end

    end

    module Cluster
      def self.create(value)
        result = []

        value.each do |cluster_type, cluster_config|
          case cluster_type
            when 'asm::cluster', 'asm::cluster::vmware'
              result << ASM::Resource::Cluster::VMware.new(cluster_config)
            when 'asm::cluster::vds'
              result << ASM::Resource::Cluster::VMware_Vds.new(cluster_config)
            when 'asm::cluster::scvmm'
              result << ASM::Resource::Cluster::Scvmm.new(cluster_config)
          end
        end
        result
      end

      class Cluster_Mash < Hashie::Mash
      end

      class VMware < Cluster_Mash
      end

      class VMware_Vds < VMware
      end

      class Scvmm < Cluster_Mash
      end
    end
  end
end


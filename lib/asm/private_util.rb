require 'io/wait'
require 'hashie'
require 'json'
require 'open3'
require 'ostruct'
require 'rest_client'
require 'socket'
require 'timeout'
require 'uri'
require 'yaml'
require 'time'
require 'asm/api'
require 'asm/util'

module ASM

  module PrivateUtil

    # TODO: give razor user access to this directory
    PUPPET_CONF_DIR='/etc/puppetlabs/puppet'
    DEVICE_CONF_DIR="#{PUPPET_CONF_DIR}/devices"
    NODE_DATA_DIR="#{PUPPET_CONF_DIR}/node_data"
    DEVICE_SSL_DIR="/var/opt/lib/pe-puppet/devices"
    DATABASE_CONF="#{PUPPET_CONF_DIR}/database.yaml"
    DEVICE_MODULE_PATH = "/etc/puppetlabs/puppet/modules"
    INSTALLER_OPTS_DIR = '/opt/razor-server/tasks/'
    DEVICE_LOG_PATH = '/opt/Dell/ASM/device'

    def self.appliance_ip_address
      %x{facter ipaddress}.chomp
    end

    def self.server_ra_url(url = nil)
      url || ASM.config.url.asm_server || 'http://localhost:9080/AsmManager/Server'
    end

    def self.networks_ra_url(url = nil)
      url || ASM.config.url.asm_network || 'http://localhost:9080/VirtualServices/Network'
    end

    def self.chassis_ra_url(url = nil)
      url || ASM.config.url.asm_chassis || 'http://localhost:9080/AsmManager/Chassis'
    end

    def self.managed_device_url(url = nil)
      url || ASM.config.url.asm_device || 'http://localhost:9080/AsmManager/ManagedDevice'
    end

    def self.deployment_service_url(url = nil)
      url || ASM.config.url.asm_deployment || 'http://localhost:9080/AsmManager/Deployment'
    end

    def self.puppetdb_url(url = nil)
      url || ASM.config.url.puppetdb || 'http://localhost:7080'
    end

    # See spec/fixtures/asm_server_m620.json for sample response
    #
    # cert_name is in format devicetype-servicetag
    def self.fetch_server_inventory(cert_name, options = {})
      options[:url] = server_ra_url(options[:url])
      service_tag = ASM::Util.cert2serial(cert_name)
      url = "#{options[:url]}/?filter=eq,serviceTag,#{service_tag}"
      data = ASM::Api::sign {
        RestClient.get(url, {:accept => :json})
      }
      ret = JSON.parse(data)
      # should return a list of one element with matching serviceTag
      if !ret || ret.empty? || ret[0]['serviceTag'] != service_tag
        raise("Failed to get inventory for server #{cert_name}")
      end
      ret[0]
    end

    def self.fetch_server_data(ref_id, options = {})
      options[:url] = server_ra_url(options[:url])
      url = "#{options[:url]}/#{ref_id}"
      data = ASM::Api::sign {
        RestClient.get(url, {:accept => :json})
      }
      ret = JSON.parse(data)
      if !ret || ret['refId'] != ref_id
        raise("Failed to get data for server #{ref_id}")
      end
      ret
    end

    def self.migrate_server(server_component_id, deployment_id, options = {})
      url = deployment_service_url(options[:url])
      url = "#{url}/migrateServer/#{deployment_id}/#{server_component_id}"
      data = ASM::Api::sign {
        RestClient.put(url, {:content_type => :json}, {:accept => :json})
      }
      unless data.nil?
        JSON.parse(data)
      end
    end

    def self.reserve_network_ips(guid, n_ips, usage_guid, options = {})
      options[:url] = networks_ra_url(options[:url])
      url = "#{options[:url]}/ipAddress/assign?networkId=#{URI.encode(guid)}&numberToReserve=#{n_ips}&usageGUID=#{URI.encode(usage_guid)}"
      data = ASM::Api::sign {
        RestClient.put(url, {:content_type => :json}, {:accept => :json})
      }
      ret = JSON.parse(data)
      n_retrieved = !ret ? 0 : ret.size
      if n_retrieved != n_ips
        raise("Retrieved invalid response to network reservation request: #{ret}")
      end
      ret
    end

    def self.fetch_managed_device_inventory(device, options={})
      options[:query] = "filter=eq,refId,%s" % device
      fetch_managed_inventory(options)
    end

    def self.fetch_managed_inventory(options = {})
      options[:url] = managed_device_url(options[:url])

      if options[:query]
        url = "%s?%s" % [options[:url], options[:query]]
      else
        url = "%s?limit=2147483647" % options[:url]
      end

      data = ASM::Api::sign {
        RestClient.get(url, {:accept => :json})
      }
      ret = JSON.parse(data)
      if !ret
        raise("Failed to get managed devices list")
      end
      ret
    end

    def self.update_asm_inventory(asm_guid, options = {})
      options[:url] = managed_device_url(options[:url])
      url = "#{options[:url]}/#{asm_guid}"
      ASM::Api::sign do
        asm_obj = JSON.parse(RestClient.get(url, :content_type => :json, :accept => :json))
        RestClient.put(url, asm_obj.to_json, :content_type => :json, :accept => :json)
      end
    end

    def self.is_chassis_stacked(chassis_service_tag,blade_server_switches)
      chassis_stacked = false
      blade_server_switches.each do |blade_server_switch|
        switch_facts = ASM::PrivateUtil.facts_find(blade_server_switch)
        stack_topology = ( switch_facts['stack_port_topology'] || 'stand alone' )
        next if stack_topology.match(/stand alone/i)
        (0..5).each do |stack_unit|
          chassis_stacked = true if (switch_facts["stack_unit_#{stack_unit}"] || '').match(/Chassis Svce Tag\s*:\s*#{chassis_service_tag}/i)
          break if chassis_stacked
        end
      end
      chassis_stacked
    end

    def self.chassis_inventory(server_cert_name, logger, options = {})
      options[:url] = chassis_ra_url(options[:url])
      chassis_info = {}
      ioaips = []
      logger.debug "URL : #{options[:url]}"
      data = ASM::Api::sign {
        RestClient.get(options[:url], {:accept => :json})
      }
      ret = JSON.parse(data)
      ret.each do |chassis|
        logger.debug "chassis : #{chassis}"
        serverinfo = chassis['servers']
        logger.debug "***************serverinfo #{serverinfo}"
        serverinfo.each do |server|
          logger.debug "server : #{server} : server_cert_name : #{server_cert_name}"
          if server['serviceTag'] == server_cert_name
            # Got chassis. get chassis information
            chassis_ip = chassis['managementIP']
            credentialRefId = chassis['credentialRefId']
            chassisservicetag = chassis['serviceTag'].downcase
            chassiscertname = "cmc-#{chassisservicetag}"
            logger.debug "************chassiscertname : #{chassiscertname}"
            device_conf ||= ASM::DeviceManagement.parse_device_config(chassiscertname)
            chassis_username = device_conf[:user]
            chassis_password = device_conf[:password]
            logger.debug "chassis_username : #{chassis_username}"
            if chassis_username == ""
              chassis_username = "root"
              chassis_password = "calvin"
            end
            slot_num = server['slot']
            ioainfo = chassis['ioms']
            ioaslots = []
            ioa_models = []
            ioa_service_tags = []
            ioainfo.each do |ioa|
              ioa_models.push(ioa['model'])
              ioa_service_tags.push(ioa['serviceTag'])
              if ioa['model'].match(/pass-through|ethernet module/i)
                logger.debug('Skipping the pass-through IOAs')
                next
              end
              ioaip = "dell_iom-"+"#{ioa['managementIP']}"
              ioaslot = ioa['location']
              logger.debug("IOA Location: #{ioaslot}")
              ioaslots.push ioaslot
              ioaips.push ioaip
            end
            logger.debug "ioaips.pushioaips :::: #{ioaips}"
            chassis_info = {'chassis_ip' => chassis_ip,
                            'chassis_username' => chassis_username,
                            'chassis_password' => chassis_password,
                            'slot_num' => slot_num,
                            'ioaips' => ioaips,
                            'ioaslots' => ioaslots,
                            'ioa_models' => ioa_models,
                            'ioa_service_tags' => ioa_service_tags,
                            'service_tag' => chassisservicetag}
            debug_chassis_info = chassis_info.dup
            debug_chassis_info['chassis_password'] = '******'
            logger.debug "*** chassis_info : #{debug_chassis_info}"
            break
          end
        end
      end
      return chassis_info
    end

    def self.get_iom_type(server_cert_name, iom_cert_name, logger, options = {})
      chassis_info = {}
      url = chassis_ra_url(options[:url])
      logger.debug "URL : #{url}"
      data = ASM::Api::sign {
        RestClient.get(url, {:accept => :json})
      }
      ret = JSON.parse(data)
      ret.each do |chassis|
        serverinfo = chassis['servers']
        serverinfo.each do |server|
          logger.debug "server : #{server} : server_cert_name : #{server_cert_name}"
          updated_service_tag = server['serviceTag'].downcase
          logger.debug "updated_service_tag :: #{updated_service_tag} *** server_cert_name : #{server_cert_name}"
          if server_cert_name.downcase == updated_service_tag.downcase
            logger.debug "Found the matching server #{server['serviceTag']}"
            # Got chassis. get chassis information
            chassis_ip = chassis['managementIP']
            chassisvervicetag = chassis['serviceTag']
            chassisvervicetag = chassisvervicetag.downcase
            ioainfo = chassis['ioms']
            logger.debug "IOM info: #{ioainfo}"
            ioainfo.each do |ioa|
              ioaip = "dell_iom-"+"#{ioa['managementIP']}"
              model = ioa['model']
              if ioaip == iom_cert_name
                if model =~ /Aggregator|IOA/
                  ioatype = "ioa"
                elsif model =~ /MXL/
                  ioatype = "mxl"
                end
                return ioatype
              end
            end
          end
        end
      end
    end

    # Execute getVmInfo.pl script to find UUID for given VM name
    #
    # TODO: this will break if there is more than one VM with same name
    #
    # Sample output of perl script:
    #
    # VM uuid :423b35e8-61ef-3d16-5fae-75c189f4711b
    # VM power State :poweredOn
    # VM committed size :17244304694
    # VM Total number of Ethernet Cards :1
    # VM Provisioned size :83.3303845431656
    # VMNicNetworkMapping=1:HypMan28|*
    def self.find_vm_uuid(cluster_device, vmname, datacenter)
      # Have to use IO.popen because jruby popen3 does not accept
      # optional environment hash
      env = { 'PERL_LWP_SSL_VERIFY_HOSTNAME' => '0' }
      cmd = 'env'
      args = ["VI_PASSWORD=#{cluster_device[:password]}",'perl']
      args += [ '-I/usr/lib/vmware-vcli/apps',
        '/opt/Dell/scripts/getVmInfo.pl',
        '--url', "https://#{cluster_device[:host]}/sdk/vimService",
        '--username', cluster_device[:user],
        '--vmName', vmname, '--datacenter', datacenter
      ]

      stdout = nil
      IO.popen([ env, cmd, *args]) do |io|
        stdout = io.read
      end

      raise("Failed to execute getVmInfo.pl") unless stdout

      # Parse output into key-value pairs
      result_hash = {}
      stdout.lines.each do |line|
        kv = line.split(/:/, 2).map(&:strip)
        if kv and kv.size == 2
          result_hash[kv[0]] = kv[1]
        end
      end

      raise("Failed to find UUID from output: #{stdout}") unless result_hash['VM uuid']

      result_hash['VM uuid']
    end

    def self.facts_find(cert_name, logger = nil, options = {})
      # TODO: remove this stub
      require 'asm/client/puppetdb'
      ASM::Client::Puppetdb.new(options.merge(:logger => logger)).facts(cert_name)
    end

    def self.get_dellswitch_fabric_mode(cert_name, logger = nil)
      facts = facts_find(cert_name)
      switch_mode = facts['switch_fc_mode']
    end

    def self.get_cisconexus_features(cert_name, logger = nil)
      facts = facts_find(cert_name)
      switch_mode = facts['features']
    end

    def self.dell_s5000_get_activezoneset(cert_name, logger = nil)
      facts = facts_find(cert_name)
      activezoneset = facts['switch_fc_active_zoneset']
    end

    def self.cisco_nexus_get_vsan_activezoneset(cert_name, compellent_controllers, logger = nil)
      facts = facts_find(cert_name)
      activezoneset_info = facts['vsan_zoneset_info']
      activezoneset_info = JSON.parse(facts["vsan_zoneset_info"]) if activezoneset_info.is_a?(String)

      vsan = []
      ns_info = facts['nameserver_info']
      ns_info = JSON.parse(ns_info) if ns_info.is_a?(String)
      unless ns_info.empty?
        ns_info.each do |ns_i|
          sym_port_name = ns_i[4]
          if sym_port_name.include?('Compellent') and
          (sym_port_name.include?(compellent_controllers['controller1']) or
          sym_port_name.include?(compellent_controllers['controller2']) )
            vsan.push(ns_i[0])
          end
        end
      else
        vsan_member_info = facts["vsan_member_info"]
        vsan_member_info = JSON.parse(vsan_member_info) if vsan_member_info.is_a?(String)
        vsan = vsan_member_info.keys.find_all {|v| !['1','4079','4094'].include?(v)}
      end

      vsan = vsan.compact.uniq
      raise(Exeption,"Compellent ports are part of different VSAN") if vsan.size > 1
      active_zoneset = ''
      if !activezoneset_info.nil? or !activezoneset_info.empty?
        activezoneset_info.each do |zoneset_info|
          if zoneset_info[1] == vsan[0]
            active_zoneset = zoneset_info[0]
          end
        end
      end

      info = {
        'vsan' => vsan[0],
        'active_zoneset' => active_zoneset
      }
    end

    def self.dell_s5000_get_compellent_wwpn(cert_name, compellent_contollers, logger = nil)
      wwpn_info = []
      facts = facts_find(cert_name)
      ns_info = facts['remote_fc_device_info']
      if ns_info
        ns_info = JSON.parse(ns_info)
        ns_info.keys.each do |count|
          sym_port_name = ns_info[count]['sym_port_name']
          if sym_port_name.include?('Compellent') and
            (sym_port_name.include?(compellent_contollers['controller1']) or
              sym_port_name.include?(compellent_contollers['controller2']) )
            wwpn_info.push(ns_info[count]['port_name'])
          end
        end
      end
      wwpn_info
    end

    def self.dell_cisconexus_get_compellent_wwpn(cert_name, compellent_contollers, logger = nil)
      wwpn_info = []
      facts = facts_find(cert_name)
      ns_info = facts['nameserver_info']
      if ns_info
        ns_info = JSON.parse(ns_info)
        ns_info.each do |ns_i|
          sym_port_name = ns_i[4]
          if sym_port_name.include?('Compellent') and
          (sym_port_name.include?(compellent_contollers['controller1']) or
          sym_port_name.include?(compellent_contollers['controller2']) )
            wwpn_info.push(ns_i[2])
          end
        end
      end
      wwpn_info
    end

    def self.find_equallogic_iscsi_ip(cert_name)
      facts = facts_find(cert_name)
      general = JSON.parse(facts['General Settings'])
      unless general['IP Address']
        raise("Could not find iSCSI IP address for #{cert_name}")
      else
        general['IP Address']
      end
    end

    def self.find_compellent_iscsi_ip(cert_name,logger)
      compellent_iscsi_ip = []
      storage_center_facts = facts_find(cert_name)
      storage_center_serial_num = storage_center_facts['system_SerialNumber']
      logger.debug("storage_center_serial_num: #{storage_center_serial_num}")
      em_facts = find_em_facts_managing_sc(storage_center_serial_num,logger)
      iscsi_info = JSON.parse(em_facts['storage_center_iscsi_fact'])
      storage_center_iscsi_info = iscsi_info[storage_center_serial_num]
      ( storage_center_iscsi_info || [] ).each do |iscsi_info|
        # For fault domain interface, chapUser is not-null
        compellent_iscsi_ip.push(iscsi_info['ipAddress']) unless iscsi_info['chapName'].empty?
      end
      raise("Cannot find iscsi fault domain IP for #{cert_name}") if compellent_iscsi_ip.empty?
      compellent_iscsi_ip.compact.uniq
    end

    def self.find_em_facts_managing_sc(storage_center_serial_num,logger)
      ret_val = ''
      logger.debug("Storage center serial num : #{storage_center_serial_num}")
      ( find_storage_center_ems(logger) || [] ).each do |em|
        em_facts = facts_find(em)
        em_storage_centers = JSON.parse(em_facts['storage_centers'])
        ret_val = em_facts if em_storage_centers.include?(storage_center_serial_num.to_i)
      end
      raise("Could not find enterprise manager which is managing storage center #{storage_center_serial_num}") if ret_val.empty?
      ret_val
    end

    def self.find_storage_center_ems(logger)
      managed_devices = ASM::PrivateUtil.fetch_managed_inventory
      certs = []
      managed_devices.each do |managed_device|
        if (managed_device['deviceType'].downcase).match(/em|enterprisemanager/) and
            managed_device['state'] != 'UNMANAGED'
          certs.push(managed_device['refId'])
        end
      end
      logger.debug("EM Certs: #{certs}")
      certs
    end

    def self.find_equallogic_iscsi_volume(cert_name, volume)
      facts = facts_find(cert_name)
      properties = JSON.parse(facts['VolumesProperties'])
      unless properties[volume]
        raise("Could not find iSCSI volume properties for #{volume}")
      else
        JSON.parse(properties[volume])
      end
    end

    def self.find_compellent_controller_info(cert_name)
      facts = facts_find(cert_name)
      { 'controller1' => facts['controller_1_ControllerIndex'],
        'controller2' => facts['controller_2_ControllerIndex'] }
    end

    def self.find_compellent_volume_info(cert_name, compellent_vol_name, compellent_vol_folder, logger)
      logger.debug("Input compellent volume: #{compellent_vol_name}")
      logger.debug("Input compellent folder: #{compellent_vol_folder}")
      facts = facts_find(cert_name, logger)
      volume_data_json = facts['volume_data']
      unless volume_data_json
        msg = "Facts for compellent array #{cert_name} did not contain volume data"
        logger.error(msg) if logger
        raise(msg)
      end
      volume_data = JSON.parse(volume_data_json)
      volume_data.each do |volume_info|
        volume = volume_info[1]
        volume.each do |data|
          logger.debug("volume name from facts #{data['Name'][0]}")
          if (data['Name'][0] == compellent_vol_name)
            volume_device_id = data['DeviceID'][0]
            logger.debug("Compellent volume device id found : #{volume_device_id}")
            return volume_device_id
            break
          end
        end
      end
    end

    def self.find_netapp_volume_info(cert_name, netapp_vol_name, logger)
      volume_info = {}
      logger.debug("Input netapp volume: #{netapp_vol_name}") if logger
      facts = facts_find(cert_name, logger)
      volume_data_json = facts['volume_data']
      unless volume_data_json
        msg = "Facts for netapp array #{cert_name} did not contain volume data"
        logger.error(msg) if logger
        raise(msg)
      end
      volume_data = JSON.parse(volume_data_json)
      volume_data.each do |volume_info|
        vol_data = JSON.parse(volume_info[1])
        volume_name = vol_data['name']
        if volume_name == netapp_vol_name
          return vol_data
        end
      end
      volume_info
    end

    def self.update_vnx_resource_hash(storage_cert, r_hash, volume_name, logger)
      resource_hash = r_hash.dup
      facts = facts_find(storage_cert)
      pool_properties = JSON.parse(facts["pools_data"])
      pool_info = pool_properties["pools"]
      pool_info.each do |pools|
        pools["MLUs"].each do |lun|
          if lun["Name"] == volume_name
            resource_hash["asm::volume::vnx"][volume_name]["size"] = lun["UserCapacity"].to_i / (2 * 1024 * 1024)
            resource_hash["asm::volume::vnx"][volume_name]["pool"] = pools["Name"]
            break
          end
        end
      end
      resource_hash
    end

    def self.get_vnx_lun_id(storage_cert, volume_name, logger)
      lun_id = nil
      facts = facts_find(storage_cert)
      pool_properties = JSON.parse(facts["pools_data"])
      pool_info = pool_properties["pools"]
      pool_info.each do |pools|
        pools["MLUs"].each do |lun|
          lun_id = lun["Number"] if lun["Name"] == volume_name
        end
      end
      lun_id
    end

    def self.get_vnx_storage_group_info(storage_cert)
      facts = facts_find(storage_cert)
      storage_groups = ( facts["storage_groups"] || '' )
      JSON.parse(storage_groups) unless storage_groups.empty?
    end

    def self.is_host_connected_to_vnx(storage_cert, host_name, logger)
      is_host_connected = false
      2.times do
        facts = facts_find(storage_cert)
        JSON.parse(facts["controllers_data"])["controllers"].each do |controller|
          is_host_connected = true if controller["HostName"] == host_name
        end
        break if is_host_connected
        ASM::DeviceManagement.run_puppet_device!(storage_cert, logger)
        sleep(60)
      end
      is_host_connected
    end


    def self.update_compellent_resource_hash(storage_cert,r_hash,volume_name,logger)
      resource_hash = r_hash.dup
      facts = facts_find(storage_cert)
      volume_properties = JSON.parse(facts['volume_data'])
      vol_info = volume_properties['volume']
      vol_info.each do |v_info|
        if v_info['Name'][0] == volume_name
          volume_size = v_info['ConfigSize'][0]
          vol_size_data = volume_size.match(/(\d+).(\d+)\s+(\S+)/)
          resource_hash['asm::volume::compellent'][volume_name]['size'] = "#{vol_size_data[1]}#{vol_size_data[3]}"
          foldername = v_info['Folder'][0]
          foldername = '' if foldername.size == 0
          resource_hash['asm::volume::compellent'][volume_name]['volumefolder'] = foldername
          break
        end
      end
      resource_hash
    end

    def self.get_eql_volume_iqn(storage_cert,storage_title)
      target_iqn = ""
      facts = facts_find(storage_cert)
      volume_properties = facts['VolumesProperties']
      volume_data = JSON.parse(volume_properties)
      volume_data.keys.each do |vol_name|
        if vol_name == storage_title
          vol_data_json = JSON.parse(volume_data[vol_name])
          target_iqn = vol_data_json['TargetIscsiName']
        end
      end
      target_iqn
    end

    def self.is_target_boot_device_none?(target_boot_device)
      (target_boot_device || '').downcase.start_with?('none')
    end

    def self.append_resource_configuration!(resource, resources={}, options = {})
      options = {
        :title => nil,
        :type => resource['id'],
        :decrypt => false
      }.merge(options)

      raise(ArgumentError, 'resource found with no type') unless options[:type]

      options[:type] = options[:type].downcase
      resources[options[:type]] ||= {}

      param_hash = {}
      if resource['parameters'].nil?
        raise(ArgumentError, "resource of type #{options[:type]} has no parameters")
      else
        resource['parameters'].each do |param|
          #If the parameter is readOnly, it should be safe to ignore
          if param['readOnly']
            next
          end
          # Determine what field in param to use as the value
          case param['type']
            when 'NETWORKCONFIGURATION'
              # These params are populating either the networkConfiguration or
              # the networks field depending on the data contained
              key = ['networkConfiguration', 'networks'].reject { |key| param[key].nil? }.first
              val_to_write = param[key]
            when 'LIST', 'ENUMERATED'
              # VM workload networks come through as a list of structured network
              # data in the networks field. All other list params come through
              # as a comma-separated value string
              key = ['networks', 'value'].reject { |key| param[key].nil? }.first
              val_to_write = param[key]
            when 'BOOLEAN'
              val_to_write = param['value'].nil? ? nil : ASM::Util.to_boolean(param['value'])
            when 'RAIDCONFIGURATION'
              val_to_write = param['raidConfiguration']
            else
              val_to_write = param['value']
          end
          unless val_to_write.nil?
            id = param['id']
            #asm::bios settings need the capitalization to be left alone, to match up to what's expected in importsystemconfiguration
            id = id.downcase unless resource['id'] == 'asm::bios'
            param_hash[id] = val_to_write
          end
          if param['value'] and param['type'] == 'PASSWORD'
            param_hash['decrypt'] = options[:decrypt]
          end
        end
      end
      title = param_hash.delete('title')
      if options[:type] == 'class'
        title = resource['id']
      end
      if title
        if options[:title]
          raise(ArgumentError, "Generated title (#{options[:title]}) passed for resource with title #{title}")
        end
      else
        title = options[:title]
      end

      raise(ArgumentError, "Component has resource #{options[:type]} with no title") unless title

      if resources[options[:type]][title]
        raise(ArgumentError, "Resource #{options[:type]}/#{title} already existed in resources hash")
      end
      resources[options[:type]][title] = param_hash
      resources
    end

    # Build data appropriate for serializing to YAML and using for component
    # configuration via the puppet asm command.
    #
    # Valid +options+ are :type and :decrypt
    def self.build_component_configuration(component, options = {})
      resource_hash = {}
      resources = {}

      if component['resources']
        resources = ASM::Util.asm_json_array(component['resources'])
      else
        resources = ASM::Util.asm_json_array(component)
      end

      resources.each do |resource|
        resource_hash = append_resource_configuration!(resource, resource_hash, options)
      end
      resource_hash
    end

    # Call to puppet returns list of hots which look like
    #  + "dell_iom-172.17.15.234" (SHA256) CF:EE:DB:CD:2A:45:17:99:E9:C0:4D:6D:5C:C4:F0:4F:9D:F1:B9:E5:1B:69:3D:99:C2:45:49:5B:0F:F0:08:83
    # this strips all the information and just returns array of host names: "dell_iom-172.17.15.234", "dell_...."
    def self.get_puppet_certs
      ASM.wait_on_counter_threshold(large_process_concurrency, ASM::PrivateUtil.large_process_max_runtime, :large_child_procs) do
        exec = ASM::Util.run_command_success("sudo puppet cert list --all")

        output = exec.stdout
        result = output.split('+')
        result.reject!{|x| x.empty?}
        result.collect do |cert|
          cert.slice(0..(cert.index('(SHA256)')-1)).gsub(/"/,'').strip
        end.compact
      end
    end

    def self.check_host_list_against_previous_deployments(hostlist)
      dup_certs =  ASM.block_hostlist(hostlist)
      if dup_certs.empty?
        puppet_certs = self.get_puppet_certs
        dup_certs = hostlist & puppet_certs
      end
      dup_certs
    end

    def self.get_report(id, certname)
      report_dir = File.join(ASM.base_dir,
                             id.to_s,
                             'resources',
                             'state',
                             certname
                             )
      report_file = File.join(report_dir, 'last_run_report.yaml')
      out_file    = File.join(report_dir, 'last_run_report_summary.yaml')

      ASM.wait_on_counter_threshold(large_process_concurrency, ASM::PrivateUtil.large_process_max_runtime, :large_child_procs) do
        Puppet::Util.run_command_success("sudo puppet asm summarize_report --infile #{report_file} --outfile #{out_file}")
      end
      YAML.load_file(out_file)
    end

    def self.large_process_concurrency
      return 5 unless ASM::config
      return ASM.config.large_process_concurrency || 5
    end

    def self.large_process_max_runtime
      return 1800 unless ASM::config
      return ASM.config.large_process_max_runtime || 1800
    end

    def self.get_puppet_log(id, certname)
      log_file = File.join(ASM.base_dir, id.to_s, "#{certname}.out")
      File.read(log_file)
    end

    def self.get_puppet_component_run(id, certname)
      log_file = File.join(ASM.base_dir, id.to_s, "resources", "state", certname.to_s, "last_run_report.yaml")
      data = ""
      #Remove invalid json and re-write level
      File.read(log_file).each_line do |line|
        if line.include? "level: !ruby/sym"
          line.slice! "!ruby/sym "
          original_level = line.split("level: ")[1].chop
          case original_level
          when "debug"
            new_level = "info"
          when "notice","warning","alert"
            new_level = "warning"
          when "error","err","emerg","crit"
            new_level = "critical"
          else
            new_level = original_level
          end
          data << line.gsub(original_level,new_level)
        elsif line.include? "!ruby/"
          split_line = line.split "!ruby/"
          new_line = "#{split_line[0]}\n"
          data << new_line
        else
          data << line
        end
      end
      yaml_data = YAML::load(data)
      #Convert time and delete logs of fact loading
      good_logs = []
      yaml_data["logs"].each_with_index do |log,i|
        if !log["message"][/(Loading facts in|Debug: \/File\[\/var\/opt\/lib)/]
          converted_time = Time.parse(log["time"].to_s).iso8601
          log["time"] = converted_time.to_s
          good_logs << log
        end
      end
      JSON.dump(good_logs)
    end

    # This function waits for a puppet device to become available
    def self.wait_until_available(cert_name, timeout = ASM::PrivateUtil.large_process_max_runtime, logger=nil, &block)
      begin
        start = Time.now
        yet_to_run_command = true
        sync_error = false

        while(yet_to_run_command)
          if ASM.block_certname(cert_name)
            yet_to_run_command = false
            ASM.wait_on_counter_threshold(large_process_concurrency, timeout, :large_child_procs, logger) do
              yield
            end
          else
            sleep 2
            if Time.now - start > timeout
              raise(SyncException, "Timed out waiting for a lock for device cert #{cert_name}")
            end
          end
        end
      rescue SyncException
        sync_error = true
        raise
      ensure
        ASM.unblock_certname(cert_name) unless sync_error
      end
    end

    # @note Ported to Type::Server#write_node_data
    def self.write_node_data(certname, config)
      # Write the node_data only when there is difference between the existing content
      # This will help in finding the create / modify time of the file
      filename = File.join(NODE_DATA_DIR, "#{certname}.yaml")
      if File.file?(filename)
        return true if File.read(filename).strip == config.to_yaml.strip
      end
      File.write(filename, config.to_yaml)
    end

    # Removes a given component hash from a node_data file
    #
    # @param certname [String] the agent-certname
    # @param component_hash [Hash] raw component hash
    # @param logger [Logger]
    # @return [Boolean]
    def self.remove_from_node_data(certname, component_hash, logger=nil)
      if (node_data = read_node_data(certname))
        begin
          node_hash = YAML.load(node_data)
          config = node_hash.values.first
          component = component_hash.keys.first
          component_title = component_hash.values.first.keys.first
          # Check resources first
          if config.fetch("resources", {}).fetch(component, {}).fetch(component_title, nil)
            config["resources"][component].delete(component_title)
            config["resources"].delete(component) if config["resources"][component].empty?
            require_string = "#{component.split('::').each(&:capitalize!).join('::')}['#{component_title}']"
          else
            config["classes"].delete(component)
            require_string = "Class['#{component}']"
          end
          # Remove corresponding require parameters
          if config["resources"]
            resources = config["resources"].select {|k,v| v.values.first["require"] == require_string}
            resources.each do |resource,value|
              name = resource
              title = value.keys.first
              config["resources"][name][title].delete("require")
            end
          end
          write_node_data(certname, {certname => config})
        rescue => e
          logger.error("Failed to remove data from node_data #{certname} with #{e.message}")
          return false
        end
        true
      else
        logger.error("Node data #{certname} does not exist")
        false
      end
    end

    # @note ported to Type::Server#node_data_time
    def self.node_data_update_time(certname)
      filename = File.join("/etc/puppetlabs/puppet/node_data", "#{certname}.yaml")
      raise("Node data #{filename} does not exists") unless File.file?(filename)
      File.mtime(filename)
    end

    # @note ported to Type::Server#node_data
    def self.read_node_data(cert_name)
      file_name = File.join(NODE_DATA_DIR, "#{cert_name}.yaml")
      File.readable?(file_name) ? File.read(file_name) : nil
    end

    def self.get_mxl_portchannel(certname,facts={})
      facts = facts_find(certname) if facts.empty?
      port_channel = (facts['port_channel_members'] || [] )
      if !port_channel.empty?
        port_channel = JSON.parse(port_channel)
      end
    end

    def self.get_mxl_vlan(certname,facts={})
      facts = facts_find(certname) if facts.empty?
      port_channel = (facts['vlan_information'] || [] )
      if !port_channel.empty?
        port_channel = JSON.parse(port_channel)
      end
    end

    def self.get_network_info(options = {})
      url = networks_ra_url(options[:url])
      data = ASM::Api::sign {
        RestClient.get(url, {:accept => :json})
      }
      ret = JSON.parse(data)
    end

    def self.hyperv_cluster_hostgroup(cert_name, cluster_name)
      conf = ASM::DeviceManagement.parse_device_config(cert_name)
      domain, user = conf['user'].split('\\')
      cmd = File.join(File.dirname(__FILE__),'scvmm_cluster_information.rb')
      args = [cmd, '-u', user, '-d', domain, '-p', conf['password'], '-s', conf['host'], '-c', cluster_name]
      result = ASM::Util.run_with_clean_env("/opt/puppet/bin/ruby", false, *args)
      host_group = 'All Hosts'
      result.stdout.split("\n").reject{|l|l.empty? || l == "\r"}.drop(2).each do |line|
        host_group = $1 if line.strip.match(/hostgroup\s*:\s+(.*)?$/i)
      end
      host_group
    end

    def self.connect_rest(endpoint, options=nil)
      options ||= ASM.config.rest_client_options
      RestClient::Resource.new(endpoint, options)
    end

    def self.query(base_url, action, method, data=nil)
      response = nil
      conn = self.connect_rest("#{base_url}")
      data ||= {}
      request = data.to_json
      if method == 'put'
        response = conn[action].put request, {:content_type => :json, :accept => :json}
      elsif method == 'get'
        response = conn[action].get
      end
      unless response.code == 200
        raise(Exception, "Error: http status code #{response.code}\n#{response.to_str}")
      end
      response
    end

    def self.fetch_cisco_nexus_switches
      managed_devices = ASM::PrivateUtil.fetch_managed_inventory()
      certs = []
      managed_devices.each do |managed_device|
        if managed_device['deviceType'] == 'genericswitch' &&
            managed_device['state'] != 'UNMANAGED' &&
            managed_device['refId'].match(/cisconexus/)
          certs.push(managed_device['refId'])
        end
      end
      certs
    end

    def self.fetch_cisco_nexus_fex(ioa_service_tag,ioa_slot)
      cisco_nexus_fex = ''
      (fetch_cisco_nexus_switches || [] ).each do |switch|
        switch_facts = ASM::PrivateUtil.facts_find(switch)
        fex = JSON.parse(switch_facts['fex'])
        next if fex.empty?
        fex.each do |fex|
          fex_chassis_info = JSON.parse(switch_facts['fex_info'])
          if ( fex_chassis_info[fex]['Service Tag'] == ioa_service_tag &&
              fex_chassis_info[fex]['Enclosure'] == "Dell M1000e Slot #{ioa_slot}")
            cisco_nexus_fex = switch
            break unless cisco_nexus_fex.empty?
          end
        end
      end
      cisco_nexus_fex
    end

    def self.get_cisco_nexus_fex_interfaces(switch_facts,ioa_slot,server_slot)
      fex_interface = ''
      fex = JSON.parse(switch_facts['fex'])
      fex.each do |f|
        local_fex_interface = "Eth#{f}/1/#{server_slot}"
        fex_chassis_info = JSON.parse(switch_facts['fex_info'])
        fex_interfaces = fex_chassis_info[f]['Interfaces']
        if ( fex_chassis_info[f]['Enclosure'] == "Dell M1000e Slot #{ioa_slot}") &&
            (fex_interfaces.include?(local_fex_interface))
          fex_interface = local_fex_interface
        end
      end
      fex_interface
    end

    def self.create_serverdata(cert_name, data)
      server_data_dir = File.join(ASM.base_dir,
                                  'serverdata')
      server_data_file = File.join(server_data_dir, "#{cert_name}.data")
      Dir.mkdir(server_data_dir,0700) unless Dir.exist?(server_data_dir)
      File.write(server_data_file, data)
    end

    def self.get_serverdata(cert_name)
      server_data_dir = File.join(ASM.base_dir,
                                  'serverdata')
      server_data_file = File.join(server_data_dir, "#{cert_name}.data")
      File.exist?(server_data_file) ? File.read(server_data_file) : nil
    end

    def self.delete_serverdata(cert_name, logger=nil)
      begin
        server_data_dir = File.join(ASM.base_dir,
                                    'serverdata')
        server_data_file = File.join(server_data_dir, "#{cert_name}.data")
        File.delete(server_data_file) if File.exist?(server_data_file)
      rescue
        logger.error("Failed to delete server data for %s" % [cert_name]) if logger
      end
    end

    def self.serverdata_dir
      File.join(ASM.base_dir, 'serverdata')
    end

    def self.clean_old_file(file_path, modify_time=14400)
      files = Dir[File.join(file_path,"/*")] || []
      files.each do |file|
        File.delete(file) if ( Time.now.to_i - File.mtime(file).to_i) > modify_time
      end

    end

    def self.uuid
      string ||= OpenSSL::Random.random_bytes(16).unpack('H*').shift

      uuid_name_space_dns = "\x6b\xa7\xb8\x10\x9d\xad\x11\xd1\x80\xb4\x00\xc0\x4f\xd4\x30\xc8"

      sha1 = Digest::SHA1.new
      sha1.update(uuid_name_space_dns)
      sha1.update(string)

      # first 16 bytes..
      bytes = sha1.digest[0, 16].bytes.to_a

      # version 5 adjustments
      bytes[6] &= 0x0f
      bytes[6] |= 0x50

      # variant is DCE 1.1
      bytes[8] &= 0x3f
      bytes[8] |= 0x80

      bytes = [4, 2, 2, 2, 6].collect do |i|
        bytes.slice!(0, i).pack('C*').unpack('H*')
      end

      bytes.join('-')
    end

    def self.domain_password_token(token_string, os_host_name)
      token_data = ASM::Cipher.create_token(token_string)
      component_cert_name = ASM::Util.hostname_to_certname(os_host_name)
      ASM::PrivateUtil.create_serverdata(component_cert_name, token_data.to_json)
      token_data['token']
    end

  end
end

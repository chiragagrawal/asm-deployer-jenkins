module ASM
  class Provider
    class Cluster
      class Vmware < Provider::Base
        puppet_type "asm::cluster"

        property :datacenter,         :default => nil,                        :validation => String
        property :cluster,            :default => nil,                        :validation => String
        property :vcenter_options,    :default => {"insecure" => true},       :validation => Hash
        property :ensure,             :default => "present",                  :validation => ["present", "absent"]
        property :vsan_enabled,       :default => false,                      :validation => :boolean
        property :vds_enabled,        :default => "standard",                 :validation => String,   :tag => :extra
        property :sdrs_config,        :default => false,                      :validation => :boolean, :tag => :extra
        property :sdrs_name,          :default => nil,                        :validation => String,   :tag => :extra
        property :sdrs_members,       :default => nil,                        :validation => String,   :tag => :extra

        def json_facts
          super + [
            "inventory",
            "storage_profiles"
          ]
        end

        def to_puppet
          resources = super
          resources.merge!(sdrs_resources) if sdrs_config && self.ensure == "present"

          resources.delete("asm::cluster::vds")
          resources
        end

        def should_inventory?
          !!type.guid
        end

        def update_inventory
          raise("Cannot update inventory for %s without a guid" % type.puppet_certname) unless type.guid

          ASM::PrivateUtil.update_asm_inventory(type.guid) unless debug?
        end

        def virtualmachine_supported?(vm)
          vm.provider_path == "virtualmachine/vmware"
        end

        def evict_related_servers!
          type.related_servers.each do |server|
            logger.info("Removing server %s from VDS configuration of cluster %s that is being torn down" % [server.puppet_certname, type.puppet_certname])
            evict_vds!(server)
          end
        end

        def evict_vsan_cluster_servers!
          evict_vsan!
        end

        def prepare_for_teardown!
          begin
            evict_vsan_cluster_servers! if vsan_enabled
            evict_related_servers! if vds_enabled == "distributed"
          rescue
            logger.info("Error removing VDS configuration for cluster %s: with error %s" % [$!.message, $!.backtrace])
          end
          true
        end

        def evict_server!(server)
          puppet_hash = asm_host_hash(server, "absent", true)

          logger.debug("Removing server %s from the cluster %s" % [server.puppet_certname, type.puppet_certname])

          type.process_generic(server.puppet_certname, puppet_hash, puppet_run_type, true)
        end

        def evict_vds!(server)
          unless vds_enabled == "distributed"
            logger.info("Skipping VDS eviction of server %s as VDS is not enabled (%s)" % [server.puppet_certname, vds_enabled])
            return
          end

          logger.info("Configuring VDS eviction of server %s as VDS is enabled (%s)" % [server.puppet_certname, vds_enabled])

          next_require = []

          v_hash = vds_hash(server, true)
          v_hash["vcenter::dvswitch"].keys.each do |key|
            next_require.push("Vcenter::Dvswitch[#{key}]")
          end
          logger.info("Removing server from VDS %s from the cluster %s" % [server.puppet_certname, type.puppet_certname])

          type.process_generic(server.puppet_certname, v_hash, puppet_run_type, true)
        end

        def evict_vsan!(server=nil)
          return false unless vsan_enabled

          if server
            logger.info("Configuring VSAN eviction of server %s as VSAN is enabled" % [server.puppet_certname])
            hostname = server.lookup_hostname
            type.process_generic(server.puppet_certname, vsan_hash(hostname), puppet_run_type, true)
          else
            logger.info("Configuring VSAN eviction of cluster %s as VSAN is enabled" % [type.puppet_certname])
            begin
              type.process_generic(type.puppet_certname, vsan_hash, puppet_run_type, true)
            rescue
              logger.info("Failure encountered during VSAN teardown of %s. Will retrying after 120 seconds: %s: %s" % [type.puppet_certname, $!.class, $!.to_s])
              sleep(120)
              type.process_generic(type.puppet_certname, vsan_hash, puppet_run_type, true)
            end

          end
        end

        # Removes a volume from a VMWare cluster, these volumes need to be removed from
        # every server and the data store resource is specific to the type of storage so
        # using the Type::Volume#esx_datastore helper it construct the correct esx_datastore
        # resource for every server and then run them all together
        #
        # Servers that are being torndown is skipped as they'd already be gone or going away
        # in the same deployment so there's no need
        def evict_volume!(volume)
          resources = {}

          type.related_servers.each do |server|
            unless server.teardown?
              logger.debug("Removing volume %s from server %s for cluster %s" % [volume.puppet_certname, server.puppet_certname, type.puppet_certname])
              resources.merge!(volume.esx_datastore(server, type, "absent"))
            end
          end

          unless resources.empty?
            resources.merge!(transport_config)
            type.process_generic(type.puppet_certname, resources, puppet_run_type, true, nil, type.guid)
          end
        end

        # Return asm::cluster::vds resource associated with the cluster VMware cluster component
        #
        # @return [Hash] asm::cluster::vds
        def existing_vds
          type.component_configuration["asm::cluster::vds"]
        end

        # Generates a transport configuration used by Puppet
        #
        # @param name [String] The name of the vcenter instance, defaults to the cert name
        # @return [Hash] a transport structure, usually combined with other data
        def transport_config(name=nil)
          name ||= type.puppet_certname

          {
            "transport" => {
              "vcenter" => {
                "name" => name,
                "options" => {"insecure" => true},
                "provider" => "device_file"
              }
            }
          }
        end

        def host_username
          ASM::ServiceDeployment::ESXI_ADMIN_USER
        end

        def asm_host_hash(server, host_ensure, include_transport=false)
          name = server.puppet_certname

          resource_hash = {
            "asm::host" => {
              name => {
                "datacenter" => datacenter,
                "cluster" => cluster,
                "hostname" => server.lookup_hostname,
                "username" => host_username,
                "password" => server.admin_password,
                "decrypt" => type.deployment.decrypt?,
                "timeout" => 90,
                "ensure" => host_ensure
              }
            }
          }

          # With teardown/brownfield, not every parameter will necessarily have a value, particularly password
          resource_hash["asm::host"][name].reject! { |_, v| v.nil? }

          include_transport ? resource_hash.merge(transport_config) : resource_hash
        end

        # Returns VDS and VMKs already configured on the ESXi server
        #
        # @param server [Type::Server] ESXi host
        # @return [Array] Array of VDS and vmnics
        # @raise [StandardError] when ESXCLI command fails to get VDS info
        def vds_vmk_nics(server)
          esx_endpoint = {
            :host => server.lookup_hostname,
            :user => host_username,
            :password => ASM::Cipher.decrypt_string(server.admin_password)
          }

          command = %w(network vswitch dvs vmware list)
          begin
            vds_info = ASM::Util.esxcli(command, esx_endpoint, nil, true)
          rescue
            logger.debug("Error while executing command '%s', this can be ignored when the server is not accessible: %s" % [command.join(" "), $!.to_s])
            vds_info = ""
          end

          vmk_nics = (vds_info.scan(/^\s*Client:\s*(vmk\S+)/) || []).flatten
          vds_switches = (vds_info.scan(/^(\S+)/) || []).flatten

          [vds_switches, vmk_nics]
        end

        # Return uplink vmnics associated with a VDS
        #
        # @param server [Type::Server] ESXi host
        # @param vds_name [String] VDS Name for which uplinks are requested
        # @return [Array] array of vmnics
        # @raise [StandardError] when ESXCLI command fails to get VDS info
        def vds_uplinks(server, vds_name)
          vds_uplink = []

          esx_endpoint = {
            :host => server.lookup_hostname,
            :user => host_username,
            :password => ASM::Cipher.decrypt_string(server.admin_password)
          }

          command = %w(network vswitch dvs vmware list --vds-name) << vds_name
          begin
            vds_info = ASM::Util.esxcli(command, esx_endpoint, nil, true)
            vds_nics = (vds_info.scan(/^\s*Uplinks:\s*(.*?)$/) || []).flatten.first
            vds_uplink = vds_nics.split(",").map(&:strip)
          rescue
            logger.debug("Error while executing command '%s', this can be ignored when the server is not accessible: %s" % [command.join(" "), $!.to_s])
          end

          vds_uplink.sort
        end

        # Return VDS resource for teardown
        #
        # @param server [Type::Server] ESXi host
        # @param include_transport [Boolean] includes the transport config when true
        # @return [Hash] Resource Hash for Management VDS switch teardown
        def vds_hash(server, include_transport=false)
          vds_vmk_nics_info = vds_vmk_nics(server)
          esx_maintmode_require = []
          server_hostname = server.lookup_hostname

          resource_hash = {
            "vcenter::vmknic" => {},
            "esx_maintmode" => {},
            "vcenter::dvswitch" => {}
          }

          vds_vmk_nics_info[1].each do |vmk_nic|
            next if vmk_nic == "vmk0"

            name = "%s:%s" % [server_hostname, vmk_nic]

            resource_hash["vcenter::vmknic"][name] = {
              "ensure" => "absent",
              "transport" => "Transport[vcenter]"
            }

            esx_maintmode_require.push("Vcenter::Vmknic[%s]" % name)
          end

          resource_hash["esx_maintmode"] = {
            server_hostname => {
              "ensure" => "present",
              "evacuate_powered_off_vms" => true,
              "timeout" => 0,
              "transport" => "Transport[vcenter]"
            }
          }

          resource_hash["esx_maintmode"][server_hostname]["require"] = esx_maintmode_require unless esx_maintmode_require.empty?

          next_require = "Esx_maintmode[%s]" % server_hostname

          management_vds_name = vds_name([server.management_network])
          logger.debug("Management vds name : %s" % [management_vds_name])

          vds_vmk_nics_info[0].each do |l_vds_name|
            next if l_vds_name == management_vds_name

            name = "/%s/%s" % [datacenter, l_vds_name]

            resource_hash["vcenter::dvswitch"][name] = {
              "ensure" => "present",
              "transport" => "Transport[vcenter]",
              "spec" => {
                "host" => host_update_spec(server_hostname, "remove")
              },
              "require" => next_require
            }

            next_require = "Vcenter::Dvswitch[%s]" % name
          end

          # Need to migrate the management vmkernel to vswitch before removing the host
          if vds_vmk_nics_info[1].include?("vmk0")
            management_hash = management_vds_hash(server, next_require)

            ["vcenter::dvswitch", "esx_vswitch", "esx_portgroup", "vcenter::vmknic"].each do |property|
              resource_hash[property] ||= {}
              resource_hash[property].merge!(management_hash[property])
            end
          end

          include_transport ? resource_hash.merge(transport_config) : resource_hash
        end

        # Returns array with a hash required to update status of host in VDS
        #
        # @param hostname [String] Hostname of ESXi host
        # @param operation [String] add / remove / edit
        # @return [Array<Hash>] Hash for host update spec
        def host_update_spec(hostname, operation)
          [
            {
              "host" => hostname,
              "operation" => operation
            }
          ]
        end

        # Return management dvswitch VDS resource for teardown
        #
        # @param hostname [String] Hostname of ESXi host
        # @param management_vds_uplink [String] Management vmnic that needs to retained to management VDS
        # @param vds_name [String] Management VDS Name
        # @param next_require [String] Next require information to be added in the resource hash
        # @return [Hash] Resource Hash for Management VDS switch teardown
        def dv_switch_spec(hostname, management_vds_uplink, vds_name, next_require)
          {
            "ensure" => "present",
            "transport" => "Transport[vcenter]",
            "require" => next_require,
            "spec" => {
              "host" => [
                {
                  "host" => hostname,
                  "operation" => "edit",
                  "backing" => {
                    "pnicSpec" => [
                      {
                        "pnicDevice" => management_vds_uplink,
                        "uplinkPortgroupKey" => "#{vds_name}-uplink-pg"
                      }
                    ]
                  }
                }
              ]
            }
          }
        end

        # Returns hash required to create vswitch
        #
        # @param vswitch_vmnic [String] vmnics that needs to be added vswitch
        # @param next_require [String] Next require information to be added in the resource hash
        # @return [Hash] Resource Hash for vSwitch configuration
        def vswitch_spec(vswitch_vmnic, next_require)
          {
            "path" => "/#{datacenter}",
            "nics" => [vswitch_vmnic],
            "nicorderpolicy" => {
              "activenic" => [vswitch_vmnic]
            },
            "transport" => "Transport[vcenter]",
            "require" => next_require
          }
        end

        # Returns hash required to create vswitch portgroup
        #
        # @param vswitch [String] vSwitch name where port-group needs to be created
        # @param vlan_id [String] VLAN ID that needs to be associated with port-group
        # @param next_require [String] Next require information to be added in the resource hash
        # @return [Hash] Resource Hash for vSwitch port-group configuration
        def vswitch_portgroup_spec(vswitch, vlan_id, next_require)
          {
            "vswitch" => vswitch,
            "path" => "/#{datacenter}/#{cluster}/",
            "vlanid" => vlan_id,
            "transport" => "Transport[vcenter]",
            "require" => next_require
          }
        end

        # Returns hash required to create vswitch portgroup vmkernel configuration
        #
        # @param port_group_name [String] Port-group name
        # @param vlan_id [String] VLAN ID that needs to be associated with port-group
        # @param next_require [String] Next require information to be added in the resource hash
        # @return [Hash] Resource Hash for vSwitch port-group configuration
        def vswitch_vmk_nic_spec(port_group_name, vlan_id, next_require)
          {
            "ensure" => "present",
            "hostVirtualNicSpec" => {
              "portgroup" => port_group_name,
              "vlanid" => vlan_id
            },
            "transport" => "Transport[vcenter]",
            "require" => next_require
          }
        end

        # Return management network VDS resource for teardown
        #
        # @param server [Type::Server] ESXi host
        # @param next_require [String] Next require information to be added in the resource hash
        # @return [Hash] Resource Hash for Management VDS switch teardown
        def management_vds_hash(server, next_require)
          server_hostname = server.lookup_hostname
          management_vds_name = vds_name([server.management_network])
          management_vds_uplinks = vds_uplinks(server, management_vds_name)
          name = "/%s/%s:run1" % [datacenter, management_vds_name]

          resource_hash = {
            "vcenter::dvswitch" => {},
            "esx_vswitch" => {},
            "esx_portgroup" => {},
            "vcenter::vmknic" => {}
          }

          resource_hash["vcenter::dvswitch"][name] = dv_switch_spec(server_hostname, management_vds_uplinks[0], management_vds_name, next_require)

          next_require = "Vcenter::Dvswitch[%s]" % name

          # Create vSwitch0 with Management Network port-group and vmnic1 as uplink
          management_backup_vmnic = get_management_backup_vmnic(server_hostname, management_vds_uplinks)
          name = "%s:vSwitch0" % server_hostname
          resource_hash["esx_vswitch"][name] = vswitch_spec(management_backup_vmnic, next_require)
          next_require = "Esx_vswitch[%s]" % name

          # TODO: Find management network VLAN ID
          management_network_vlan_id = server.management_network["vlanId"]
          name = "%s:Management Network" % server_hostname

          resource_hash["esx_portgroup"][name] = vswitch_portgroup_spec("vSwitch0", management_network_vlan_id, next_require)
          next_require = "Esx_portgroup[%s]" % name

          # Migrate vmk0 from VDS to vSwitch
          name = "%s:vmk0" % server_hostname
          resource_hash["vcenter::vmknic"][name] = vswitch_vmk_nic_spec("Management Network", management_network_vlan_id, next_require)
          next_require = "vcenter::vmknic[%s]" % name

          # Remove vmnic0 from VDS
          name = "/%s/%s:run2" % [datacenter, management_vds_name]

          resource_hash["vcenter::dvswitch"][name] = {
            "ensure" => "present",
            "transport" => "Transport[vcenter]",
            "require" => next_require,
            "spec" => {
              "host" => host_update_spec(server_hostname, "edit")
            }
          }

          next_require = "Vcenter::Dvswitch[%s]" % name

          # Remove host from management VDS
          name = "/%s/%s:run3" % [datacenter, management_vds_name]
          resource_hash["vcenter::dvswitch"][name] = {
            "ensure" => "present",
            "transport" => "Transport[vcenter]",
            "spec" => {
              "host" => host_update_spec(server_hostname, "remove")
            },
            "require" => next_require
          }

          resource_hash
        end

        # Identify backup vmnic that needs to be associated with vSwitch0 while migrating the vmk0.
        #
        # If management vds uplinks has two vmnics then return the second vmnic as backup vmnic
        # in case second vmnic is not configured then get the value from the input defined in the deployment template
        #
        # @param hostname [String] ESXi SSH Username
        # @param management_vds_uplinks [Array] Array of VMNICS associated with manangement VDS
        # @return [String] Management VDS backup uplink
        def get_management_backup_vmnic(hostname, management_vds_uplinks)
          return management_vds_uplinks[1] unless management_vds_uplinks[1].nil?
          logger.info("Management backup vmnic not configured. Retrieve value from deployment input")

          esx_vmnics = type.deployment.esx_vmnic_info(type.component)
          esx_vmnics[hostname].find { |team| team[:management] }[:management][:vmnics].last
        end

        # Get the VDS name specified from the template
        #
        # @param networks [Array] list of networks to find vds_names for
        # @param vds_params [Hash] Hash of asm::cluster::vds having VDS and DV Portgroup name
        # @param cluster_cert [String] Certname of the cluster component
        # @return [String] VDS name provided in the deployment
        def vds_name(networks, vds_params=nil, cluster_cert=nil)
          cluster_cert ||= type.puppet_certname
          vds_params ||= existing_vds
          network_ids = networks.collect { |network| network["id"] }.flatten
          vds_id = vds_params[cluster_cert].keys.find do |id, _value|
            # vds name will be of the form vds_name::network_id1:network_id2:...::1
            id.start_with?("vds_name:") && network_ids.all? { |network_id| id.include?(network_id)}
          end
          vds_params[cluster_cert][vds_id]
        end

        # Return VSAN resource for teardown
        #
        # @param server_hostname [String, nil] Specific hostname or nil, wben cluster vsan needs to disabled
        # @return [Hash] Resource Hash for Management VDS switch teardown
        def vsan_hash(server_hostname=nil)
          resource_hash = {"vc_vsan" => {}, "esx_maintmode" => {}, "vc_vsan_disk_initialize" => {}}
          resource_hash.merge!(vc_vsan_resource(type.puppet_certname, "present"))
          next_require = "Vc_vsan[%s]" % type.puppet_certname

          if server_hostname.nil?
            type.related_servers.each do |server|
              hostname = server.lookup_hostname
              resource_hash = resource_hash.deep_merge(esx_maint_mode_resource(hostname, next_require))
              next_require = "Esx_maintmode[%s]" % hostname
            end
          else
            resource_hash = resource_hash.deep_merge(esx_maint_mode_resource(server_hostname, next_require))
            next_require = "Esx_maintmode[%s]" % server_hostname
          end

          resource_hash.merge!(vc_vsan_disk_init_resource(next_require))

          unless server_hostname.nil?
            resource_hash["vc_vsan_disk_initialize"][type.puppet_certname]["cleanup_hosts"] = [server_hostname]
          end

          resource_hash = resource_hash.deep_merge(vc_vsan_resource("#{type.puppet_certname}restore", "absent"))
          resource_hash["vc_vsan"]["#{type.puppet_certname}restore"]["require"] = "Vc_vsan_disk_initialize[%s]" % type.puppet_certname
          resource_hash = resource_hash.deep_merge(transport_config)
        end

        def vc_vsan_disk_init_resource(next_require)
          {
            "vc_vsan_disk_initialize" => {
              type.puppet_certname => {
                "ensure" => "absent",
                "cluster" => cluster,
                "datacenter" => datacenter,
                "transport" => "Transport[vcenter]",
                "require" => next_require
              }
            }
          }
        end

        def vc_vsan_resource(resource_name, vc_vsan_ensure)
          {
            "vc_vsan" => {
              resource_name => {
                "ensure" => vc_vsan_ensure,
                "auto_claim" => "false",
                "cluster" => cluster,
                "datacenter" => datacenter,
                "transport" => "Transport[vcenter]"
              }
            }
          }
        end

        def esx_maint_mode_resource(hostname, next_require)
          resource = {
            "esx_maintmode" => {
              hostname => {
                "ensure" => "present",
                "evacuate_powered_off_vms" => true,
                "timeout" => 0,
                "transport" => "Transport[vcenter]",
                "require" => next_require
              }
            }
          }

          resource["esx_maintmode"][hostname]["vsan_action"] = "noAction" if vsan_enabled

          resource
        end

        def sdrs_resource(require_list)
          {
            "vc_storagepod" => {
              sdrs_name => {
                "ensure" => type.teardown? ? "absent" : "present",
                "datacenter" => datacenter,
                "drs" => true,
                "datastores" => sdrs_member_names,
                "transport" => "Transport[vcenter]",
                "require" => require_list
              }
            }
          }
        end

        def sdrs_member_names
          type.related_volumes.map {|m| m.uuid if sdrs_members.split(",").include?(m.id)}.reject(&:empty?)
        end

        def sdrs_resources
          require_list = []
          type.related_servers.each do |server|
            server.related_volumes.each do |volume|
              next unless sdrs_members.include?(volume.id)
              require_list += volume.datastore_require(server)
            end
          end
          sdrs_resource(require_list)
        end
      end
    end
  end
end

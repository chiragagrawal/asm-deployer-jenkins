require "asm/network_configuration"
require "asm/wsman"
require "asm/ipmi"
require "asm/util"
require "asm/ipxe_builder"

module ASM
  class Provider
    class Server
      class Server < Provider::Base
        puppet_type "asm::server"

        property :razor_image,              :default => nil,        :validation => String
        property :admin_password,           :default => nil,        :validation => String
        property :os_host_name,             :default => nil,        :validation => String
        property :serial_number,            :default => nil,        :validation => String
        property :policy_name,              :default => nil,        :validation => String
        property :os_image_type,            :default => nil,        :validation => String
        property :os_image_version,         :default => nil,        :validation => String
        property :broker_type,              :default => "noop",     :validation => String
        property :ensure,                   :default => "present",  :validation => ["present", "absent"]
        property :decrypt,                  :default => false,      :validation => :boolean
        property :installer_options,        :default => {},         :validation => Hash
        property :esx_mem,                  :default => "",         :validation => String
        property :local_storage_vsan,       :default => false,      :validation => :boolean
        property :razor_api_options,        :default => nil,        :validation => Hash
        property :client_cert,              :default => nil,        :validation => String

        property :domain_admin_user,        :default => nil,        :validation => String,  :tag => [:hyperv, :installer_options]
        property :domain_admin_password,    :default => nil,        :validation => String,  :tag => [:hyperv, :installer_options]
        property :domain_name,              :default => nil,        :validation => String,  :tag => [:hyperv, :installer_options]
        property :fqdn,                     :default => nil,        :validation => String,  :tag => :hyperv
        property :local_storage_vsan_type,  :default => nil,        :validation => String,  :tag => :extra

        property :ntp_server,               :default => nil,        :validation => String,  :tag => :installer_options
        property :os_type,                  :default => nil,        :validation => String,  :tag => :installer_options
        property :language,                 :default => nil,        :validation => String,  :tag => :installer_options
        property :keyboard,                 :default => nil,        :validation => String,  :tag => :installer_options
        property :product_key,              :default => nil,        :validation => String,  :tag => :installer_options
        property :time_zone,                :default => nil,        :validation => String,  :tag => :installer_options # linux
        property :timezone,                 :default => nil,        :validation => String,  :tag => :installer_options # hyperv

        BOOT_FROM_SAN_TARGETS = ["FC", "iSCSI"].freeze

        # The deployment includes component resources that are not strictly resources
        # but are instead used to convey information for the rest of the deployment,
        # so a special case to_puppet here will remove those when they exist leaving
        # only asm::server
        def to_puppet
          Hash[super.select do |key|
            key == "asm::server"
          end]
        end

        def model
          type.retrieve_inventory["model"]
        end

        def configure_hook
          self[:serial_number] ||= type.cert2serial
          self[:razor_api_options] ||= ASM.config.http_client_options || {}
          self[:razor_api_options]["url"] ||= "%s/api" % ASM.config.url.razor
          self[:client_cert] ||= ASM.config.client_cert
        end

        def policy_name_prefetch_hook
          self[:policy_name] ||= ("policy-%s-%s" % [hostname, type.deployment.id]).downcase
        end

        def installer_options_prefetch_hook
          return unless self[:installer_options].empty?

          properties(:installer_options).each do |option|
            self[:installer_options][option] = self[option] if self[option]
          end

          self[:installer_options]["os_type"] = self[:os_image_type]
          self[:installer_options]["agent_certname"] = hostname_to_certname if hostname
          self[:installer_options]["network_configuration"] = type.network_config.to_hash.to_json
        end

        def wwpns
          return fc_wwpns if type.fc?
          return fcoe_wwpns if type.fcoe?
          # see ServiceDeployment#get_specific_dell_server_wwpns for other cases
        end

        def fcoe_fqdds
          type.fcoe_san_partitions.map do |partition|
            partition["fqdd"]
          end.compact
        end

        def fcoe_wwpns
          fqdds = fcoe_fqdds
          wwpns = []

          fcoe_interfaces.each do |interface, dets|
            if fqdds.include?(interface)
              wwpns << dets["wwpn"]
            else
              logger.debug("Found FCoE interface %s on %s but it's not in the FQDD list" % [interface, type.puppet_certname])
            end
          end

          wwpns
        end

        def fc_wwpns
          fc_interfaces.map(&:wwpn)
        end

        def fcoe_views
          ASM::WsMan.get_fcoe_wwpn(type.device_config, logger)
        end

        def fc_views
          return [] unless dell_server?
          wsman.fc_views
        end

        def fcoe_interfaces
          fcoe_views.map do |fqdd, details|
            details["fqdd"] = fqdd
            Hashie::Mash.new(details)
          end
        end

        def fc_interfaces
          fc_views.map {|v| Hashie::Mash.new(v)}
        end

        def should_inventory?
          !!type.guid
        end

        def update_inventory
          raise("Cannot update inventory for %s without a guid" % type.puppet_certname) unless type.guid

          ASM::PrivateUtil.update_asm_inventory(type.guid) unless debug?
        end

        # (see Type::Server#physical_type)
        def physical_type
          inventory = type.retrieve_inventory
          type = inventory["serverType"]

          type = "SLED" if inventory["model"] =~ /PowerEdge FC\d+/

          type
        end

        def controller_supported?(controller)
          controller.provider_path == "controller/idrac"
        end

        def cluster_supported?(cluster)
          case cluster.provider_path
          when "cluster/scvmm"
            configured_for_hyperv?
          else
            true
          end
        end

        def configured_for_hyperv?
          hyperv_properties = to_hash(true, :hyperv).keys

          missing = (Provider::Cluster::Scvmm::SERVER_REQUIRED_PROPERTIES - hyperv_properties)

          return true if missing.empty?

          logger.warn("Server %s is not supported by HyperV as it lacks these properties or they have nil values: %s" % [type.puppet_certname, missing.join(", ")])
          false
        end

        def os_host_name_update_hook(_)
          if type.deployment
            self[:policy_name] ||= ("policy-%s-%s" % [hostname, type.deployment.id]).downcase
          end
        end

        def hostname
          self[:os_host_name]
        end

        def agent_certname
          ASM::Util.hostname_to_certname(hostname)
        end

        # @see Type#nic_info
        def nic_info
          @__nic_info ||= NetworkConfiguration::NicInfo.fetch(type.device_config, logger)
        end

        def wsman
          @__wsman ||= ASM::WsMan.new(type.device_config, :logger => logger)
        end

        # Disconnects the RFS ISO via WsMan
        #
        # @return [void]
        # @raise [StandardError] when wsman fails
        def disconnect_rfs_iso
          if wsman.rfs_iso_image_connection_info[:return_value] == "0"
            wsman.disconnect_rfs_iso_image
          end
        end

        # Attempts to remove PXE from the bootorder using WsMan
        #
        # This will retry once after an initial failure and then raise whatever if
        # it still cannot do it
        #
        # @return [void]
        # @raise [StandardError] when it fails
        def disable_pxe
          if debug?
            logger.info("Would have disabled PXE on %s, skipping while in debug" % [type.puppet_certname])
            return
          end

          type.do_with_retry(2, 30, "Failed to remove PXE from boot for %s" % type.puppet_certname) do
            wsman.set_boot_order(:hdd, :reboot_job_type => :graceful_with_forced_shutdown)
            disconnect_rfs_iso
          end
        end

        # Configures the server for PXE booting
        #
        # For Intel NIC based servers a custom iPXE ISO will be created to match
        # the desired network configuration.  The ISO will be mounted as virtual
        # CD and set to boot first.
        #
        # Other servers will do native PXE booting.
        #
        # @return [void]
        # @raise [StandardError] on failure
        def enable_pxe
          if debug?
            logger.info("Would have enabled PXE on %s, skipping while in debug" % [type.puppet_certname])
            return
          end

          raise("No PXE partition found for OS installation on %s" % type.puppet_certname) if type.pxe_partitions.empty?

          if type.static_pxe? && !static_boot_eligible?
            raise("Static OS installation is only supported on servers with all Intel NICs, cannot enable PXE on %s" % type.puppet_certname)
          end

          if static_boot_eligible?
            build_and_boot_from_ipxe!
          else
            pxe_fqdd = type.pxe_partitions.first.fqdd

            raise("Failed to enable PXE boot on %s - cannot determine FQDD for PXE partition" % [type.puppet_certname]) unless pxe_fqdd

            type.do_with_retry(2, 30, "Failed to add PXE to the boot order on %s" % [type.puppet_certname]) do
              logger.info("Setting PXE partition %s to first in boot order for %s" % [pxe_fqdd, type.puppet_certname])
              wsman.set_boot_order(pxe_fqdd, :reboot_job_type => :power_cycle)
            end
          end
        end

        # Builds a suitable iPXE ISO and boot from it
        #
        # @return [void]
        # @raise [StandardError] on failure
        def build_and_boot_from_ipxe!
          _, iso_uri = build_ipxe!
          boot_ipxe!(iso_uri)
        end

        # Boots a machine from a iPXE image
        #
        # @param uri [String] uri to the PXE image
        # @raise [StandardError] on failure
        def boot_ipxe!(uri)
          logger.info("Booting %s from custom iPXE ISO %s" % [type.puppet_certname, uri])
          wsman.boot_rfs_iso_image(:uri => uri, :reboot_job_type => :power_cycle)
        end

        # Builds a custom iPXE ISO for this machine
        #
        # @return [Array<String, String>] path and uri to the ISO
        # @raise [StandardError] on failure
        def build_ipxe!
          iso_name = "ipxe-%s.iso" % wsman.host
          iso_path = File.join(ASM.config.generated_iso_dir, iso_name)
          iso_uri = File.join(ASM.config.generated_iso_dir_uri, iso_name)

          logger.info("Building custom iPXE ISO for %s in %s" % [type.puppet_certname, iso_path])
          IpxeBuilder.build(type.network_config, wsman.nic_views.size, iso_path)

          [iso_path, iso_uri]
        end

        # Determines if a computer is static boot elegable
        #
        # Today that means machines with all Intel cards
        #
        # @return [Boolean]
        def static_boot_eligible?
          enabled_cards.all? { |c| c.ports.first.vendor == :intel }
        end

        # Finds all network cards that are enabled
        #
        # @return [Array<NetworkConfiguration::NicInfo>]
        def enabled_cards
          nic_info.cards.reject(&:disabled)
        end

        def wait_for_lc_ready
          wsman.poll_for_lc_ready if !debug? && dell_server?
        end

        def hostname_to_certname(name=nil)
          name ||= hostname
          ASM::Util.hostname_to_certname(name)
        end

        # Determines if a server is a dell server by inspecting its certname for our patterns
        #
        # @return [Boolean]
        def dell_server?(cert_name=nil)
          !!Util.dell_cert?(cert_name || type.puppet_certname)
        end

        # Look up the target_boot_device from the asm::idrac component resource
        #
        # @return [String, nil] the boot device or nil
        def target_boot_device
          idrac = type.service_component.resource_by_id("asm::idrac")

          idrac ? idrac["target_boot_device"] : nil
        end

        def boot_from_iscsi?
          target_boot_device == "iSCSI"
        end

        def boot_from_san?
          return false unless dell_server?

          BOOT_FROM_SAN_TARGETS.include?(target_boot_device)
        end

        def has_os?
          !os_image_type.nil?
        end

        def idrac?
          type.service_component.has_resource_id?("asm::idrac")
        end

        def os_only?
          !idrac?
        end

        def bios_settings
          if bios = type.service_component.resource_by_id("asm::bios")
            settings = bios.configuration["asm::bios"][type.puppet_certname].dup

            if settings
              settings.delete("bios_configuration")
              settings.delete("ensure")

              return settings
            end
          end

          {}
        end

        # Creates a Type::Controller instance from the asm::idrac component resource
        #
        # @return [Type::Controller, nil] nil when it could not be created
        def create_idrac_resource
          idrac = nil

          if resource = type.service_component.resource_by_id("asm::idrac")
            component = resource.to_component(type.puppet_certname, "CONTROLLER")
            idrac = component.to_resource(type.deployment, logger)

            if idrac.supports_resource?(type)
              idrac.configure_for_server(type)
            else
              logger.warn("Created the asm::idrac resource but it does not support this server")
              idrac = nil
            end
          end

          idrac
        end

        def delete_server_network_overview_cache!
          filename = "/opt/Dell/ASM/cache/%s_portview.json" % type.puppet_certname.downcase
          File.delete(filename) if File.exist?(filename)
        end

        def delete_server_cert!
          # without an os_image_type it would never have run puppet so would not have a cert
          return if os_image_type == "" || os_image_type.nil?

          logger.info("Deleting certificate for server %s" % os_host_name)
          ASM::DeviceManagement.clean_cert(hostname_to_certname(os_host_name)) unless debug?
        end

        def delete_server_node_data!
          return if os_image_type == "" || os_image_type.nil?

          logger.info("Deleting node data for server %s" % os_host_name)
          ASM::DeviceManagement.remove_node_data(hostname_to_certname(os_host_name)) unless debug?
          ASM::PrivateUtil.delete_serverdata(hostname_to_certname(os_host_name)) unless debug?
        end

        # (see Type::Server#delete_network_topology!)
        def delete_network_topology!
          ASM::DeviceManagement.deactivate_node(type.puppet_certname)
        end

        def leave_cluster!
          cluster = type.related_cluster

          # We do not try and remove ourselves from clusters that are being torn down in the same
          # deployment as they would already be torn down at this point so this would fail anyway
          # even if they are not already torn down this would be a needless action and so this is
          # both avoiding errors in some cases and a performance optimisation in others
          if cluster
            if !cluster.teardown?
              cluster.evict_vsan!(type)
              cluster.evict_vds!(type)
              cluster.evict_server!(type)
            else
              logger.debug("Server %s skipping cluster eviction as the %s cluster is also being torn down" % [type.puppet_certname, cluster.puppet_certname])
            end
          else
            logger.debug("Did not find any cluster associated with server %s" % type.puppet_certname)
          end
        end

        def clean_related_volumes!
          if idrac?
            type.related_volumes.each do |volume|
              # Skip volumes that are being torn down as the cleanup will happen
              # when they get torn down. This is a optimisation short circuit only
              # and not for functional reasons
              next if volume.teardown?

              logger.info("Removing associated storage access for volume %s after removal of server %s" % [volume.puppet_certname, type.puppet_certname])

              begin
                volume.remove_server_from_volume!(type)
              rescue
                logger.warn("Failed to remove the server %s from the volume %s: %s: %s" % [type.puppet_certname, volume.puppet_certname, $!.class, $!.to_s])
                logger.debug($!.backtrace.inspect)
              end
            end
          else
            logger.debug("Not attempting to clean any related volumes on non iDRAC server %s" % type.puppet_certname)
          end
        end

        def clean_virtual_identities!
          if idrac = create_idrac_resource
            logger.info("Cleaning virtual identities from %s" % type.puppet_certname)

            idrac.ensure = "teardown"
            idrac.process!

            wait_for_lc_ready
          else
            logger.warn("Server %s has no associated asm::idrac resource, cannot clean its virtual identities" % type.puppet_certname)
          end
        end

        # (see Type::Server#power_state)
        def power_state
          if dell_server?
            wait_for_lc_ready
            return wsman.power_state
          else
            state = ASM::Ipmi.get_power_status(type.device_config, logger)

            return :off if state == "off"
            return :on
          end
        end

        # (see Type::Server#power_on!)
        def power_on!(wait=0)
          if !debug?
            if power_state == :on
              logger.debug("Server is already on, not rebooting")
              return
            end

            if dell_server?
              wait_for_lc_ready
              wsman.reboot
            else
              ASM::Ipmi.reboot(type.device_config, logger)
            end

            logger.debug("%s have been powered on, sleeping %d seconds" % [type.puppet_certname, wait])
            sleep(wait)
          else
            logger.debug("Would have powered off %s but running in debug mode" % type.puppet_certname)
          end
        end

        # (see Type::Server#power_off!)
        def power_off!
          if !debug?
            if dell_server?
              wait_for_lc_ready
              ASM::WsMan.poweroff(type.device_config, logger)
            else
              ASM::Ipmi.power_off(type.device_config, logger)
            end
          else
            logger.debug("Would have powered off %s but running in debug mode" % type.puppet_certname)
          end
        end

        # (see Type::Server#enable_switch_inventory!)
        def enable_switch_inventory!
          return if debug?

          tries ||= 0
          if dell_server?
            # NOTE: power_cycle is used rather than graceful shutdown because
            # it can be much faster, and in this context we are already
            # disrupting the server in preparation for installing a new OS.
            logger.info("Booting from LLDP ISO %s on %s" % [ASM.config.lldp_iso_uri, type.puppet_certname])
            wsman.boot_rfs_iso_image(:uri => ASM.config.lldp_iso_uri, :reboot_job_type => :power_cycle)
          else
            logger.info("Unable to boot non-Dell servers from ISO, falling back to powering on %s" % type.puppet_certname)
            power_on!
          end
        rescue
          raise if (tries += 1) > 1

          logger.warn("Failed to enable switch inventory for %s: %s: %s" % [type.puppet_certname, $!.class, $!.to_s])
          sleep(30)
          logger.info("Retrying enable switch inventory once for %s" % type.puppet_certname)
          retry
        end

        # (see Type::Server#disable_switch_inventory!)
        def disable_switch_inventory!
          unless debug?
            if dell_server? && wsman.rfs_iso_image_connection_info[:return_value] == "0"
              wsman.disconnect_rfs_iso_image
            end
            power_off!
          end
        end

        # (see Type::Server#network_overview)
        def network_overview
          connected_switches = []
          type.switch_collection.switches.each do |switch|
            ports_local = Hash.new {|hsh, key| hsh[key] = []}
            remote_device_info = switch.facts["remote_device_info"]
            remote_device_info = remote_device_info.values if remote_device_info.is_a?(Hash)

            remote_device_info.each do |switch_local|
              ports_local[switch_local["remote_mac"]].push switch_local["interface"]
            end

            remote_device_info.each do |current_switch_info|
              type.switch_collection.switches.each do |inventory_switch|
                next unless current_switch_info["remote_mac"].to_s == inventory_switch.facts["stack_mac"].to_s
                ports_remote = []
                remote_switch = inventory_switch.facts["remote_device_info"]
                remote_switch = remote_switch.values if remote_switch.is_a?(Hash)
                remote_switch.each do |info|
                  ports_remote << info["interface"] if info["remote_mac"] == switch.facts["stack_mac"]
                end
                port_info = {
                  :local_device => switch.id,
                  :local_device_type => switch.blade_switch? ? "blade" : "rack",
                  :local_ports => ports_local[current_switch_info["remote_mac"]].uniq,
                  :remote_device => inventory_switch.id,
                  :remote_device_type => inventory_switch.blade_switch? ? "blade" : "rack",
                  :remote_ports => ports_remote.uniq
                }
                connected_switches << port_info unless ports_remote.uniq == ports_local[current_switch_info["remote_mac"]].uniq
              end
            end
          end

          type.network_topology.each do |interface|
            next if interface[:switch].nil?
            connected_switches <<
              {
                :local_device => type.puppet_certname,
                :local_device_type => type.bladeserver? ? "blade" : "rack",
                :local_ports => [interface[:interface].fqdd],
                :remote_device => interface[:switch].puppet_certname,
                :remote_device_type => interface[:switch].blade_switch? ? "blade" : "rack",
                :remote_ports => [interface[:port]]
              }
          end

          port_view_data(connected_switches)
        end

        # @api private
        def fc_interface_overview
          return [] unless type.fc?

          fc_interfaces.map do |interface|
            next unless switch = type.switch_collection.switch_for_mac(interface.wwpn)
            {
              :fqdd => interface.fqdd,
              :wwpn => interface.wwpn,
              :connected_switch => switch.puppet_certname,
              :connected_zones => switch.fc_zones(interface.wwpn),
              :active_zoneset => switch.active_fc_zone(interface.wwpn)
            }
          end.compact
        end

        # @api private
        def fcoe_interface_overview
          return [] unless type.fcoe?

          fcoe_interfaces.map do |interface|
            next unless switch = type.switch_collection.switch_for_mac(interface.wwpn)
            {
              :fqdd => interface.fqdd,
              :wwpn => interface.wwpn,
              :connected_switch => switch.puppet_certname,
              :connected_zones => switch.fc_zones(interface.wwpn),
              :active_zoneset => switch.active_fc_zone(interface.wwpn)
            }
          end.compact
        end

        # @api private
        def port_view_data(connected_switches)
          related_switches = type.related_switches.map(&:puppet_certname)
          {
            :fc_interfaces      => fc_interface_overview,
            :fcoe_interfaces    => fcoe_interface_overview,
            :network_config     => type.network_config.to_hash,
            :related_switches   => related_switches,
            :name               => type.name,
            :server             => type.puppet_certname,
            :physical_type      => type.physical_type,
            :serial_number      => type.serial_number,
            :razor_policy_name  => policy_name,
            :connected_switches => connected_switches.uniq
          }
        end

        # (see Type::Server#reset_management_ip!)
        def reset_management_ip!
          if type.esxi_installed?
            logger.info("Resetting ESXi management IP for server %s" % os_host_name)
            esxi_management_ip = type.management_network["staticNetworkConfiguration"]["ipAddress"]
            # command is under the assumption that the management IP will always be on vmk0
            cmd_array = %w(network ip interface ipv4 set -i vmk0 -t none)
            password = ASM::Cipher.decrypt_string(admin_password)
            endpoint = {:host => esxi_management_ip, :user => ASM::ServiceDeployment::ESXI_ADMIN_USER, :password => password}
            # Hard to tell if esxcli times out because the management IP isn't reachable or if we successfully made it unreachable
            # We just make a silent call, and assume it works. Yay!
            begin
              ASM::Util.esxcli(cmd_array, endpoint, nil, true, 20)
            rescue StandardError => _
              logger.info("ESXi management IP %s has been reset." % esxi_management_ip)
            end
          end
        end
      end
    end
  end
end

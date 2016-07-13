require "asm/provider/switch/force10/base"
require "base64"

module ASM
  class Provider
    class Switch
      class Force10
        # Manage Interface VLAN membership for Dell Force10 blade switches
        #
        # This class builds a temporary map of every interface and all its
        # VLAN membership via {#configure_interface_vlan} and then turns that into
        # an appropriate puppet resource using {#to_puppet}
        class BladeMxl < Base
          # Configures the switch using the force10_settings hash
          #
          # MXL switches get a config_file that contains a Base64 encoded desired configuration
          # that it configures the switch to boot from
          #
          # There are a few things in the desired config that needs updating before sending it
          # to the switch though, we do not want to edit credentials or boot lines and hostname
          # might need to be set to the current running boot name.
          #
          # So this method takes the incoming force10_settings and pre-process the switch config
          # accordingly using the replace_* methods and then sets the switch to boot from the new
          # config
          #
          # When no config_file is given it just passes the settings onto puppet into the the
          # port_resources, but puppet is not run something else have to do that.
          #
          # @note does not run puppet, something else must run puppet later
          # @param settings [Hash] of force10_settings properties
          # @return [void]
          def configure_force10_settings(settings)
            if settings["config_file"]
              config_contents = Base64.decode64(settings["config_file"])

              logger.debug("Configuring switch %s using force10_settings" % type.puppet_certname)

              replace_hostname_in_config!(config_contents, settings)
              replace_management_ethernet_in_config!(config_contents)
              replace_credentials_in_config!(config_contents)
              replace_boot_in_config!(config_contents)

              config_file_name = "%s_config_file.cfg" % type.puppet_certname
              config_file_path = type.save_file_to_deployment(config_contents, config_file_name)

              port_resources["force10_config"] ||= {}
              port_resources["force10_config"]["%s_apply_config_file" % type.puppet_certname] = {
                "startup_config" => "true",
                "force" => "true",
                "source_server" => type.appliance_preferred_ip,
                "source_file_path" => config_file_path,
                "copy_to_tftp" => ["/var/lib/tftpboot/%s" % config_file_name]
              }
            else
              port_resources["force10_settings"] = {type.puppet_certname => settings.clone}
            end

            nil
          end

          def configure_iom_mode!(pmux, ethernet_mode, vlt_data=nil)
            raise("iom-mode_vlt resource is already created in this instance for switch %s" % type.puppet_certname) if port_resources["ioa_mode"]

            if vlt_data
              port_resources["ioa_mode"] = {
                "vlt_settings" => {
                  "ensure" => "present",
                  "port_channel" => vlt_data["portChannel"],
                  "destination_ip" => vlt_data["Destination_ip"],
                  "unit_id" => vlt_data["unit-id"].to_s,
                  "interface" => vlt_data["portMembers"].to_s
                }
              }
            end
            if port_resources["ioa_mode"]
              key, resource = port_resources["ioa_mode"].first
              resource["require"] = sequence if sequence
              @sequence = "Ioa_mode[%s]" % key
            end

            nil
          end

          # Configures the boot settings in a switch config string
          #
          # @note the passed in config text will be edited in place
          # @api private
          # @param config [String] force10 configuration
          # @return [void]
          def replace_boot_in_config!(config)
            config.gsub!(/boot.*?$/m, "")
            config.gsub!(/!\s*end/, "%s\n!\nend" % type.configured_boot)

            nil
          end

          # Configures the credentials in a switch config string
          #
          # @note the passed in config text will be edited in place
          # @api private
          # @param config [String] force10 configuration
          # @return [void]
          def replace_credentials_in_config!(config)
            config.gsub!(/username.*?$/m, "")

            type.configured_credentials.each do |cred|
              config.gsub!(/!\s*end/, "%s\n!\nend" % cred)
            end

            nil
          end

          # Configures a switch management ethernet in a switch config string
          #
          # If the switch is currently statically configured it's config is updated
          # for the new static information
          #
          # If the switch is currently configured with DHCP no changes are made to its
          # config
          #
          # If the switch has no Management Ethernet configuration we configure it statically
          #
          # @note the passed in config text will be edited in place
          # @api private
          # @param config [String] force10 configuration
          # @return [void]
          def replace_management_ethernet_in_config!(config)
            _, cidr = type.configured_management_ip_information

            mgmt_config = <<-EOF % [type.cert2ip, cidr]
interface ManagementEthernet 0/0
 ip address %s/%s
 no shutdown
!
            EOF

            if type.management_ip_static_configured?
              config.gsub!(/interface ManagementEthernet.*?!/m, mgmt_config)
            elsif type.management_ip_dhcp_configured?
              config.gsub!(/interface ManagementEthernet.*?!/m, "\n")
            else
              config.gsub!(/!\s*end/, "%s\n!\nend" % mgmt_config)
            end

            nil
          end

          # Configures a switch configuration hostname in a switch config string
          #
          # If the hostname is currently set it's updated else a hostname config line is added
          #
          # The hostname is either the one from the passed in settings or what is currently configured
          # on the switch according to its facts as reported by {Type::Switch#configured_hostname}
          #
          # @note the passed in config text will be edited in place
          # @api private
          # @param config [String] force10 configuration
          # @param settings [Hash] hash of desired force10_settings
          # @return [void]
          def replace_hostname_in_config!(config, settings)
            desired_hostname = settings["hostname"] ? settings["hostname"] : type.configured_hostname

            if config =~ /!\s*hostname\s*(\S+)/m
              logger.debug("force10_settings for %s has a hostname %s configured, updating it to %s" % [type.puppet_certname, $1, desired_hostname])
              config.gsub!(/hostname.*?!/m, "hostname %s\n!" % desired_hostname)
            else
              logger.debug("force10_settings for %s does not have a hostname configured, setting it to %s" % [type.puppet_certname, desired_hostname])
              config.gsub!(/!\s*end/m, "hostname %s\n!\nend" % desired_hostname)
            end

            nil
          end

          # Configures a list of interfaces for quodmode
          #
          # Only 40 Gb interfaces can be part of a group, any non 40 Gb interfaces
          # listed when enable is true will be silently skipped and logged
          #
          # @param interfaces [Array,nil] list of interfaces, when nil will use the quad_port_interfaces fact
          # @param enable [Boolean] should it be enabled or not for quadmode
          # @param reboot [Boolean] should the last interface set reboot required
          # @return [void]
          def configure_quadmode(interfaces, enable, reboot=true)
            interfaces ||= provider.facts["quad_port_interfaces"]

            if interfaces.empty?
              logger.debug("Could not find any interfaces to configure quadmode on")
              return
            end

            port_resources["mxl_quadmode"] ||= {}

            eligible_interfaces = interfaces.select {|i| !enable || forty_gb_interface?(i)}

            (interfaces - eligible_interfaces).each do |interface|
              logger.warn("Interface %s/%s requested to be configured for quad mode but its not a 40 gig interface, skipping" % [type.puppet_certname, interface])
            end

            eligible_interfaces.each do |interface|
              if enable && !forty_gb_interface?(interface)
                logger.warn("Interface %s/%s requested to be configured for quad mode but its not a 40 gig interface, skipping" % [type.puppet_certname, interface])
                next
              end

              resource = port_resources["mxl_quadmode"][interface] = {}

              resource["ensure"] = enable ? "present" : "absent"

              if reboot && interface == eligible_interfaces.last
                resource["reboot_required"] = "true"
              end

              resource["require"] = sequence if sequence
              @sequence = "Mxl_quadmode[%s]" % interface
            end
          end

          # Determines if an interface name is a 40Gb interface
          #
          # @param interface [String] the interface name
          # @return [Boolean]
          def forty_gb_interface?(interface)
            !!interface.match(/^fo/i)
          end

          # Reset each port in the switch to a default state
          #
          # @note this will populate the interface resources and not run puppet
          # @return [void]
          def initialize_ports!
            port_names.each do |port|
              configure_interface_vlan(port, "1", false, true)
              configure_interface_vlan(port, "1", true, true)
            end

            populate_port_resources(:remove)
          end

          # Creates interfaces resources for consumption by puppet
          #
          # @return [Hash]
          def to_puppet
            if port_resources["force10_interface"]
              port_resources["force10_interface"].keys.each do |vlan|
                resource = port_resources["force10_interface"][vlan]
                ["tagged_vlan", "untagged_vlan"].each do |prop|
                  next unless resource[prop].is_a?(Array) && !resource[prop].empty?
                  resource[prop] = resource[prop].sort.uniq.join(",")
                end
              end
            end

            port_resources
          end

          # Prepares the final internal state for a given action
          #
          # This should be called before {#to_puppet} to construct
          # the state based on interface information created using
          # {#configure_interface_vlan}
          #
          # The return value indicates if there were any interfaces to
          # configure for the action, if it's false there's no point
          # in calling process for the type as there's nothing to process
          #
          # @param [:add, :remove] action
          # @return [Boolean] if any interfaces were found for the action
          def prepare(action)
            reset!
            validate_vlans!
            populate_port_resources(action)
            populate_vlan_resources(action)

            !port_resources.empty?
          end

          # Construct asm::mxl resources for a VLAN
          #
          # Interfaces added with {#configure_interface_vlan} have various
          # associated VLANs, this adds resources to manage those VLANs
          # to the {#port_resources} hash
          #
          # @param number [String, Fixnum] vlan number
          # @param [Hash] properties
          # @option properties [String] :vlan_name
          # @option properties [String] :desc
          # @option properties [String] :portchannel
          # @option properties [String] :tagged
          # @return [void]
          def vlan_resource(number, properties={:portchannel => ""})
            vlan = number.to_s

            port_resources["asm::mxl"] ||= {}

            unless port_resources["asm::mxl"][vlan]
              vlan_config = {
                "vlan_name" => properties.fetch(:vlan_name, "VLAN_%s" % vlan),
                "desc" => properties.fetch(:desc, "VLAN Created by ASM"),
                "before" => []
              }

              unless properties[:portchannel].empty?
                if properties[:tagged]
                  vlan_config["tagged_portchannel"] = properties[:portchannel]
                else
                  vlan_config["untagged_portchannel"] = properties[:portchannel]
                end
              end

              port_resources["asm::mxl"][vlan] = vlan_config
            end

            if (interfaces = interface_map.select {|i| i[:vlan] == vlan})
              interfaces.each do |interface|
                config = port_resources["asm::mxl"][vlan]
                before_name = "Force10_interface[%s]" % interface[:interface]
                config["before"] |= [before_name]
                unless interface[:portchannel].empty?
                  config["require"] ||= []
                  config["require"] |= ["Mxl_portchannel[%s]" % interface[:portchannel]]
                end
              end
            end
          end

          # Find all the interfaces for a certain action and create VLANs
          #
          # Interfaces are made using {#configure_interface_vlan} and are
          # marked  as add or remove.  This finds all previously made interfaces
          # for a given action and calls {#vlan_resource) for each to construct
          # the correct asm::mxl resources
          #
          # @param [:add, :remove] action
          # @return [void]
          def populate_vlan_resources(action)
            action_interfaces = interface_map.select {|i| i[:action] == action}
            vlan_info = {}
            action_interfaces.each do |i|
              vlan_info[i[:vlan]] = i
            end

            vlan_info.each do |vlan, props|
              vlan_resource(vlan, props) unless action == :remove
            end
          end

          # Produce a list of port names for a certain switch
          #
          # @note only returned TE names not FC and only for a single unit
          # @return [Array<String>] array of port names
          def port_names
            (1..port_count).map {|i| "Te 0/%s" % i}
          end
        end
      end
    end
  end
end

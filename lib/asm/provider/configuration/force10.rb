module ASM
  class Provider
    class Configuration
      class Force10 < Provider::Base
        puppet_type "force10_settings", "asm::iom::uplink"

        attr_writer :switch_type

        property :vlt_enabled,            :default => false,   :validation => :boolean,  :tag => :uplink
        property :quadportmode,           :default => false,   :validation => :boolean,  :tag => :uplink
        property :config_file,            :default => nil,     :validation => String,    :tag => :uplink
        property :uplinks,                :default => nil,     :validation => Array,     :tag => :uplink
        property :vlt,                    :default => nil,     :validation => Hash,      :tag => :uplink

        def configure_networking!
          if config_file
            raise("Cannot configure networking when a config_file is set (%s) on %s" % [config_file, type.puppet_certname])
          end

          logger.debug("Configuring iom_mode on %s" % type.puppet_certname)
          if vlt_mode?
            vlt["portChannel"] = vlt_port_channel
            logger.debug("port channel %s added to the vlt data on %s" % [vlt["portChannel"], type.puppet_certname])
            vlt["unit-id"], vlt["Destination_ip"] = backup_link_ip_for_vlt
            vlt["model"] = switch.facts["model"]
          end

          process_iom_mode! # does a puppet run

          configure_quadportmode

          configure_port_channels

          configure_vlans

          initialize_ports!

          switch.process!(:update_inventory => true, :skip_prepare => true)
        end

        # Configured Quad port mode
        #
        # If uplinks are received in the deployment and quadmode is true those
        # ports will be used else the ports found in # the switch quad_port_interfaces
        # will be used. see {Provider::Switch::Force10#configure_quadmode}
        #
        # @return [void]
        def configure_quadportmode
          if quadportmode
            if uplinks
              members = uplinks.map do |uplink|
                uplink["portMembers"]
              end.compact.flatten

              logger.debug("Configuring quadmode on %s with members %s" % [type.puppet_certname, members.inspect])
            else
              members = nil

              logger.debug("Configuring quadmode on %s with members based on the quad_port_interfaces fact" % [type.puppet_certname])
            end

            switch.provider.configure_quadmode(members, true, true)
          else
            logger.debug("Unconfiguring quadmode on %s" % type.puppet_certname)
            switch.provider.configure_quadmode(nil, false, true)
          end
        end

        # Configures VLANs
        #
        # All desired port channels and member interfaces are mapped, desired VLANs
        # are extracted and created to traverse the port channels.  VLANs not needed
        # are removed on MXL switches
        #
        # When an IOA is in VLT mode it will automaticall learn about new port channels and
        # their VLAN membership via LACP thus no mxl_vlan or ioa_interface resources are
        # created for VLT mode IOAs but a debug log message will be logged to indicate that
        #
        # @note this does not run puppet, something should call process! on the switch later
        # @return [void]
        def configure_vlans
          logger.debug("Configuring vlans on %s" % type.puppet_certname)
          desired = desired_port_channels
          desired_vlans = vlans_from_desired(desired)
          current_vlans = switch.vlan_information.keys

          desired_vlans.each do |vlan|
            port_channels = vlan_portchannels_from_desired(desired, vlan)

            logger.info("Adding vlan %d with tagged port channels %s to %s" % [vlan, port_channels, type.puppet_certname])
            if switch.model =~ /MXL/ || switch.model =~ /PE-FN/
              switch.provider.mxl_vlan_resource(vlan, vlan_name(vlan), vlan_description(vlan), port_channels)
            else
              switch.provider.mxl_vlan_resource(vlan, vlan_name(vlan), vlan_description(vlan), [])
            end
          end

          # IOAs cannot set their vlan membership on the mxl_vlan resources
          # so need to get ioa_interfaces made for them instead

          unless switch.model =~ /PE-FN/
            desired.keys.each do |port_channel|
              switch.provider.ioa_interface_resource("po %s" % port_channel, desired_vlans, [])
            end
            logger.debug("created IOA interface vlans for %s" % type.puppet_certname)
          end

          (current_vlans - desired_vlans).each do |vlan|
            next if vlan == "1"

            # old code did not support removing vlans from !MXLs,
            # we might support this now in puppet so worth checking
            # if that is still good behaviour
            next unless switch.model =~ /MXL/

            logger.info("Removing VLAN %s from %s" % [vlan, type.puppet_certname])
            switch.provider.mxl_vlan_resource(vlan, "", "", [], true)
          end

          nil
        end

        # Gets the cmc_inventory data
        #
        # Calls the webservice call to cmc and return the whole json,
        # uses chassis_ra_url method to get the url for get request
        #
        # @param service_tag [String] taken from the device facts
        # @param options [Hash] options used when constructing the url
        # @option options [String] url override the url to the chassis RA
        # @return [Hash] chassis response
        def cmc_inventory(service_tag, options={})
          options[:url] = ASM::PrivateUtil.chassis_ra_url(options[:url])
          url = "%s/?filter=eq,serviceTag,%s" % [options[:url], service_tag]
          data = ASM::Api.sign { RestClient.get(url, :accept => :json) }
          JSON.parse(data).first
        end

        # Finds vlt configuration settings
        #
        # Takes device facts and returns destination_ip and device_id for creating back-uplink for IOA
        # calls iom and chassis_ioms to get current iom and all ioms to process based on the slot
        #
        # @note this does not run puppet, adds vlt information to the vlt property
        # @raise [StandardError] if no management_ip is found
        # @return [Array<String>] can be used this to configure iom vlt device_id,destination_ip
        def backup_link_ip_for_vlt
          candidate_ioms = chassis_ioms.select { |m| m["model"] == iom["model"] }

          candidate_ioms.sort_by { |m| m["slot"] }.each do |m|
            next unless m["managementIP"]
            next if m == iom

            return ["1", m["managementIP"]] if m["slot"] == iom["slot"] + 1
            return ["0", m["managementIP"]] if m["slot"] == iom["slot"] - 1
          end

          raise("unable to find the device backuplinks for %s" % type.puppet_certname)
        end

        # Configure vlt_port-channel for vlt settings
        #
        # Selects the current iom device and always return only one Iom.
        #
        # @return [Hash] a current iom matching ip_address
        def iom
          @_iom ||= chassis_ioms.select { |m| m["managementIP"] == switch.facts["management_ip"] }.first
        end

        # Finds Chassis ioms
        #
        # Gets all ioms data from the facts by calling cmc_inventory method see {#cmc_inventory}
        #
        # @return [Array<Hash>] all chassis_ioms data
        def chassis_ioms
          @_chassis_ioms ||= cmc_inventory(switch.facts["chassis_service_tag"])["ioms"]
        end

        # Finds the vlt port-channel
        #
        # Configure vlt_port-channel for vlt settings
        # assigns the highest of all port-channels used in up-links
        # compares with the up-links that are configured
        #
        # @return [Integer]  port-channel for vlti in iom-configuration
        def vlt_port_channel
          port_channels = uplinks.map do |uplink|
            Integer(uplink["portChannel"])
          end
          ((1..128).to_a - port_channels).max
        end

        # Configures port channels and interfaces
        #
        # All desired port channels and member interfaces are managed, port channels not listed
        # in the desired configuration are removed
        #
        # @note this does not run puppet, something should call process! on the switch later
        # @return [void]
        def configure_port_channels
          unless uplinks
            logger.debug("Skipping port channel configuration on %s as no uplink configuration were provided" % type.puppet_certname)
            return
          end

          logger.debug("Configuring port channels on %s" % type.puppet_certname)

          desired = desired_port_channels
          current = switch.portchannel_members
          in_use_interfaces = desired.map { |_, s| s[:interfaces] }.flatten

          desired.each do |pc, settings|
            switch.provider.portchannel_resource(pc, settings[:fcoe], false, vlt_mode?)

            settings[:interfaces].each do |interface|
              logger.info("Adding interface %s to port channel %s on %s" % [interface, pc, type.puppet_certname])
              switch.provider.mxl_interface_resource(interface, pc)
            end

            next unless current.include?(pc)

            if current[pc].is_a?(Hash)
              current_interfaces = current[pc][:interfaces]
            else
              current_interfaces = current[pc]
            end

            (current_interfaces - settings[:interfaces]).each do |interface|
              # any interface and puppet resource can only be managed once,
              # checking here if these interfaces are being added to some port
              # channel will avoid duplicate managing of resources and thus impossible
              # to resolve dependency loops
              next if in_use_interfaces.include?(interface)

              logger.info("Removing interface %s from port channel %s on %s" % [interface, pc, type.puppet_certname])
              switch.provider.mxl_interface_resource(interface, "0")
            end
          end

          (current.keys - desired.keys).each do |pc|
            logger.info("Removing unused port channel %s from %s" % [pc, type.puppet_certname])
            switch.provider.portchannel_resource(pc, false, true)
          end
        end

        # Given a map of desired port channels and a VLAN id, extract the port channels the VLAN traverse
        #
        # @param desired [Hash] as produced by {#desired_port_channels}
        # @param vlan [String] a VLAN Id
        # @return [Array<Hash>] matching port channel definitions
        def vlan_portchannels_from_desired(desired, vlan)
          desired.map {|pc, settings| settings[:vlans].include?(vlan) ? pc : nil}.compact
        end

        # Given a map of desired port channels extract all the VLANs
        #
        # @param desired [Hash] as produced by {#desired_port_channels}
        # @return [Array<String>] list of VLAN IDs
        def vlans_from_desired(desired)
          desired.map {|_, settings| settings[:vlans]}.flatten.sort.uniq
        end

        # Calculate the desired list of port channels and their configurations
        #
        # @example output
        #
        #     {
        #        "128" => {
        #           :interfaces => ["TenGigabitEthernet 0/10", .....],
        #           :vlans => ["20", .....],
        #           :fcoe => false
        #        }
        #     }
        #
        # @return [Hash]
        def desired_port_channels
          channels = {}

          return channels unless uplinks

          uplinks.each do |uplink|
            channel = {
              :interfaces => member_interfaces(uplink["portMembers"]),
              :vlans => uplink_vlans(uplink),
              :fcoe => uplink_has_network_of_type?(uplink, "storage_fcoe_san")
            }

            # SN2210S use a FC interface in the uplinks calling it Te will
            # reconfigure it to a Te and not a FCOE in the Puppet Module
            channel[:interfaces].map! {|i| i.gsub(/fc/i, "Te")}

            channel[:interfaces].map! {|int| int.gsub("Te ", "TenGigabitEthernet ")}
            channel[:interfaces].map! {|int| int.gsub("Fo ", "fortyGigE ")}
            channel[:interfaces].sort!

            channels[uplink["portChannel"]] = channel
          end

          channels
        end

        # Parse a Force10 interface into named matchdata
        #
        # @return [Matchdata,nil] with named groups type, unit and interface
        def parse_interface(interface)
          interface.match(/^(?<type>\S+)\s(?<unit>\d+)\/(?<interface>\d+)$/)
        end

        # Determines the quad group member interfaces
        #
        # When quad port mode is requested the incoming interface names are converted
        # based on convention via {#quadport_member_interfaces} else the existing
        # quad port groups configured on the switch is considered via {#quadport_member_interfaces}
        #
        # @param interfaces [Array<String>,String] interface or a list of interfaces
        # @return [Array<String>] member interfaces names
        def member_interfaces(interfaces)
          if quadportmode
            quadport_member_interfaces(interfaces)
          else
            nonquadport_member_interfaces(interfaces)
          end
        end

        # Determines the member port list based on existing quad port interfaces
        #
        # If interfaces are given that are not in the quad groups from the current
        # config via facts they are included in the final result
        #
        # @param interfaces [Array<String>,String] interface or a list of interfaces
        # @return [Array<String>] member interfaces names
        def nonquadport_member_interfaces(interfaces)
          Array(interfaces).map do |interface|
            next unless parsed = parse_interface(interface)

            if parsed[:type] == "Fo" && switch.facts["quad_port_interfaces"].include?(parsed[:interface])
              quadport_member_interfaces(interface)
            else
              interface
            end
          end.flatten.compact.uniq.sort
        end

        # Given interface names like Fo 0/33 return the conventionally member ports
        #
        # If any non Fo ports are given they will be included in the returned result
        # verbatim as well as the resulting group
        #
        # @see #quadport_for_member
        # @note ported from ServiceDeployment#get_quadport_interfaces
        # @param interfaces [Array<String>,String] interface or a list of interfaces
        # @return [Array<String>] member interfaces names
        def quadport_member_interfaces(interfaces)
          Array(interfaces).map do |interface|
            next unless parsed = parse_interface(interface)

            if parsed[:type] == "Fo"
              (Integer(parsed[:interface])..(Integer(parsed[:interface]) + 3)).map do |int|
                "Te %s/%s" % [parsed[:unit], int]
              end
            else
              interface
            end
          end.flatten.compact.uniq.sort
        end

        # Determines which quad port interface a interface belongs to
        #
        # By convention Te 0/33 - Te 0/36 belongs to Fo 0/33
        #
        # @see #quadport_member_interfaces
        # @note ported from ServiceDeployment#get_nonquadport_interfaces
        # @param interfaces [String,Array<String>] interface names
        # @return [Array<String>] quad port names
        def quadport_for_members(interfaces)
          quads = (0..64).map do |group|
            start_port = (group * 4) + 1
            end_port = start_port + 3

            (start_port..end_port).map(&:to_s)
          end

          Array(interfaces).map do |interface|
            next unless parsed = parse_interface(interface)

            quad = quads.find { |q| q.include?(parsed[:interface]) }

            "Fo %s/%s" % [parsed[:unit], quad.first] if quad
          end.flatten.compact.sort.uniq
        end

        # Retrieves the network description for a specific VLAN id
        #
        # @param vlan_id [String, Fixnum]
        # @return [String, nil] the network name based on its description or name
        def vlan_description(vlan_id)
          vlan_id = Integer(vlan_id)

          if network = asm_networks.find { |net| net["vlanId"] == vlan_id }
            (network["description"].nil? || network["description"].empty?) ? network["name"] : network["description"]
          end
        end

        # Retrieves the network name for a specific VLAN id
        #
        # @param vlan_id [String, Fixnum]
        # @return [String, nil] the network name
        def vlan_name(vlan_id)
          vlan_id = Integer(vlan_id)

          if network = asm_networks.find { |net| net["vlanId"] == vlan_id }
            network["name"]
          end
        end

        # Retrieves all the VLAN network information for a uplink
        #
        # All known ASM networks are searched using {#uplink_networks} and the
        # VLAN IDs are returned
        #
        # @see #uplink_networks
        # @return [Array<String>] list of VLAN IDs
        def uplink_vlans(uplink)
          uplink_networks(uplink).map do |link|
            link["vlanId"].to_s
          end
        end

        # Configures force10 settings
        #
        # When a config_file is provided that file will be used to configure the switch
        # and the normal switch configuration steps in {#configure_networking!} should be
        # skipped, the settings will be used and a {#configure_networking!} based config
        # should be done.
        #
        # @return [Boolean] indicating if the switch was configured using a config file
        def configure_force10_settings!
          settings = type.component_configuration["force10_settings"][type.puppet_certname]

          if settings && !settings.empty?
            switch.provider.configure_force10_settings(settings)
          end

          !!config_file
        end

        def additional_resources
          @additional_resources ||= {}
        end

        # Configures the I/O Module modes for VLT or not
        #
        # Will perform a puppet run and update inventories should any
        # changes be needed
        #
        # @return [void]
        # @raise [StandardError] when the switch is not a IOA
        def process_iom_mode!
          switch.provider.configure_iom_mode!(pmux_mode?, ioa_ethernet_mode?, vlt)
        end

        def vlt_mode?
          !(vlt.nil? || vlt.empty?)
        end

        def uplinks_update_munger(_, n_value)
          return n_value unless n_value.is_a?(String)

          links = JSON.parse(n_value).reject {|l| l == "vlt"}.map do |link|
            JSON.parse(type.component_configuration["asm::iom::uplink"][type.puppet_certname][link.strip.downcase])
          end.compact

          links.each do |link|
            link["portMembers"].map!(&:strip)
          end

          links
        end

        def vlt_update_munger(_, n_value)
          n_value.is_a?(String) ? JSON.parse(n_value) : n_value
        end

        # Configures each port on the switch with default settings
        #
        # @return [void]
        def initialize_ports!
          switch.initialize_ports!
        rescue
          logger.debug("Failed to initialize ports: %s: %s" % [$!.class, $!.to_s])
        end

        # Determins if the switch should be in pmux mode
        #
        # @return [Boolean]
        def pmux_mode?
          return false unless uplinks
          return false if uplinks.empty?
          return false if vlt_mode?
          return false unless switch.provider.blade_ioa_switch?

          true
        end

        # Determines if the ioa_ethernet_mode should be set for a uplink
        #
        # If any member ports for a uplink are FC then ioa_ethernet_mode
        # should be set for FX2 switches
        #
        # @note ported from {ASM::ServiceDeployment#snioa_2210_ethernet}
        # @return [Boolean]
        # @raise [StandardError] when FC interfaces are used by both an uplink and FCoE networks
        def ioa_ethernet_mode?
          return false unless pmux_mode?
          return false unless switch.model =~ /2210/

          uplinks.map do |uplink|
            fc_interfaces = uplink["portMembers"].select {|p| p.match(/^fc/i)}
            fc_in_use = uplink_has_network_of_type?(uplink, "storage_fcoe_san")

            if !fc_interfaces.empty? && fc_in_use
              raise("Invalid switch configuration for %s: FC interfaces %s are in use by FCoE networks, cannot also use in uplinks for uplink %s" %
                    [type.puppet_certname, fc_interfaces.join(", "), uplink["uplinkId"]])
            end

            !fc_interfaces.empty?
          end.include?(true)
        end

        # Fetch the network definitions for a uplink
        #
        # From all the networks known to ASM as found using
        # {#asm_networks} return the ones used by a uplink
        # according to its portNetworks
        #
        # @param uplink [Hash] a member of the uplinks list
        # @return [Array<Hash>]
        def uplink_networks(uplink)
          asm_networks.select do |network|
            uplink["portNetworks"].include?(network["id"])
          end
        end

        # Checks if any of the associated networks for a uplink is of a certain type
        #
        # @return [Boolean]
        def uplink_has_network_of_type?(uplink, type)
          uplink_networks(uplink).map do |network|
            network["type"].downcase
          end.include?(type.downcase)
        end

        # Look up the switch being configured
        #
        # @return [ASM::Type::Switch, nil]
        def switch
          @switch ||= type.switch_collection.switch_by_certname(type.puppet_certname)
        end

        # Retreives information about all networks known to the appliance
        #
        # @return [Array<Hash>]
        def asm_networks
          @asm_networks ||= ASM::PrivateUtil.get_network_info
        end
      end
    end
  end
end

require "json"
require "fileutils"
require "asm"
require "asm/private_util"
require "rest_client"
require "logger"
require "asm/service"

module ASM
  module PortView
    @data_version = 1

    def self.logger
      @logger ||= ASM.logger
    end

    def self.get_server_info(id, server_puppet_certname)
      deployment = deployment_data(id)
      service = ASM::Service.new(deployment, :deployment => ASM::ServiceDeployment.new(id, ASM::Data::Deployment.new(ASM.database)))
      server = service.servers.find {|s| s.puppet_certname.downcase == server_puppet_certname.downcase}
      get_cache(server)
    end

    def self.get_network_overview(server)
      # picking out only the fields from network_overview json that the AsmManager expects
      all_keys = [:fc_interfaces, :fcoe_interfaces, :network_config, :related_switches, :name, :server, :physical_type, :serial_number, :razor_policy_name, :connected_switches]
      network_overview = server.network_overview.select {|k, _v| all_keys.include?(k) } if server
      network_overview if server
    end

    def self.get_cache_filename(server_puppet_certname)
      "/opt/Dell/ASM/cache/#{server_puppet_certname.downcase}_portview.json"
    end

    def self.write_cache(server)
      server_puppet_certname = server.puppet_certname
      cache_filename = get_cache_filename(server_puppet_certname)
      network_overview = get_network_overview(server)
      portview_data = updated_port_view_json(network_overview)
      portview_data["DATA_VERSION"] = @data_version
      logger.debug("Writing the cache for #{server_puppet_certname} at #{cache_filename} with data version, #{@data_version}")
      File.write(cache_filename, portview_data.to_json)
    end

    def self.get_cache(server)
      server_puppet_certname = server.puppet_certname
      filename = get_cache_filename(server_puppet_certname)
      cache_write = false
      logger.debug("Checking cache for server network overview for #{server_puppet_certname} at #{filename}")
      portview_data_json = File.read(filename) if File.exist?(filename) && !File.symlink?(filename)
      if portview_data_json.nil?
        logger.debug("No cache exists for #{server_puppet_certname}.. Write the fresh cache!")
        cache_write = true
      else
        portview_data = JSON.parse(portview_data_json)
        if portview_data["DATA_VERSION"] != @data_version
          logger.debug("Cache exists for #{server_puppet_certname}, but the data version does not match! Rewrite the cache!")
          cache_write = true
        end
      end

      if cache_write
        network_overview = get_network_overview(server)
        portview_data = updated_port_view_json(network_overview)
        write_cache(server)
      end

      portview_data.delete("DATA_VERSION")
      portview_data
    end

    def self.updated_port_view_json(port_view_info)
      interface_keys = ["id", "name", "redundancy", "enabled", "usedforfc", "partitioned", "nictype", "interfaces", "fabrictype", "card_index"]
      inner_interface_keys = ["id", "name", "partitioned", "partitions", "enabled", "redundancy", "nictype", "fqdd"]
      partition_keys = [
        "id", "name", "networks", "networkObjects", "minimum", "maximum", "lanMacAddress",
        "iscsiMacAddress", "iscsiIQN", "wwnn", "wwpn", "port_no", "partition_no", "partition_index", "fqdd", "mac_address"
      ]

      network_config = port_view_info[:network_config].select {|k, _v| ["id", "interfaces"].include?(k) }

      all_outer_interfaces = []
      network_config["interfaces"].each do |each_outer_interface|
        this_outer_interface = each_outer_interface.select {|k, _v| interface_keys.include?(k) }
        all_outer_interfaces << this_outer_interface
        all_inner_interfaces = []
        this_outer_interface["interfaces"].each do |each_inner_interface|
          inner_interfaces_for_this_outer_interface = each_inner_interface.select {|k, _v| inner_interface_keys.include?(k) }
          all_inner_interfaces << inner_interfaces_for_this_outer_interface
          all_partitions = []
          inner_interfaces_for_this_outer_interface["partitions"].each do |each_partition_in_this_interface|
            all_partitions << each_partition_in_this_interface.select {|k, _v| partition_keys.include?(k) }
          end
          inner_interfaces_for_this_outer_interface["partitions"] = all_partitions
        end
        this_outer_interface["interfaces"] = all_inner_interfaces
      end

      network_config["interfaces"] = all_outer_interfaces

      port_view_info[:network_config] = network_config

      port_view_info
    end

    def self.deployment_data(id)
      file_name = File.join(ASM.base_dir, id.to_s, "deployment.json")
      JSON.parse(File.read(file_name))
    end
  end
end

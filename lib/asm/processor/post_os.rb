require "asm/private_util"
require "asm/network_configuration"

module ASM
  module Processor
    class PostOS
      def initialize(service_deployment, component)
        @server_component = component
        @sd = service_deployment
        @server_config = ASM::PrivateUtil.build_component_configuration(component, :decrypt => service_deployment.decrypt?)
        @server_cert = @server_component["puppetCertName"]
        @network_params = (@server_config["asm::esxiscsiconfig"] || {})[@server_cert]
        @server_device_conf = ASM::DeviceManagement.parse_device_config(@server_cert)
        @required_resource = nil
      end

      def logger
        @sd.logger
      end

      def network_config
        return nil unless @network_params
        @nc_config ||= begin
          network_config = ASM::NetworkConfiguration.new(@network_params["network_configuration"], logger)

          network_config.add_nics!(@server_device_conf)

          network_config
        end
      end

      def asm_server
        @asm_server ||= begin
          @server_config["asm::server"].fetch(@server_component["puppetCertName"], {})
        end
      end

      def default_gateway_network
        network_params = (@server_config["asm::esxiscsiconfig"] || {})[@server_cert]
        network_params ? network_params.fetch("default_gateway", "") : ""
      end

      def mtu
        @mtu ||= begin
          network_params = (@server_config["asm::esxiscsiconfig"] || {})[@server_cert]
          network_params ? network_params.fetch("mtu", "9000").to_i : 9000
        end
      end

      def applications
        @associated_applications ||= begin
          component_obj = ASM::Service.new(@sd.service_hash).component_by_id(@server_component["id"])
          component_obj.associated_components("SERVICE")
        end
      end

      # Returns hash of puppet module post-install resources/classes
      #
      # @example Returned data example:
      #   {"classes"=>{"linux_postinstall"=>{"install_packages"=>"httpd", "upload_recursive"=>"false"}, "haproxy"=>{"require"=>"Class['linux_postinstall']"}},
      #   "resources"=> {"haproxy::listen"=>{"puppet00"=>{"collect_exported"=>"false", "ipaddress"=>"0.0.0.0", "ports"=>"8080"}},
      #   "haproxy::balancermember"=>
      #   {"master00"=>{"listening_service"=>"puppet00", "require"=>"Haproxy::listen['puppet00']", "server_names"=>"master00.example.com", "ipaddresses"=>"10.0.0.10"}}}}
      # @return [Hash]
      def post_os_services
        services = {}
        classes = post_os_components("class")
        services["classes"] = classes unless classes.empty?

        resources = post_os_components("type")
        services["resources"] = resources unless resources.empty?
        services
      end

      # Returns puppet post-install components of a given type
      #
      # @param type [String] puppet install type (type | class)
      # @return [Hash]
      def post_os_components(type)
        result = {}
        components = applications.select { |c| c["service_type"] == type }.sort_by { |c| c["install_order"]}

        components.each do |component|
          component_hash = post_os_component(component["component"], type)
          if result[component_hash.keys.first]
            result[component_hash.keys.first].merge!(component_hash.values.first)
          else
            result.merge!(post_os_component(component["component"], type))
          end
          @required_resource = build_require_name(component["component"], type) unless type == "class"
        end
        result
      end

      def host_ip_config(networks)
        appliance_ip = ASM::Util.default_routed_ip
        networks.each do |network|
          if network["static"]
            preferred_ip = ASM::Util.get_preferred_ip(network["staticNetworkConfiguration"]["ipAddress"])
            return preferred_ip unless preferred_ip == appliance_ip
          end
        end
        appliance_ip
      end

      # Returns puppet hash for given post-install component
      #
      # @param component [ASM::Service::Component]
      # @return [Hash]
      def post_os_component(component, component_type)
        puppet_class = {}
        component_name = component.configuration.keys.first
        component_data = component.configuration.values.first
        component_title = component_data.keys.first
        component_config = ASM::PrivateUtil.build_component_configuration(component.to_hash, :decrypt => @sd.decrypt?)
        params = component_data.values.first

        if params.empty?
          puppet_class[component_name] = {}
          # @note: This is broken in our current puppet version
          # puppet_class[component_name]["require"] = require unless require.nil?
        end

        if component_type == "class"
          puppet_class[component_name] = component_config[component_name].values.first
          puppet_class[component_name].delete_if { |_, v| v.is_a?(String) && v.empty? }
        else
          puppet_class = component_config
          puppet_class[component_name][component_title].delete_if { |_, v| v.is_a?(String) && v.empty? }
          puppet_class[component_name][component_title]["require"] = @required_resource unless @required_resource.nil?
        end

        puppet_class
      end

      def build_require_name(component, type)
        name = component.configuration.keys.first
        if type == "class"
          require = "Class[#{name.downcase}]"
        else
          data = component.configuration.values.first
          title = data.keys.first
          require = "#{name.split('::').each(&:capitalize!).join('::')}[#{title}]"
        end
        require
      end
    end
  end
end

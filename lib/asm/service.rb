require "asm/service/component"
require "asm/service/component/resource"
require "asm/service/component/generator"
require "asm/service/switch_collection"
require "asm/service/processor"
require "asm/service/rule_gen"

# wrapper class with helpers for the service template received from the UI
module ASM
  class Service
    if RUBY_PLATFORM == "java"
      require "jruby/synchronized"
      include JRuby::Synchronized
    end

    attr_accessor :deployment

    # Creates a new ASM::Service object.
    #
    # @example create an ASM::Service from deployment JSON data
    #
    #     data = JSON.parse(File.read("deployment.json"), :max_nesting => 100)
    #     deployment = ASM::ServiceDeployment.new(data["id"], nil)
    #     service = ASM::Service.new(data, :deployment => deployment, :decrypt => true)
    #
    # @param service [String] hash of service deployment data in the form passed to {ASM::ServiceDeployment#process}
    # @param options [Hash]
    # @option options [Boolean] :decrypt (true) true if password parameters are encrypted, false otherwise.
    # @option options [ASM::ServiceDeployment] :deployment passed through to created {#resources}
    # @return [ASM::Service]
    def initialize(service, options={})
      options = {:decrypt => true}.merge(options)
      @service = service
      @deployment = options[:deployment]
      @decrypt = !!options[:decrypt]
      @component_instances = nil

      # Force these to be instantiated eagerly so that this instance is thread-safe
      switch_collection
      components
      resources
    end

    # Retrieves the deployment data instance for the associated deployment
    #
    # @return [Data::Deployment, nil]
    def database
      deployment.db
    end

    # Creates an ASM::Service::Processor for the service
    #
    # @param rules [String] rule sets to use, multiple sets are File::PATH_SEPARATOR separated
    # @return [Processor]
    def create_processor(rules=nil)
      Processor.new(@service, rules, logger)
    end

    def to_s
      "#<ASM::Service name: %s id: %s>" % [deployment_name, id]
    end

    def teardown?
      !!@service["teardown"]
    end

    def migration?
      !!@service["migration"]
    end

    def retry?
      !!@service["retry"]
    end

    def raw_service
      @service
    end

    def deployment_name
      @service["deploymentName"]
    end

    def id
      @service["id"]
    end

    def template
      @service["serviceTemplate"]
    end

    def logger
      deployment ? deployment.logger : ASM.logger
    end

    def debug?
      deployment.debug?
    rescue
      ASM.config.debug_service_deployments
    end

    # Creates a switch collection and caches it
    #
    # @return ASM::Service::SwitchCollection
    def switch_collection
      @switch_collection ||= switch_collection!
    end

    # Creates a switch collection without consulting the cache
    #
    # @return ASM::Service::SwitchCollection
    def switch_collection!
      ret = ASM::Service::SwitchCollection.new(logger)
      ret.service = self
      ret
    end

    # Generates a component programatically and inject it into the template
    #
    # @example generates a basic cluster resource
    #     service.generate_component("my_cluster.aidev.com") do |component|
    #       component.type = "CLUSTER"
    #       component.add_resource("asm::cluster", "Cluster Settings", [
    #         {:id => "datacenter", :value => "M830Datacenter"},
    #         {:id => "title", :value => "vcenter-env10-vcenter.aidev.com"}
    #       ])
    #     end
    #
    #     component = service.component_by_id("my_cluster.aidev.com")
    #
    # @see ASM::Service::Component::Generator
    # @param certname [String] a certificate name
    # @yieldparam generated [Component::Generator]
    # @return [void]
    # @raise [StandardError] any unhandled errors raised while calling Component::Generator
    def generate_component(certname)
      generated = Component::Generator.new(certname)
      yield(generated)

      component_hash = generated.to_component_hash

      template["components"] << component_hash

      if @component_instances
        @component_instances << Component.new(component_hash, @decrypt, self)
      end

      nil
    end

    def components
      @component_instances ||= template["components"].map do |c|
        Component.new(c, @decrypt, self)
      end
    end

    def each_component
      components.each do |component|
        yield(component)
      end
    end

    # Find a component given its ID
    #
    # @param id [String] the component ID
    # @return [ASM::Service::Component,nil]
    def component_by_id(id)
      ret = components.find {|c| c.id == id}

      unless ret
        # Check switch_collection, switches are discovered dynamically
        switch = switch_collection.find {|s| s.service_component.id == id }
        ret = switch.service_component if switch
      end

      ret
    end

    # Finds components of a certain type
    #
    # @param type [String] a type like SERVER or CLUSTER
    # @return [Array<ASM::Service::Component>]
    def components_by_type(type)
      components.select {|c| c.type == type}
    end

    # Find related components in the service, optionally for a certain type
    #
    # It uses {ASM::Service::Component#related_components} to do the actual work
    # but this is a shortcut via the service rather than via component in a case
    # where a component might not know it's service
    #
    # This is a replacement for {ASM::ServiceDeployment#find_related_components}
    #
    # @param component [ASM::Service::Component] the companant to inspect
    # @param type [String] a type like SERVER or CLUSTER
    # @return [Array<ASM::Service::Component>]
    def related_components(component, type=nil)
      component.related_components(type, self)
    end

    # Returns cached resource objects for each component in the service.
    #
    # @return [Array<ASM::Type::Base>]
    def resources
      @resources ||= begin
        # TODO: SERVICE components are not supported
        filtered = components.reject { |component| component.type == "SERVICE" }
        resources = Type.to_resources(filtered, nil, deployment, logger)

        @resources_by_id = {}
        @resources_by_type = {}
        @resources_by_certname = {}

        resources.each do |resource|
          @resources_by_id[resource.id] = resource
          @resources_by_certname[resource.puppet_certname] = resource

          @resources_by_type[resource.type] ||= []
          @resources_by_type[resource.type] << resource
        end
      end
    end

    # Returns resource by its component id
    #
    # @return [ASM::Type::Base]
    def resource_by_id(id)
      @resources_by_id[id]
    end

    # Returns resources of a certain type
    #
    # @param type [String] a type like SERVER or CLUSTER
    # @return [Array<ASM::Type::Base>]
    def resources_by_type(type)
      @resources_by_type[type] || []
    end

    # Returns a resource that match a certname
    #
    # @param certname [String] the puppet certname
    # @return [ASM::Type::Base, nil]
    def resource_by_certname(certname)
      @resources_by_certname[certname]
    end

    # Returns server resources
    #
    # @return [Array<ASM::Type::Server>]
    def servers
      resources_by_type("SERVER")
    end

    # Returns cluster resources
    #
    # @return [Array<ASM::Type::Cluster>]
    def clusters
      resources_by_type("CLUSTER")
    end

    # Returns volume resources
    #
    # @return [Array<ASM::Type::Volume>]
    def volumes
      resources_by_type("STORAGE")
    end

    # Returns switch resources attached to servers in the service
    #
    # @return [Array<ASM::Type::Switch>]
    def switches
      servers.map(&:related_switches).flatten.uniq
    end
  end
end

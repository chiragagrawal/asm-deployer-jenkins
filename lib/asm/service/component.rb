require "asm/private_util"
require "asm/type"

module ASM
  class Service
    class Component
      attr_accessor :service

      def initialize(component, decrypt=true, service=nil)
        @component = component
        @decrypt = decrypt
        @service = service
      end

      def to_s
        "#<ASM::Service::Component name: %s type: %s id: %s>" % [name, type, id]
      end

      def puppet_certname
        @component["puppetCertName"]
      end

      def id
        @component["id"]
      end

      def component_id
        @component["componentId"]
      end

      def type
        @component["type"]
      end

      def to_resource(deployment=nil, logger=ASM.logger, type=nil)
        ASM::Type.to_resource(self, type, deployment, logger)
      end

      def resources
        @resources ||= @component["resources"].map do |r|
          Resource.new(self, r, @decrypt, service)
        end
      end

      def resource_ids
        resources.map(&:id)
      end

      # Checks if a component resource with a name like asm::idrac exist
      #
      # @return [Boolean]
      def has_resource_id?(id)
        resource_ids.include?(id)
      end

      # Look up a resource by its id
      #
      # It's built on the assumption that any component only ever have a single
      # resource of a certain type, as far as I can tell this is correct but might
      # need some tweaking if that's not the case.  In any event, the first found
      # one will be returned should that not be the case
      #
      # @param id [String] the resource id like asm::idrac
      # @return [Component::Resource, nil] nil if none were found
      def resource_by_id(id)
        resources.find {|r| r.id == id}
      end

      def name
        @component["name"]
      end

      def guid
        @component["asmGUID"]
      end

      def teardown
        @component["teardown"]
      end

      def teardown?
        !!teardown
      end

      def brownfield?
        !!@component["brownfield"]
      end

      # Finds related components in the service, optionally of a certain type
      #
      # This is a replacement for {ASM::ServiceDeployment#find_related_components}
      #
      # @param type [String] a type like SERVER or CLUSTER
      # @param service [ASM::Service] an optional service to use
      # @return [Array<ASM::Service::Component>]
      # @raise [StandardError] when the service is not set or supplied
      def related_components(type=nil, service=nil)
        service ||= @service

        raise("Cannot determine related resources as the component don't have access to the full service") unless service

        @component["relatedComponents"].map do |id, _|
          related = service.component_by_id(id)
          (type.nil? || (related && related.type == type)) ? related : nil
        end.compact
      end

      # Finds associated components in the service, optionally of a certain type
      #
      # This is a replacement for {ASM::ServiceDeployment#find_related_components}
      #
      # @param type [String] a type like SERVER or CLUSTER
      # @param service [ASM::Service] an optional service to use
      # @return [Array<Hash>]
      # @raise [StandardError] when the service is not set or supplied
      def associated_components(type=nil, service=nil)
        service ||= @service

        raise("Cannot determine associated resources as the component don't have access to the full service") unless service
        ac = []
        if @component["associatedComponents"]["entry"]
          @component["associatedComponents"]["entry"].each do |component|
            related = service.component_by_id(component["key"])
            if type.nil? || (related && related.type == type)
              val = {}
              component["value"]["entry"].each do |entry|
                val[entry["key"]] = entry["value"]
              end
              val["component"] = related
              ac << val
            else
              next
            end
          end
        end
        ac
      end

      def add_relation(component)
        @component["relatedComponents"][component.id] = component.name
      end

      def to_hash(include_resources=true)
        hash = @component.clone

        hash["resources"] = []

        # specifically fetching each resources here to be sure
        # we capture any changes made to those resources since they
        # were created.  Currently no means of changing is supported
        # but this is likely to happen in future
        if include_resources
          resources.each do |resource|
            hash["resources"] << resource.to_hash
          end
        end

        hash
      end

      def configuration(include_resources=true)
        Hash.new({}).merge(ASM::PrivateUtil.build_component_configuration(to_hash(include_resources), :decrypt => @decrypt))
      end

      # Creates a copy of the Component with no shared component state. The
      # copy and its resources may be modified without affecting the original
      # component.
      #
      # Note that the service reference is not copied, and still points to the
      # original service object.
      #
      # @return [Component] the copied component.
      def deep_copy
        Component.new(JSON.parse(@component.to_json), @decrypt, @service)
      end
    end
  end
end

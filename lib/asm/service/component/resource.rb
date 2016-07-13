module ASM
  class Service
    class Component
      class Resource
        attr_accessor :service
        attr_accessor :configuration

        def initialize(component, resource, decrypt=true, service=nil)
          @component = component
          @resource = resource
          @configuration = ASM::PrivateUtil.build_component_configuration(resource, :decrypt => @decrypt)
          @configuration_types = @resource["parameters"].inject({}) do |acc, param|
            acc[param["id"]] = param["type"]
            acc
          end
          @decrypt = decrypt
          @service = service
        end

        def id
          @resource["id"]
        end

        def title
          configuration[id].keys[0]
        end

        # Retrieves just the parameter from the resource
        #
        # Given a resource like:
        #
        #     {"asm::idrac" => {"some.device" => {"target_boot_device" => "iSCSI"}}}
        #
        # This will return:
        #
        #     {"target_boot_device" => "iSCSI"}
        #
        # @return [Hash]
        def parameters
          configuration[id][title]
        end

        # Fetch a property from the resource
        #
        # Given a resource like:
        #
        #     {"asm::idrac" => {"some.device" => {"target_boot_device" => "iSCSI"}}}
        #
        # resource["target_boot_device"] will return "iSCSI"
        #
        # Currently does not support a case where there are multiple devices in the same resource
        #
        # @return [Object, nil] The item stored in the property, nil if no property such property exist
        def [](parameter)
          parameters[parameter]
        end

        # Returns true if the specified type is a complex type that may not be
        # overwritten using {#[]=}
        #
        # @return [Boolean]
        def complex_type(type)
          %w(NETWORKCONFIGURATION RAIDCONFIGURATION).include?(type)
        end

        # Set a property on the resource. Only "simple" properties may currently
        # be set. That limitation is primarily due to the fact that it is difficult to
        # exactly recreate the original input format via {#to_hash} for complex types.
        #
        # @see {#[]}
        # @return [Object] The newly set value
        # @raise [ASM::NotFoundException] the resource did not contain the specified parameter
        def []=(parameter, value)
          raise(ASM::NotFoundException, "Invalid property %s" % parameter) unless parameters.key?(parameter)

          param_type = @configuration_types[parameter]
          raise(StandardError, "Parameters of type %s may not be changed" % param_type) if complex_type(param_type)

          parameters[parameter] = value
        end

        # Creates an ASM::Service::Component from the resource
        #
        # These resources are most often half configured and lacks things like puppetCertName
        # keys so some guesswork has to be done here to make a valid component.
        #
        # Specifically it will when a certname is not given look if the resource has "hostname"
        # or "os_host_name" and use those else it will use "unknown". You can specify the
        # certname parameter if you can figure out a better name
        #
        # Similarly these resources almost never have the type key which is essential for
        # turning a component into a ASM::Type instance.  You can supply your own programatically
        # as you'd probably know what you're trying to achieve when you get to a place where
        # this method is useful
        #
        # @example create a ASM::Type::Server from a resource
        #
        #    service = ASM::Service.new(JSON.parse(File.read("deployment.json")))
        #
        #    vm = service.components_by_type("VIRTUALMACHINE").first
        #
        #    resource = vm.resource_by_id("asm::server")
        #    component = resource.to_component(nil, "SERVER")
        #    type = component.to_resource(deployment, Logger.new(STDOUT))
        #
        # @note this has not been extensively tested, only used in the virtualmachine providers
        #       now so expect edge cases due to almost arbitrary nature of component resources
        #       it just will not work in all cases
        # @param certname [String] a optional certificate name to use for the component
        # @param type [String] an optional component type like SERVER or STORAGE
        # @return [ASM::Service::Component]
        # @raise [StandardError] when a resource is too incomplete to succesfully be turned into a component
        def to_component(certname=nil, type=nil)
          component_hash = {}
          component_hash["resources"] ||= [to_hash]
          component_hash["type"] = type if type

          if certname
            component_hash["puppetCertName"] = certname
          else
            detected_hostname = self["hostname"] || self["os_host_name"] || "unknown"
            component_hash["puppetCertName"] ||= "unknown-%s" % detected_hostname
          end

          Component.new(component_hash, @decrypt, @service)
        end

        def to_hash
          ret = @resource.clone
          # Capture any parameters that may have been changed
          ret["parameters"] = []
          @resource["parameters"].each do |orig|
            param = orig.clone
            # Match original format where all non-nil values are strings
            unless param["id"] == "title" || parameters[param["id"]].nil? || complex_type(param["type"])
              param["value"] = parameters[param["id"]].to_s
            end
            ret["parameters"] << param
          end
          ret
        end
      end
    end
  end
end

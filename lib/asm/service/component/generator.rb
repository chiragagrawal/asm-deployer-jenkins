require "asm/util"
require "asm/type"
require "securerandom"

module ASM
  class Service
    class Component
      # Generates hashes like those found in templates for each component
      class Generator
        attr_accessor :puppet_certname, :id, :component_id, :name, :teardown, :guid, :resources
        attr_accessor :related_components, :manage_firmware

        attr_reader :type

        def initialize(certname)
          @puppet_certname = certname
          @id = SecureRandom.uuid
          @component_id = nil
          @name = nil
          @teardown = false
          @guid = nil
          @resources = []
          @related_components = {}
          @manage_firmware = false
          @type = nil
        end

        # Add a related component to the component
        #
        # @param component [Component, String] a ASM::Service::Component instnace or string matching a component id
        # @param type [String] when giving a component id this should be a paramater type like STRING
        # @raise [StandardError] when no type is given or for invalid types
        # @return [void]
        def add_related_component(component, type=nil)
          if component.is_a?(ASM::Service::Component)
            @related_components[component.id] = component.type
          else
            raise("Need a type for the related component %s" % component) unless type
            raise("Type %s is not a valid component type" % type) unless valid_type?(type)

            @related_components[component] = type
          end
        end

        # Adds a resource to the component
        #
        # In order for a component to be valid it must have a resource with
        # a parameter id of "title"
        #
        # @param id [String] The resource id like asm::server
        # @param name [String] A resource name
        # @param parameters [Array<Hash>] array of parameters needing at least :id, and :value
        def add_resource(id, name, parameters)
          resource = {
            "id" => id,
            "displayName" => (name || "Generated Resource"),
            "parameters" => []
          }

          parameters.each do |param|
            resource["parameters"] << {
              "id" => param[:id],
              "value" => param[:value],
              "type" => param.fetch(:type, "STRING")
            }
          end

          @resources << resource
        end

        # Checks if a parameter was added matching a given id
        #
        # @return [Boolean]
        def has_parameter?(id)
          params = @resources.map do |resource|
            resource["parameters"].map do |param|
              param["id"]
            end
          end.compact.flatten

          params.include?(id)
        end

        def to_component_hash
          raise("Components need :id set") unless @id
          raise("Components need :puppet_certname set") unless @puppet_certname
          raise("Components need :type") unless @type
          raise("Components need resources") if @resources.empty?
          raise("Components must have titles") unless has_parameter?("title")

          {
            "id" => @id,
            "componentID" => (@component_id || "generated_%s_component_%d" % [type.downcase, Time.now.to_i]),
            "puppetCertName" => @puppet_certname,
            "name" => (@name || "Generated %s Component" % [@type.capitalize]),
            "type" => @type,
            "teardown" => @teardown,
            "asmGUID" => @guid,
            "relatedComponents" => (@related_components || []),
            "resources" => @resources,
            "manageFirmware" => !!@manage_firmware
          }
        end

        # Checks a type against the known types in the type system
        #
        # @param type [String] the type name like CLUSTER
        # @return [Boolean]
        def valid_type?(type)
          Type.providers.map {|p| p[:type].upcase}.include?(type.upcase)
        end

        # Sets the component type
        #
        # A valid type would be something like CLUSTER, ones for which a type exist in ASM::Types
        #
        # @raise [StandardError] for invalid types
        # @return [void[
        def type=(type)
          if valid_type?(type)
            @type = type.upcase
          else
            raise("Invalid type %s" % type)
          end
        end
      end
    end
  end
end

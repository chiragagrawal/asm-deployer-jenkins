module ASM
  class Provider
    class Base
      require "asm/provider/phash"
      require "asm/translatable"

      attr_accessor :uuid

      # Set the ASM::Type::Base instance this provider is part of
      #
      # @return [ASM::Type::Base]
      attr_writer :type

      include Phash
      extend Phash::ClassMethods

      include ASM::Translatable

      # @visibility private
      def self.inherited(klass)
        type = klass.to_s.split("::")[2]
        Type.register_provider(type, klass)
      end

      # Set or get the puppet types for this provider, any resource found that matches
      # any of these types will be handled by an instance of this provider.  These should
      # be unique across all providers
      #
      # The first one listed will be used as the type created by to_puppet
      #
      # When no type has been set yet, [] will be returned
      #
      # @example Set multiple types
      #    puppet_type "asm::foo", "asm::bar"
      #
      # @return [Array] the puppet types
      def self.puppet_type(*types)
        if !types.empty?
          @__puppet_types = types
        else
          @__puppet_types || []
        end
      end

      # Set or get the puppet run type for this provider, this defaults to
      # "apply", valid values are "device" or "apply"
      #
      # @return [String] the puppet type
      # @raise [ArgumentError] for invalid run types
      def self.puppet_run_type(type=nil)
        if type
          if ["apply", "device"].include?(type)
            return @puppet_run_type = type
          else
            raise(ArgumentError, "Invalid puppet_run_type '%s'" % type)
          end
        end

        @puppet_run_type || "apply"
      end

      # List of facts to parse as JSON strings.
      #
      # These are in the form ["fact", default] so an entry of
      # ["interfaces", {}] would parse the interfaces fact and if
      # its not present default it to a empty hash.  As this is the
      # most common a shorthand of just "interfaces" achieves the same
      #
      # Inheriting providers should override this and call super, merging
      # the two results with +
      #
      # @return [Array<String>,Array<String,Object>]
      def json_facts
        []
      end

      # Normalize inventory facts into data structures
      #
      # The inventory will return some structured facts as JSON text,
      # this method should be called after any update of the fact property
      # to ensure those JSON text gets turned into appropriate data
      #
      # For providers what have their own JSON facts to contribute they
      # can define a method json_facts that should append to what the super
      # method produce. See {Provider::Switch::Base#json_facts} for an example
      #
      # @return [void]
      def normalize_facts!
        json_facts.uniq.each do |fact|
          if fact.is_a?(Array)
            parse_json_fact(fact[0], fact[1])
          else
            parse_json_fact(fact)
          end
        end
      end

      # Parse a fact that holds a JSON string otherwise populate it with a default
      #
      # This has various work around and special handling, some JSON facts are not
      # always JSON but somtimes just a string that would need to become a array
      # containing the string.cw
      #
      # So in the case of a default being an array it will check if the string
      # starts with "[" and only parse it then, if it does not start with "[" it will
      # just turn the found data into an array containing the found data
      #
      # @param [String] fact_name the name of the fact to process
      # @param [Object] default the value to assign to the fact if it's not present
      # @raise [StandardError] when data cannot be parsed
      # @return [void]
      def parse_json_fact(fact_name, default={})
        if @__facts[fact_name].is_a?(String)
          if default.is_a?(Array)
            if @__facts[fact_name].start_with?("[")
              @__facts[fact_name] = JSON.parse(@__facts[fact_name])
            else
              @__facts[fact_name] = Array(@__facts[fact_name])
            end
          else
            # can't coerce a string into a hash like with arrays so
            # just try and fail rather than be overly clever
            @__facts[fact_name] = JSON.parse(@__facts[fact_name])
          end
        end

        @__facts[fact_name] ||= default
      end

      # Returned the cached facts or retrieve and cache it
      #
      # use {#retrieve_facts!} to force an update
      #
      # @return [Hash]
      # @raise [StandardError]
      def retrieve_facts
        facts || retrieve_facts!
      end

      # Retrieves the facts stored by PuppetDB and update a local cache
      #
      # @todo make thread safe, see Service::SwitchCollection#update_inventory
      # @return [Hash]
      # @raise [StandardError]
      def retrieve_facts!
        self.facts = type.facts_find
      end

      # Retrieve the facts for the host
      #
      # @return [Hash] stored facts, {} when unset
      def facts
        return @__facts if @__facts

        retrieve_facts!
      end

      # Sets the facts for the
      #
      # Facts will be normalized via {#normalize_facts!}
      #
      # @return [Hash] normalized facts
      # @raise [StandardError] when invalid data is stored
      def facts=(raw_facts)
        unless raw_facts.is_a?(Hash)
          raise("Facts has to be a hash, cannot store facts for %s" % type.puppet_certname)
        end

        @__facts = raw_facts

        normalize_facts!

        @__facts
      end

      def debug?
        type.debug?
      end

      # (see ASM::Type::Base#db_log)
      def db_log(level, message, options={})
        type.db_log(level, message, options)
      end

      # Captures the current state of the resource and run Puppet to process the
      # deployment.
      #
      # Puppet has a number of modes - device or apply - it will use the {#puppet_run_type}
      # property of the provider to determine which to use, +apply+ is the default
      #
      # @param options [Hash] Options used when processing the resource
      # @option options [Hash] :append_to_resources Do not call Puppet, just append the resources to the provided set
      # @option options [Hash] :update_inventory request a inventory update after the puppet run
      # @return [void]
      def process!(options={})
        if options[:append_to_resources]
          options[:append_to_resources].merge!(to_puppet)
        else
          resources = to_puppet

          logger.debug("Doing process_generic for %s with puppet run type %s in provider %s" % [type.puppet_certname, puppet_run_type, to_s])
          logger.info("Resources for %s:\n %s" % [type.puppet_certname, resources.pretty_inspect])
          type.process_generic(type.puppet_certname, resources, puppet_run_type, true, nil, type.guid, options.fetch(:update_inventory, false))
        end
      end

      # Configures the provider instance using a set of properties
      #
      # Components from the template maps to the properties defined in the type, this method
      # will iterate the known properties and set any values found in the incoming configuration
      #
      # If provider authors want to do custom configuration - like vary some options during teardown
      # or compute a specific value from other information if not set then rather than override
      # this method with your own logic you can just create a *configure_hook* method which would
      # be call after the basic configuration is done
      #
      # @return [void]
      def configure!(config)
        config.collect do |uuid, resource|
          @uuid = uuid

          properties.each do |property|
            next unless resource.include?(property)

            self[property] = resource[property]
          end
        end

        if respond_to?(:configure_hook)
          logger.debug("Calling %s provider configure_hook to complete configuration" % [self.class])
          configure_hook
        end

        logger.debug("Configured %s provider with resource %s for %s" % [self.class, @uuid, puppet_type])
      end

      # Get the type the provider is part of
      #
      # @return [ASM::Type::Base]
      # @raise [StandardError] when no type was set
      def type
        @type || raise("The type has not been set")
      end

      def logger
        type.logger
      end

      def to_s
        "#<%s uuid: %s type: %s certname: %s>" % [self.class, @uuid, puppet_type, type.puppet_certname]
      end

      # The puppet type this Provider is configured to use
      #
      # This proxies {ASM::Provider::Base#puppet_type} but while that returns an
      # array this returns the first entry in that array thus ensuring that all created
      # resources are of the primary type - the first one in the list
      #
      # @return [String] the primary type
      def puppet_type
        self.class.puppet_type.first || raise("The puppet type has not been set")
      end

      def puppet_run_type
        self.class.puppet_run_type
      end

      # Creates additional resources for merging into the Puppet run
      #
      # @return [Hash] additional resources
      def additional_resources
        {}
      end

      # Creates a standard puppet hash ready for processing with process_generic
      #
      # The final puppet resource contains a number of parts:
      #
      #   * First the component resources will be fetched and stored
      #   * It will then create the resource of the type including all properties tagged as :puppet
      #   * It will then call a *additional_resources* and merge any resources
      #
      # The ordering is specific. So that the component resources will be overrode
      # by the type and the type can vary it's own behaviour by using *additional_resources*
      #
      # @return [Hash] Puppet resources
      def to_puppet
        resources = {}

        unless properties(:puppet).empty?
          resources.merge!(type.component_configuration)
          resources[puppet_type] = {@uuid => to_hash(true, :puppet)}
        end

        additional = additional_resources
        resources.merge!(additional) if additional.is_a?(Hash)

        resources
      end

      # Determines if inventory should be run for a specific piece of hardware
      #
      # @api private
      # @return [Boolean]
      def should_inventory?
        return true if debug?
        return true if puppet_run_type == "device"

        if puppet_run_type == "apply"
          if config = type.device_config
            return true if config[:provider] == "script"
          end
        end

        false
      end

      # Updates the inventory of a device using {ASM::DeviceManagement#run_puppet_device!}
      #
      # Provider authors can customise their inventory lookup methods here, the ASM default
      # is good for most
      #
      # @api private
      # @return [void]
      # @raise [ASM::DeviceManagement::SyncException] when a inventory update is already in progress
      # @raise [StandardError] on any failure encountered during gathering of device data
      def update_inventory
        logger.info("Updating inventory data for %s using DeviceManagement" % type.puppet_certname)
        ASM::DeviceManagement.run_puppet_device!(type.puppet_certname, logger) unless debug?

        if type.guid
          logger.info("Updating inventory for guid %s using DeviceManagemnet" % type.guid)
          ASM::DeviceManagement.run_puppet_device!(type.guid, logger) unless debug?
        end
      end

      # (see ASM::Type::Base#supports_resource?)
      def supports_resource?(resource)
        type.supports_resource?(resource)
      end

      # Determines if a Volume resource is supported by this resource
      #
      # Unless a provider overrides this method it supports everything
      #
      # @return [Boolean]
      def volume_supported?(volume)
        true
      end

      # Determines if a Server resource is supported by this resource
      #
      # Unless a provider overrides this method it supports everything
      #
      # @return [Boolean]
      def server_supported?(server)
        true
      end

      # Determines if a Cluster resource is supported by this resource
      #
      # Unless a provider overrides this method it supports everything
      #
      # @return [Boolean]
      def cluster_supported?(cluster)
        true
      end

      # Determines if a Virtualmachine resource is supported by this resource
      #
      # Unless a provider overrides this method it supports everything
      #
      # @return [Boolean]
      def virtualmachine_supported?(cluster)
        true
      end

      # (see ASM::Type::Base#prepare_for_teardown!)
      def prepare_for_teardown!
        true
      end

      # Determines if a Controller resource is supported by this resource
      #
      # Unless a provider overrides this method it does not support anything
      # due to the nature of this resource type it would only ever be supported
      # on specific kind of server so false is a good default
      #
      # @return [Boolean]
      def controller_supported?(controller)
        false
      end

      # Determines if a Switch resource is supported by this resource
      #
      # Unless a provider overrides this method it supports everything
      #
      # @return [Boolean]
      def switch_supported?(switch)
        true
      end
    end
  end
end

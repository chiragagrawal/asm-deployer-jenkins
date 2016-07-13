require "asm/translatable"
require "asm/service"
require "asm/private_util"
require "asm/device_management"
require "forwardable"

module ASM
  class Type
    class Base
      extend Forwardable

      include ASM::Translatable

      # Select a list of providers that meet some criteria satisfied by a block
      #
      # @example find providers that handles "asm::idrac" using the puppet_type method
      #
      #   ASM::Type::Controller.provider_names(logger) do |provider|
      #     Array(provider[:class].puppet_type).include?("asm::idrac")
      #   end
      #
      #   #=> ["Idrac"]
      #
      # @return [Array<String>] provider names like 'Idrac'
      def self.select_providers
        type = to_s.downcase.split("::").last.capitalize
        possible_providers = Type.providers.select {|p| p[:type] == type}

        providers = possible_providers.select do |provider|
          yield(provider)
        end

        providers.map do |provider|
          provider[:class].to_s.split("::").last
        end
      end

      # Within the providers for the type find a provider to handle a puppet type
      #
      # @raise [StandardError] when no provider can be found to handle the puppet type
      def self.provider_name(resource_type_name)
        providers = select_providers do |provider|
          Array(provider[:class].puppet_type).include?(resource_type_name)
        end

        if providers.empty?
          raise("Could not find a provider for resource type '%s' within types of class %s" % [resource_type_name, self.class])
        end

        providers[0]
      end

      # Creates a Type instance from a Component
      #
      # @param component [ASM::Service::Component] the component to turn into a type
      # @return [ASM::Type::Base]
      def self.create(component, logger=ASM.logger)
        provider = nil
        resource = nil

        component.resource_ids.each do |resource_id|
          begin
            provider = provider_name(resource_id)
            resource = component.configuration[resource_id]
          rescue
            next
          end

          break
        end

        unless provider
          raise("Could not find a provider to handle configuration for component %s with resources %s using type %s" % [component.to_s, component.resource_ids.join(", "), self])
        end

        new(component, provider, resource, logger)
      end

      attr_reader :provider_config, :component, :service_component, :provider_name
      attr_accessor :deployment, :logger, :puppet_certname

      # @method process!
      # @method to_puppet
      def_delegators :provider, :process!, :to_puppet, :ensure, :ensure=, :uuid, :uuid=
      def_delegators :service_component, :component_id, :id, :teardown, :name, :guid, :type, :teardown?, :brownfield?
      def_delegator :service_component, :configuration, :component_configuration

      def initialize(component, provider_name, provider_config, logger=ASM.logger)
        @service_component = component
        @component = component.to_hash
        @provider_name = provider_name.downcase
        @provider_config = provider_config
        @logger = logger
        @puppet_certname = service_component.puppet_certname
        @provider_configure_mutex = Mutex.new

        startup_hook
      end

      def startup_hook
        true
      end

      # Retrieves the deployment data instance for the associated deployment
      #
      # @return [Data::Deployment, nil]
      def database
        service.database
      rescue
        logger.warn("Error accessing the service database: %s: %s" % [$!.class, $!.to_s])
        nil
      end

      # Retrieves the component status from the database components table
      #
      # Uses {Data::Deployment#get_component_status}
      #
      # @raise [ASM::Data::NoExecution] when no execution is configured in the db
      # @return [String, nil] the component status from the database
      def db_execution_status
        begin
          status = database.get_component_status(id)
        rescue ASM::Data::NoExecution
          raise
        rescue
          logger.warn("Could not retrieve deployment status from the database for id %s: %s: %s" % [id, $!.class, $!.to_s])
          status = nil
        end

        status ? status[:status] : nil
      end

      # Sets the component status during a deployment
      #
      # @param status [Data::VALID_STATUS_LIST]
      # @return [void]
      # @raise [StandardError] as per {Data::Deployment#set_component_status}
      def db_status!(status)
        database.set_component_status(id, status)
      rescue StandardError, NoMethodError
        logger.warn("Failed to set database status for %s to %s: %s: %s" % [puppet_certname, status, $!.class, $!.to_s])
      end

      # Sets the component status in the database to pending
      def db_pending!
        db_status!("pending")
      end

      # Sets the component status in the database to in progress
      def db_in_progress!
        db_status!("in_progress")
      end

      # Sets the component status in the database to complete
      def db_complete!
        db_status!("complete")
      end

      # Sets the component status in the database to error
      def db_error!
        db_status!("error")
      end

      # Sets the component status in the database to cancelled
      def db_cancelled!
        db_status!("cancelled")
      end

      # Saves text to a file in the deployment dir
      #
      # @param contents [String] the file contents
      # @param file_name [String] the name of the file in the deployment dir
      # @return [String] the path to the saved file
      def save_file_to_deployment(contents, file_name)
        config_file = type.deployment_file(file_name)

        File.open(config_file, "w") do |file|
          file.write(contents)
        end

        config_file
      end

      def deployment_file(*file)
        deployment.deployment_file(*file)
      end

      def debug?
        deployment.debug?
      rescue
        ASM.config.debug_service_deployments
      end

      # User facing logging method
      #
      # Puts a log message into the deployment database for exposure through
      # the GUI and inclusion in the deployment XML
      #
      # @note supports ASM::Translatable
      # @note this will not log when debug is true unless override in options
      #
      # @example
      #   db_log(:info, t(:ASM063, "Validating Vlan for %{server}", :server => server.puppet_certname))
      #
      # @param level [:info, :warn, :debug, :error]
      # @param message [ASM::Translatable] translatable log message
      # @param options [Hash]
      # @option options [String] :deployment_id the deployment_id to save the message to
      # @option options [Boolean] :server_log (true) also log to server
      # @option options [Boolean] :override_debug (true) set to false to have message show up in debug mode
      def db_log(level, message, options={})
        options = {:override_debug => false}.merge(options)
        logger.send(level, message) if options[:server_log]
        database.log(level, message, options) if options[:override_debug] || !debug?
      end

      def service_teardown?
        service.teardown?
      end

      def type_name
        self.class.to_s.downcase.split("::").last
      end

      def management_ip
        device_config["host"]
      end

      # @api private
      def get_provider_class(provider_name)
        klass_type = ::ASM::Provider.const_get(type_name.capitalize)
        klass_type.const_get(provider_name.capitalize)
      end

      def provider
        @provider_configure_mutex.synchronize do
          unless @provider
            klass = get_provider_class(@provider_name)

            @provider = klass.new
            @provider.type = self
            @provider.configure!(@provider_config)
          end
        end

        @provider
      end

      # A helper to log and forward a method call to another object
      #
      # We often need to set up proxy methods in types where the type will call a method
      # on a provider.  It's good to log these calls for debug purposes to be sure we're
      # calling the right object and so forth but it's tedious to log every time.
      #
      # @example Typically we'd use a wrapper method like this:
      #    def remove_server_from_volume!(server)
      #       logger.debug("Calling remove_server_from_volume! for server %s" % server.to_s)
      #       provider.remove_server_from_volume!(server)
      #    end
      #
      # @example This will get tedious for types with many methods and yield inconsistent logging, so this helper lets you do:
      #    def remove_server_from_volume!(server)
      #      delegate(provider, :remove_server_from_volume!, server)
      #    end
      #
      # And will cause standard log lines to be produced that shows the caller, destination object
      # and method
      #
      # @api private
      # @raise Any exception from the called method
      # @return Any return value from the called method
      def delegate(target, method, *args)
        logger.debug("%s calling delegated method %s on %s" % [File.basename(caller[1]), method, target.to_s])
        target.send(method, *args)
      end

      # Extracts a Service Tag from a standard format certificate name
      #
      # @return [String]
      def cert2serial(cert_name=nil)
        /^[^-]+-(.*)$/.match(cert_name || puppet_certname)[1].upcase
      end
      alias_method :cert2servicetag, :cert2serial

      # Determines if inventory should be run for a specific piece of hardware
      #
      # @return [Boolean]
      def should_inventory?
        provider.should_inventory?
      end

      # Updates the inventory of a device
      #
      # It will check using {#should_inventory?} if the device supports being inventoried
      #
      # This proxies to the provider, so different hardware can support different inventory methods
      #
      # @return (see ASM::Provider::Base#update_inventory)
      # @raise (see ASM::Provider::Base#update_inventory)
      def update_inventory
        if should_inventory?
          logger.info("Updating inventory for %s" % puppet_certname)
          @inventory = nil
          provider.update_inventory
          retrieve_inventory!
        else
          logger.info("update_inventory called for %s but it does not support being inventoried" % puppet_certname)
        end
      end
      alias_method :update_inventory!, :update_inventory

      # Save facts back to PuppetDB
      #
      # @return [void]
      # @raise [StandardError] on failure to save
      def save_facts!
        if deployment
          logger.info("Updating %s facts with %s" % [puppet_certname, facts])
          deployment.puppetdb.replace_facts_blocking!(puppet_certname, facts)
        else
          logger.warn("Unable to save facts for %s without deployment" % puppet_certname)
        end
      end

      # Determines if ASM is managing the device
      #
      # @return [Boolean]
      def managed?
        state = retrieve_inventory.fetch("state", "UNMANAGED")
        !["UNMANAGED", "RESERVED"].include?(state)
      end

      # Determines if the inventory for a device is invalid
      #
      # This might happen when a device gets deleted mid deploy where
      # it once existed.  A called might request an inventory update
      # which will fetch from PuppetDB but when it does so the device
      # is gone.  In that case the inventory will be an empty Hash.
      #
      # @return [Boolean]
      def valid_inventory?
        inventory = retrieve_inventory

        inventory && inventory.is_a?(Hash) && !inventory.empty?
      end

      # Returned the cached inventory or retrieve and cache it
      #
      # use {#retrieve_inventory!} to force an update
      #
      # @return [Hash] in the format seen in spec/fixtures/asm_server_m620.json
      def retrieve_inventory
        @inventory || retrieve_inventory!
      end

      # Retrieves the inventory stored by ASM Server RA and update a local cache
      #
      # @todo this should use Util.fetch_managed_device_inventory and server types should use this code
      # @return [Hash] in the format seen in spec/fixtures/asm_server_m620.json or empty when fetching failed
      def retrieve_inventory!
        if (inventory = PrivateUtil.fetch_managed_device_inventory(puppet_certname).first)
          @inventory = inventory
        else
          logger.warn("Could not retrieve inventory for %s, nil was returned from fetch_managed_device_inventory" % [puppet_certname])
          @inventory = {}
        end
      end

      # Parses the device configuration
      #
      # @return [Hashie::Mash, nil] nil when the config cannot be found
      def device_config
        ASM::DeviceManagement.parse_device_config(puppet_certname)
      end

      # Run process_generic on the deployment and surpress running inventories
      #
      # Updating of inventories are to be done in a rule
      #
      # @param cert_name [String] the certificate name to process
      # @param config [Hash] a set of puppet resource asm process_node will accept
      # @param puppet_run_type ["device", "apply"] the way puppet should be run
      # @param override [Boolean] override config file settings
      # @param server_cert_name [String] allow customization of log file names for shared devices
      # @param asm_guid [String] internal ASM inventory GUID
      # @param update_inventory [Boolean] instruct the {ServiceDeployment#process_generic} to do inventory updates
      # @return [Hash] the results from the puppet run
      def process_generic(cert_name, config, puppet_run_type, override=true, server_cert_name=nil, asm_guid=nil, update_inventory=false)
        if config.empty?
          logger.debug("Skipping puppet run for %s as the supplied config hash is empty" % cert_name)
          return {}
        end

        if !debug?
          result = deployment.process_generic(cert_name, config, puppet_run_type, override, server_cert_name, asm_guid, update_inventory)
        else
          require "pp"
          logger.info("Would have run process_generic for %s using %s" % [cert_name, puppet_run_type])
          logger.info("\n%s" % config.pretty_inspect)
          result = {}
        end

        result
      end

      def provider_path
        "%s/%s" % [type_name, @provider_name]
      end

      # Validates the relationships between this resource and another
      #
      # Given a resource it will extract the resource type from it and then run
      # a type specific check on the provider.  The current list of methods
      # being called are {ASM::Provider::Base#volume_supported?},
      # {ASM::Provider::Base#server_supported?}, {ASM::Provider::Base#cluster_supported?}
      # {ASM::Provider::Base#virtualmachine_supported?}
      #
      # This allow provider writers to declare their support for other related systems
      # for example ASM does not support using NetAPP volumes with HyperV so the
      # {ASM::Provider::Volume::Netapp#cluster_supported?} method enforces that
      # it only supports VMWare today
      #
      # @param resource [ASM::Type::Base] Any valid resource type
      # @return [Boolean]
      def supports_resource?(resource)
        logger.debug("Checking if provider %s supports a resource of provider %s" % [provider_path, resource.provider_path])

        case resource.type_name
        when "volume"
          provider.volume_supported?(resource)
        when "server"
          provider.server_supported?(resource)
        when "cluster"
          provider.cluster_supported?(resource)
        when "virtualmachine"
          provider.virtualmachine_supported?(resource)
        when "controller"
          provider.controller_supported?(resource)
        when "switch"
          provider.switch_supported?(resource)
        else
          raise("Do not know how to check if a resource of type %s is supported" % resource.type_name)
        end
      end

      def to_s
        "#<%s:%s:%s %s>" % [self.class, object_id, provider_path, puppet_certname]
      end

      # Retrieves facts from PuppetDB
      #
      # @return [Hash] as per ASM::PrivateUtil.facts_find
      def facts_find
        # deep copy the facts mainly to make debugging easier, the fact normalization
        # will edit the facts in place and under a debugger that means the fixtures
        # are edited
        Marshal.load(Marshal.dump(ASM::PrivateUtil.facts_find(puppet_certname)))
      end

      # Retrieves the normalized facts from a provider
      #
      # If you need to get a copy of the original facts
      # as in PuppetDB please use {#facts_find}
      #
      # @return [Hash] or normalized facts
      def facts
        provider.facts
      end

      def retrieve_facts!
        provider.retrieve_facts!
      end

      # Find related components in the current deployment
      #
      # @param type [String] a type like CLUSTER, SERVER, STORAGE etc
      # @return [Array<ASM::Type::Base>] found components as resources
      def related_components(type)
        components = service_component.related_components(type)
        if type == "SWITCH"
          components.map do |component|
            switch_collection.switch_by_certname(component.puppet_certname)
          end
        else
          components.map do |component|
            service.resource_by_id(component.id)
          end
        end
      end

      # Find the first related server
      #
      # @return [ASM::Type::Server, nil] nil when none are found
      def related_server
        related_servers.first
      end

      # Find the first related virtual machine
      #
      # @return [ASM::Type::Virtualmachine]
      def related_vm
        related_vms.first
      end

      # Find the first related cluster
      #
      # @return [ASM::Type::Cluster, nil] nil when none are found
      def related_cluster
        related_clusters.first
      end

      # Find all related clusters
      #
      # @return [Array<ASM::Type::Cluster>]
      def related_clusters
        related_components("CLUSTER")
      end

      # Find all related servers
      #
      # @return [Array<ASM::Type::Server>]
      def related_servers
        related_components("SERVER")
      end

      # Find all related virtual machines
      #
      # @return [Array<ASM::Type::Virtualmachine]
      def related_vms
        related_components("VIRTUALMACHINE")
      end

      # Find all related volumes
      #
      # @return [Array<ASM::Type::Volume>]
      def related_volumes
        related_components("STORAGE")
      end

      # Find all related switches
      #
      # @return [Array<ASM::Type::Switch>]
      def related_switches
        related_components("SWITCH")
      end

      # Prepares a resource for teardown
      #
      # Steps that need to be taken to prepare a related resources for
      # teardown can go in here,  types can do more or less anything they
      # need in here including custom teardown steps.
      #
      # Should these steps remove the need for process! to be run or
      # just wish to short circuit that or prevent teardown they should
      # return false
      #
      # @return [Boolean] false to indicate process! should be skipped
      def prepare_for_teardown!
        delegate(provider, :prepare_for_teardown!)
      end

      def service
        service_component.service
      end

      def switch_collection
        service.switch_collection
      end

      def add_relation(resource)
        service_component.add_relation(resource.service_component)
      end

      # Processes a block with retries and sleep between
      #
      # @param tries [Fixnum] how many times to try
      # @param sleep_time [Fixnum] how long to sleep for
      # @param fail_msg [String] a message to log on failure
      # @raise [StandardError] any raised error from the block or when no block is given
      def do_with_retry(tries, sleep_time, fail_msg)
        raise("A block is required for do_with_retry on %s" % puppet_certname) unless block_given?

        begin
          yield
        rescue
          logger.warn("%s sleeping for %s: %s: %s" % [fail_msg, sleep_time, $!.class, $!.to_s])

          raise if (tries -= 1) <= 0

          sleep(sleep_time)

          retry
        end
      end
    end
  end
end

require "asm/item_validator"

module ASM
  class Provider
    # helper module to provider hash like access to provider properties but with
    # built in concepts of default values and validation.
    #
    # code is based on https://github.com/ripienaar/gwtf/blob/master/lib/objhash.rb
    module Phash
      include Enumerable

      module ClassMethods
        # Defines a property including it's defaults and validation
        #
        # @macro [attach] phash.property
        #   Provides access to the $1 property of the resource
        #
        #   When setting a value using $1=(value) validation is done using {ASM::ItemValidator}
        #   and inputs are expected to pass validation as defined in +$3+
        #
        #   When accessing a value using the $1 method the default is returned when nothing
        #   has been set, defaults can be something that do not pass validation - something can
        #   be nil by default while setting something would require a String matching a regex
        #   for example
        #
        #   @method $1
        #   @method $1=(value)
        #
        #   @attribute
        #   @return The value stored, +$2+ if none is set, type depends on stored data
        #   @raise [StandardError] when attempting read or write to a non existing property
        #   @raise [StandardError] when attempting to write data that does not pass validation
        def property(name, args={:default => nil, :validation => nil, :tag => [:puppet]})
          invalid_keys = args.keys.reject {|k| [:default, :validation, :tag].include?(k)}
          raise("Invalid keys for property %s: %s" % [name, invalid_keys.join(", ")]) unless invalid_keys.empty?

          name = name.to_s
          raise("Already have a property %s" % name) if phash_config.include?(name)

          args[:tag] = Array(args[:tag]) if args[:tag]

          phash_config[name] = {:default => nil, :validation => nil, :tag => [:puppet]}.merge(args)
        end

        # @api private
        def phash_config
          @__phash_config ||= {}
        end

        # @api private
        def phash_default_value(property)
          property = property.to_s

          raise("Unknown property %s" % property) unless phash_config.include?(property)

          if phash_config[property][:default].is_a?(Proc)
            phash_config[property][:default].call
          else
            phash_config[property][:default]
          end
        end

        # @api private
        def phash_reset!
          @__phash_config = {}
        end
      end

      # @api private
      def default_property_value(property)
        default = self.class.phash_default_value(property)

        begin
          default = Marshal.load(Marshal.dump(default))
        rescue # rubocop:disable Lint/HandleExceptions
        end

        default
      end

      # @api private
      def phash_config
        self.class.phash_config
      end

      # @api private
      def phash_values
        return @__phash_values if @__phash_values

        @__phash_values = {}

        phash_config.each_pair do |property, _|
          update_property(property, default_property_value(property), true)
        end

        @__phash_values
      end

      def include?(property)
        phash_config.include?(property.to_s)
      end

      # Updates the value of a property, supports munging and calling hooks
      #
      # @example munging a value before saving it
      #
      #     property :facts, :default => {}, :validation => Hash
      #
      #     def facts_update_munger(old, new)
      #        new.is_a?(String) ? JSON.parse(new) : new
      #     end
      #
      # @example being notified when a value changes
      #
      #     def facts_update_hook(old)
      #        # do stuff with old and self.facts
      #     end
      #
      # @api private
      # @param property [String] the property name being updated
      # @param value [Object] the value being stored
      # @param setup [Boolean] set to true during object initialization so hooks and mungers dont fire while setting defaults
      def update_property(property, value, setup=false)
        property = property.to_s

        raise("Unknown property %s" % property) unless include?(property)

        munger = ("%s_update_munger" % property).intern
        hook = ("%s_update_hook" % property).intern
        old_value = phash_values[property]

        value = send(munger, old_value, value) if !setup && has_hook_method?(munger)

        validate_property(property, value)

        phash_values[property] = value

        send(hook, old_value) if !setup && has_hook_method?(hook)

        value
      end

      # @api private
      def validate_property(property, value)
        raise("Unknown property %s" % property) unless include?(property)

        validation = phash_config[property.to_s][:validation]

        return true if validation.nil?

        # if the value is the default we dont validate it allowing nil
        # defaults but validation only on assignment of non default value
        return true if value == phash_config[property.to_s][:default]

        raise("%s should be %s but got %s" % [property, validation, value.inspect]) if value.nil? && !validation.nil?

        validated, fail_msg = ItemValidator.validate!(value, validation)

        return true if validated

        raise("%s failed to validate: %s" % [property.to_s, fail_msg])
      end

      def to_hash(exclude_nil=false, tagged=[])
        hash = {}

        properties(tagged).each do |property|
          value = get_property_value(property)

          hash[property] = value unless exclude_nil && value.nil?
        end

        hash
      end

      def each
        properties.sort.each do |property|
          yield [property, get_property_value(property)]
        end
      end

      # Obtain the value of a property and optionally call a pre-hook
      #
      # The hook is there to facilitate lazy initializing of some propeties
      #
      #   @example lazy initialize something
      #
      #   property :example, :default => nil
      #
      #   def example_prefetch_hook
      #     return if @__initialized
      #     lazy_load
      #     @__initialized = true
      #   end
      #
      #   def do_something
      #     puts example  # will only be initialized when called the first time
      #   end
      #
      # Note that initializing only happens when using method like access to a
      # property and not array like, so self.example will call the hook but
      # self[:example] will not, this is to enable self[:example] ||= something
      # to work
      #
      # @param property [Symbol,String] property name
      # @param hook [Boolean] false to disable hooks, see {#[]}
      # @return [Object] the stored data
      # @raise [StandardError] when a property is not found
      def get_property_value(property, hook=true)
        raise("No such property: %s" % property) unless include?(property)

        if hook
          hook_method = ("%s_prefetch_hook" % property).intern
          send(hook_method) if has_hook_method?(hook_method)
        end

        phash_values[property.to_s]
      end

      # @api private
      def has_hook_method?(hook)
        respond_to?(hook)
      end

      # Retrieves a property value without triggering a pre-fetch hook
      #
      # See {#get_property_value} for details on how fetch hooks work to facilitate
      # lazy initialization of data
      #
      # @param property [String,Symbol] property name
      # @return [Object] the stored data
      # @raise [StandardError] when a property is not found
      def [](property)
        get_property_value(property, false)
      end

      def []=(property, value)
        update_property(property, value)
      end

      def merge(hsh)
        raise(TypeError, "Can't merge %s into Hash" % hsh.class) unless hsh.respond_to?(:to_hash)

        to_hash.merge(hsh)
      end

      # Performs a shallow merge on hashes
      #
      # Given that phashes tend to have predefined lists of properties it does not make sense
      # to do deep merges that would contribute more properties to the hashes - since they wont
      # have property definitions and validations.
      #
      # Thus this merge will only take from the provided hash values for keys we know, discarding
      # other properties
      #
      # @param hsh [Hash]
      # @return [void]
      def merge!(hsh)
        raise(TypeError, "Can't merge %s into Hash" % hsh.class) unless hsh.respond_to?(:to_hash)

        properties.each do |k|
          update_property(k, hsh[k]) if hsh.include?(k)
        end

        self
      end

      # Retrieve a sorted list of known properties regardless of their value
      #
      # When supplying the tagged argument it should be a list of tags, any
      # property that has at least all these tags - or no tags - will be included
      # in the list.  Keep in mind the default tag for any unspecified tag when
      # creating a property is [:puppet]
      #
      # @param tagged [Array] Retrieve properties with all these tags
      # @return [Array] property names
      def properties(tagged=nil)
        if tagged
          tagged = Array(tagged)

          phash_values.select do |k, _|
            (tagged - phash_config[k][:tag]).empty?
          end.keys.sort
        else
          phash_values.keys.map(&:to_s).sort
        end
      end

      # Provides access to the hash using a object like methods
      #
      # @example simple read from the class
      #
      #   i.description #=> "Sample Item"
      #
      # @example method like writes
      #
      #   i.description "This is a test" #=> "This is a test"
      #
      # @example assignment
      #
      #   i.description = "This is a test" #=> "This is a test"
      #
      # @raise [NameError] for unknown keys or access to methods not shown above
      def method_missing(method, *args)
        method = method.to_s

        if include?(method)
          if args.empty?
            return get_property_value(method, true)
          else
            return update_property(method, args.first)
          end

        elsif method =~ /^(.+)=$/
          property = $1
          return update_property(property, args.first) if include?(property)
        end

        raise(NameError, "undefined local variable or method `%s'" % method)
      end
    end
  end
end

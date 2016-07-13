module ASM
  # Class to manage a selection of named caches and their contents
  #
  # Caches can be created on demand and each cache has a different TTL and unique contents
  #
  # @example create a cache and store something in it
  #
  #    # sets up a cache called 'bladeserver-123' with a 1200 second ttl
  #    ASM.cache.setup("bladeserver-123", 1200)
  #
  #    ASM.cache.write("bladeserver-123", :network_config, network_config)
  #    ASM.cache.read("bladeserver-123", :network_config) #=> ASM::NetworkConfiguration
  #
  # @example use the cache to create global mutexes
  #
  #    ASM.cache.setup(:some_mutex, Cache::Day)
  #
  #    # short hand dot syntax only works with symbol cache names
  #    ASM.cache.some_mutex do
  #      do_something_synchronized
  #    end
  #
  #    # equivelant longer syntax, supports cache names as strings
  #    ASM.cache.synchronize(:some_mutex) do
  #      do_something_synchronized
  #    end
  #
  # @example read or set a value in the cache based on a block
  #
  #    ASM.cache.read_or_set("bladeserver-123", :network_config) do
  #      raw_config = network_params["network_configuration"] || {"interfaces" => []}
  #      config = ASM::NetworkConfiguration.new(raw_config)
  #      config.add_nics!(device_config, :add_partitions => true)
  #      config
  #    end
  class Cache
    MINUTE = 60
    HOUR = MINUTE * 60
    DAY = HOUR * 24
    WEEK = DAY * 7

    # Create an instance of the cache manager
    #
    # Generally no arguments would be supplied, they are mainly supported to facilitate testing
    #
    # @param lock_mutex [Mutex] a Mutex used to procted access to the per cache locks
    # @param cache_locks [Hash] a store where metadata and locks for each named cache will be stored
    # @param cache [Hash] the actual stored caches
    def initialize(lock_mutex=Mutex.new, cache_locks={}, cache={}, logger=ASM.logger)
      @locks_mutex = lock_mutex
      @cache_locks = cache_locks
      @cache = cache
      @logger = logger
      @gc_thread = start_gc!
    end

    # Tend to the cache and expire any old data
    #
    # A background thread is started to wake up and manage the cache every sleep_time seconds.
    # Any keys found to have expired in any caches are evicted from the cache
    #
    # It will log it's activities roughly every 30 iiterations but will log all cache cleaning
    # failures
    #
    # @api private
    # @param sleep_time [Fixnum] how long to sleep between GCs
    # @return [Thread]
    def start_gc!(sleep_time=60)
      Thread.new do
        gc_count = 0

        loop do
          sleep sleep_time

          begin
            @logger.debug("Starting Cache GC itteration %d" % gc_count) if gc_count % 30 == 0
            gc!
            @logger.debug("Finished Cache GC itteration %d" % gc_count) if gc_count % 30 == 0
          rescue
            @logger.warn("Cache GC failed: %s: %s" % [$!.class, $!.to_s])
          end

          gc_count += 1
        end
      end
    end

    # Initiate a cache GC for every cache
    #
    # Calls {#gc_cache!} for every known cache
    #
    # @api private
    # @return [void]
    def gc!
      @locks_mutex.synchronize do
        @cache_locks.keys.each do |cache|
          gc_cache!(cache)
        end
      end
    end

    # Clears all the expired keys from a cache
    #
    # @api private
    # @param cache [String, Symbol] the unique name of this cache
    # @return [void]
    def gc_cache!(cache)
      @cache_locks[cache].synchronize do
        @cache[cache].keys.each do |key|
          next if key == :__cache_max_age

          @cache[cache].delete(key) if unsafe_ttl(cache, key) <= 0
        end
      end
    end

    # Reads or sets a key when not found
    #
    # If a block is passed the result of the block will be used to
    # set the value, block will only be called on cache miss
    #
    # If a block is passed the specific cache key will be locked for the duration
    # of the block being executed and the value saved but access to other keys should
    # continue in other threads
    #
    # @example set the result of a block to the value if not set or expired
    #
    #    result = cache.read_or_set(:cache, :key) { synchronised_data_fetcher }
    #
    # @example set the value if not set or expired
    #
    #    result = cache.read_or_set(:cache, :key, :val)
    #
    # @param cache [String, Symbol] the unique name of this cache
    # @param key [String, Symbol] unique item name to store in the cache
    # @param value [Object] anything can be stored in it
    # @raise [StandardError] when a cache has not previously been created with {#setup}
    # @return [Object] the stored value
    def read_or_set(cache, key, value=nil, &block)
      raise("No cache called '%s'" % cache) unless has_cache?(cache)

      @cache_locks[cache].synchronize do
        @cache[cache][key] ||= {
          :lock => Mutex.new,
          :item_create_time => Time.now
        }
      end

      result = @cache[cache][key][:lock].synchronize do
        if !@cache[cache][key].include?(:value) || unsafe_ttl(cache, key) <= 0
          @cache[cache][key][:value] = value.nil? ? yield : value
          @cache[cache][key][:item_create_time] = Time.now
        end

        Marshal.dump(@cache[cache][key][:value])
      end

      Marshal.load(result)
    end

    # Creates a new named cache
    #
    # Can be called many times, future calls will be noop.
    #
    # Helper constants exist for MINUTE, HOUR, DAY and WEEK to assist with constructing TTLs
    #
    # @param cache [String, Symbol] the unique name of this cache
    # @param ttl [Fixnum, Float] how long data in this cache should be valid for by default
    # @return [void]
    def setup(cache, ttl=HOUR)
      @locks_mutex.synchronize do
        break if unsafe_has_cache?(cache)

        @cache_locks[cache] = Mutex.new

        @cache_locks[cache].synchronize do
          @cache[cache] = {:__cache_max_age => Float(ttl)}
        end
      end

      nil
    end

    # Checks if a named cache exist
    #
    # @param cache [String, Symbol] unique cache name, see {#setup}
    # @return [Boolean]
    def has_cache?(cache)
      @locks_mutex.synchronize do
        unsafe_has_cache?(cache)
      end
    end

    # Checks if a named cache exist without any locking or error handling
    #
    # @api private
    # @param cache [String, Symbol] unique cache name, see {#setup}
    # @return [Boolean]
    def unsafe_has_cache?(cache)
      @cache_locks.include?(cache)
    end

    # Stores data in a named cache
    #
    # Stores an item in the cache with a key, the TTL for the item
    # matches that of the named cache as created using {#setup}
    #
    # @param cache [String, Symbol] unique cache name, see {#setup}
    # @param key [String, Symbol] unique item name to store in the cache
    # @param value [Object] anything can be stored in it
    # @raise [StandardError] when a cache has not previously been created with {#setup}
    # @return [Object] the value stored
    def write(cache, key, value)
      raise("No cache called '%s'" % cache) unless has_cache?(cache)

      @cache_locks[cache].synchronize do
        @cache[cache][key] ||= {
          :lock => Mutex.new,
          :item_create_time => Time.now
        }
      end

      @cache[cache][key][:lock].synchronize do
        @cache[cache][key][:value] = value
        @cache[cache][key][:item_create_time] = Time.now
      end

      value
    end

    # Determines how long before a item expires
    #
    # @param cache [String, Symbol] unique cache name, see {#setup}
    # @param key [String, Symbol] unique item name to store in the cache
    # @raise [StandardError] when a cache has not previously been created with {#setup}
    # @raise [StandardError] when an item can not be found on the cache
    # @return [Fixnum, Float] age till expiry, negative for already expired items
    def ttl(cache, key)
      raise("No cache called '%s'" % cache) unless has_cache?(cache)

      ttl = @cache_locks[cache].synchronize do
        unless @cache[cache].include?(key) && @cache[cache][key].include?(:value)
          raise("No item called '%s' for cache '%s'" % [key, cache])
        end

        unsafe_ttl(cache, key)
      end

      ttl
    end

    # Calculates the TTL of a item in a cache without locking the cache
    #
    # The individual cache item will still be locked though
    #
    # @param cache [String, Symbol] unique cache name, see {#setup}
    # @param key [String, Symbol] unique item name to store in the cache
    # @api private
    # @return [Fixnum, Float]
    def unsafe_ttl(cache, key)
      @cache[cache][:__cache_max_age] - (Time.now - @cache[cache][key][:item_create_time])
    rescue
      0
    end

    # Reads a key from a named cache
    #
    # @param cache [String, Symbol] unique cache name, see {#setup}
    # @param key [String, Symbol] unique item name to read from the cache
    # @raise [StandardError] when a cache has not previously been created with {#setup}
    # @raise [StandardError] when a item has expired from the cache
    # @raise [StandardError] when an item with the key name can not be found
    # @return [Object] the stored value
    def read(cache, key)
      raise("No cache called '%s'" % cache) unless has_cache?(cache)

      @cache_locks[cache].synchronize do
        if unsafe_ttl(cache, key) <= 0
          raise("Cache for item '%s' on cache '%s' has expired" % [key, cache])
        end
      end

      data = @cache[cache][key][:lock].synchronize do
        Marshal.dump(@cache[cache][key][:value])
      end

      Marshal.load(data)
    end

    # Removes something from the cache
    #
    # @param cache [String, Symbol] unique cache name, see {#setup}
    # @param key [String, Symbol] unique item name to removed from the cache
    # @raise [StandardError] when a cache has not previously been created with {#setup}
    # @return [Boolean] false when no key was found, true if it was deleted
    def evict!(cache, key)
      raise("No cache called '%s'" % cache) unless has_cache?(cache)

      @cache_locks[cache].synchronize do
        return false unless @cache[cache].include?(key)

        @cache[cache].delete(key)

        true
      end
    end

    # Use the named cache to synchronise some code
    #
    # @param cache [String, Symbol] unique cache name, see {#setup}
    # @raise [StandardError] when a cache has not previously been created with {#setup}
    # @raise [StandardError] when a block is not given
    def synchronize(cache)
      raise("No cache called '%s'" % cache) unless has_cache?(cache)

      raise("No block supplied to synchronize") unless block_given?

      @cache_locks[cache].synchronize do
        yield
      end
    end

    # Syntax sugar allowing dot access to a cache mutex
    #
    # @example synchronise a something using {#synchronize}
    #
    #    cache.setup(:bob)
    #    cache.bob do
    #       do_something
    #    end
    #
    # @note only works with cache names being symbols
    def method_missing(method, *args, &block)
      if has_cache?(method) && args.empty? && block_given?
        return synchronize(method) do
          yield
        end
      end

      super
    end
  end
end

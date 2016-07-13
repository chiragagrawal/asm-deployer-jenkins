require 'hashie'
require 'openssl'
require 'yaml'

module ASM
  class Config

    # Returns the default ASM configuration file path
    #
    # The default configuration file will be obtained from the ASM_CONFIG environment
    # variable, or if that is empty from the top-level config.yaml file.
    #
    # @return [String]
    def self.default_config_file
      ENV["ASM_CONFIG"] || File::join(File::dirname(__FILE__), '..', '..', 'config.yaml')
    end

    # Creates an {ASM::Config} object
    #
    # If the options are empty they will be loaded from {ASM::Config.default_config_file}
    #
    # @param options [Hash]
    # @return [ASM::Config]
    def initialize(options = {})
      options = YAML.load_file(ASM::Config.default_config_file) if options.empty?
      @mash = Hashie::Mash.new(options)

      [:large_process_concurrency, :large_process_max_runtime,
       :metrics_poller_concurrency, :metrics_poller_timeout].each do |key|
        # These are expected to be integers, but allow code to be specified as a string
        if @mash[key].is_a?(String)
          @mash[key] = eval(@mash[key])
        end
      end

      # Prep http_client_options for use by RestClient
      options = @mash[:http_client_options] ||= {}
      @mash[:http_client_options] = options.to_hash.dup
      [[:ssl_client_cert, OpenSSL::X509::Certificate],
       [:ssl_client_key, OpenSSL::PKey::RSA]].each do |key, init_class|
        if options[key].is_a?(String) && File.exists?(options[key])
          options[key] = init_class.new(File.read(options[key]))
        end
      end
      @mash[:rest_client_options] = options

      # url is expected to be a hash of key => url, make sure it exists
      @mash.url = {} unless @mash.url

      required_params = [:ipxe_src_dir, :generated_iso_dir] #probably missing a lot...
      missing_params = required_params.reject { |k| @mash[k] }
      raise("Missing required configuration parameters: %s" % missing_params.join(", ")) unless missing_params.empty?
    end

    def http_client_options
      @mash[:http_client_options].to_hash
    end

    def rest_client_options
      @mash[:rest_client_options].to_hash.inject({}) { |h, (k, v)| h[k.to_sym] = v; h }
    end

    # Forward methods we don't define directly to the mash
    def method_missing(sym, *args, &block)
      @mash.send(sym, *args, &block)
    end

  end
end
#!/opt/puppet/bin/ruby

$: << "/opt/asm-deployer/lib"

require "rubygems"
require "nokogiri"
require "optparse"
require "asm"
require "asm/cipher"
require "asm/nagios"

module ASM
  module Nagios
    # The Abstract base class for all supported NaviSec devices.
    #
    # For each supported device model, the suggested convention is to implement the least specific subclass
    # possible in the suggested naming format:
    #
    #  <Vendor><ProductLine>  ( most general )
    #  <Vendor><Model>        ( most specific )
    #
    # @abstract Subclass this and implement the {NaviSecDevice#checks} attribute to return an array of NaviSec query structures.
    class NaviSecDevice
      # @return [Hash] Navisec query options
      attr_accessor :options
      # @return [Hash] NaviSec query responses indexed by the name of the check used to generate that response
      attr_writer :results_cache

      # Instantiate with an optional hash
      #
      # @param opts [Hash] the options to query NaviSec
      # @option opts [String] :version The NaviSec version
      # @option opts [String] :credential The NaviSec community string
      # @option opts [String] :host The NaviSec device IP address
      # @option opts [Boolean] :debug enable logging debug messages to stderr
      # @option opts [Boolean] :cache_results enable saving results to /tmp which is useful for capturing test cases
      # @option opts [String] :model The device model, currently used only to generate the cache file {#store_cache}
      def initialize(opts={})
        @options = opts
      end

      # An array of checks to perform on a specific NaviSec enabled device.
      #
      # @example Single hash element illustrating the required data structure for a check
      #
      #    [{
      #      :name => "SP Status",                    # The name of the check.
      #      :action => "getcrus",                    # The navisec subcommand to run.
      #      :display => "Status",                    # What to display in the message.
      #      :response => /regex/                      # A regex to match the output against
      #      :processor => :process_status,           # Method to process the matched regex captures
      #      :rollup => false                         # Rollup check takes precedence over others
      #    }]
      #
      # @return [Array<Hash>] Array of checks to perform on a specific Navisec enabled device class
      def checks
        []
      end

      # Extra indirection to allow check messages to be dynamically generated
      #
      # If message_builder is a symbol, send the data to it.
      # Otherwise, if it's a string just return the string.  The symbol is specified as part of the checks structure.
      #
      # @param message_builder [String,Symbol]
      # @param data [String] the subgroup matching the response regex specified in the check.
      # @return [String]
      def build_message(message_builder, data)
        case message_builder
        when Symbol
          send(message_builder, data)
        when String
          message_builder
        else
          "Unknown"
        end
      end

      # Iterates over all device checks to determine a Nagios Status.
      #
      # The check with the worst status is reported in general unless
      # one check is marked as a rollup. In that case only its status is reported, but if
      # it is not OK, other checks will contribute to the status message.
      #
      # @param opts [Hash] (see #initialize)
      # @return [Nagios::Status]
      # @see #initialize list of available options
      # @see #checks checks attribute
      def query_navisec(opts=nil)
        self.options = opts unless opts.nil?

        exit_code = nil
        exit_message = nil
        index = 0

        if results_cache.empty?
          debug("No results\n")
          exit_code = Nagios::UNKNOWN
          exit_message = ["Invalid NaviSec credentials specified or naviseccli is disabled"]
        else

          # concrete subclasses implement checks method
          checks.each do |check|
            if results = results_cache[check[:action]]

              # Loop on possibly multiple lines of output
              results.each_line do |line|
                match = line.match(check[:response])
                send(check[:processor], *match.captures) if match
                debug(ok_output)
                debug(nok_output.join(","))
              end
            else
              debug("No results for check %s\n" % check[:name])
              next
            end
            index += 1
          end
        end

        if error_count == 0 && !ok_output.empty?
          exit_code = Nagios::OK
          exit_message = "OK"
        elsif nok_output.empty?
          exit_code = Nagios::UNKNOWN
          exit_message = "Unknown"
        else
          exit_code = Nagios::WARNING
          exit_message = nok_output.join(",")
        end

        Status.new(exit_code, exit_message)
      end

      # Hash of NaviSec query responses indexed by the name of the check used to generate that response
      #
      # @example output from NaviSec checks for
      #  {"getcrus" => "DPE7 Bus 0 Enclosure 0
      #                 SP A State:                 Present
      #                 SP B State:                 Present
      #                 Bus 0 Enclosure 0 Power A State: Present"
      #  }
      #
      # @return [Hash]
      def results_cache
        return @results_cache unless @results_cache.nil?
        @results_cache = {}

        checks.each do |check|
          navisec_cmd = check[:action]
          next if @results_cache.key? navisec_cmd
          command = "%s -User %s -Password %s -Scope 0 -Address %s #{navisec_cmd}" % options.values_at(:navisec, :username, :password, :host)
          results = `#{command}`
          @results_cache[navisec_cmd] = results
        end

        @results_cache = {} if @results_cache.values.all?(&:empty?)

        store_cache
      end

      # Store the results cache to a file.
      #
      # File is stored at /<cachedir>/<model>_<host>_navisec_results.json
      #
      # @return [Hash] the results_cache that was stored
      # @see #initialize options that affect the cache file name
      def store_cache
        if options.key? :cache_results
          json = @results_cache.to_json
          File.open("/%s/%s_%s_navisec_results.json" % [options[:cachedir], options[:model], options[:host]], "w") do |f|
            f.write(json)
          end
        end
        @results_cache
      end

      # Print a message to stderr if the debug option was set
      #
      # @param msg [String] the message to print to stderr
      # @return [void]
      def debug(msg)
        STDERR.puts msg if options.key? :debug
      end
    end

    # EMC VNX storage array
    class EmcVnx < NaviSecDevice
      # Internal state shared among processors
      # @return [Integer] error count
      attr_accessor :error_count
      # @return [String] output used only for debugging
      attr_accessor :ok_output
      # @return [Array] output strings used to build nagios output status message
      attr_accessor :nok_output
      # @return [Boolean] enclosure status seen in navisec outpu
      attr_accessor :sp_line

      def initialize
        @error_count = 0
        @ok_output = ""
        @nok_output = []
        @output = ""
        @sp_line = false
      end

      #  @return [Array<Hash>] An array of checks to perform on a VNX device class
      # (see NaviSecDevice#checks)
      def checks
        [
          {
            :name => "enclosure",
            :action => "getcrus",
            :display => "Enclosure",
            :response => /(^DPE|^SPE)/,
            :processor => :process_enclosure
          },
          {
            :name => "state",
            :action => "getcrus",
            :display => "SP state",
            :response => /^SP\s(\w+)\s\w+:\s+(\w+)/,
            :processor => :process_sp_state
          },
          {
            :name => "power",
            :action => "getcrus",
            :display => "SPS state",
            :response => /Enclosure\s(\d+|\w+)\s(\w+)\s(\w+)\d?\sState:\s+(\w+)/,
            :processor => :process_sps_state
          },
          {
            :name => "cabling",
            :action => "getcrus",
            :display => "Cabling",
            :response => /Enclosure\s(\d+|\w+)\s\w+\s(\w+)\s(\w+)\sState:\s+(\w+)/,
            :processor => :process_sps_cabling
          }
        ]
      end

      # The following check processors have argument signatures that
      # match the groups in the corresponding response regexps.

      # @return [void]
      def process_enclosure(id)
        self.sp_line = true
        self.ok_output += "Enclosure %s present" % id
      end

      # @return [void]
      def process_sp_state(id, status)
        if sp_line
          if status =~ /(Present|Valid)/
            self.ok_output += "SP #{id} #{status},"
          else
            nok_output << "SP #{id} #{status}"
            self.error_count += 1
          end
        end
      end

      # @return [void]
      def process_sps_state(enclosure, check, id, status)
        if sp_line
          if status =~ /Present|Valid|N/
            self.ok_output += "#{check} #{id} #{status},"
          else
            nok_output << "#{check} #{id} #{status}"
            self.error_count += 1
          end
        end
      end

      # @return [void]
      def process_sps_cabling(enclosure, id, check, status)
        if sp_line
          if status =~ /Present|Valid/
            self.ok_output += "#{check} #{id} #{status},"
          else
            nok_output << "#{check} #{id} #{status}"
            self.error_count += 1
          end
        end
      end
    end

    # Main Nagios plugin controller class for NaviSec devices
    #
    # Parses command line options and implements the nagios check by forwarding to
    # an appropriate NaviSecCli object
    #
    # Currently supported devices are:
    #
    # EMC VNX5300
    #
    class CheckNaviSec
      # @return [Hash]
      # @see #initialize list of available options
      attr_accessor :options

      # Instantiate with an optional hash
      #
      # @param options [Hash] the options to query NaviSec
      # @option options [String] :host The NaviSec device IP address
      # @option options [String] :vendor (EMC) The device vendor
      # @option options [String] :model The device model
      # @option options [String] :version The NaviSec version
      # @option options [String] :credential The NaviSec credential id string
      # @option options [Boolean] :debug (false) enable logging debug messages to stderr
      # @option options [Boolean] :cache_results (false) enable saving results to /tmp which is useful for capturing test cases
      def initialize(options={})
        @options = {:host => nil,
                    :vendor => "EMC",
                    :model  => nil,
                    :username => nil,
                    :password => nil,
                    :credential => nil,
                    :decrypt => false,
                    :navisec => "/opt/Navisphere/bin/naviseccli",
                    :cachedir => "/opt/Dell/ASM/cache"
                   }
        @options.merge!(options) if options.is_a?(Hash)
        @debug = false
      end

      # Parse command line options and check for required options
      #
      # @return [void]
      def create_and_parse_cli_options
        opt = OptionParser.new

        opt.on("--host HOST", "-h", "Management IP address or hostname") do |v|
          @options[:host] = v
        end

        opt.on("--vendor VENDOR", "-p", "Hardware vendor default EMC") do |v|
          @options[:vendor] = v
        end

        opt.on("--model MODEL", "-m", "Hardware model") do |v|
          @options[:model] = v
        end

        opt.on("--user USERNAME", "-u", "Username to use when querying naviseccli") do |v|
          @options[:username] = v
        end

        opt.on("--password PASSWORD", "-p", "Password to use when querying naviseccli") do |v|
          @options[:password] = v
        end

        opt.on("--decrypt", "Decrypt passwords that are supplied on the cli") do
          @options[:decrypt] = true
        end

        opt.on("--credential CREDENTIAL", "-c", "Credential Reference") do |v|
          @options[:credential] = v
        end

        opt.on("--navisec PATH", "-e", "NaviSec executable path default /opt/Navisphere/bin/naviseccli") do |v|
          @options[:navisec] = v
        end

        opt.on("--version VERSION", "-v", "NaviSec version") do |v|
          @options[:version] = v
        end

        opt.on("--cachedir PATH", "Directory path to store cache files default /opt/Dell/ASM/cache") do |v|
          @options[:cachedir] = v
        end

        opt.on("--debug", "Enable debug output") do
          @options[:debug] = true
          @debug = true
        end

        opt.on("--cache-results", "Store results output as JSON in /tmp") do
          @options[:cache_results] = true
        end

        opt.on("--supported", "List supported devices") do
          supported_devices.keys.each do |vendor|
            supported_devices[vendor].keys.each do |model|
              puts "%s %s" % [vendor, model]
            end
          end

          exit
        end

        opt.parse!
      end

      # Assert that required options are present
      #
      # @return [Boolean]
      def check_options
        unless @options[:stub]
          creds = ((@options[:username] && @options[:password]) || @options[:credential])
          STDERR.puts "Please specify a host to connect to using --host" unless @options[:host]
          STDERR.puts "Please specify a model to check using --model" unless @options[:model]
          unless creds
            STDERR.puts "Please specify user credentials using --credential or --user and --password"
          end
          return false unless @options[:host] && @options[:model] && creds
        end

        # Decrypt credentials if necessary.
        # Either a credential id is supplied or a username and password,
        # the latter which may be the id of an encrypted string.
        if @options[:username] && @options[:password]
          if @options[:decrypt]
            password = ASM::Cipher.decrypt_string(@options[:password])
            raise("Could not decrypt password %s" % v) unless password
            @options[:password] = password
          end
        elsif @options[:credential]
          # Decrypt this credential
          creds = ASM::Cipher.decrypt_credential(@options[:credential])
          raise("Could not lookup password credentials %s" % v) unless creds
          @options[:username] = creds[:username]
          @options[:password] = creds[:password]
        end

        # Verify navisec executable is present
        raise("naviseccli not found #{@options[:navisec]}") unless File.exist?(@options[:navisec])

        true
      end

      # Print message to stderr if debug attribute is enabled
      #
      # @param msg [String]
      # @return [void]
      def debug(msg)
        STDERR.puts msg if @debug
      end

      # Instantiate the appropriate device class based on the given vendor and model
      #
      # @param vendor [String] NaviSec device vendor
      # @param model [String] NaviSec device model
      # @return [NaviSecDevice]
      # @raise [StandardError] Unsupported vendor,model combination
      def create_device(vendor, model)
        # Map (vendor,model) to device class
        # Current implementation is to explicitly list all supported models and require exact match.
        #
        klass_map = supported_devices

        raise("Health unavailable on vendor: %s" % vendor) unless klass_map.key? vendor
        raise("Health unavailable on %s model: [%s]" % [vendor, model]) unless klass_map[vendor].key? model

        device_klass = klass_map[vendor][model]
        device_klass.new
      end

      # Hash of supported device classes indexed  by [vendor][model]
      #
      def supported_devices
        {
          "EMC" => {
            "VNX5300" => EmcVnx,
            "VNX5400" => EmcVnx
          }
        }
      end

      # Calculate Nagios Status for the given command line options
      #
      # The Nagios Status message is printed to stdout
      #
      # @return [OK,WARNING,CRITICAL,UNKNOWN]
      def nagios_check
        exit_code = Nagios::UNKNOWN
        begin
          create_and_parse_cli_options
          return Nagios::WARNING unless check_options

          # Instantiate the proper device
          device = create_device(options[:vendor], options[:model])

          # Try to decrypt the credential
          valid_cred = true
          if valid_cred
            status = device.query_navisec(options)
          else
            status = Status.new(Nagios::WARNING, "Invalid NaviSec credential reference (%s) specified" % options[:credential])
          end
          exit_code = status.code
          message = status.message

        rescue StandardError => e
          message = "%s" % e
          exit_code = Nagios::UNKNOWN
        ensure
          puts message
        end
        exit_code
      end

      # Print Nagios status message to stdout and exit with Nagios status code
      #
      # @return [void]
      # @note This function exits with the calculated Nagios status code
      def nagios_check!
        exit nagios_check
      end
    end
  end
end

ASM::Nagios::CheckNaviSec.new.nagios_check! if $0 == __FILE__

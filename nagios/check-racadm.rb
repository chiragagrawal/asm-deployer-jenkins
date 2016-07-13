#!/opt/puppet/bin/ruby

$: << "/opt/asm-deployer/lib"

require 'rubygems'
require 'optparse'
require 'tempfile'
require 'fileutils'
require 'asm/cipher'

module ASM
  module Nagios
    class CheckRacadm
      NAGIOS_OK = 0
      NAGIOS_WARNING = 1
      NAGIOS_CRITICAL = 2
      NAGIOS_UNKNOWN = 3

      attr_accessor :options, :debug

      def initialize(options=nil)
        @options = {:host => nil,
                   :port => 22,
                   :user => "root",
                   :password => "calvin",
                   :module_svctag => nil,
                   :module_slot => nil,
                   :check_power => nil,
                   :decrypt => false}

        @options.merge!(options) if options.is_a?(Hash)
        @debug = false
      end

      def create_and_parse_cli_options
        opt = OptionParser.new

        opt.on("--host HOST", "-h", "Management IP address or hostname") do |v|
          @options[:host] = v
        end

        opt.on("--port PORT", "-p", Integer, "Port to connect to - 22 by default") do |v|
          @options[:port] = Integer(v)
        end

        opt.on("--user USERNAME", "-u", "Username to use when querying wsman") do |v|
          @options[:user] = v
        end

        opt.on("--password PASSWORD", "-p", "Password to use when querying wsman") do |v|
          @options[:password] = v
        end

        opt.on("--decrypt", "Decrypt passwords that are supplied on the cli") do |v|
          @options[:decrypt] = true
        end

        opt.on("--tag SVCSTAG", "Restrict the check to a single module with a specific Service Tag") do |v|
          @options[:module_svctag] = v
        end

        opt.on("--slot SLOT", "Restrict the check to a single module with a specific slot identifier like Switch-1") do |v|
          @options[:module_slot] = v
        end

        opt.on("--power", "Consider the power state as part of the health of the module") do
          @options[:check_power] = true
        end

        opt.on("--stub-racadm FILE", "Stub the output from racadm with a text file on disk for testing") do |v|
          @options[:stub] = v
        end

        opt.on("--stub-activeerrors FILE", "Stub the output from getactiveerrors with a text file on disk for testing") do |v|
          @options[:stub_ae] = v
        end

        opt.on("--debug", "Enable debug output") do |v|
          @debug = true
        end

        opt.parse!
      end


      def check_options
        unless @options[:stub]
          STDERR.puts "Please specify a host to connect to using --host" unless @options[:host]
          STDERR.puts "Please specify a port to connect to using --port" unless @options[:port]
          STDERR.puts "Please specify a user to connect as using --user" unless @options[:user]
          STDERR.puts "Please specify a password to connect with using --password" unless @options[:password]

          return false unless @options[:host] && @options[:port] && @options[:user] && @options[:password]
        end

        true
      end

      def debug(msg)
        STDERR.puts msg if @debug
      end

      def get_password(cred_id)
        creds = ASM::Cipher.decrypt_credential(cred_id)
        raise("Could not lookup password credentials %s" % cred_id) unless creds
        creds[:password]
      end

      def get_cache_for(host, port, key="getmod")
        cache_file = "/tmp/racadm_%s_%s_%d.cache" % [key, host, port]

        if File.exist?(cache_file) && (Time.now - File.mtime(cache_file) < 60)
          return File.read(cache_file)
        else
          return nil
        end
      end

      def save_cache_for(data, host, port, key="getmod")
        cache_file = "/tmp/racadm_%s_%s_%d.cache" % [key, host, port]

        file = Tempfile.new("racadm")
        begin
          file.puts(data)
        ensure
          file.close
          FileUtils.mv(file.path, cache_file)
        end

        return data
      end

      def racadm_getactiveerrors(stub_output=nil)

        if stub_output
          @activeerrors = nil
        end
        
        return @activeerrors unless @activeerrors.nil?
        
        # example_output =
        #
        # """Module ID     = switch-5
        #    Severity      = NonCritical
        #    Message       = A fabric mismatch detected on IO module C1.
        #
        #    Module ID     = switch-6
        #    Severity      = Critical
        #    Message       = A thermal catastrophe is happening on module C2."
        # """

        regex = /^Module ID\s*=\s*(?<device>.*)\nSeverity\s*=\s*(?<severity>.*)\nMessage\s*=\s*(?<message>.*)$/
        # Generates:
        #  match[:device]
        #  match[:severity]
        #  match[:message]
        #
        if stub_output
          output = stub_output
        else
          begin
            unless output = get_cache_for(@options[:host], @options[:port], "activeerrors")
              debug("Fetching new activeerrors data")
              require 'net/ssh'
              Net::SSH.start(@options[:host], @options[:user], :password => @options[:password], :port => @options[:port], :timeout => 2) do |ssh|
                output = ssh.exec!("getactiveerrors")
                ssh.exec!("exit")
              end
              
              save_cache_for(output, @options[:host], @options[:port], "activeerrors")
            else
              debug("Using cached activeerrors data")
            end
          rescue Errno::ECONNREFUSED, Timeout::Error
            return({"asm_error" => "Could not connect to host %s:%d" % [@options[:host], @options[:port]], "asm_nagios_code" => NAGIOS_CRITICAL})
          rescue 
            return({"asm_error" => "Unknown error [activeerrors] querying racadm on host %s:%d" % [@options[:host], @options[:port]], "asm_nagios_code" => NAGIOS_UNKNOWN})
          end
        end
        
        if output =~ /COMMAND NOT RECOGNIZED/m
          # We simply have no additional messages to report.
          output = ""
        end
        
        messages = {}
        
        # Find all matches to above regex
        output.scan(regex) do
          # access the current match object
          mo = Regexp.last_match
          canonical_name = mo[:device].downcase
          if messages.has_key? canonical_name
            messages[ canonical_name ] += ",%s" % mo[:message]
          else
            messages[ canonical_name ] = mo[:message]
          end
        end

        @activeerrors = messages
        messages
      end

      
      def racadm_getmodinfo(stub_output=nil)
        if stub_output
          output = stub_output
        else
          begin
            unless output = get_cache_for(@options[:host], @options[:port])
              debug("Fetching new data")
              require 'net/ssh'
              Net::SSH.start(@options[:host], @options[:user], :password => @options[:password], :port => @options[:port], :timeout => 2) do |ssh|
                output = ssh.exec!("getmodinfo -A")
                ssh.exec!("exit")
              end

              save_cache_for(output, @options[:host], @options[:port])
            else
              debug("Using cached data")
            end
          rescue Errno::ECONNREFUSED, Timeout::Error
            return({"asm_error" => "Could not connect to host %s:%d" % [@options[:host], @options[:port]], "asm_nagios_code" => NAGIOS_CRITICAL})
          rescue 
            return({"asm_error" => "Unknown error querying racadm on host %s:%d" % [@options[:host], @options[:port]], "asm_nagios_code" => NAGIOS_UNKNOWN})
          end
        end

        if output =~ /COMMAND NOT RECOGNIZED/m
          return({"asm_error" => "Host %s does not support get the getmodinfo command" % @options[:host], "asm_nagios_code" => NAGIOS_UNKNOWN})
        end
        
        # map all possible racadm status to nagios numbers, different versions of racadm will show
        # different statusses, 4.5 might only do "OK", "Not OK" and "N/A"
        racadm_to_nagios_map = {"Warning" => NAGIOS_WARNING, "Failed" => NAGIOS_CRITICAL, "OK" => NAGIOS_OK, "N/A" => NAGIOS_UNKNOWN, "Not OK" => NAGIOS_WARNING, "Unknown" => NAGIOS_UNKNOWN, "OFF" => NAGIOS_CRITICAL}

        modinfo = {}

        # racadm lines tend to look like this usually:
        #
        # <module>        <presence>      <pwrState>      <health>        <svcTag>
        # Chassis         Present         ON              Not OK          BY4KQV1
        #
        # this indicates an even 16 character split for columns but sometimes this happens:
        #
        # PS-5            Present         Failed(No Input Power)Not OK
        #
        # which makes parsing fun, so now I detect the "OK", "Not OK" "N/A", "Warning" or "Failed"
        # health statusses and anchor the rest around that strippping out white space as needed.  If a
        # chassis reports something that isn't one of those statusses this will fail the check but
        # can't see any other good way given what is basically corrupt output from racadm
        #
        # newer ones like in the FX2 series has an additional field:
        #
        # <module>        <presence>      <pwrState>      <health>        <svcTag>        <nodeId>
        #
        # The updated regex will just discard that for now
        output.each_line do |line|
          line.chomp!

          if line =~ /^(.{16})(.{16})(.+?)(OK|Not OK|N\/A|Warning|Failed|Unknown)\s*([^\s]+|\s{16})/
            health = $4.strip
            modname = $1.strip

            modinfo[modname] = {"presence" => $2.strip, "pwrState" => $3.strip, "svcTag" => $5.strip}

            if @options[:check_power] && modinfo[modname]["pwrState"] == "OFF"
              health = modinfo[modname]["pwrState"]
            end

            modinfo[modname]["health"] = racadm_to_nagios_map[health]
          else
            return({"asm_error" => "Could not parse output from racadm, unexpected line: %s" % line, "asm_nagios_code" => NAGIOS_UNKNOWN})
          end
        end

        if modinfo.empty?
          {"asm_error" => "Could not parse output from racadm, no output were received", "asm_nagios_code" => NAGIOS_UNKNOWN}
        else
          modinfo
        end
      end

      def calculate_overall_status(modinfo, svctag=nil, slot=nil)
        statusses = modinfo.map do |mod, status|
          next unless status["presence"] == "Present"
          next if svctag && status["svcTag"] != svctag
          next if slot && mod != slot

          debug("Selecting module '%s' as part of overall health calculation based on filter: svctag='%s' slot='%s'" % [mod, svctag, slot])

          status["health"]
        end.compact

        statusses.include?(NAGIOS_CRITICAL) ? NAGIOS_CRITICAL : statusses.max
      end

      def get_status_from_modinfo(info, svctag=nil, slot=nil)
        nagios_to_str_map = {NAGIOS_OK => "OK", NAGIOS_WARNING => "Degraded", NAGIOS_CRITICAL => "Error", NAGIOS_UNKNOWN => "Unknown"}

        overall_state = calculate_overall_status(info, svctag, slot)

        found_module = false

        subsystem_states = info.keys.sort.map do |subsystem|
          next nil if info[subsystem]["presence"] != "Present" 
          next nil if svctag && info[subsystem]["svcTag"] != svctag
          next nil if slot && subsystem != slot

          found_module = true

          debug("Considering module '%s' for health check based on filter: svctag='%s' slot='%s'" % [subsystem, svctag, slot])
          debug("%s:%s" %[subsystem, info[subsystem].inspect])

          next nil if info[subsystem]["health"] == 0

          # If health is not Ok, check if we have additional error messages available
          canonical_name = subsystem.downcase
          if slot && racadm_getactiveerrors[canonical_name]
            "%s : %s" % [ nagios_to_str_map[ info[subsystem]["health"] ], racadm_getactiveerrors[canonical_name] ]
          else
            "%s: %s" % [subsystem, nagios_to_str_map[ info[subsystem]["health"] ]]
          end
        end.compact

        if subsystem_states.empty? && found_module
          result_str = "OK"
        elsif !found_module
          result_str = "%s: could not find module %s" % [nagios_to_str_map[NAGIOS_UNKNOWN], svctag || slot]
          overall_state = NAGIOS_UNKNOWN
        else
          result_str = subsystem_states.join(" ")
        end

        [overall_state, result_str]
      end

      def nagios_check!
        create_and_parse_cli_options
        exit(1) unless check_options

        exit_code = NAGIOS_UNKNOWN

        begin
          @options[:password] = get_password(@options[:password]) if @options[:decrypt]

          if @options.has_key? :stub
            stub = File.read(@options[:stub])

            # Set activeerrors to empty by default.
            racadm_getactiveerrors("")
          else
            stub = nil
          end
          
          if @options.has_key? :stub_ae
            stub_ae = File.read(@options[:stub_ae])
            racadm_getactiveerrors(stub_ae)
          end

          modinfo = racadm_getmodinfo(stub)

          if result = modinfo["asm_error"]
            exit_code = modinfo["asm_nagios_code"]
          else
            exit_code, result = get_status_from_modinfo(modinfo, @options[:module_svctag], @options[:module_slot])
          end

          puts result
        rescue => e
          puts "Unknown: Failed to get hardware status for host %s: %s" % [@options[:host], e.to_s]
          exit_code = NAGIOS_UNKNOWN
        ensure
          exit exit_code
        end
      end
    end
  end
end

if $0 == __FILE__
  ASM::Nagios::CheckRacadm.new.nagios_check!
end

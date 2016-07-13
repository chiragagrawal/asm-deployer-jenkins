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
    # The Abstract base class for all supported SNMP devices.
    #
    # For each supported device model, the suggested convention is to implement the least specific subclass
    # possible in the suggested naming format:
    #
    #  <Vendor><ProductLine>  ( most general )
    #  <Vendor><Model>        ( most specific )
    #
    # @abstract Subclass this and implement the {SnmpDevice#checks} attribute to return an array of SNMP query structures.
    # @!attribute [rw] options
    #  @return [Hash] SNMP query options
    # @!attribute [r] checks
    #  @return [Array<Hash>] An array of checks to perform on a specific SNMP enabled device class
    # @!attribute [rw] results_cache
    #  @return [Hash] SNMP query responses indexed by the name of the check used to generate that response
    class SnmpDevice
      attr_accessor :options
      attr_writer :results_cache

      # Instantiate with an optional hash
      #
      # @param [Hash] opts the options to query SNMP
      # @option opts [String] :version The SNMP version
      # @option opts [String] :community The SNMP community string
      # @option opts [String] :host The SNMP device IP address
      # @option opts [Boolean] :debug enable logging debug messages to stderr
      # @option opts [Boolean] :cache_results enable saving results to /tmp which is useful for capturing test cases
      # @option opts [String] :model The device model, currently used only to generate the cache file {#store_cache}
      def initialize(opts={})
        @options = opts
      end

      # An array of checks to perform on a specific SNMP enabled device.
      #
      # @return [Array<Hash>]
      #
      # @example Single hash element illustrating the required data structure for a check
      #
      #    [{
      #      :rollup => true,                         # The code from this check overrides all other checks.
      #      :name => "eqlMemberHealthStatus",        # The name of the check.
      #      :display => "Status",                    # What to display in the message.
      #      :oid => "1.3.6.1.4.1.12740.2.1.5.1.1",   # The SNMP OID to query for this check.
      #      :response => /INTEGER: ([0-9]+)/,        # Regex describing the expected SNMP response.
      #      :codes => {                              # Expected result codes mapped to Nagios codes.
      #        "0" => [Nagios::UNKNOWN, 'Unknown'],
      #        "1" => [Nagios::OK, 'OK'],
      #        "2" => [Nagios::WARNING, 'Warning'],    # This will generate Status:Warning as the health message.
      #        "3" => [Nagios::CRITICAL, 'Critical'],
      #        "9" => [Nagios::WARNING, :process_it],   # Call the named method to dynamically generate the message.
      #        :any => [Nagios::WARNING, :process_it]   #  As above but match any error code.
      #      }
      #    }]
      def checks
        []
      end

      # Extra indirection to allow check messages to be dynamically generated
      #
      # If message_builder is a symbol, send the data to it.
      # Otherwise, if it's a string just return the string.  The symbol is specified as part of the checks structure.
      #
      # @param [String,Symbol] message_builder
      # @param [String] data the subgroup matching the response regex specified in the check.
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

      # Iterates over all device checks to determine a Nagios Status
      #
      # The check with the worst status is reported in general
      #
      # If a check is marked as a rollup, only its status is reported, but in the
      # case it is not OK, other checks will contribute to the status message
      #
      # @param (see #initialize)
      # @return [Nagios::Status]
      # @see #initialize list of available options
      # @see #checks checks attribute
      def query_snmp(opts=nil)
        self.options = opts unless opts.nil?

        exit_code = nil
        exit_message = []
        index = 0
        has_rollup = false

        if results_cache.empty?
          debug("No results\n")
          exit_code = Nagios::UNKNOWN
          exit_message = ["Invalid SNMP community string specified or snmp is disabled"]
        else

          # concrete subclasses implement checks method
          checks.each do |check|
            unless results = results_cache[check[:name]]
              debug("No results for check %s\n" % check[:name])
              next
            end

            # Loop on possibly multiple lines of output
            results.each_line do |line|
              next unless line =~ check[:response]
              status = $1

              # Iterate over the expected return codes from a check.
              # line_exit_code,line_message = check[:codes][status]
              check[:codes].keys.each do |code|
                # Might want to support regex codes.
                # For now add support for 'any' value.
                next unless status == code || code == :any

                # Map to a nagios code
                # check[:codes][code] maps to a pair of ( nagios_code, message )
                line_exit_code = check[:codes][code][0]

                # Does it matter that index = 0?
                # Yes, currently rollup check must be first
                if index == 0 && check[:rollup]
                  # Base the overall exit code only on the first check if it is marked as rollup.
                  exit_code = line_exit_code
                  exit_message = ["OK"] if exit_code == Nagios::OK
                  has_rollup = true
                else

                  # Sub checks only affect the message but not the exit code for rollups
                  unless has_rollup
                    exit_code = Status.worst_case(line_exit_code, exit_code)
                  end

                  # Only affect the message if not OK
                  if exit_code != Nagios::OK && line_exit_code != Nagios::OK

                    # Here, instead of the message being static, we generalized this
                    # to call a custom function by symbol name, sending it the check value.
                    # Main application thus far is to blow up a bit string.
                    line_exit_message = build_message(check[:codes][code][1], status)
                    prefix = ""

                    unless check[:display].nil? || check[:display].empty?
                      prefix = "%s:" % check[:display]
                    end
                    unless line_exit_message.empty?
                      exit_message << "%s%s" % [prefix, line_exit_message]
                    end
                  end

                end
              end
            end
            index += 1
          end
        end
        # In case no checks ran or other pathological
        # cases lead to no assignments
        exit_code ||= Nagios::UNKNOWN
        if exit_message.empty?
          if exit_code == Nagios::OK
            exit_message = "OK"
          else
            exit_message = "Unknown"
          end
        else
          exit_message = exit_message.uniq.join(",")
        end

        Status.new(exit_code, exit_message)
      end

      def is_snmp_community_correct?(community_string, host)
        # querying puppet db to get device certname with host ip
        certname = get_device_certname(host)
        if certname.eql?(false)
          return true
        else
          facts_for_device = ASM::PrivateUtil.facts_find(certname)
          # checks if facts about snmp is available or not
          if facts_for_device["snmp_community_string"].nil?
            return true
          else
            strings_in_json = JSON.parse(facts_for_device["snmp_community_string"])
            if strings_in_json.empty? || strings_in_json.include?(community_string)
              return true
            else
              return false
            end
          end
        end
      end

      # get device cert_name for the host
      def get_device_certname(host)
        db = ASM::Client::Puppetdb.new
        # querying puppet db to get device certname with host ip
        begin
          fact_hash = db.find_node_by_management_ip(host)
          return fact_hash["name"]
        rescue StandardError
          return false
        end
      end

      # Hash of SNMP query responses indexed by the name of the check used to generate that response
      #
      # @return [Hash]
      # @example S4810 output from SNMP checks
      #  {
      #   "chStackUnitStatus": "SNMPv2-SMI::enterprises.6027.3.10.1.2.2.1.8.1 = INTEGER: 1",
      #   "chSysFanTrayOperStatus": "SNMPv2-SMI::enterprises.6027.3.10.1.2.4.1.2.1.1 = INTEGER: 1",
      #   "chSysPowerSupplyOperStatus": "SNMPv2-SMI::enterprises.6027.3.10.1.2.3.1.2.1.1 = INTEGER: 1"
      #  }
      def results_cache
        return @results_cache unless @results_cache.nil?
        @results_cache = {}
        checks.each do |check|
          oid = check[:oid]
          command = "snmpwalk -v %s -c %s %s #{oid}" % options.values_at(:version, :community, :host)
          results = `#{command}`
          @results_cache[check[:name]] = results
        end
        @results_cache = {} if @results_cache.values.all?(&:empty?)
        store_cache
        @results_cache
      end

      # Store the results cache to a file for use in testing for example
      #
      # File is stored at /tmp/<model>_<host>_snmp_results.json
      #
      # @return [void]
      # @see #initialize options that affect the cache file name
      def store_cache
        if options.key? :cache_results
          json = @results_cache.to_json
          outf = File.open("/tmp/%s_%s_snmp_results.json" % [options[:model], options[:host]], "w")
          outf.write(json)
          outf.close
        end
      end

      # Print a message to stderr if the debug option was set
      #
      # @param [String] msg the message to print to stderr
      # @return [void]
      def debug(msg)
        STDERR.puts msg if options.key? :debug
      end
    end

    # Dell Compellent Storage
    #
    # @!attribute [r] checks
    #  @return [Array<Hash>] An array of checks to perform on a specific SNMP enabled device class
    class DellCompellent < SnmpDevice
      # (see SnmpDevice#checks)
      def checks
        enabled = [
          {
            :name => "scEnclStatus",
            :display => "Enclosure",
            :oid => "1.3.6.1.4.1.16139.2.15.1.3",
            :response => /INTEGER: ([0-9]+)/,
            :codes => {
              "1" => [Nagios::OK, "OK"],
              "2" => [Nagios::CRITICAL, "Down"],
              "3" => [Nagios::WARNING, "Degraded"]
            }
          },
          {
            :name => "scEnclFanStatus",
            :display => "Fan",
            :oid => "1.3.6.1.4.1.16139.2.20.1.3",
            :response => /INTEGER: ([0-9]+)/,
            :codes => {
              "1" => [Nagios::OK, "OK"],
              "2" => [Nagios::CRITICAL, "Down"],
              "3" => [Nagios::WARNING, "Degraded"]
            }
          },
          {
            :name => "scEnclPowerStatus",
            :display => "Power",
            :oid => "1.3.6.1.4.1.16139.2.21.1.3",
            :response => /INTEGER: ([0-9]+)/,
            :codes => {
              "1" => [Nagios::OK, "OK"],
              "2" => [Nagios::CRITICAL, "Down"],
              "3" => [Nagios::WARNING, "Degraded"]
            }
          },
          {
            :name => "scEnclTempStatus",
            :display => "Temp",
            :oid => "1.3.6.1.4.1.16139.2.23.1.3",
            :response => /INTEGER: ([0-9]+)/,
            :codes => {
              "1" => [Nagios::OK, "OK"],
              "2" => [Nagios::CRITICAL, "Down"],
              "3" => [Nagios::WARNING, "Degraded"]
            }
          },
          {
            :name => "scCtlrStatus",
            :display => "Controller",
            :oid => "1.3.6.1.4.1.16139.2.13.1.3",
            :response => /INTEGER: ([0-9]+)/,
            :codes => {
              "1" => [Nagios::OK, "OK"],
              "2" => [Nagios::CRITICAL, "Down"],
              "3" => [Nagios::WARNING, "Degraded"]
            }
          },
          {
            :name => "scCacheBatStat",
            :display => "Battery",
            :oid => "1.3.6.1.4.1.16139.2.28.1.5",
            :response => /INTEGER: ([0-9]+)/,
            :codes => {
              "0" => [Nagios::CRITICAL, "Missing"],
              "1" => [Nagios::OK, "OK"],
              "2" => [Nagios::WARNING, "Degraded"],
              "3" => [Nagios::CRITICAL, "Dead"]
            }
          }
        ]
        enabled
      end
    end

    # Dell Equallogic Storage
    #
    # @!attribute [r] checks
    #  @return [Array<Hash>] An array of checks to perform on a specific SNMP enabled device class
    # @!attribute [r] eqlMemberHealthCriticalMessages
    #  @return [Hash<Fixnum,String>]
    # @!attribute [r] eqlMemberHealthWarningMessages
    #  @return [Hash<Fixnum,String>]
    class DellEqualLogic < SnmpDevice
      # Build a custom message from a sequence of space separated hex octets
      #
      # See eqlmember.mib file
      #
      # @param [String] hexstr A sequence of space separated hex octects
      # @param [Hash<Fixnum,String>] messages A map from error bits to error strings
      # @return [String]
      def process_eqlMemberHealthConditions(hexstr, messages)
        # Build a binary string from the hex octets
        binstr = ""
        hexstr.split.each do |x|
          binstr << x.to_i(16).to_s(2).rjust(8, "0")
        end

        # No use searching 128 bits if they're all 0's
        message = ""
        range = binstr.rindex("1")
        return message if range.nil?

        for idx in 0..range
          next unless binstr[idx].chr == "1"
          next unless messages.key? idx
          message << "," unless message.empty?
          sub_message = messages[idx]
          # Map camelCase messages to human readable.
          humanized_message = sub_message.split(/(?=[A-Z])/).join(" ").capitalize
          message << humanized_message
        end
        message
      end

      # Build a custom message from a hex string
      #
      # @param [String] hexstr A sequence of space separated hex octects
      # @return [String]
      def process_eqlMemberHealthWarningConditions(hexstr)
        process_eqlMemberHealthConditions(hexstr, eqlMemberHealthWarningMessages)
      end

      # Build a custom message from a hex string
      #
      # @param [String] hexstr A sequence of space separated hex octects
      # @return [String]
      def process_eqlMemberHealthCriticalConditions(hexstr)
        process_eqlMemberHealthConditions(hexstr, eqlMemberHealthCriticalMessages)
      end

      def eqlMemberHealthWarningMessages
        {
          0 => "hwComponentFailedWarn",
          1 => "powerSupplyRemoved",
          2 => "controlModuleRemoved",
          3 => "psfanOffline",
          4 => "fanSpeed",
          5 => "cacheSyncing",
          6 => "raidSetFaulted",
          7 => "highTemp",
          8 => "raidSetLostblkEntry",
          9 => "secondaryEjectSWOpen",
          10 => "b2bFailure",
          11 => "replicationNoProg",
          12 => "raidSpareTooSmall",
          13 => "lowTemp",
          14 => "powerSupplyFailed",
          15 => "timeOfDayClkBatteryLow",
          16 => "incorrectPhysRamSize",
          17 => "mixedMedia",
          18 => "sumoChannelCardMissing",
          19 => "sumoChannelCardFailed",
          20 => "batteryLessthan72hours",
          21 => "cpuFanNotSpinning",
          22 => "raidMoreSparesExpected",
          23 => "raidSpareWrongType",
          24 => "raidSsdRaidsetHasHdd",
          25 => "driveNotApproved",
          26 => "noEthernetFlowControl",
          27 => "fanRemovedCondition",
          28 => "smartBatteryLowCharge",
          29 => "nandHighBadBlockCount",
          30 => "networkStorm",
          31 => "batteryEndOfLifeWarning"
        }
      end

      def eqlMemberHealthCriticalMessages
        {
          0 => "raidSetDoubleFaulted",
          1 => "bothFanTraysRemoved",
          2 => "highAmbientTemp",
          3 => "raidLostCache",
          4 => "moreThanOneFanSpeedCondition",
          5 => "fanTrayRemoved",
          6 => "raidSetLostblkTableFull",
          7 => "raidDeviceIncompatible",
          8 => "raidOrphanCache",
          9 => "raidMultipleRaidSets",
          10 => "nVRAMBatteryFailed",
          11 => "hwComponentFailedCrit",
          12 => "incompatControlModule",
          13 => "lowAmbientTemp",
          14 => "opsPanelFailure",
          15 => "emmLinkFailure",
          16 => "highBatteryTemperature",
          17 => "enclosureOpenPerm",
          18 => "sumoChannelBothMissing",
          19 => "sumoEIPFailureCOndition",
          20 => "sumoChannelBothFailed",
          21 => "staleMirrorDiskFailure",
          22 => "c2fPowerModuleFailureCondition",
          23 => "raidsedUnresolved",
          24 => "colossusDeniedFullPower",
          25 => "cemiUpdateInProgress",
          26 => "colossusCannotStart",
          27 => "multipleFansRemoved",
          28 => "smartBatteryFailure",
          29 => "critbit29",
          30 => "nandFailure",
          31 => "batteryEndOfLife"
        }
      end

      # (see SnmpDevice#checks)
      def checks
        enabled = [
          {
            :rollup => true,
            :name => "eqlMemberHealthStatus",
            :display => "Status",
            :oid => "1.3.6.1.4.1.12740.2.1.5.1.1",
            :response => /INTEGER: ([0-9]+)/,
            :codes => {
              "0" => [Nagios::UNKNOWN, "Unknown"],
              "1" => [Nagios::OK, "OK"],
              "2" => [Nagios::WARNING, "Warning"],
              "3" => [Nagios::CRITICAL, "Critical"]
            }
          },
          {
            :name => "eqlMemberHealthWarningConditions",
            :display => "",
            :oid => "1.3.6.1.4.1.12740.2.1.5.1.2",
            :response => /Hex-STRING:\s*([0-9a-zA-Z ]+)$/,
            :codes => {
              :any => [Nagios::WARNING, :process_eqlMemberHealthWarningConditions]
            }
          },
          {
            :name => "eqlMemberHealthCriticalConditions",
            :display => "",
            :oid => "1.3.6.1.4.1.12740.2.1.5.1.3",
            :response => /Hex-STRING:\s*([0-9a-zA-Z ]+)$/,
            :codes => {
              :any => [Nagios::CRITICAL, :process_eqlMemberHealthCriticalConditions]
            }
          }
        ]

        # Kept these here because we may still need them, subject to more QA.
        disabled = [
          {
            :name => "eqlMemberHealthDetailsTemperatureCurrentState",
            :display => "Temp",
            :oid => "1.3.6.1.4.1.12740.2.1.6.1.4",
            :response => /INTEGER: ([0-9]+)/,
            :codes => {
              "0" => [Nagios::UNKNOWN, "Unknown"],
              "1" => [Nagios::OK, "OK"],
              "2" => [Nagios::WARNING, "Warning"],
              "3" => [Nagios::CRITICAL, "Critical"]
            }
          },
          {
            :name => "eqlMemberHealthDetailsPowerSupplyCurrentState",
            :display => "Power",
            :oid => "1.3.6.1.4.1.12740.2.1.8.1.3",
            :response => /INTEGER: ([0-9]+)/,
            :codes => {
              "1" => [Nagios::OK, "OK"],
              "2" => [Nagios::WARNING, "No-AC"],
              "3" => [Nagios::UNKNOWN, "Unknown"]
            }
          },
          {
            :name => "eqlMemberHealthDetailsFanCurrentState",
            :display => "Fan",
            :oid => "1.3.6.1.4.1.12740.2.1.7.1.4",
            :response => /INTEGER: ([0-9]+)/,
            :codes => {
              "0" => [Nagios::UNKNOWN, "Unknown"],
              "1" => [Nagios::OK, "OK"],
              "2" => [Nagios::WARNING, "Warning"],
              "3" => [Nagios::CRITICAL, "Critical"]
            }
          },
          {
            :name => "eqlMemberRaidStatus",
            :display => "Raid",
            :oid => "1.3.6.1.4.1.12740.2.1.13.1.1",
            :response => /INTEGER: ([0-9]+)/,
            :codes => {
              "1" => [Nagios::OK, "OK"],
              "2" => [Nagios::WARNING, "Degraded"],
              "3" => [Nagios::WARNING, "Verifying"],
              "4" => [Nagios::WARNING, "Reconstructing"],
              "5" => [Nagios::CRITICAL, "Failed"],
              "6" => [Nagios::WARNING, "CatastrophicLoss"],
              "7" => [Nagios::WARNING, "Expanding"],
              "8" => [Nagios::WARNING, "Mirroring"]
            }
          },
          {
            :name => "eqlControllerBatteryStatus",
            :display => "Battery",
            :oid => "1.3.6.1.4.1.12740.4.1.1.1.5",
            :response => /INTEGER: ([0-9]+)/,
            :codes => {
              "1" => [Nagios::OK, "OK"],
              "2" => [Nagios::CRITICAL, "Failed"],
              "3" => [Nagios::OK, "Charging"],
              "4" => [Nagios::WARNING, "LowVoltage"],
              "5" => [Nagios::OK, "LowVoltageCharging"],
              "6" => [Nagios::CRITICAL, "Missing"],
              "7" => [Nagios::WARNING, "Hi-Temp"],
              "8" => [Nagios::WARNING, "Lo-Temp"],
              "9" => [Nagios::CRITICAL, "EndOfLife"],
              "10" => [Nagios::WARNING, "EndOfLife"]
            }
          }
        ]
        enabled
      end
    end

    # Dell Force10 Switches
    #
    # @!attribute [r] checks
    #  @return [Array<Hash>] An array of checks to perform on a specific SNMP enabled device class
    class DellForce10 < SnmpDevice
      # (see SnmpDevice#checks)
      def checks
        [
          {
            :name => "chStackUnitStatus",
            :display => "unitStatus",
            :oid => "1.3.6.1.4.1.6027.3.10.1.2.2.1.8",
            :response => /INTEGER: ([0-9]+)/,
            :codes => {
              "1" => [Nagios::OK, "OK"],
              "2" => [Nagios::WARNING, "Unsupported"],
              "3" => [Nagios::WARNING, "CodeMismatch"],
              "4" => [Nagios::WARNING, "ConfigMismatch"],
              "5" => [Nagios::CRITICAL, "UnitDown"],
              "6" => [Nagios::WARNING, "NotPresent"]
            }
          },
          {
            :name => "chSysFanTrayOperStatus",
            :display => "Fan",
            :oid => "1.3.6.1.4.1.6027.3.10.1.2.4.1.2",
            :response => /INTEGER: ([0-9]+)/,
            :codes => {
              "1" => [Nagios::OK, "Up"],
              "2" => [Nagios::WARNING, "Down"],
              "3" => [Nagios::WARNING, "Absent"]
            }
          },
          {
            :name => "chSysPowerSupplyOperStatus",
            :display => "Power",
            :oid => "1.3.6.1.4.1.6027.3.10.1.2.3.1.2",
            :response => /INTEGER: ([0-9]+)/,
            :codes => {
              "1" => [Nagios::OK, "Up"],
              "2" => [Nagios::WARNING, "Down"],
              "3" => [Nagios::WARNING, "Absent"]
            }
          }
        ]
      end
    end

    # Dell Powerconnect switches
    #
    # @!attribute [r] checks
    #  @return [Array<Hash>] An array of checks to perform on a specific SNMP enabled device class
    class DellPowerConnect < SnmpDevice
      # (see SnmpDevice#checks)
      def checks
        [
          {
            :name => "productStatusGlobalStatus",
            :rollup => true,
            :display => "unitStatus",
            :oid => "1.3.6.1.4.1.674.10895.3000.1.2.110.1",
            :response => /INTEGER: ([0-9]+)/,
            :codes => {
              "3" => [Nagios::OK, "OK"],
              "4" => [Nagios::WARNING, "warning"],
              "5" => [Nagios::CRITICAL, "critical"]
            }
          },
          {
            :name => "envMonFanState",
            :display => "Fan",
            :oid => "1.3.6.1.4.1.674.10895.3000.1.2.110.7.1.1.3",
            :response => /INTEGER: ([0-9]+)/,
            :codes => {
              "1" => [Nagios::OK, "normal"],
              "2" => [Nagios::WARNING, "warning"],
              "3" => [Nagios::CRITICAL, "critical"],
              "4" => [Nagios::WARNING, "shutdown"],
              "5" => [Nagios::WARNING, "notPresent"],
              "6" => [Nagios::WARNING, "notFunctioning"]
            }
          },
          {
            :name => "envMonSupplyState",
            :display => "Power",
            :oid => "1.3.6.1.4.1.674.10895.3000.1.2.110.7.2.1.3",
            :response => /INTEGER: ([0-9]+)/,
            :codes => {
              "1" => [Nagios::OK, "normal"],
              "2" => [Nagios::WARNING, "warning"],
              "3" => [Nagios::CRITICAL, "critical"],
              "4" => [Nagios::WARNING, "shutdown"],
              "5" => [Nagios::WARNING, "notPresent"],
              "6" => [Nagios::WARNING, "notFunctioning"]
            }
          }
        ]
      end
    end

    # Main Nagios plugin controller class
    #
    # Parses command line options and implements the nagios check by forwarding to
    # an appropriate SnmpDevice object
    #
    # Currently supported SNMP devices are:
    #
    # Dell Networking N3024,
    # Dell Networking N3024F,
    # Dell Networking N3024P,
    # Dell Networking N3048,
    # Dell Networking N3048P,
    # Dell Networking N4032,
    # Dell Networking N4032F,
    # Dell Networking N4064,
    # Dell Networking N4064F,
    # S4810,
    # S4820T,
    # S5000,
    # S6000,
    # EqualLogic,
    # Compellent
    class CheckSnmp
      # @return [Hash]
      # @see #initialize list of available options
      attr_accessor :options

      # Instantiate with an optional hash
      #
      # @param [Hash] options the options to query SNMP
      # @option options [String] :host The SNMP device IP address
      # @option options [String] :vendor (Dell) The device vendor
      # @option options [String] :model The device model
      # @option options [String] :version (2c) The SNMP version
      # @option options [String] :community (public) The SNMP community string
      # @option options [Boolean] :debug (false) enable logging debug messages to stderr
      # @option options [Boolean] :cache_results (false) enable saving results to /tmp which is useful for capturing test cases
      def initialize(options={})
        @options = {:host => nil,
                    :vendor => "Dell",
                    :model  => nil,
                    :version => "2c",
                    :community => "public"
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

        opt.on("--vendor VENDOR", "-p", "Hardware vendor") do |v|
          @options[:vendor] = v
        end

        opt.on("--model MODEL", "-m", "Hardware model") do |v|
          @options[:model] = v
        end

        opt.on("--community COMMUNITY", "-c", "SNMP community") do |v|
          @options[:community] = v
        end

        opt.on("--version VERSION", "-v", "SNMP version") do |v|
          @options[:version] = v
        end

        opt.on("--debug", "Enable debug output") do |_v|
          @options[:debug] = true
          @debug = true
        end

        opt.on("--cache-results", "Store results output as JSON in /tmp") do |_v|
          @options[:cache_results] = true
        end

        opt.parse!
      end

      # Assert that required options are present
      #
      # @return [Boolean]
      def check_options
        unless @options[:stub]
          STDERR.puts "Please specify a host to connect to using --host" unless @options[:host]
          STDERR.puts "Please specify a model to check using --model" unless @options[:model]
          return false unless @options[:host] && @options[:model]
        end

        true
      end

      # Print message to stderr if debug attribute is enabled
      #
      # @param [String] msg
      # @return [void]
      def debug(msg)
        STDERR.puts msg if @debug
      end

      # Instantiate the appropriate device class based on the given vendor and model
      #
      # @param [String] vendor SNMP device vendor
      # @param [String] model SNMP device model
      # @return [SnmpDevice]
      # @raise [StandardError] Unsupported vendor,model combination
      def create_device(vendor, model)
        # Map (vendor,model) to device class
        # Current implementation is to explicitly list all supported models and require exact match.
        #
        klass_map = {
          "Dell" => {
            "Dell Networking N3024" => DellPowerConnect,
            "Dell Networking N3024F" => DellPowerConnect,
            "Dell Networking N3024P" => DellPowerConnect,
            "Dell Networking N3048" => DellPowerConnect,
            "Dell Networking N3048P" => DellPowerConnect,
            "Dell Networking N4032" => DellPowerConnect,
            "Dell Networking N4032F" => DellPowerConnect,
            "Dell Networking N4064" => DellPowerConnect,
            "Dell Networking N4064F" => DellPowerConnect,
            "S4810" => DellForce10,
            "S4048-ON" => DellForce10,
            "S4820T" => DellForce10,
            "S5000" => DellForce10,
            "S6000" => DellForce10,
            "EqualLogic" => DellEqualLogic,
            "Compellent" => DellCompellent
          }
        }

        raise("Health unavailable on vendor: %s" % vendor) unless klass_map.key? vendor
        raise("Health unavailable on %s model: [%s]" % [vendor, model]) unless klass_map[vendor].key? model

        device_klass = klass_map[vendor][model]
        device_klass.new
      end

      # Calculate Nagios Status for the given command line options
      #
      # The Nagios Status message is printed to stdout
      #
      # @return [NAGIOS_OK,NAGIOS_WARNING,NAGIOS_CRITICAL,NAGIOS_UNKNOWN]
      def nagios_check
        create_and_parse_cli_options
        return 1 unless check_options

        exit_code = Nagios::UNKNOWN

        begin
          # Instantiate the proper device
          device = create_device(options[:vendor], options[:model])
          # check if snmp community is correct or not for authentication
          if device.is_snmp_community_correct?(options[:community], options[:host])
            status = device.query_snmp(options)
          else
            status = Status.new(Nagios::WARNING, "Invalid SNMP community string specified")
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

ASM::Nagios::CheckSnmp.new.nagios_check! if $0 == __FILE__

#!/opt/puppet/bin/ruby

$: << "/opt/asm-deployer/lib"

require 'rubygems'
require 'optparse'
require 'csv'
require 'asm/cipher'

NAGIOS_OK = 0
NAGIOS_WARNING = 1
NAGIOS_CRITICAL = 2
NAGIOS_UNKNOWN = 3

options = {:host => nil,
           :user => "root",
           :password => "root",
           :ipmimonitoring => "/usr/sbin/ipmimonitoring",
           :debug => false,
           :decrypt => false}

opt = OptionParser.new

opt.on("--host HOST", "-h", "Management IP address or hostname") do |v|
  options[:host] = v
end

opt.on("--user USERNAME", "-u", "Username to use when querying wsman") do |v|
  options[:user] = v
end

opt.on("--password PASSWORD", "-p", "Password to use when querying wsman") do |v|
  options[:password] = v
end

opt.on("--decrypt", "Decrypt passwords that are supplied on the cli") do |v|
  options[:decrypt] = true
end

opt.on("--stub-ipmi FILE", "Stub the output from ipmi with a text file on disk for testing") do |v|
  options[:stub] = v
end

opt.on("--ipmimonitoring", "Location of the ipmimonitoring command") do |v|
  options[:ipmimonitoring] = v
end

opt.on("--debug", "Enable debug output") do |v|
  options[:debug] = true
end

opt.parse!

unless options[:stub]
  STDERR.puts "Please specify a host to connect to using --host" unless options[:host]
  STDERR.puts "Please specify a user to connect as using --user" unless options[:user]
  STDERR.puts "Please specify a password to connect with using --password" unless options[:password]

  exit(NAGIOS_UNKNOWN) unless options[:host] && options[:user] && options[:password]
end

def get_password(cred_id)
  creds = ASM::Cipher.decrypt_credential(cred_id)
  raise("Could not lookup password credentials %s" % cred_id) unless creds
  creds[:password]
end

def ipmi_getmodinfo(options, stub_output=nil)
  if stub_output
    output = stub_output
  else
    raise("Please specify a path to the ipmimonitoring command using --ipmimonitoring") unless File.executable?(options[:ipmimonitoring])

    command = "%s -h %s -u %s -p %s --no-header-output --interpret-oem-data  --ignore-not-available-sensors --output-sensor-state --comma-separated-output 2>&1" % [options[:ipmimonitoring], options[:host], options[:user], options[:password]]
    puts("Running command: %s" % command) if options[:debug]

    output = %x{#{command}}

    # ipmi utilities exit 1 for failures and put some stuff on STDERR
    unless $?.success?
      raise("Could not retrieve IPMI status: %s" % output)
    end
  end

  modinfo = {}

  CSV.parse(output) do |row|
    health = NAGIOS_UNKNOWN

    health = NAGIOS_OK if row[3] =~ /nominal/i
    health = NAGIOS_WARNING if row[3] =~ /warning/i
    health = NAGIOS_CRITICAL if row[3] =~ /critical/i

    modinfo[row[1]] = {"type" => row[2], "health" => health, "reading" => row[4], "units" => row[5], "event" => row[6]}
  end

  modinfo
rescue
  return({"asm_error" => "Unknown error querying ipmi on host %s: %s" % [options[:host], $!.to_s], "asm_nagios_code" => NAGIOS_UNKNOWN})
end

def calculate_overall_status(modinfo)
  modinfo.map do |mod, status|
    status["health"]
  end.compact.max
end

def get_status_from_modinfo(info)
  nagios_to_str_map = {NAGIOS_OK => "OK", NAGIOS_WARNING => "Degraded", NAGIOS_CRITICAL => "Error", NAGIOS_UNKNOWN => "Unknown"}

  overall_state = calculate_overall_status(info)

  subsystem_states = info.keys.sort.map do |subsystem|
    next nil if info[subsystem]["health"] == NAGIOS_OK

    "%s: %s" % [subsystem, nagios_to_str_map[ info[subsystem]["health"] ]]
  end.compact

  if subsystem_states.empty?
    result_str = "OK"
  else
    result_str = subsystem_states.join(" ")
  end

  [overall_state, result_str]
end

begin
  options[:password] = get_password(options[:password]) if options[:decrypt]

  options[:stub] ? stub = File.read(options[:stub]) : stub = nil

  modinfo = ipmi_getmodinfo(options, stub)

  if result = modinfo["asm_error"]
    exit_code = modinfo["asm_nagios_code"]
  else
    exit_code, result = get_status_from_modinfo(modinfo)
  end

  puts result
rescue
  puts "UNKNOWN: Failed to get hardware status for host %s: %s" % [options[:host], $!.to_s]
  puts e.backtrace.join("\n\t") if options[:debug]

  exit_code = NAGIOS_UNKNOWN
ensure
  exit exit_code
end

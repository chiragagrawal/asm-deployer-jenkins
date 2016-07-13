#!/opt/puppet/bin/ruby

$: << "/opt/asm-deployer/lib"

require 'rubygems'
require 'nokogiri'
require 'optparse'
require 'asm'
require 'asm/cipher'

NAGIOS_OK = 0
NAGIOS_WARNING = 1
NAGIOS_CRITICAL = 2
NAGIOS_UNKNOWN = 3

options = {:host => nil,
           :port => 443,
           :user => "root",
           :password => "calvin",
           :decrypt => false}

opt = OptionParser.new

opt.on("--host HOST", "-h", "Management IP address or hostname") do |v|
  options[:host] = v
end

opt.on("--port PORT", "-p", Integer, "Port to connect to - 443 by default") do |v|
  options[:port] = Integer(v)
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

opt.parse!

STDERR.puts "Please specify a host to connect to using --host" unless options[:host]
STDERR.puts "Please specify a port to connect to using --port" unless options[:port]
STDERR.puts "Please specify a user to connect as using --user" unless options[:user]
STDERR.puts "Please specify a password to connect with using --password" unless options[:password]

exit(1) unless options[:host] && options[:port] && options[:user] && options[:password]

def get_password(cred_id)
  creds = ASM::Cipher.decrypt_credential(cred_id)
  raise("Could not lookup password credentials %s" % cred_id) unless creds
  creds[:password]
end

def query_wsman_dcim_systemview(options)
  command = "wsman enumerate 'http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/root/dcim/DCIM_SystemView' -h '%s' -V -v -c dummy.cert -P '%d' -u '%s' -p '%s' -j utf-8 -y basic -o --transport-timeout 5 2>&1" % [options[:host], options[:port], options[:user], options[:password]]

  xml = %x{#{command}}

  if xml =~ /Connection failed/
    return({"asm_error" => "Could not connect to host %s:%d" % [options[:host], options[:port]], "asm_nagios_code" => 2})
  elsif !xml.start_with?("<?xml version")
    return({"asm_error" => "Did not receive valid XML from wsman: %s" % xml, "asm_nagios_code" => 3})
  end

  raise("Did not receive valid XML from wsman: %s" % xml) unless xml.start_with?("<?xml version")

  doc = Nokogiri::XML(xml)

  begin
    sv = doc.xpath("//n1:DCIM_SystemView/*")
  rescue
    raise "No DCIM_SystemView properties found, unsupported hardware"
  end

  raise "No DCIM_SystemView properties found" unless sv.size > 0

  Hash[sv.map{|s| [s.name, s.text.strip]}]
end

def get_status_from_dcim_systemview(sv)
  rollup_to_str_map = {"0" => "Unknown", "1" => "OK", "2" => "Degraded", "3" => "Error"}
  rollup_to_nagios_map = {"0" => NAGIOS_UNKNOWN, "1" => NAGIOS_OK, "2" => NAGIOS_WARNING, "3" => NAGIOS_CRITICAL}

  rollups = sv.keys.grep(/.+?RollupStatus/).sort

  raise "RollupStatus not available" if rollups.empty?

  subsystem_states = rollups.map do |subsystem|
    next nil if ["0", "1"].include?(sv[subsystem])

    subsystem =~ /(.+?)RollupStatus/

    "%s: %s" % [$1, rollup_to_str_map[ sv[subsystem] ]]
  end.compact

  # We specifically check here if RollupStatus is 1, in that case we
  # ignore the other statusses and just report as OK.  These machines
  # will sometimes report that the CPU state is not ok while still showing
  # everything is fine in the overall rollup.  In that case a user cant
  # find any information about whats going on in the various UIs, so we
  # just hide that discrepancy.
  if sv["RollupStatus"] == "1"
    result_str = rollup_to_str_map[ sv["RollupStatus"] ]

  # sometimes the overall RollupStatus indicates an error but all the other RollupStatuses are ok
  # this means something is going on with another subsystem and the SEL might have more information
  elsif subsystem_states.empty? && ["2", "3"].include?(sv["RollupStatus"])
    result_str = "%s: Unknown reason, please consult iDrac System Event Log" % rollup_to_str_map[ sv["RollupStatus"] ]
  else
    result_str = subsystem_states.join(" ")
  end

  [rollup_to_nagios_map[ sv["RollupStatus"] ], result_str]
end

begin
  options[:password] = get_password(options[:password]) if options[:decrypt]

  dcim = query_wsman_dcim_systemview(options)

  if result = dcim["asm_error"]
    exit_code = dcim["asm_nagios_code"]
  else
    exit_code, result = get_status_from_dcim_systemview(dcim)
  end

  puts result
rescue 
  puts "UNKNOWN: Failed to get hardware status for host %s: %s" % [options[:host], $!.to_s]
  exit_code = NAGIOS_UNKNOWN
ensure
  exit exit_code
end

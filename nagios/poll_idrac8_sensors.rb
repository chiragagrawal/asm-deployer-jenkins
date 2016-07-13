#!/opt/puppet/bin/ruby

require 'rubygems'
require 'nokogiri'
require 'asm'
require 'asm/cipher'
require 'optparse'
require 'thread'
require 'yaml'
require 'json'
require 'tempfile'

def default_options(config="/opt/asm-deployer/config.yaml")
  config = YAML.load(File.read(config))

  {:graphite_host   => "localhost",
   :graphite_port   => 2003,
   :lockfile        => "/var/lock/asm_idrac8_metrics_poller",
   :metadata_dir    => "/var/lib/carbon/",
   :concurrency     => config.fetch("metrics_poller_concurrency", 4),
   :wsman_timeout   => config.fetch("metrics_poller_timeout", 10),
   :debug           => config.fetch("metrics_poller_debug", false)}
end

options = default_options

opt = OptionParser.new

opt.on("--host HOST", "Graphite host") do |v|
  options[:graphite_host] = v
end

opt.on("--post PORT", "Graphite port") do |v|
  options[:graphite_port] = Integer(v)
end

opt.on("--host HOST", "Graphite host") do |v|
  options[:graphite_host] = v
end

opt.on("--lockfile FILE", "-l", "Path to the lock file to use") do |v|
  options[:lockfile] = v
end

opt.on("--concurrency COUNT", "How many wsman processes to run concurrently") do |v|
  options[:concurrency] = Integer(v)
end

opt.on("--timeout TIMEOUT", "The timeout to run wsman with") do |v|
  options[:wsman_timeout] = Integer(v)
end

opt.on("--metadata DIR", "Where to store node metadata like peak values and first seen time") do |v|
  options[:metadata_dir] = v
end

opt.on("--debug", "-d", "Enable debug") do
  options[:debug] = true
end

opt.parse!

DEBUG = options[:debug]

class LockViolation < StandardError; end

def unlock(options)
  File.unlink(options[:lockfile])
end

def lock(options)
  debug("Attempting to gain lock using %s" % options[:lockfile])

  if File.exist?(options[:lockfile])
    locking_pid = File.readlines(options[:lockfile]).first.chomp

    if File.directory?("/proc/%s" % locking_pid)
      raise(LockViolation, "Another copy of %s is already running with pid %s.  Remove %s if no other copy is running" % [$0, locking_pid, options[:lockfile]])
    else
      log("Stale lock detected with pid %s" % locking_pid)
      unlock(options)
    end
  end

  File.open(options[:lockfile], "w") {|f| f.puts $$}

  true
end

def with_lock(options)
  lock_owner = lock(options)

  yield
rescue LockViolation
  log($!.message)
ensure
  unlock(options) if lock_owner
end

def log(msg)
  STDERR.puts("%s: %d: %s" % [Time.now, $$, msg])
end

def debug(msg)
  log(msg) if DEBUG
end

def nagios_query(action,data=nil)
  base_url = ASM.config.url.nagios || 'http://localhost:8081/asm/nagios/'
  response = ASM::PrivateUtil.query(base_url, action, 'put', data)
  JSON.parse(response, :symbolize_names => true)
end

def graphite_query(action,data)
  base_url = ASM.config.url.graphite || 'http://localhost:8081/asm/graphite/'
  response = ASM::PrivateUtil.query(base_url, action, 'put', data)
  JSON.parse(response, :symbolize_names => true)
end

def inventory_db
  nagios_query('idrac_eight_inventory')
end

def submit_metrics(metrics)
  graphite_query('submit_metrics', metrics)
end

def query_wsman_dcim_numericsensor(host, user, password, timeout)
  command = "wsman enumerate 'http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/root/dcim/DCIM_NumericSensor' -h '%s' -V -v -c dummy.cert -P '%d' -u '%s' -p '%s' -j utf-8 -y basic -o --transport-timeout %d 2>&1" % [host, 443, user, password, timeout]

  xml = %x{#{command}}

  if xml =~ /Connection failed/
    raise("Could not connect to host %s:%d: %s" % [host, 443, xml])
  elsif !xml.start_with?("<?xml version")
    raise("Did not receive valid XML from wsman: %s" % xml)
  end

  sensors = []

  xml.split(/<\?xml version.+\?>\n/).each do |doc|
    next if doc.empty?

    doc = Nokogiri::XML(doc)
    sv = doc.xpath("//n1:DCIM_NumericSensor/*")

    sensors << Hash[sv.map{|s| [s.name, s.text.strip]}]
  end

  sensors
end

def fetch_metrics_for(server, metrics, timeout)
  success = true
  count = 0
  starttime = Time.now
  graphite_root = "asm.server.%s" % server[:ref_id]

  log("Fetching metrics for %s with ip address %s" % [server[:ref_id], server[:ip_address]])

  sensor_data = query_wsman_dcim_numericsensor(server[:ip_address], server[:credentials][:username], server[:credentials][:password], timeout)

  collecttime = Time.now.to_i

  log("Got wsman result for %s" % server[:ref_id])

  sensor_data.each do |sensor|
    if sensor["CurrentState"] == "Unknown"
      log("Sensor %s is in an Unknown state, server is likely turned off, discarding sensor result" % sensor["ElementName"])
      next
    end

    debug("Got metric %s for %s" % [sensor["ElementName"], server[:ref_id]])

    count += 1
    name = sensor["ElementName"].gsub(" ", "_")
    value = Float(sensor["CurrentReading"]) * 10 ** Integer(sensor["UnitModifier"])

    metrics["%s.%s" % [graphite_root, name]] = {:value => value, :time => collecttime}

    ["LowerThresholdCritical", "LowerThresholdNonCritical", "UpperThresholdCritical", "UpperThresholdNonCritical"].each do |threshold|
      if sensor[threshold] && !sensor[threshold].empty?
        count += 1
        value = Float(sensor[threshold]) * 10 ** Integer(sensor["UnitModifier"])
        metrics["%s.%s_%s" % [graphite_root, name, threshold]] = {:value => value, :time => collecttime}
      end
    end
  end

  metrics["#{graphite_root}.collect_time"] = {:value => Time.now - starttime, :time => collecttime}
  metrics["#{graphite_root}.metric_count"] = {:value => count, :time => collecttime}

  log("Gathered %d metrics for %s" % [count, server[:ref_id]])
rescue
  log("Failed to fetch metrics for %s: %s: %s" % [server[:ref_id], $!.class, $!.to_s])
  success = false
ensure
  return success
end

def thread_pooled(item_count, max_workers)
  threads = []

  item_count.times do |idx|
    threads << Thread.new do
      yield(idx)
    end

    # waits for threads to finish without joining them or blocking
    # fast threads by slow ones like a join would, removes completed
    # threads from the array of running threads
    while threads.size >= max_workers
      threads.size.times do |thr_idx|
        threads[thr_idx] = nil unless threads[thr_idx].status
      end

      threads.compact!

      sleep 0.5
    end
  end

  # at the end we are below max_workers so just join whats left
  # till all the work is finished
  threads.each {|t| t.join}
end

def atomic_file(file, mode=0644)
  tempfile = Tempfile.new(File.basename(file), File.dirname(file))

  yield(tempfile)

  tempfile.close

  FileUtils.chmod(mode, tempfile.path)
  File.rename(tempfile.path, file)
end

def device_metadata_file_path(dir, devic)
  File.join(dir, "%s-asm-metadata.json" % devic)
end

def update_device_metadata(metrics, dir)
  raise("Metadata storage directory %s should be a directory" % dir) unless File.directory?(dir)
  raise("Metadata storage directory %s should be writable" % dir) unless File.writable?(dir)

  metadata = {}

  metrics.each do |k, v|
    next if k =~ /(.+)_((Lower|Upper)Threshold.+)$/
    next if v.nil?
    next if v.empty?

    debug("Saving metadata for %s" % k)

    if k =~ /^asm.server\.(.+?)\.(.+)/
      device = $1
      metric_name = $2
    else
      next
    end
    
    unless metadata[device]
      metadata[device] = JSON.parse(File.read(device_metadata_file_path(dir, device))) rescue {}
    end

    metadata[device]["device"] = device
    metadata[device]["last_seen"] = Time.now.to_i
    metadata[device]["first_seen"] ||= v[:time]
    metadata[device][metric_name] ||= {"value" => -1.0/0.0, "time" => 0}

    if v[:value] > metadata[device][metric_name]["value"]
      metadata[device][metric_name] = {"value" => v[:value], "time" => v[:time]}
    end
  end

  metadata.each do |device, metadata|
    metadatafile = device_metadata_file_path(dir, device)
    debug("Storing metadata for device %s in %s" % [device, metadatafile])
    atomic_file(metadatafile) do |f|
      f.puts JSON.dump(metadata)
    end
  end
end

with_lock(options) do
  metrics = {}
  starttime = Time.now

  resources = inventory_db

  log("Collecting metrics for %d servers using %d concurrent wsman processes with a timeout of %d" % [resources.size, options[:concurrency], options[:wsman_timeout]])

  fetch_statusses = []

  thread_pooled(resources.size, options[:concurrency]) do |idx|
    server = resources[idx]
    server[:credentials] = ASM::Cipher::decrypt_credential(server[:cred_id])
    fetch_statusses << fetch_metrics_for(server, metrics, options[:wsman_timeout])
  end

  successful_hosts = fetch_statusses.grep(true).size

  metrics["asm.poller.server.servers"] = {:value => resources.size, :time => Time.now.to_i}
  metrics["asm.poller.server.collect_time"] = {:value => Time.now - starttime, :time => Time.now.to_i}
  metrics["asm.poller.server.fetched_servers"] = {:value => successful_hosts, :time => Time.now.to_i}

  response = submit_metrics(metrics)
  submitted = response[:submitted]
  graphite_time = response[:graphite_time]

  log("Finished submitting %d/%d metrics for %d/%d srvers in %0.2fs, total run time %0.2fs" % [submitted, metrics.size, successful_hosts, resources.size, graphite_time, Time.now - starttime])

  update_device_metadata(metrics, options[:metadata_dir])
end

#!/opt/puppet/bin/ruby

require 'asm'
require 'rubygems'
require 'optparse'
require 'uri'
require 'rest_client'
require 'json'
require 'asm/private_util'

HEALTH_MAP = {0 => "GREEN", 1 => "YELLOW", 2 => "RED", 3 => "UNKNOWN"}

options = {:statusfile => "/var/log/nagios/status.dat",
           :debug => false,
           :lockfile => "/var/lock/asm_process_nagios_status"}

opt = OptionParser.new

opt.on("--statusfile FILE", "-s", "Path to nagios status.dat") do |v|
  options[:statusfile] = v
end

opt.on("--lockfile FILE", "-l", "Path to the lock file to use") do |v|
  options[:lockfile] = v
end

opt.on("--debug", "-d", "Enable debug") do
  options[:debug] = true
end

opt.parse!

class LockViolation < StandardError; end

module Nagios
  class Status
    attr_reader :status, :path

    def initialize(statusfile=nil)
      if statusfile
        raise(ArgumentError, "Statusfile file name must be provided") unless statusfile
        raise(RuntimeError, "Statusfile #{statusfile} does not exist") unless File.exist?(statusfile)
        raise(RuntimeError, "Statusfile #{statusfile} is not readable") unless File.readable?(statusfile)
        @path = statusfile
      end
      @status = {'hosts' => { }}
    end

    # Parses a nagios status file returning a data structure for all the data
    def parsestatus(path=nil)
      path ||= @path

      raise(ArgumentError, "Statusfile file name must be provided either in constructor or as argument to parsestatus method") unless path

      @status, handler, blocklines = {'hosts' => {}}, '', []

      File.readlines(path, :encoding => 'iso-8859-1').each do |line|

        # start of new sections
        if line =~ /(\w+) \{/
          blocklines = []
          handler = $1
        end

        # gather all the lines for the block into an array
        # we'll pass them to a handler for this kind of block
        if line =~ /\s+(\w+)=(.+)/ && handler != ""
          blocklines << line
        end

        # end of a section
        if line =~ /\}/ && handler != "" && self.respond_to?("handle_#{handler}", include_private = true)
          self.send "handle_#{handler}".to_sym, blocklines
          handler = ""
        end
      end

      self
    end

    alias :parse :parsestatus

    # Returns a list of all hosts matching the options in options
    def find_hosts(options = {})
      forhost = options.fetch(:forhost, [])
      notifications = options.fetch(:notifyenabled, nil)
      action = options.fetch(:action, nil)
      withservice = options.fetch(:withservice, [])

      hosts = []
      searchquery = []

      # Build up a search query for find_with_properties each
      # array member is a hash of property and a match
      forhost.each do |host|
        searchquery << search_term("host_name", host)
      end

      withservice.each do |s|
        searchquery << search_term("service_description", s)
      end

      searchquery << {"notifications_enabled" => notifications.to_s} if notifications

      hsts = find_with_properties(searchquery)

      hsts.each do |host|
        host_name = host["host_name"]

        hosts << parse_command_template(action, host_name, "", host_name)
      end

      hosts.uniq.sort
    end

    # Returns a list of all services matching the options in options
    def find_services(options = {})
      forhost = Array(options.fetch(:forhost, []))
      notifications = options.fetch(:notifyenabled, nil)
      action = options.fetch(:action, nil)
      withservice = Array(options.fetch(:withservice, []))
      acknowledged = options.fetch(:acknowledged, nil)
      passive = options.fetch(:passive, nil)
      current_state = options.fetch(:current_state, nil)

      services = []
      searchquery = []

      # Build up a search query for find_with_properties each
      # array member is a hash of property and a match
      forhost.each do |host|
        searchquery << search_term("host_name", host)
      end

      withservice.each do |s|
        searchquery << search_term("service_description", s)
      end

      searchquery << {"current_state" => current_state } if current_state
      searchquery << {"notifications_enabled" => notifications.to_s} if notifications
      searchquery << {"problem_has_been_acknowledged" => acknowledged.to_s} if acknowledged
      if passive
        searchquery << {"active_checks_enabled"  => 0}
        searchquery << {"passive_checks_enabled" => 1}
      end

      svcs = find_with_properties(searchquery)

      svcs.each do |service|
        service_description = service["service_description"]
        host_name = service["host_name"]

        # when printing services with notifications en/dis it makes
        # most sense to print them in host:service format, abuse the
        # action option to get this result
        action = "${host}:${service}" if (notifications != nil && action == nil)

        services << parse_command_template(action, host_name, service_description, service_description)
      end

      services.uniq.sort
    end

    # Loops the services for a host and returns the overall state
    # which means if anything is CRITICAL it's CRITICAL, if anything
    # is UNKNOWN it's UNKNOWN else highest of OK and WARNING
    #
    # In the event that a service is new and have not yet been checked
    # the state is forced to UNKNOWN rather than OK that nagios does
    def aggregate_service_state_for_host(host)
      states = find_with_properties(search_term("host_name", host)).map do |service|
        if service["has_been_checked"] == "0"
          state = 3
        else
          state = Integer(service["current_state"])
        end

        state
      end

      # if it's critical its critical else it's whatever is highest
      return 2 if states.include?(2)
      return states.max
    end

    def aggregate_host_output(host)
      output = find_with_properties(search_term("host_name", host)).map do |service|
        # surpress "OK" strings, else we end up with "Error: foo OK" in the case where
        # one service is bad and another is ok.
        service["plugin_output"] == "OK" ? nil : service["plugin_output"]
      end.compact.join(" ")

      output = "OK" if output.empty?

      output
    end

    private

    # Add search terms, does all the mangling of regex vs string and so on
    def search_term(haystack, needle)
      needle = Regexp.new(needle.gsub("\/", "")) if needle.match("^/")
      {haystack => needle}
    end

    # Return service blocks for each service that matches any options like:
    #
    # "host_name" => "foo.com"
    #
    # The 2nd parameter can be a regex too.
    def find_with_properties(search)
      services = []
      query = []

      query << search if search.class == Hash
      query = search if search.class == Array

      @status["hosts"].each do |host,v|
        find_host_services(host) do |service|
          matchcount = 0

          query.each do |q|
            q.each do |option, match|
              if match.class == Regexp
                matchcount += 1 if service[option].match(match)
              else
                matchcount += 1 if service[option] == match.to_s
              end
            end
          end

          if matchcount == query.size
            services << service
          end
        end
      end

      services
    end

    # yields the hash for each service on a host
    def find_host_services(host)
      if @status["hosts"][host].has_key?("servicestatus")
        @status["hosts"][host]["servicestatus"].each do |s, v|
          yield(@status["hosts"][host]["servicestatus"][s])
        end
      end
    end

    # Parses a template given with a nagios command string and populates vars
    # else return the string given in default
    def parse_command_template(template, host, service, default)
      if template.nil?
        default
      else
        template.gsub(/\$\{host\}/, host).gsub(/\$\{service\}/, service).gsub(/\$\{tstamp\}/, Time.now.to_i.to_s)
      end
    end

    # Figures out the service name from a block in a nagios status file
    def get_service_name(lines)
      if s = lines.grep(/\s+service_description=(\S+)/).first
        if s =~ /service_description=(.+)$/
          service = $1
        else
          raise("Cant't parse service in block: #{s}")
        end
      else
        raise("Cant't find a service in block")
      end

      service
    end

    # Figures out the host name from a block in a nagios status file
    def get_host_name(lines)
      if h = lines.grep(/\s+host_name=(\w+)/).first
        if h =~ /host_name=(.+)$/
          host = $1
        else
          raise("Cant't parse hostname in block: #{h}")
        end
      else
        raise("Cant't find a hostname in block")
      end

      host
    end

    # Parses an info block
    def handle_info(lines)
      @status["info"] = {} unless @status["info"]

      lines.each do |l|
        if l =~ /\s+(\w+)=(\w+)/
          @status["info"][$1] = $2
        end
      end
    end

    # Parses a servicestatus block
    def handle_servicestatus(lines)
      host = get_host_name(lines)
      service = get_service_name(lines)

      @status["hosts"][host] = {} unless @status["hosts"][host]
      @status["hosts"][host]["servicestatus"] = {} unless @status["hosts"][host]["servicestatus"]
      @status["hosts"][host]["servicestatus"][service] = {} unless @status["hosts"][host]["servicestatus"][service]

      lines.each do |l|
        if l =~ /\s+(\w+)=(.+)$/
          if $1 == "host_name"
            @status["hosts"][host]["servicestatus"][service][$1] = host
          else
            @status["hosts"][host]["servicestatus"][service][$1] = $2
          end
        end
      end
    end

    # Parses a servicestatus block
    def handle_contactstatus(lines)
      @status['contacts'] ||= {}
      contact = get_contact_name(lines)
      @status['contacts'][contact] ||= {}
      lines.each do |line|
        match = line.match(/^\s*(.+)=(.*)$/)
        @status['contacts'][contact][match[1]] = match[2] unless match[1] == 'contact_name'
      end
    end

    def get_contact_name(lines)
      if h = lines.grep(/\s+contact_name=(\w+)/).first
        if h =~ /contact_name=(.*)$/
          contact_name = $1
        else
          raise("Can't parse contact_name in block: #{h}")
        end
      else
        raise("Can't parse contactstatus block")
      end
      return contact_name
    end

    # Parses a servicecomment block
    def handle_servicecomment(lines)
      host = get_host_name(lines)
      service = get_service_name(lines)
      @status["hosts"][host]['servicecomments'] ||= {}
      @status["hosts"][host]['servicecomments'][service] ||= []
      comment = {}
      lines.each do |line|
        match = line.match(/^\s*(.+)=(.*)$/)
        comment[match[1]] = match[2] unless match[1] == 'service_name'
      end
      @status['hosts'][host]['servicecomments'][service] << comment
    end

    # Parses hostcomment block
    def handle_hostcomment(lines)
      host = get_host_name(lines)
      @status['hosts'][host]['hostcomments'] ||= []
      comment = {}
      lines.each do |line|
        match = line.match(/^\s*(.+)=(.*)$/)
        comment[match[1]] = match[2] unless match[1] == 'host_name'
      end
      @status['hosts'][host]['hostcomments'] << comment
    end

    # Parses servicedowntime block
    def handle_servicedowntime(lines)
      host = get_host_name(lines)
      service = get_service_name(lines)
      downtime_id = get_downtime_id(lines)
      @status["hosts"][host]["servicedowntime"] = {} unless @status["hosts"][host]["servicedowntime"]
      @status["hosts"][host]["servicedowntime"][service] = downtime_id
    end

    # Parses hostdowntime block
    def handle_hostdowntime(lines)
      host = get_host_name(lines)
      downtime_id = get_downtime_id(lines)
      @status["hosts"][host]["hostdowntime"] = downtime_id
    end

    # Parse the downtime_id out of a block
    def get_downtime_id(lines)
      if h = lines.grep(/\s+downtime_id=(.*)$/).first
        if h =~ /downtime_id=(.+)$/
          downtime_id = $1
        else
          raise("Can't parse downtime_id in block: #{h}")
        end
      else
        raise("Can't find downtime_id in block")
      end

      return downtime_id
    end

    # Parses a programstatus block
    def handle_programstatus(lines)
      @status["process"] = {} unless @status["process"]

      lines.each do |l|
        if l =~ /\s+(\w+)=(\w+)/
          @status["process"][$1] = $2
        end
      end
    end

    # Parses a hoststatus block
    def handle_hoststatus(lines)
      host = get_host_name(lines)

      @status["hosts"][host] = {} unless @status["hosts"][host]
      @status["hosts"][host]["hoststatus"] = {} unless @status["hosts"][host]["hoststatus"]

      lines.each do |l|
        if l =~ /\s+(\w+)=(.+)\s*$/
          @status["hosts"][host]["hoststatus"][$1] = $2
        end
      end
    end
  end
end

def nagios_query(data=nil)
  base_url = ASM.config.url.nagios || 'http://localhost:8081/asm/nagios/'
  ASM::PrivateUtil.query(base_url, 'process_monitoring_data', 'put', data)
end

def unlock(options)
  File.unlink(options[:lockfile])
end

def lock(options)
  STDERR.puts("Attempting to gain lock using %s" % options[:lockfile]) if options[:debug]

  if File.exist?(options[:lockfile])
    locking_pid = File.readlines(options[:lockfile]).first.chomp

    if File.directory?("/proc/%s" % locking_pid)
      raise(LockViolation, "Another copy of %s is already running with pid %s.  Remove %s if no other copy is running" % [$0, locking_pid, options[:lockfile]])
    else
      STDERR.puts("Stale lock detected with pid %s" % locking_pid) if options[:debug]
      unlock(options)
    end
  end

  File.open(options[:lockfile], "w") {|f| f.puts $$}

  true
end

begin
  STDERR.puts("Starting nagios export %s, active pid is %d" % [Time.now, $$]) if options[:debug]

  lock_owner = lock(options)

  nagios = Nagios::Status.new.parse(options[:statusfile])

  nagios.find_hosts.each do |host|
    next if host == "dell-asm"

    state = HEALTH_MAP[nagios.aggregate_service_state_for_host(host)]
    service = nagios.aggregate_host_output(host)
    data = {
        :host => host,
        :service => service,
        :state => state
    }
    nagios_query(data)
  end
rescue LockViolation
  STDERR.puts $!.message
ensure
  unlock(options) if lock_owner
end

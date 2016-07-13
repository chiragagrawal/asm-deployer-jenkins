require "asm/client"
require "asm/errors"
require "asm/private_util"
require "asm/translatable"
require "rest_client"
require "json"
require "hashie"

module ASM
  module Client
    class Puppetdb
      include ASM::Translatable

      attr_reader :logger

      def initialize(options={})
        @logger = options.delete(:logger)
        url = options.delete(:url) || ASM.config.url.puppetdb || "http://localhost:7080"
        options = options[:options] || ASM.config.rest_client_options || {}
        @transport = RestClient::Resource.new(url, options)
      end

      def facts(cert_name)
        path = "v3/nodes/%s/facts" % URI.escape(cert_name)
        resp = @transport[path].get(:content_type => :json, :accept => :json)
        unless resp.code.between?(200, 299)
          msg = "Failed to find puppet facts for certificate name %s" % cert_name
          logger.error(msg) if logger
          raise(msg)
        end

        facts = {}

        JSON.parse(resp).inject({}) do |_, elem|
          facts[elem["name"]] = elem["value"]
        end

        facts.merge!(JSON.parse(facts.delete("json_facts"))) if facts["json_facts"]

        facts
      end

      def find_node_by_management_ip(value)
        query_str = '["and",  ["=", ["fact", "management_ip"], "%s"]]' % value
        path = "v3/nodes?query=%s" % URI.escape(query_str)
        response = @transport[path].get(:content_type => :json, :accept => :json)
        raise("Error response code %d while retrieving key %s" % [response.code, key]) unless response.code.between?(200, 299)
        JSON.parse(response).first
      end

      def node(cert_name)
        query_str = '["and", ["=", ["node", "active"], true], ["=", "name", "%s"]]]' % cert_name
        path = "v3/nodes?query=%s" % URI.escape(query_str)
        response = @transport[path].get(:content_type => :json, :accept => :json)
        raise("Error response code %d while retrieving node %s" % [response.code, cert_name]) unless response.code.between?(200, 299)
        JSON.parse(response).first
      end

      def latest_report(cert_name)
        query_str = '["=", "certname", "%s"]' % cert_name
        order_str = '[{"field": "receive-time", "order": "desc"}]'
        path = "v3/reports?query=%s&order-by=%s&limit=1" % [URI.escape(query_str), URI.escape(order_str)]
        response = @transport[path].get(:content_type => :json, :accept => :json)
        raise("Error response code %d while retrieving report for %s" % [response.code, cert_name]) unless response.code.between?(200, 299)
        JSON.parse(response).first
      end

      def events(report_id)
        query_str = '["=", "report", "%s"]' % report_id
        path = "v3/events?query=%s" % URI.escape(query_str)
        response = @transport[path].get(:content_type => :json, :accept => :json)
        raise("Error response code %d while retrieving event for report %s" % [response.code, report_id]) unless response.code.between?(200, 299)
        JSON.parse(response)
      end

      def successful_report_after?(cert_name, timestamp, options={})
        raise("Invalid timestamp argument: %s" % timestamp) unless timestamp.is_a?(Time)
        options = {
          :verbose => true
        }.merge(options)

        # check if cert is in list of active nodes
        logger.info("Waiting for puppet agent to check in for #{cert_name}") if options[:verbose]
        raise(ASM::CommandException, "Node %s has not checked in." % cert_name) unless node(cert_name)

        # get the latest report
        report = latest_report(cert_name)
        raise(ASM::CommandException, "No reports for #{cert_name}.") unless report
        logger.debug("Latest report: #{report}")

        # If report is from before the given timestamp, it's assumed it's from an old node reusing the same hostname
        report_receive_time = Time.parse(report["receive-time"])
        if report_receive_time < timestamp
          msg = "Puppet reports found for %s, but not from current node using that hostname." % cert_name
          logger.debug(msg) if options[:verbose]
          raise(ASM::CommandException, msg)
        end

        events = events(report["hash"])
        node_data = ASM::PrivateUtil.read_node_data(cert_name)
        if node_data && windows_yaml?(node_data, cert_name) && events.empty?
          msg = "There is no event in the report but node data is not empty for %s" % cert_name
          logger.debug(msg) if options[:verbose]
          raise(ASM::CommandException, msg)
        end

        logger.debug("Report response: #{events}")

        if events.any? { |event| event["status"] == "failure" }
          logger.error(t(:ASM049, "A recent Puppet event for the node %{certName} has failed. Node may not be correctly configured", :certName => cert_name)) if options[:verbose]
          false
        else
          if events.empty? && options[:verbose]
            logger.warn("No events for the latest report for agent %s. Assuming node checkin was successful." % cert_name)
          end
          true
        end
      end

      def windows_yaml?(string, cert_name)
        require "yaml"
        win_classes_pattern = ["mssql", "windows"]
        node_yaml = YAML.load(string)
        if node_yaml[cert_name]
          classes = (node_yaml[cert_name]["classes"] || {}).keys
          windows_resource = classes.find {|cl| cl.match(Regexp.union(win_classes_pattern))}
          return true unless windows_resource.nil?
        end
        false
      end

      def replace_facts!(cert_name, facts)
        facts = {"update_time" => Time.now.to_s}.merge(facts)
        payload = {
          "name" => cert_name,
          "values" => facts,
          "timestamp" => facts["update_time"]
        }.to_json

        message = {
          "command" => "replace facts",
          "version" => 1,
          "payload" => payload
        }.to_json

        path = "v3/commands"
        response = @transport[path].post("payload=#{CGI.escape(message)}", :accept => :json)
        logger.info("Update %s facts: response %d %s" % [cert_name, response.code, response])

        raise("Error response from replace facts call: %d: %s" %
              [response.code, response]) unless response.code.between?(200, 299)
        facts
      end

      def replace_facts_blocking!(cert_name, facts, options={})
        options = {:timeout => 60}.merge(options)
        facts = replace_facts!(cert_name, facts)
        replace_time = Time.parse(facts["update_time"])
        ASM::Util.block_and_retry_until_ready(options[:timeout], ASM::CommandException, nil) do
          facts = facts(cert_name)
          updated_time = Time.parse(facts["update_time"]) if facts["update_time"]
          raise(ASM::CommandException, "Facts last updated at %s" % updated_time) unless updated_time && updated_time >= replace_time
        end
        facts
      end
    end
  end
end

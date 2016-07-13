require 'spec_helper'
require 'hashie'
require 'asm/client/puppetdb'
require 'asm/config'

describe ASM::Client::Puppetdb do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil, :error => nil) }

  let(:config) do
    Hashie::Mash.new({:logger => logger,
                      :url => {:puppetdb => "http://asm-puppetdb-api:7080"},
                      :rest_client_options => {:verify_ssl => OpenSSL::SSL::VERIFY_PEER}})
  end

  before do
    SpecHelper.init_i18n
    ASM.stubs(:config).returns(Hashie::Mash.new(config))
  end

  describe "#initialize" do
    it "should instantiate RestClient::Resource with url and options" do
      RestClient::Resource.expects(:new).with(config.url.puppetdb, config.rest_client_options)
      @client = ASM::Client::Puppetdb.new(:logger => config.logger,
                                          :url => config.url.puppetdb,
                                          :options => config.rest_client_options)
    end

    it "should instantiate RestClient::Resource with ASM.config url and options" do
      RestClient::Resource.expects(:new).with(config.url.puppetdb, config.rest_client_options)
      @client = ASM::Client::Puppetdb.new
    end
  end

  def mock_response(code, data, method = :get)
    response = mock('response')
    response.stubs(:code).returns(code)

    data = JSON.generate(data) unless data.is_a?(String)
    response.stubs(:to_s).returns(data)
    response.stubs(:to_str).returns(data)

    intermediary = mock('intermediary')
    intermediary.stubs(method).returns(response)

    intermediary
  end

  def mock_transport(responses)
    transport = mock('transport')
    responses.each do |path, code, resp, method|
      method ||= :get
      if path
        transport.stubs(:[]).with(path).returns(mock_response(code, resp, method))
      else
        transport.stubs(:[]).returns(mock_response(code, resp, method))
      end
    end
    transport
  end

  describe "#facts" do

    it "should return facts on 200" do
      facts = {"certname" => "foo"}
      resp = facts.map { |k, v| {"name" => k, "value" => v} }
      RestClient::Resource.stubs(:new).returns(mock_transport([["v3/nodes/foo/facts", 200, resp]]))
      expect(ASM::Client::Puppetdb.new.facts("foo")).to eq(facts)
    end

    it "should fail on 500" do
      RestClient::Resource.stubs(:new).returns(mock_transport([["v3/nodes/foo/facts", 500, ""]]))
      expect { ASM::Client::Puppetdb.new.facts("foo") }.to raise_error("Failed to find puppet facts for certificate name foo")
    end

    it "should merge json_facts into response" do
      facts = {"certname" => "foo", "json_facts" => {"embedded" => 1}.to_json}
      resp = facts.map { |k, v| {"name" => k, "value" => v} }
      RestClient::Resource.stubs(:new).returns(mock_transport([["v3/nodes/foo/facts", 200, resp]]))
      expect(ASM::Client::Puppetdb.new.facts("foo")).to eq({"certname" => "foo", "embedded" => 1})
    end

  end

  describe "#node" do
    it "should return first matching node" do
      query_str = "[\"and\", [\"=\", [\"node\", \"active\"], true], [\"=\", \"name\", \"foo\"]]]"
      path = "v3/nodes?query=#{URI.escape(query_str)}"
      response = [path, 200, [{"name" => "foo"}, {"name" => "bar"}]]
      RestClient::Resource.stubs(:new).returns(mock_transport([response]))
      expect(ASM::Client::Puppetdb.new.node("foo")).to eq({"name" => "foo"})
    end

    it "should return nil if no matching node found" do
      query_str = "[\"and\", [\"=\", [\"node\", \"active\"], true], [\"=\", \"name\", \"foo\"]]]"
      path = "v3/nodes?query=#{URI.escape(query_str)}"
      RestClient::Resource.stubs(:new).returns(mock_transport([[path, 200, []]]))
      expect(ASM::Client::Puppetdb.new.node("foo")).to be_nil
    end

    it "should fail if error response code returned" do
      query_str = "[\"and\", [\"=\", [\"node\", \"active\"], true], [\"=\", \"name\", \"foo\"]]]"
      path = "v3/nodes?query=#{URI.escape(query_str)}"
      RestClient::Resource.stubs(:new).returns(mock_transport([[path, 404, ""]]))
      expect do
        ASM::Client::Puppetdb.new.node("foo")
      end.to raise_error("Error response code %d while retrieving node %s" % [404, "foo"])
    end
  end

  describe "#latest_report" do
    it "should return the latest report if found" do
      cert_name = "foo"
      query_str = "[\"=\", \"certname\", \"#{cert_name}\"]"
      order_str = "[{\"field\": \"receive-time\", \"order\": \"desc\"}]"
      path = "v3/reports?query=#{URI.escape(query_str)}&order-by=#{URI.escape(order_str)}&limit=1"
      report = {"certname" => cert_name, "hash" => "297b44f1762d589d28423dc88582906198e847b8"}
      RestClient::Resource.stubs(:new).returns(mock_transport([[path, 200, [report]]]))
      expect(ASM::Client::Puppetdb.new.latest_report("foo")).to eq(report)
    end

    it "should return nil if not found" do
      cert_name = "foo"
      query_str = "[\"=\", \"certname\", \"#{cert_name}\"]"
      order_str = "[{\"field\": \"receive-time\", \"order\": \"desc\"}]"
      path = "v3/reports?query=#{URI.escape(query_str)}&order-by=#{URI.escape(order_str)}&limit=1"
      RestClient::Resource.stubs(:new).returns(mock_transport([[path, 200, []]]))
      expect(ASM::Client::Puppetdb.new.latest_report("foo")).to be_nil
    end

    it "should raise an error on unsuccessful respnse code" do
      cert_name = "foo"
      query_str = "[\"=\", \"certname\", \"#{cert_name}\"]"
      order_str = "[{\"field\": \"receive-time\", \"order\": \"desc\"}]"
      path = "v3/reports?query=#{URI.escape(query_str)}&order-by=#{URI.escape(order_str)}&limit=1"
      RestClient::Resource.stubs(:new).returns(mock_transport([[path, 503, []]]))
      expect do
        ASM::Client::Puppetdb.new.latest_report("foo")
      end.to raise_error("Error response code %d while retrieving report for %s" % [503, cert_name])
    end
  end

  describe "#events" do
    it "should return events if found" do
      report_id = "297b44f1762d589d28423dc88582906198e847b8"
      query_str = "[\"=\", \"report\", \"#{report_id}\"]"
      path = "v3/events?query=#{URI.escape(query_str)}"
      events = [{"certname" => "foo", "status" => "failure", "message" => "stuff went wrong"},
                {"certname" => "foo", "status" => "success", "message" => "stuff went right"}]
      RestClient::Resource.stubs(:new).returns(mock_transport([[path, 200, events]]))
      expect(ASM::Client::Puppetdb.new.events(report_id)).to eq(events)
    end

    it "should return an empty list if events not found" do
      RestClient::Resource.stubs(:new).returns(mock_transport([[nil, 200, []]]))
      expect(ASM::Client::Puppetdb.new.events("no-report-id")).to eq([])
    end

    it "should raise an exception on unsuccessful response code" do
      report_id = "no-report-id"
      RestClient::Resource.stubs(:new).returns(mock_transport([[nil, 501, []]]))
      expect do
        ASM::Client::Puppetdb.new.events(report_id)
      end.to raise_error("Error response code %d while retrieving event for report %s" % [501, report_id])
    end

  end

  describe "find_node_by_management_ip" do
    it "should return facts when found" do
      value="172.17.11.13"
      query_str = '["and",  ["=", ["fact", "management_ip"], "172.17.11.13"]]'
      path = "v3/nodes?query=#{URI.escape(query_str)}"
      facts ={"name" => "dell_ftos-172.17.11.13", "deactivated" => nil, "catalog_timestamp" => nil, "facts_timestamp" => "2016-04-06T05:00:10.467Z", "report_timestamp" => nil}
      RestClient::Resource.stubs(:new).returns(mock_transport([[path, 200, [facts]]]))
      expect(ASM::Client::Puppetdb.new.find_node_by_management_ip(value)).to eq(facts)
    end

    it "should return nill if fact is not found" do
      value = "172.17.11.13"
      query_str = '["and",  ["=", ["fact", "management_ip"], "172.17.11.13"]]'
      path = "v3/nodes?query=#{URI.escape(query_str)}"
      RestClient::Resource.stubs(:new).returns(mock_transport([[path, 200, []]]))
      expect(ASM::Client::Puppetdb.new.find_node_by_management_ip(value)).to eq(nil)
    end

    it "should raise an exception on unsuccessful response code" do
      key = "management_ip"
      value = "172.17.11.13"
      query_str = '["and",  ["=", ["fact", "management_ip"], "172.17.11.13"]]'
      path = "v3/nodes?query=#{URI.escape(query_str)}"
      RestClient::Resource.stubs(:new).returns(mock_transport([[path, 501, []]]))
      expect do
        ASM::Client::Puppetdb.new.find_node_by_management_ip(value)
        raise("Error response code %d while retrieving key %s" % [response.code, key])
      end
    end

  end

  describe "#successful_report_after?" do
    let(:puppetdb) { ASM::Client::Puppetdb.new(:logger => logger) }
    let(:time) { Time.parse("2001-07-26T00:35:35.127Z") }

    it "should raise an exception if node not found" do
      puppetdb.stubs(:node).returns(nil)
      cert_name = "certname"
      expect do
        puppetdb.successful_report_after?(cert_name, time)
      end.to raise_error(ASM::CommandException, "Node #{cert_name} has not checked in.")
    end

    it "should raise an exception if report not found" do
      cert_name = "certname"
      puppetdb.stubs(:node).with(cert_name).returns({"certname" => cert_name})
      puppetdb.stubs(:latest_report).returns(nil)
      expect do
        puppetdb.successful_report_after?(cert_name, time)
      end.to raise_error(ASM::CommandException, "No reports for #{cert_name}.")
    end

    it "should raise an exception if report time is before timestamp" do
      cert_name = "certname"
      puppetdb.stubs(:node).with(cert_name).returns({"certname" => cert_name})
      puppetdb.stubs(:latest_report).returns({"certname" => cert_name, "receive-time" => "1999-07-26T00:35:35.127Z"})
      expected_msg = "Puppet reports found for #{cert_name}, but not from current node using that hostname."
      expect do
        puppetdb.successful_report_after?(cert_name, time)
      end.to raise_error(ASM::CommandException, expected_msg)
    end

    it "should return false if a report event failed" do
      cert_name = "certname"
      puppetdb.stubs(:node).with(cert_name).returns({"certname" => cert_name})
      report_id = "169c2a6bf825d5f42d6bfad3131f5c36f2e51abf"
      report = {"certname" => cert_name,
                "receive-time" => "2015-07-26T00:35:35.127Z",
                "hash" => report_id}
      puppetdb.stubs(:latest_report).with(cert_name).returns(report)
      events = [{"certname" => cert_name, "status" => "failure"}]
      puppetdb.stubs(:events).with(report_id).returns(events)
      expect(puppetdb.successful_report_after?(cert_name, time)).to eq(false)
    end

    it "should return true if all report events successful" do
      cert_name = "certname"
      puppetdb.stubs(:node).with(cert_name).returns({"certname" => cert_name})
      report_id = "169c2a6bf825d5f42d6bfad3131f5c36f2e51abf"
      report = {"certname" => cert_name,
                "receive-time" => "2015-07-26T00:35:35.127Z",
                "hash" => report_id}
      puppetdb.stubs(:latest_report).with(cert_name).returns(report)
      events = [{"certname" => cert_name, "status" => "success"}]
      puppetdb.stubs(:events).with(report_id).returns(events)
      expect(puppetdb.successful_report_after?(cert_name, time)).to eq(true)
    end

    it "should return true if no report events found" do
      cert_name = "certname"
      puppetdb.stubs(:node).with(cert_name).returns({"certname" => cert_name})
      report_id = "169c2a6bf825d5f42d6bfad3131f5c36f2e51abf"
      report = {"certname" => cert_name,
                "receive-time" => "2015-07-26T00:35:35.127Z",
                "hash" => report_id}
      puppetdb.stubs(:latest_report).with(cert_name).returns(report)
      puppetdb.stubs(:events).with(report_id).returns([])
      expect(puppetdb.successful_report_after?(cert_name, time)).to eq(true)
    end
  end

  describe "#replace_facts!" do
    let(:puppetdb) { ASM::Client::Puppetdb.new(:logger => logger) }
    let(:time) { Time.parse("2001-07-26T00:35:35.127Z") }

    it "should update facts" do
      RestClient::Resource.stubs(:new).returns(mock_transport([[nil, 200, "", :post]]))
      facts = {"update_time" => time.to_s}
      expect(puppetdb.replace_facts!("cert_name", facts)).to eq(facts)
    end

    it "should fail if post fails" do
      RestClient::Resource.stubs(:new).returns(mock_transport([[nil, 503, "", :post]]))
      facts = {"update_time" => time.to_s}
      expect do
        puppetdb.replace_facts!("cert_name", facts)
      end.to raise_error("Error response from replace facts call: %d: %s" %
                             [503, ""])
    end
  end

  describe "#replace_facts_blocking!" do
    let(:puppetdb) { ASM::Client::Puppetdb.new(:logger => logger) }
    let(:time) { Time.parse("2001-07-26T00:35:35.127Z") }

    it "should succeed if facts update_time is reached" do
      facts = {"update_time" => time.to_s}
      cert_name = "cert_name"
      puppetdb.stubs(:replace_facts!).with(cert_name, facts).returns(facts)
      puppetdb.stubs(:facts).with(cert_name).returns({"update_time" => time.to_s})
      expect(puppetdb.replace_facts_blocking!(cert_name, facts, :timeout => 0.1)).to eq(facts)
    end

    it "should fail if facts update_time not update" do
      facts = {"update_time" => time.to_s}
      cert_name = "cert_name"
      puppetdb.stubs(:replace_facts!).with(cert_name, facts).returns(facts)
      puppetdb.stubs(:facts).with(cert_name).returns({"update_time" => "2001-01-01T00:35:35.127Z"})
      expect do
        puppetdb.replace_facts_blocking!(cert_name, facts, :timeout => 0.1)
      end.to raise_error(Timeout::Error)
    end
  end
end

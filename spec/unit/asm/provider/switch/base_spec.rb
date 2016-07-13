require 'spec_helper'
require 'asm/type'

ASM::Type.load_providers!

describe ASM::Provider::Switch::Base do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil, :error => nil) }
  let(:raw_switches) { SpecHelper.json_fixture("switch_providers/switch_inventory.json") }

  let(:collection) { ASM::Service::SwitchCollection.new(logger) }
  let(:type) { collection.switches.first }
  let(:provider) { type.provider }

  let(:base) { ASM::Provider::Switch::Base.new }

  let(:switch_facts) { eval(SpecHelper.load_fixture("switch_providers/dell_iom-172.17.9.171_facts.json"))}

  let(:service) {SpecHelper.service_from_fixture("cisco_fc_deployment/deployment.json")}
  let(:server_component) { service.components_by_type("SERVER").first }

  let(:server) { server_component.to_resource(nil, logger)}
  let(:server_network) { SpecHelper.json_fixture("cisco_fc_deployment/%s_network_config.json" % server.puppet_certname) }

  before(:each) do
    collection.stubs(:managed_inventory).returns(raw_switches)
    base.type = type
  end

  describe "#valid_wwpn?" do
    it "should detect wwpn correctly" do
      expect(base.valid_wwpn?("20:01:74:86:7A:EF:48:3D")).to be(true)
      expect(base.valid_wwpn?("08:00:27:6b:57:88")).to be(false)
      expect(base.valid_wwpn?("20:01:74:86:7A:EF:48:3Z")).to be(false)
      expect(base.valid_wwpn?("08:00:27:6b:57:zz")).to be(false)
      expect(base.valid_wwpn?("08:00")).to be(false)
    end
  end

  describe "#valid_mac?" do
    it "should detect macs correctly" do
      expect(base.valid_mac?("08:00:27:6b:57:88")).to be(true)
      expect(base.valid_mac?("20:01:74:86:7A:EF:48:3D")).to be(false)
      expect(base.valid_mac?("08:00:27:6b:57:zz")).to be(false)
      expect(base.valid_mac?("08:00")).to be(false)
    end
  end

  describe "#features" do
    it "should fetch and return the features fact" do
      base.facts = {"features" => {"rspec" => 1}}
      expect(base.features).to include("rspec")
    end

    it "should default to empty hash when no features are set" do
      base.facts = {}
      expect(base.features).to eq({})
    end
  end

  describe "#find_mac" do
    it "should return the interface when found" do
      base.facts = {"remote_device_info" => {"Int/1" => {"remote_mac" => "rspec:rspec"}}}
      expect(base.find_mac("rspec:rspec")).to eq("Int/1")
      expect(base.find_mac("rspec")).to be(nil)
    end

    it "should return nil when there are no facts" do
      base.facts = {}
      expect(base.find_mac("rspec:rspec")).to be(nil)
    end
  end

  describe "#configure!" do
    it "should configure the device url" do
      expect(provider.connection_url).to be(nil)
      type.expects(:device_config).returns({"url" => "http://rspec"})
      provider.configure!(raw_switches.first)
      expect(provider.connection_url).to eq("http://rspec")
    end
  end

  describe "#validate_network_config" do
    before(:each) do
      network_config = ASM::NetworkConfiguration.new(SpecHelper.json_fixture("cisco_fc_deployment/rackserver-2vzc5x1_network_config.json"))
      server.stubs(:network_config).returns(network_config)
      type.stubs(:find_mac).returns("Eth1/21")
      server.stubs(:db_log).returns(nil)
    end

    it "should return false when validation fails" do
      type.stubs(:facts).returns(SpecHelper.json_fixture("switch_providers/vlan_info_missing.json"))
      type.stubs(:retrieve_inventory).returns({"state" => "UNMANAGED"})
      expect(base.validate_network_config(server)).to eq(false)
    end

    it "should return true when valid config found" do
      type.stubs(:facts).returns(SpecHelper.json_fixture("switch_providers/vlan_information.json"))
      type.stubs(:retrieve_inventory).returns({"state" => "UNMANAGED"})
      expect(base.validate_network_config(server)).to eq(true)
    end
  end
end

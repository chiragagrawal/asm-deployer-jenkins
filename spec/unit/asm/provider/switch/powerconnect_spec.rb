require 'spec_helper'
require 'asm/type'

ASM::Type.load_providers!

describe ASM::Provider::Switch::Powerconnect do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }

  let(:raw_switches) { SpecHelper.json_fixture("powerconnect_deployment/switch_inventory.json") }

  let(:collection) { ASM::Service::SwitchCollection.new(logger) }
  let(:type) { collection.switches[0] }
  let(:provider) { type.provider }

  let(:service) { SpecHelper.service_from_fixture("powerconnect_deployment/deployment.json") }
  let(:server_component) { service.components_by_type("SERVER").first }
  let(:storage_component) { service.components_by_type("STORAGE").first }

  let(:server) { server_component.to_resource(nil, logger) }
  let(:server_network) { SpecHelper.json_fixture("powerconnect_deployment/%s_network_config.json" % server.puppet_certname) }
  let(:storage) { storage_component.to_resource(nil, logger) }

  before(:each) do
    server.stubs(:network_config).returns(ASM::NetworkConfiguration.new(server_network))
    collection.stubs(:managed_inventory).returns(raw_switches)
    ASM::Service::SwitchCollection.stubs(:new).returns(collection)
  end

  describe "#handles_switch" do
    it "should handle switches starting with dell_powerconnet and not others" do
      expect(provider.class.handles_switch?("refId" => "cisconexus5k")).to be(false)
      expect(provider.class.handles_switch?("refId" => "dell_powerconnect")).to be(true)
      expect(provider.class.handles_switch?("refId" => "dell_ftos_rspec")).to be(false)
    end
  end

  describe "#server_supported?" do
    it "should support only rack servers" do
      provider.stubs(:rack_switch?).returns(true)
      provider.stubs(:blade_switch?).returns(false)
      expect(provider.server_supported?(stub(:rack_server? => true, :blade_server? => false))).to be true
    end
  end

  describe "#resource_creator!" do
    it "should support rack creators" do
      provider.stubs(:rack_switch?).returns(true)
      provider.stubs(:blade_switch?).returns(false)
      provider.resource_creator.should be_a(ASM::Provider::Switch::Powerconnect::Rack)
    end
  end

  describe "#additional_resources" do
    it "should get the generated resources from the creator" do
      provider.stubs(:resource_creator).returns(mock(:to_puppet => {:rspec => 1}))
      expect(provider.additional_resources).to eq(:rspec => 1)
    end
  end

  describe "#process!" do
    let(:creator) { stub }
    before(:each) do
      provider.stubs(:resource_creator).returns(creator)
    end

    it "should prepare and process both add and removes" do
      creator.expects(:prepare).with(:add)
      creator.expects(:prepare).with(:remove)
      type.process!
    end

    it "should only process resources when ones were found" do
      s = sequence(:process_order)
      creator.expects(:prepare).with(:remove).returns(true).in_sequence(s)
      provider.expects(:to_puppet).in_sequence(s)
      type.expects(:process_generic).in_sequence(s)
      creator.expects(:prepare).with(:add).returns(false).in_sequence(s)

      type.process!
    end
  end

  describe "#configure_server!" do
    it "should support provisioning" do
      provider.expects(:provision_server_networking).with(server)
      provider.expects(:process!)
      server.stubs(:teardown?).returns(false)
      provider.configure_server(server, false)
    end

    it "should support teardown" do
      provider.expects(:teardown_server_networking).with(server)
      provider.expects(:process!)
      server.stubs(:teardown?).returns(true)
      provider.configure_server(server)
    end
  end

  describe "#provision_server_networking" do
    context "on standup" do
      it "should configure every network" do
        server.stubs(:razor_policy_name).returns("rspec")
        provider.stubs(:resource_creator).returns(creator = stub)
        provider.stubs(:use_portchannel?).returns(false)
        type.stubs(:find_mac).returns("Te1/0/33")

        creator.expects(:configure_interface_vlan).with("Te1/0/33", 18, false, false, "", "12000").twice
        provider.provision_server_networking(server)
      end
    end

    describe "#teardown_server_networking" do
      it "should reset all partitions to vlan 1" do
        creator = stub("creator")
        provider.stubs(:resource_creator).returns(creator)
        type.stubs(:find_mac).returns("Te1/0/33")
        creator.expects(:configure_interface_vlan).with("Te1/0/33", "1", false, true).twice

        provider.teardown_server_networking(server)
      end
    end

    context "on teardown" do
      it "should remove every network" do
        server.stubs(:razor_policy_name).returns("rspec")
        provider.stubs(:resource_creator).returns(creator = stub)
        provider.stubs(:use_portchannel?).returns(false)
        type.stubs(:find_mac).returns("Te1/0/33")
        server.stubs(:teardown?).returns(true)

        creator.expects(:configure_interface_vlan).with("Te1/0/33", 18, false, true, "", "12000").twice
        provider.provision_server_networking(server)
      end
    end
  end
end
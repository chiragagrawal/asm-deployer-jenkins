require 'spec_helper'
require 'asm/type'

ASM::Type.load_providers!

describe ASM::Provider::Switch::Force10 do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:raw_switches) { SpecHelper.json_fixture("switch_providers/switch_inventory.json") }

  let(:collection) { ASM::Service::SwitchCollection.new(logger) }
  let(:type) { collection.switches[0] }
  let(:provider) { type.provider }

  let(:service) { SpecHelper.service_from_fixture("switch_providers/deployment.json") }
  let(:server_component) { service.components_by_type("SERVER").first }
  let(:server) { server_component.to_resource(nil, logger) }
  let(:server_network) { SpecHelper.json_fixture("switch_providers/%s_network_config.json" % server.puppet_certname) }
  let(:vltdata) {{"uplinkId"=>"vlt", "uplinkName"=>"VLT", "portChannel"=>"25", "portMembers"=>["Te 0/44", "Te 0/37"], "portNetworks"=>[]}}

  before(:each) do
    server.stubs(:network_config).returns(ASM::NetworkConfiguration.new(server_network))
    collection.stubs(:managed_inventory).returns(raw_switches)
    ASM::Service::SwitchCollection.stubs(:new).returns(collection)
  end

  describe "#configure_iom_mode!" do
    it "should delegate to the provider and run puppet whenvlt is false" do
      creator = stub
      creator.expects(:configure_iom_mode!).with(false, true, nil).once
      provider.stubs(:resource_creator).returns(creator)

      provider.expects(:process!).with(:skip_prepare => true)

      provider.configure_iom_mode!(false, true, nil)
    end
  end

  describe "#configure_force10_settings" do
    it "should fail for invalid settings" do
      expect {
        provider.configure_force10_settings("rspec")
      }.to raise_error('Received invalid force10_settings for dell_iom-172.17.9.174: "rspec"')
    end

    it "should configure settings via the resource creator" do
      type.expects(:process_generic).with("dell_iom-172.17.9.174", {"force10_settings" => {"dell_iom-172.17.9.174" => {"rspec" => 1}}}, "apply", true, nil, nil, false)
      provider.configure_force10_settings("rspec" => 1)
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

  describe "#additional_resources" do
    it "should get the generated resources from the creator" do
      provider.stubs(:resource_creator).returns(mock(:to_puppet => {:rspec => 1}))
      expect(provider.additional_resources).to eq(:rspec => 1)
    end
  end

  describe "#resource_creator!" do
    it "should support rack creators" do
      provider.stubs(:rack_switch?).returns(true)
      provider.stubs(:blade_switch?).returns(false)
      provider.resource_creator.should be_a(ASM::Provider::Switch::Force10::Rack)
    end

    it "should support blade ioa creators" do
      provider.stubs(:rack_switch?).returns(false)
      provider.stubs(:blade_switch?).returns(true)
      provider.stubs(:blade_io_switch?).returns(true)
      provider.resource_creator.should be_a(ASM::Provider::Switch::Force10::BladeIoa)
    end

    it "should support blade mxl creators" do
      provider.stubs(:rack_switch?).returns(false)
      provider.stubs(:blade_ioa_switch?).returns(false)
      provider.stubs(:blade_mxl_switch?).returns(true)
      provider.resource_creator.should be_a(ASM::Provider::Switch::Force10::BladeMxl)
    end
  end

  describe "#server_supported?" do
    it "should support rack servers" do
      provider.stubs(:rack_switch?).returns(true)
      provider.stubs(:blade_switch?).returns(false)
      expect(provider.server_supported?(stub(:rack_server? => true, :blade_server? => false))).to be true
    end

    it "should support blade servers" do
      provider.stubs(:rack_switch?).returns(false)
      provider.stubs(:blade_switch?).returns(true)
      expect(provider.server_supported?(stub(:rack_server? => false, :blade_server? => true, :tower_server? => false))).to be true
    end

    it "should support tower servers" do
      provider.stubs(:rack_switch?).returns(true)
      provider.stubs(:blade_switch?).returns(false)
      expect(provider.server_supported?(stub(:rack_server? => false, :blade_server? => false, :tower_server? => true))).to be true
    end

    it "should not support others" do
      expect(provider.server_supported?(stub(:rack_server? => false, :blade_server? => false, :tower_server? => false))).to be false
    end
  end

  describe "when configuring servers" do
    before(:each) do
      ["dell_iom-172.17.9.174", "dell_ftos-172.17.9.13", "dell_ftos-172.17.9.14", "dell_iom-172.17.9.171"].each do |sw|
        facts_fixture = "switch_providers/%s_facts.json" % sw
        ASM::PrivateUtil.stubs(:facts_find).with(sw).returns(SpecHelper.json_fixture(facts_fixture))
      end

      network_config = ASM::NetworkConfiguration.new(SpecHelper.json_fixture("switch_providers/bladeserver-gp181y1_network_config.json"))
      facts = SpecHelper.json_fixture("switch_providers/bladeserver-gp181y1_facts.json")

      server.stubs(:network_config).returns(network_config)
      server.stubs(:retrieve_facts!).returns(facts)
    end

    describe "#teardown_server_networking" do
      it "should reset all partitions to vlan 1" do
        provider.stubs(:resource_creator).returns(creator = stub)
        creator.expects(:configure_interface_vlan).with("Te 0/2", "1", false, true)

        provider.teardown_server_networking(server)
      end
    end

    describe "#provision_server_networking" do
      it "should configure every network" do
        server.stubs(:razor_policy_name).returns("rspec")
        provider.stubs(:resource_creator).returns(creator = stub)
        provider.stubs(:use_portchannel?).returns(false)
        creator.expects(:configure_interface_vlan).with("Te 0/2", 18, false, false, "", "12000")
        creator.expects(:configure_interface_vlan).with("Te 0/2", 20, true, false, "", "12000")
        creator.expects(:configure_interface_vlan).with("Te 0/2", 23, true, false, "", "12000")
        creator.expects(:configure_interface_vlan).with("Te 0/2", 28, true, false, "", "12000")
        provider.provision_server_networking(server)
      end
    end
  end

  describe "#configure_server!" do
    it "should support provisioning" do
      provider.expects(:provision_server_networking).with(server)
      provider.expects(:process!)
      server.stubs(:teardown?).returns(false)
      provider.configure_server(server)
    end

    it "should support teardown" do
      provider.expects(:teardown_server_networking).with(server)
      provider.expects(:process!)
      server.stubs(:teardown?).returns(true)
      provider.configure_server(server)
    end
  end

  describe "#npiv_switch?" do
    it "should only consider NPG mode switches as npiv switches" do
      provider.facts["switch_fc_mode"] = "NPG"
      expect(provider.npiv_switch?).to be(true)

      provider.facts["switch_fc_mode"] = "rspec"
      expect(provider.npiv_switch?).to be(false)
    end
  end

  describe "#san_switch?" do
    it "should only consider Fabric-Services mode switches as san switches" do
      provider.facts["switch_fc_mode"] = "Fabric-Services"
      expect(provider.san_switch?).to be(true)

      provider.facts["switch_fc_mode"] = "rspec"
      expect(provider.san_switch?).to be(false)
    end
  end

  describe "#fcflexiom_switch?" do
    it "should be a flexiom switch when there is a fc interface" do
      provider.stubs(:blade_switch?).returns(true)
      provider.facts["interfaces"] << "fc_rspec"
      expect(provider.fcflexiom_switch?).to be(true)
    end

    it "should only consider blade switches" do
      provider.facts.expects(:key).never
      provider.expects(:blade_switch?).returns(false)
      expect(provider.fcflexiom_switch?).to be(false)
    end

    it "should not consider switches without fc ports" do
      provider.expects(:blade_switch?).returns(true)
      expect(provider.fcflexiom_switch?).to be(false)
    end
  end

  describe "#blade_switch?" do
    it "should be a blade switch for MXL, Aggregator and IOA models" do
      ["Aggregator RSPEC", "IOA RSPEC", "MXL RSPEC"].each do |model|
        provider.model = model
        expect(provider.blade_switch?).to be(true)
      end
    end

    it "should not be a blade switch for other models" do
      provider.model = "rspec"
      expect(provider.blade_switch?).to be(false)
    end
  end

  describe "#rack_switch?" do
    it "should detect rack switches" do
      provider.refId = "dell_ftos_rspec"
      expect(provider.rack_switch?).to be(true)

      provider.refId = "dell_iom_rspec"
      expect(provider.rack_switch?).to be(false)
    end
  end

  describe "#handles_switch?" do
    it "should handle switches starting with dell_ftos and not others" do
      expect(provider.class.handles_switch?("refId" => "dell_ftos_rspec", "model" => "I/O-Aggregator")).to be(true)
      expect(provider.class.handles_switch?("refId" => "dell_rspec", "model" => "I/O-Aggregator")).to be(false)
    end
  end

  describe "#blade_ioa_switch?" do
    it "should return true if PE-FN" do
      provider.stubs(:model).returns("PE-FN-410S-IOM")
      expect(provider.blade_ioa_switch?).to eq(true)
    end

    it "should return false if PE-FN"do
      provider.stubs(:model).returns("PE-FN-410S-IOM")
      expect(provider.blade_ioa_switch?).to eq(true)
    end
  end

  describe "#blade_mxl_switch?" do
    context "PE-FN models" do
      it "should return false if switch is not MXL" do
        provider.stubs(:model).returns("PE-FN-410S-IOA")
        expect(provider.blade_mxl_switch?).to eq(false)
      end

      it "should return true if switch is MXL" do
        provider.stubs(:model).returns("MXL")
        expect(provider.blade_mxl_switch?).to eq(true)
      end
    end
  end
end

require 'spec_helper'
require 'asm/type'

ASM::Type.load_providers!

describe ASM::Provider::Switch::Nexus5k do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }

  let(:raw_switches) { SpecHelper.json_fixture("cisco_fc_deployment/switch_inventory.json") }

  let(:collection) { ASM::Service::SwitchCollection.new(logger) }
  let(:type) { collection.switches[0] }
  let(:provider) { type.provider }

  let(:service) {SpecHelper.service_from_fixture("cisco_fc_deployment/deployment.json")}
  let(:server_component) { service.components_by_type("SERVER").first }
  let(:storage_component) { service.components_by_type("STORAGE").first }

  let(:server) { server_component.to_resource(nil, logger)}
  let(:server_network) { SpecHelper.json_fixture("cisco_fc_deployment/%s_network_config.json" % server.puppet_certname)}
  let(:storage) { storage_component.to_resource(nil, logger)}

  before(:each) do
    server.stubs(:network_config).returns(ASM::NetworkConfiguration.new(server_network))
    collection.stubs(:managed_inventory).returns(raw_switches)
    ASM::Service::SwitchCollection.stubs(:new).returns(collection)

    provider.facts["flogi_info"] = [
      ["fc2/2", "3", "0x880040", "50:00:d3:10:00:5e:c4:09", "50:00:d3:10:00:5e:c4:00"],
      ["vfc103", "3", "0x880100", "20:01:74:86:7a:ef:48:3d", "20:00:74:86:7a:ef:48:3d"],
      ["vfc201", "3", "0x880000", "20:01:90:b1:1c:21:a2:b8", "20:00:90:b1:1c:21:a2:b8"]
    ]

    provider.facts["zone_member"] = {
      "1"=>{},
      "3"=>{
        "CML-physicl-ports"=>["50:00:d3:10:00:5e:c4:05", "50:00:d3:10:00:5e:c4:09"], "R620-Mgmt"=>["20:01:90:b1:1c:21:a2:b8", "50:00:d3:10:00:5e:c4:23", "50:00:d3:10:00:5e:c4:22", "20:01:00:10:18:d0:3d:b1"], "CML-virtual-ports"=>["50:00:d3:10:00:5e:c4:23", "50:00:d3:10:00:5e:c4:22"],
        "ASM_14HMW12"=>["20:01:74:86:7a:ef:39:0d", "20:01:74:86:7a:ef:39:0f", "50:00:d3:10:00:5e:c4:05", "50:00:d3:10:00:5e:c4:22", "50:00:d3:10:00:5e:c4:23", "50:00:d3:10:00:5e:c4:09"],
        "ASM_14HLW12"=>["20:01:74:86:7a:f0:bf:f1", "20:01:74:86:7a:f0:bf:f3", "50:00:d3:10:00:5e:c4:05", "50:00:d3:10:00:5e:c4:22", "50:00:d3:10:00:5e:c4:23", "50:00:d3:10:00:5e:c4:09"],
        "ASM_14HNW12"=>["20:01:74:86:7a:ef:48:3d", "20:01:74:86:7a:ef:48:3f", "50:00:d3:10:00:5e:c4:05", "50:00:d3:10:00:5e:c4:22", "50:00:d3:10:00:5e:c4:23", "50:00:d3:10:00:5e:c4:09"]
      }
    }

    provider.facts["vsan_zoneset_info"] = [["ASM_FCOE", "3"]]
  end

  describe "#fc_zones" do
    it "should be able to retrieve all zones" do
      expect(provider.fc_zones).to eq(["ASM_14HLW12", "ASM_14HMW12", "ASM_14HNW12", "CML-physicl-ports", "CML-virtual-ports", "R620-Mgmt"])
    end

    it "should be able to retrieve the zone for a wwpn" do
      expect(provider.fc_zones("20:01:74:86:7a:ef:48:3d")).to eq(["ASM_14HNW12"])
    end
  end

  describe "#active_fc_zone" do
    it "should find the correct zone for a wwpn" do
      expect(provider.active_fc_zone("20:01:74:86:7a:ef:48:3d")).to eq("ASM_FCOE")
      expect(provider.active_fc_zone("20:01:74:86:7a:ef:39:0d")).to eq(nil)
    end
  end

  describe "#host_vsan_zones" do
    it "should find the zones a wwpn belong to" do
      expect(provider.host_vsan_zones("3", "20:01:74:86:7a:ef:39:0d")).to eq(["ASM_14HMW12"])
      expect(provider.host_vsan_zones("2", "rspec")).to eq([])
      expect(provider.host_vsan_zones("1", "20:01:74:86:7a:ef:39:0d")).to eq([])
    end
  end

  describe "#host_vsan" do
    it "should find the vsan id for known wwpns" do
      expect(provider.host_vsan("20:01:74:86:7a:ef:48:3d")).to eq("3")
      expect(provider.host_vsan("rspec")).to be(nil)
    end
  end

  describe "#flogi" do
    it "should look up the flogi information for the wwpn" do
      provider.flogi("20:01:74:86:7a:ef:48:3d").should eq(provider.facts["flogi_info"][1])
      provider.flogi("rspec").should be(nil)
    end
  end

  describe "#find_mac" do
    it "should call super for mac addresses" do
      provider.expects(:valid_wwpn?).never
      provider.find_mac("08:00:27:6b:57:88")
    end

    it "should detect valid wwpns" do
      provider.expects(:flogi).with("20:01:74:86:7A:EF:48:3D").returns(["vfc103", "3", "0x880100", "20:01:74:86:7a:ef:48:3d", "20:00:74:86:7a:ef:48:3d"])
      expect(provider.find_mac("20:01:74:86:7A:EF:48:3D")).to eq("vfc103")
    end

    it "should not find unknown wwpns" do
      provider.expects(:flogi).with("20:01:74:86:7A:EF:48:3D").returns(nil)
      expect(provider.find_mac("20:01:74:86:7A:EF:48:3D")).to be(nil)
    end
  end

  describe "#npiv_switch?" do
    it "should be a npiv switch when the npiv features exists" do
      provider.expects(:features).returns("npiv" => 1)
      expect(provider.npiv_switch?).to be(true)
    end

    it "should be npiv switch when the npv feature does exist" do
      provider.expects(:features).returns("npv" => 1)
      expect(provider.npiv_switch?).to be(false)
    end
  end

  describe "#san_switch?" do
    it "should be a san_switch when not a npiv switch" do
      provider.expects(:npiv_switch?).returns(false)
      expect(provider.san_switch?).to be(true)
    end

    it "should not be a san_switch when a npiv switch" do
      provider.expects(:npiv_switch?).returns(true)
      expect(provider.san_switch?).to be(false)
    end
  end

  describe "#rack_switch?" do
    it "should be a rack switch" do
      expect(provider.rack_switch?).to be(true)
    end
  end

  describe "#handles_switch?" do
    it "should handle switches starting with cisconexus5k and not others" do
      expect(provider.class.handles_switch?("refId" => "cisconexus5k")).to be(true)
      expect(provider.class.handles_switch?("refId" => "xxcisconexus5k")).to be(false)
      expect(provider.class.handles_switch?("refId" => "dell_ftos_rspec")).to be(false)
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
      provider.resource_creator.should be_a(ASM::Provider::Switch::Nexus5k::Rack)
    end
  end

  describe "#server_supported?" do
    it "should support rack servers" do
      provider.stubs(:rack_switch?).returns(true)
      provider.stubs(:blade_switch?).returns(false)
      expect(provider.server_supported?(stub(:rack_server? => true, :blade_server? => false))).to be true
    end

    it "should not support others" do
      expect(provider.server_supported?(stub(:rack_server? => false, :blade_server? => false))).to be false
    end
  end

  describe "when configuring servers do" do
    before(:each) do
      ["cisconexus5k-172.31.63.42", "dell_ftos-172.31.63.99", "compellent-24485", "dell_iom-172.31.61.114"].each do |sw|
        facts_fixture = "cisco_fc_deployment/%s_facts.json" % sw
        ASM::Util.stubs(:facts_find).with(sw).returns(SpecHelper.json_fixture(facts_fixture))
      end

      network_config = ASM::NetworkConfiguration.new(SpecHelper.json_fixture("cisco_fc_deployment/rackserver-2vzc5x1_network_config.json"))

      facts = SpecHelper.json_fixture("cisco_fc_deployment/rackserver-2vzc5x1_facts.json")

      server.stubs(:network_config).returns(network_config)
      server.stubs(:retrieve_facts!).returns(facts)
    end

    describe "#provision_server_networking" do
      it "should configure every network" do
        server.stubs(:razor_policy_name).returns("rspec")
        provider.stubs(:resource_creator).returns(creator = stub)
        type.stubs(:find_mac).returns("Eth1/21")
        provider.stubs(:active_zoneset).returns({"vsan"=>"256", "active_zoneset"=>""})

        creator.expects(:configure_interface_vlan).with("Eth1/21", 50, false, false, "", "12000").twice
        creator.expects(:configure_interface_vlan).with("Eth1/21", 255, true, false, "", "12000")
        creator.expects(:configure_interface_vlan).with("Eth1/21", 33, true, false, "", "12000").twice
        creator.expects(:configure_interface_vlan).with("Eth1/21", 36, true, false, "", "12000").twice
        creator.expects(:configure_interface_vlan).with("Eth1/21", 37, true, false, "", "12000").twice
        creator.expects(:configure_interface_vlan).with("Eth1/21", 256, true, false, "", "12000")

        creator.expects(:configure_interface_vsan).with("Eth1/21", "256", false).twice

        provider.provision_server_networking(server)
      end

      it "should raise error on missing zoneset" do
        server.stubs(:razor_policy_name).returns("rspec")
        provider.stubs(:resource_creator).returns(creator = stub)
        type.stubs(:find_mac).returns("Eth1/21")
        provider.stubs(:active_zoneset).returns({})


        creator.expects(:configure_interface_vlan).with("Eth1/21", 50, false, false, "", "12000")
        creator.expects(:configure_interface_vlan).with("Eth1/21", 255, true, false, "", "12000")
        creator.expects(:configure_interface_vlan).with("Eth1/21", 33, true, false, "", "12000")
        creator.expects(:configure_interface_vlan).with("Eth1/21", 36, true, false, "", "12000")
        creator.expects(:configure_interface_vlan).with("Eth1/21", 37, true, false, "", "12000")

        expect do
          provider.provision_server_networking(server)
        end.to raise_error
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

    describe "#teardown_server_networking" do
      it "should reset all partitions to vlan 1" do
        creator = stub("creator")
        provider.stubs(:resource_creator).returns(creator)
        type.stubs(:find_mac).returns("Eth1/19")
        creator.expects(:configure_interface_vlan).with("Eth1/19", "1", false, true).twice

        provider.teardown_server_networking(server)
      end
    end
  end
end



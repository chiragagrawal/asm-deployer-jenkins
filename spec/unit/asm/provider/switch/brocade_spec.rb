require 'spec_helper'
require 'asm/type'

ASM::Type.load_providers!

describe ASM::Provider::Switch::Brocade do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:raw_switches) { SpecHelper.json_fixture("switch_providers/switch_inventory.json") }

  let(:collection) { ASM::Service::SwitchCollection.new(logger) }
  let(:type) { collection.switch_by_certname("brocade_fos-172.17.9.15") }
  let(:provider) { type.provider }

  let(:service) { SpecHelper.service_from_fixture("switch_providers/deployment.json") }
  let(:facts) { SpecHelper.json_fixture("switch_providers/%s_facts.json" % type.puppet_certname)}
  let(:domain_faultfact) {SpecHelper.json_fixture("switch_providers/brocade_fos.json") }

  before(:each) do
    collection.stubs(:managed_inventory).returns(raw_switches)
    ASM::Service::SwitchCollection.stubs(:new).returns(collection)
    type.stubs(:facts_find).returns(SpecHelper.json_fixture("switch_providers/%s_facts.json" % type.puppet_certname))
  end

  describe "#provision_server_networking" do
    let(:server) do
      stub(
        :puppet_certname => "rspec.server",
        :cert2servicetag => "RSPEC",
        :fc_wwpns => ["50:00:d3:10:00:55:5b:3d", "50:00:d3:10:00:55:5b:3e", "50:00:d3:10:00:55:5b:3f"]
      )
    end

    it "should configure the zone based on the first found wwpn" do
      provider.expects(:storage_alias).with(server).returns("RSPEC_domain")
      server.expects(:teardown?).returns(false)
      provider.expects(:find_mac).with("50:00:d3:10:00:55:5b:3d").returns(false)
      provider.expects(:find_mac).with("50:00:d3:10:00:55:5b:3e").returns("2")
      provider.expects(:find_mac).with("50:00:d3:10:00:55:5b:3f").returns("3")
      provider.resource_creator.expects(:createzone_resource).with("ASM_RSPEC", "RSPEC_domain", "50:00:d3:10:00:55:5b:3e;50:00:d3:10:00:55:5b:3f", "Config_09_Top",false)
      provider.provision_server_networking(server)
    end
  end

  describe "#configure_server" do
    let(:server) do
      stub(
        :fc? => true,
        :valid_fc_target? => true,
        :puppet_certname => "rspec.server",
        :teardown? => false
      )
    end

    it "should skip non fc servers" do
      server.stubs(:fc?).returns(false)
      server.expects(:valid_fc_target?).never
      provider.configure_server(server, true)
    end

    it "should reset and process when not staged" do
      provider.expects(:provision_server_networking).with(server)
      provider.expects(:process!)
      provider.configure_server(server, false)
    end

    it "should not reset and process when staged" do
      provider.expects(:provision_server_networking).with(server)
      provider.expects(:process!).never
      provider.configure_server(server, true)
    end

    it "should fail for servers that are not valid FC targets" do
      server.expects(:valid_fc_target?).returns(false)
      expect {
        provider.configure_server(server, true)
      }.to raise_error("Server rspec.server is requesting FC config but it's not a valid FC target")
    end

    it "should support teardown" do
      provider.expects(:provision_server_networking).with(server)
      provider.expects(:process!)
      provider.configure_server(server, false)
    end
  end

  describe "#fault_domain" do
    let(:compellent) { stub }
    let(:volume) { stub(:provider => compellent, :puppet_certname => "rspec_compellent") }
    let(:server) { stub(:related_volumes => [volume], :puppet_certname => "rspec_server") }
    let(:related_storage) { stub }

    before(:each) do
      compellent.stubs(:controllers_info).returns([
                                                      "ControllerIndex" => "21852",
                                                      "ControllerIndex" => "21851"
                                                  ])
      server.related_volumes.stubs(:first).returns(related_storage)
      related_storage.expects(:fault_domain).with(type).returns("Compellent_Top")
    end

    it "should determine the correct fault domain" do
      expect(provider.storage_alias(server)).to eq("Compellent_Top")
    end
  end

  describe "#active_zoneset" do
    it "should default when not set" do
      expect(provider.active_zoneset).to eq("Config_09_Top")

      provider.expects(:active_fc_zone).returns(nil)
      expect(provider.active_zoneset).to eq("ASM_Zoneset")
    end
  end

  describe "#active_fc_zone" do
    it "should find the correct active config" do
      expect(provider.active_fc_zone(nil)).to eq("Config_09_Top")
    end
  end

  describe "#fc_zones" do
    it "should support returning all known zones" do
      expect(provider.fc_zones).to eq(["ASM_GP181Y1", "ASM_H4N71Y1", "ASM_HV7QQV1", "ASM_Host_Top", "Cntrl_Phys_Top", "Cntrl_Virtual_Top", "ESXi_9_3"])
    end

    it "should support limiting zones based on wwpn membership" do
      provider.facts["Zone_Members"] = {"ASM_GP181Y1" => ["50:00:d3:10:00:55:5b:3d"], "RSPEC" => ["50:00:d3:10:00:55:5b:3d"]}
      expect(provider.fc_zones("50:00:d3:10:00:55:5b:3d")).to eq(["ASM_GP181Y1", "RSPEC"])
      expect(provider.fc_zones("50:00:D3:10:00:55:5B:3D")).to eq(["ASM_GP181Y1", "RSPEC"])
    end
  end

  describe "#find_mac" do
    it "should return the interface when found" do
      ["21:00:00:24:ff:46:63:5a", "21:00:00:24:ff:4a:70:3e", "20:11:00:05:33:45:75:f3"].each do |mac|
        expect(provider.find_mac(mac)).to eq("port0")
      end

      expect(provider.find_mac("20:12:00:05:33:45:75:f3")).to eq("port1")
    end

    it "should return nil when there are no facts" do
      provider.facts = {}
      expect(provider.find_mac("rspec:rspec")).to be(nil)

      provider.facts = {}
      expect(provider.find_mac("rspec:rspec")).to be(nil)
    end
  end

  describe "#handles_switch?" do
    it "should handle switches starting with brocade_fos/ and not others" do
      expect(provider.class.handles_switch?("refId" => "brocade_fos_rspec")).to be(true)
      expect(provider.class.handles_switch?("refId" => "dell_rspec")).to be(false)
    end
  end
end

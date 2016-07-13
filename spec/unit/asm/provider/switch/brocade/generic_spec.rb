require 'spec_helper'

ASM::Type.load_providers!

require 'asm/provider/switch/brocade/generic'

describe ASM::Provider::Switch::Brocade::Generic do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:raw_switches) { SpecHelper.json_fixture("switch_providers/switch_inventory.json") }
  let(:collection) { ASM::Service::SwitchCollection.new(logger) }
  let(:type) { collection.switch_by_certname("brocade_fos-172.17.9.15") }
  let(:provider) { type.provider }
  let(:generic) { provider.resource_creator }

  before(:each) do
    collection.stubs(:managed_inventory).returns(raw_switches)
    ASM::Service::SwitchCollection.stubs(:new).returns(collection)
    type.stubs(:facts_find).returns(SpecHelper.json_fixture("switch_providers/%s_facts.json" % type.puppet_certname))
  end

  describe "#createzone_resource" do
    it "should create the correct resource" do
      generic.createzone_resource("RSPEC_Zone1", "rspec_alias1", "50:00:d3:10:00:55:5b:3d", "rspec_set1",false)
      generic.createzone_resource("RSPEC_Zone2", "rspec_alias2", "50:00:d3:10:00:55:5b:3e", "rspec_set2",false)
      expect(generic.port_resources["brocade::createzone"]).to include({
        "RSPEC_Zone1" => {
          "storage_alias" => "rspec_alias1",
          "server_wwn" => "50:00:d3:10:00:55:5b:3d",
          "zoneset" => "rspec_set1",
          "ensure" => "present"
        },
        "RSPEC_Zone2" => {
          "storage_alias" => "rspec_alias2",
          "server_wwn" => "50:00:d3:10:00:55:5b:3e",
          "zoneset" => "rspec_set2",
          "require" => "Brocade::Createzone[RSPEC_Zone1]",
          "ensure" => "present"
        }
      })
    end
    it "should create the correct resource for removing zone" do
      generic.createzone_resource("RSPEC_Zone1", "rspec_alias1", "50:00:d3:10:00:55:5b:3d", "rspec_set1", true)
      generic.createzone_resource("RSPEC_Zone2", "rspec_alias2", "50:00:d3:10:00:55:5b:3e", "rspec_set2", true)
      expect(generic.port_resources["brocade::createzone"]).to include({
                                                                           "RSPEC_Zone1" => {
                                                                               "storage_alias" => "rspec_alias1",
                                                                               "server_wwn" => "50:00:d3:10:00:55:5b:3d",
                                                                               "zoneset" => "rspec_set1",
                                                                               "ensure" => "absent"
                                                                           },
                                                                           "RSPEC_Zone2" => {
                                                                               "storage_alias" => "rspec_alias2",
                                                                               "server_wwn" => "50:00:d3:10:00:55:5b:3e",
                                                                               "zoneset" => "rspec_set2",
                                                                               "require" => "Brocade::Createzone[RSPEC_Zone1]",
                                                                               "ensure" => "absent"
                                                                           }
                                                                       })
    end


    it "should support multiple wwpns" do
      provider.expects(:valid_wwpn?).with("50:00:d3:10:00:55:5b:3d").returns(true)
      provider.expects(:valid_wwpn?).with("50:00:d3:10:00:55:5b:3e").returns(true)

      generic.createzone_resource("RSPEC_Zone1", "rspec_alias1", "50:00:d3:10:00:55:5b:3d;50:00:d3:10:00:55:5b:3e", "rspec_set1",false)
      expect(generic.port_resources["brocade::createzone"]).to include({
        "RSPEC_Zone1" => {
          "storage_alias" => "rspec_alias1",
          "server_wwn" => "50:00:d3:10:00:55:5b:3d;50:00:d3:10:00:55:5b:3e",
          "zoneset" => "rspec_set1",
          "ensure" => "present"
        }})
    end

    it "should fail on invalid wwpns" do
      expect {
        generic.createzone_resource("RSPEC_Zone", "rspec_alias", "50:00", "rspec_set",false)
      }.to raise_error(/Invalid WWPN/)

      expect {
        provider.expects(:valid_wwpn?).with("50:00:d3:10:00:55:5b:3d").returns(true)
        provider.expects(:valid_wwpn?).with("50:00").returns(false)
        generic.createzone_resource("RSPEC_Zone", "rspec_alias", "50:00:d3:10:00:55:5b:3d;50:00", "rspec_set",false)
      }.to raise_error(/Invalid WWPN/)
    end

    it "should not allow dupes" do
      generic.createzone_resource("RSPEC_Zone", "rspec_alias", "50:00:d3:10:00:55:5b:3d", "rspec_set",false)
      expect {
        generic.createzone_resource("RSPEC_Zone", "rspec_alias", "50:00:d3:10:00:55:5b:3d", "rspec_set",false)
      }.to raise_error(/Already have a brocade::createzone resources for RSPEC_Zone/)
    end
  end

end

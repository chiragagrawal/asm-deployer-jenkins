require 'spec_helper'
require 'asm/type'

ASM::Type.load_providers!

describe ASM::Provider::Volume::Vnx do
  let(:service) { SpecHelper.service_from_fixture("EMC_deployment_test.json") }
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:deployment) { stub(:id => "1234", :is_teardown? => true, :debug? => false, :log => nil) }
  let(:type) { volume_component.to_resource(deployment, logger) }
  let(:volume_component) { service.components_by_type("STORAGE")[0] }
  let(:server_components) { service.components_by_type("SERVER") }
  let(:cluster_components) { service.components_by_type("CLUSTER") }
  let(:provider) { type.provider }
  let(:facts) { SpecHelper.json_fixture("EMC_facts.json")}
  let(:brocade_fact) { SpecHelper.json_fixture("switch_providers/brocade_fos.json")}
  let(:storage_controllers) {SpecHelper.json_fixture("EMC_controllers.json")}

  describe "#controller" do
    it "should retrive controllerdata facts of the storage " do
      type.expects(:facts_find).returns(facts)
      expect(provider.controllers).to eq(storage_controllers)
    end
  end

  describe "#haswwpn?" do
    before(:each) do
      provider.expects(:controllers).returns(storage_controllers)
    end

    it "should return true if wwpn exixt" do
      expect(provider.has_wwpn?('50:06:01:60:3e:e0:39:dc')).to eq(true)
    end

    it "should return false if wwpn not exists" do
      expect(provider.has_wwpn?('50:06:01:30:3b:e0:39:1c')).to eq(false)
    end
  end

  describe "#fault_domain" do
    let(:volume) { stub(:puppet_certname => "rspec_emc") }
    let(:server) { stub(:related_volumes => [volume], :puppet_certname => "rspec_server") }
    let(:switch){ stub(:nameserver_info => brocade_fact, :puppet_certname => "rspec_switch") }

    it "should return storage allias" do
      provider.expects(:controllers).at_least(1).returns(storage_controllers)

      expect(provider.fault_domain(switch)).to eq("EMX_VNX")
    end

    it "should fail with a good error when relations are missing" do
      provider.stubs(:has_wwpn?).returns(false)

      expect {
        provider.fault_domain(switch)
      }.to raise_error("No storage alias found on switch rspec_switch for volume vnx-apm00132402069")
    end
  end

  describe "#datastore_require" do
    let(:server) { stub(:hostname => "server1") }

    it "should return the require array" do
      type.stubs(:related_server).returns(server)

      expect(provider.datastore_require(type.related_server)).to eq(["Asm::Fcdatastore[server1:createdbyasm]"])
    end
  end

  describe "#vnx_server_resource" do
    let(:server) { stub(:hostname => "server1") }
    it "should return hash to disconnect host" do
      expect(provider.vnx_server_resource(server)).to eq({"asm::volume::vnx"=>{"ASM-1234"=>{"ensure"=>"absent","sgname"=>"ASM-1234","host_name"=>"server1"}}})
    end
  end

  describe "#esx_datastore" do
    let(:server) { stub(:hostname => "server1",:hostip => "172.17.10.23") }
    let(:datastore_name){stub("vnx-datastore")}
    let(:deployment){stub(:host_lun_info => "0", :debug? => true)}
    it "should return hash to disconnect host" do
      expect(provider.esx_datastore(server, nil, "present")).to eq({"esx_datastore"=>{"172.17.10.23:createdbyasm"=>{"ensure"=>"present", "datastore"=>"createdbyasm", "type"=>"vmfs", "lun"=>nil, "transport"=>"Transport[vcenter]"}}})
    end
   end

  describe "#clean_access_rights" do
    let(:server) { stub(:hostname => "server1",:hostip => "172.17.10.23") }
    it "should not run puppet when there are no servers" do
      type.stubs(:related_server).returns([])
      type.expects(:process_generic).never
      provider.clean_access_rights!
    end
  end
end

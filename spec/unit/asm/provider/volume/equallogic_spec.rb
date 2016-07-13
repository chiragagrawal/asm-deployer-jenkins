require 'spec_helper'
require 'asm/type'

ASM::Type.load_providers!

describe ASM::Provider::Volume::Equallogic do
  let(:service) { SpecHelper.service_from_fixture("Teardown_EQL_VMware_Cluster.json") }
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:deployment) { stub(:id => "1234", :is_teardown? => true, :debug? => false, :log => nil) }
  let(:volume_component) { service.components_by_type("STORAGE")[0] }
  let(:server_components) { service.components_by_type("SERVER") }
  let(:cluster_components) { service.components_by_type("CLUSTER") }

  let(:type) { volume_component.to_resource(deployment, logger) }
  let(:provider) { type.provider }

  let(:expected_esx_datastore) do
    {"esx_datastore" =>
      {"172.28.10.63:M830-01" =>
        {"ensure"=>"absent",
         "datastore"=> "M830-01",
         "type"=>"vmfs",
         "target_iqn"=>"RSPECIQN",
         "transport"=>"Transport[vcenter]"
        }
      }
    }
  end

  before :each do
    ASM::NetworkConfiguration.any_instance.stubs(:add_nics!)
    ASM::PrivateUtil.stubs(:get_eql_volume_iqn).returns("RSPECIQN")
  end

  describe "#fc?" do
    it "should be false" do
      expect(provider.fc?).to be(false)
    end
  end

  describe "#initialize" do
    it "should specify the device run type" do
      expect(provider.puppet_type).to eq("asm::volume::equallogic")
    end
  end

  describe "#remove_server_from_volume!" do
    it "should use the deployment to process the volume" do
      deployment.expects(:process_storage).with(volume_component.to_hash)
      provider.remove_server_from_volume!(stub)
    end
  end

  describe "#esx_datastore_hash" do
    it "should create a valid datastore config" do
      expect(provider.esx_datastore(type.related_server, type.related_cluster, "absent")).to eq(expected_esx_datastore)
    end

    describe "when leaving a cluster" do
      it "should delegate to the cluster" do
        cluster = type.related_cluster
        cluster.stubs(:teardown?).returns(false)
        type.stubs(:related_cluster).returns(cluster)

        expected_hash = {}.merge(expected_esx_datastore).merge(cluster.provider.transport_config)

        servers = type.related_servers
        cluster.stubs(:related_servers).returns(servers)

        servers.each do |server|
          server.stubs(:teardown?).returns(false)
       end

        cluster.expects(:process_generic).with("vcenter-env10-vcenter.aidev.com", expected_hash, "apply", true, nil, "ff8080814dbf2d1d014dc2a280fd011f")
        type.leave_cluster!
      end
    end
  end

  describe "#datastore_require" do
    it "should return the require array" do
      ASM::PrivateUtil.stubs(:find_equallogic_iscsi_ip).returns("172.16.1.10")
      expect(provider.datastore_require(type.related_server)).to eq(["Asm::Datastore[172.28.10.63:M830-01:datastore_172.16.1.10]"])
    end
  end
end

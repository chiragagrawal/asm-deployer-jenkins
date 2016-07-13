require 'spec_helper'
require 'asm/type'

ASM::Type.load_providers!

describe ASM::Provider::Volume::Netapp do
  let(:service) { SpecHelper.service_from_fixture("Teardown_NetApp_VMware_Cluster_Server_VM.json") }
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:deployment) { stub(:debug? => false) }
  let(:volume_component) { service.components_by_type("STORAGE")[0] }
  let(:server_components) { service.components_by_type("SERVER") }
  let(:cluster_components) { service.components_by_type("CLUSTER") }

  let(:type) { volume_component.to_resource(deployment, logger) }
  let(:provider) { type.provider }

  let(:expected_esx_datastore) do
    {"esx_datastore" =>
      {"172.28.10.74:newdeployer01" =>
        {"ensure" => "absent",
          "path" => "/NFSDC/NFSCluster/",
          "type" => "nfs",
          "transport" => "Transport[vcenter]"
        }
      }
    }
  end

  before(:each) do
    ASM::NetworkConfiguration.any_instance.stubs(:add_nics!)
  end

  describe "#size_update_munger" do
    it "should convert template numbers to netapp numbers" do
      [["100KB", "100k"], ["100GB", "100g"], ["100MB", "100m"], ["100TB", "100t"]].each do |given, result|
        provider.size = given
        expect(provider.size).to eq(result)
      end
    end
  end

  describe "#volume_bytes_formatter" do
    it "should correctly format numbers" do
      expect(provider.volume_bytes_formatter(2 * 1024**3)).to eq("2g")
      expect(provider.volume_bytes_formatter(2 * 1024**2)).to eq("2m")
      expect(provider.volume_bytes_formatter(2 * 1024)).to eq("2k")
      expect(provider.volume_bytes_formatter(1024**3)).to eq("1g")
      expect(provider.volume_bytes_formatter(1024**2)).to eq("1m")
      expect(provider.volume_bytes_formatter(1024)).to eq("1k")
    end

    it "should round down" do
      expect(provider.volume_bytes_formatter(9.999 * 1024**3)).to eq("9g")
    end

    it "should fail to format numbers below 1024" do
      expect { provider.volume_bytes_formatter(10) }.to raise_error("Invalid volume size received, has to be numeric and above 1024")
    end
  end

  describe "#fc?" do
    it "should be false" do
      expect(provider.fc?).to be(false)
    end
  end

  describe "#cluster_supported?" do
    it "should support vmware clusters" do
      expect(provider.cluster_supported?(cluster_components.first.to_resource(deployment, logger))).to be(true)
    end

    it "should support no other clusters" do
      expect(provider.cluster_supported?(stub(:provider_path => "rspec/rspec"))).to be(false)
    end
  end

  describe "#initialize" do
    it "should specify the device run type" do
      expect(provider.puppet_type).to eq("netapp::create_nfs_export")
    end
  end

  describe "#configure_hook" do
    it "should get volume size in from facts when volume size is nil" do
      provider.size = nil
      ASM::PrivateUtil.stubs(:find_netapp_volume_info).returns({"name"=>"newdeployer01",
                                                                "size-total"=>"214748364800",
                                                                "size-available"=>"214740205568",
                                                                "size-used"=>"8159232",
                                                                "type"=>"flex",
                                                                "state"=>"online",
                                                                "spacereserve-enabled"=>nil})
      provider.configure_hook
      expect(provider.size).to eq('200g')
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
        cluster.stubs(:related_servers).returns([servers.first])

        servers.each do |server|
          server.stubs(:teardown?).returns(false)
       end

        cluster.expects(:process_generic).with("vcenter-env10-vcenter.aidev.com", expected_hash, "apply", true, nil, "ff8080814e00d3ca014e00dc10130075")

        type.leave_cluster!
      end
    end
  end

  describe "#datastore_require" do
    it "should return the require array" do
      expect(provider.datastore_require(type.related_server)).to eq(["Asm::Nfsdatastore[nfsserver2:newdeployer01]"])
    end
  end
end


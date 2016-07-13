require 'spec_helper'
require 'asm/type'

ASM::Type.load_providers!

describe ASM::Provider::Volume::Compellent do
  let(:service) { SpecHelper.service_from_fixture("Teardown_CMPL_VMware_Cluster.json") }
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:deployment) { stub(:id => "1234", :is_teardown? => true, :debug? => false, :log => nil) }
  let(:volume_component) { service.components_by_type("STORAGE")[0] }
  let(:server_components) { service.components_by_type("SERVER") }
  let(:cluster_components) { service.components_by_type("CLUSTER") }
  let(:switch_fact) {SpecHelper.json_fixture("switch_providers/brocade_fos.json") }
  let(:type) { volume_component.to_resource(deployment, logger) }
  let(:provider) { type.provider }

  before do
    ASM::NetworkConfiguration.any_instance.stubs(:add_nics!)
  end

  describe "#controller_ids" do
    it "should provide backward compatible data" do
      type.expects(:facts_find).returns(SpecHelper.json_fixture("cisco_fc_deployment/compellent-24485_facts.json"))
      expect(provider.controller_ids).to eq("controller1"=>"24485", "controller2"=>"24486")
    end
  end

  describe "#controllers_info" do
    it "should correctly parse facts" do
      type.expects(:facts_find).returns(SpecHelper.json_fixture("cisco_fc_deployment/compellent-24485_facts.json"))
      info = provider.controllers_info

      expect(info.size).to be(2)
      expect(info[0]["Name"]).to eq("SN 24485")
      expect(info[1]["Name"]).to eq("SN 24486")

      info.each do |i|
        expect(
          i.keys - [
            "ControllerIndex", "Name", "Leader", "Status", "LocalPortCondition", "Version", "DomainName", "PrimaryDNS", "ControllerIPAddress",
            "ControllerIPGateway", "ControllerIPMask", "IpcIPAddress", "IpcIPGateway", "IpcIPMask", "LastBootTime"
          ]
        ).to be_empty
      end
    end
  end

  describe "#fc?" do
    it "should be true for FibreChannel port types when configuresan is set" do
      provider.porttype = "FibreChannel"
      provider.configuresan = true

      expect(provider.fc?).to be(true)
    end

    it "should be false otherwise" do
      provider.porttype = "FibreChannel"
      provider.configuresan = false
      expect(provider.fc?).to be(false)

      provider.porttype = "iscsi"
      provider.configuresan = true
      expect(provider.fc?).to be(false)
    end
  end

  describe "#fault_domain" do
    let(:volume) { stub(:puppet_certname => "rspec_compellent") }
    let(:server) { stub(:related_volumes => [volume], :puppet_certname => "rspec_server") }
    let(:related_volumes) { stub }
    let(:switch){ stub(:nameserver_info)}

    before(:each) do
      provider.stubs(:controllers_info).returns([
                                                    "ControllerIndex" => "21852",
                                                    "ControllerIndex" => "21851"
                                                ])
      switch.stubs(:nameserver_info).returns(switch_fact)
    end
    it "should return storage alias of the device for brocade" do
      expect(provider.fault_domain(switch)).to eq("Compellent_storage")
    end

    it "should return right storage alias of the device for brocade when multiple storages are connected" do
      expect(provider.fault_domain(switch)).not_to eq("Compellent_Bottom")
    end

  end

  describe "#initialize" do
    it "should specify the device run type" do
      expect(provider.puppet_type).to eq("asm::volume::compellent")
    end
  end

  describe "#clean_access_rights!" do
    it "should create compellent_server objects for any server being torn down" do
      type.stubs(:related_servers).returns([
        mock(:cert2serial => "server1", :puppet_certname => "server1", :teardown? => true),
        mock(:cert2serial => "server2", :puppet_certname => "server2", :teardown? => true)
      ])

      expected = {'compellent_server' =>
                  {'ASM_server1' =>
                   {'ensure' => 'absent',
                    'serverfolder' => ''},
                   'ASM_server2' =>
                   {'ensure' => 'absent',
                    'serverfolder' => ''}
                  }
      }

      type.expects(:process_generic).with("compellent-24260", expected, "apply", true, nil, "compellent-172.17.10.40")

      provider.clean_access_rights!
    end

    it "should not run puppet when there are no servers" do
      type.stubs(:related_servers).returns([])
      type.expects(:process_generic).never
      provider.clean_access_rights!
    end
  end

  describe "#compellent_server_resource" do
    it "should construct the right hash based on the server" do
      server = server_components.first.to_resource(deployment, logger)

      expected_data = {"compellent_server" => {"ASM_DP181Y1" => {"ensure" => "absent", "serverfolder" => ""}}}

      expect(provider.compellent_server_resource(server)).to eq(expected_data)
    end
  end

  describe "#remove_server_from_volume!" do
    it "should process_generic with the right data" do
      server = server_components.first.to_resource(deployment, logger)

      expected_data = {"compellent_server" => {"ASM_DP181Y1" => {"ensure" => "absent", "serverfolder" => ""}}}
      type.expects(:process_generic).with(type.puppet_certname, expected_data, "apply", true, nil, type.guid)

      provider.remove_server_from_volume!(server)
    end

    it "should raise failures from process_generic" do
      type.expects(:process_generic).raises("rspec simulation")
      server = server_components.first.to_resource(deployment, logger)
      expect { provider.remove_server_from_volume!(server) }.to raise_error("rspec simulation")
    end
  end

  describe "#esx_datastore_hash" do
    let(:expected_esx_datastore) do
      {"esx_datastore" =>
        {"172.28.10.60:ESXIFCCluster1" =>
          {"ensure"=>"absent",
           "datastore"=> "ESXIFCCluster1",
           "type"=>"vmfs",
           "lun"=>"RSPEC_LUNID",
           "transport"=>"Transport[vcenter]"
          }
        }
      }
    end

    before :each do
      ASM::PrivateUtil.stubs(:find_compellent_volume_info).returns("RSPEC_DEVICE_ID")
      ASM::Cipher.stubs(:decrypt_string).returns("DECRYPTED_STRING")
      ASM::NetworkConfiguration.any_instance.stubs(:add_nics!)
      deployment.stubs(:get_compellent_lunid).with(type.related_server.hostip, 'root', "DECRYPTED_STRING", "RSPEC_DEVICE_ID").returns("RSPEC_LUNID")
    end

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
    context "when fc" do
      it "should return the require array" do
        expect(provider.datastore_require(type.related_server)).to eq(["Asm::Fcdatastore[esxifc2:ESXIFCCluster1]"])
      end
    end

    context "when !fc" do
      it "should return the require array" do
        provider.stubs(:fc?).returns(false)
        ASM::PrivateUtil.stubs(:find_compellent_iscsi_ip).returns(["172.16.1.10","172.16.1.11"])
        expect(provider.datastore_require(type.related_server)).to eq([
                                                                        "Asm::Datastore[172.28.10.60:ESXIFCCluster1:datastore_172.16.1.10]",
                                                                        "Asm::Datastore[172.28.10.60:ESXIFCCluster1:datastore_172.16.1.11]"])
      end
    end
  end
end

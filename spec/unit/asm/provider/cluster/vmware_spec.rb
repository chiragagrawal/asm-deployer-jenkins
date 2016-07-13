require 'spec_helper'
require 'asm/type'

ASM::Type.load_providers!

describe ASM::Provider::Cluster::Vmware do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:deployment) { stub(:id => "1234", :debug? => false, :decrypt? => true) }
  let(:service) { SpecHelper.service_from_fixture("Teardown_EQL_VMware_Cluster.json") }
  let(:server_components) { service.components_by_type("SERVER") }
  let(:volume_components) { service.components_by_type("STORAGE") }
  let(:cluster_component) { service.components_by_type("CLUSTER").first }
  let(:private_util) { ASM::PrivateUtil }

  let(:type) { cluster_component.to_resource(deployment, logger) }
  let(:provider) { type.provider }

  let(:server) { server_components.first.to_resource(deployment, logger) }

  let(:vsan_cluster_hash) {{'vc_vsan' =>
                      {'vcenter-env10-vcenter.aidev.com' =>
                         {'ensure' => 'present',
                          'auto_claim' => 'false',
                          'cluster' => 'M830Cluster',
                          'datacenter' => 'M830Datacenter',
                          'transport' => 'Transport[vcenter]'},
                       'vcenter-env10-vcenter.aidev.comrestore' =>
                         {'ensure' => 'absent',
                          'auto_claim' => 'false',
                          'cluster' => 'M830Cluster',
                          'datacenter' => 'M830Datacenter',
                          'transport' => 'Transport[vcenter]',
                          'require' => 'Vc_vsan_disk_initialize[vcenter-env10-vcenter.aidev.com]'}},
                  'esx_maintmode' =>
                      {'rspec-testhost' =>
                       {'ensure' => 'present',
                        'evacuate_powered_off_vms' => true,
                        'timeout' => 0,
                        'transport' => 'Transport[vcenter]',
                        'vsan_action' => 'noAction',
                        'require' => 'Vc_vsan[vcenter-env10-vcenter.aidev.com]'}},
                'vc_vsan_disk_initialize' =>
                      {'vcenter-env10-vcenter.aidev.com' =>
                       {'ensure' => 'absent',
                        'cluster' => 'M830Cluster',
                        'datacenter' => 'M830Datacenter',
                        'transport' => 'Transport[vcenter]',
                        'require' => 'Esx_maintmode[rspec-testhost]'}},
                  'transport' =>
                      {'vcenter' =>
                       {'name' => 'vcenter-env10-vcenter.aidev.com',
                        'options' => {'insecure' => true},
                        'provider' => 'device_file'}}}}

  let(:vsan_server_hash) {{'vc_vsan' =>
                               {'vcenter-env10-vcenter.aidev.com' =>
                                    {'ensure' => 'present',
                                     'auto_claim' => 'false',
                                     'cluster' => 'M830Cluster',
                                     'datacenter' => 'M830Datacenter',
                                     'transport' => 'Transport[vcenter]'},
                                'vcenter-env10-vcenter.aidev.comrestore' =>
                                    {'ensure' => 'absent',
                                     'auto_claim' => 'false',
                                     'cluster' => 'M830Cluster',
                                     'datacenter' => 'M830Datacenter',
                                     'transport' => 'Transport[vcenter]',
                                     'require' => 'Vc_vsan_disk_initialize[vcenter-env10-vcenter.aidev.com]'}},
                           'esx_maintmode' =>
                               {'rspec-testhost' =>
                                    {'ensure' => 'present',
                                     'evacuate_powered_off_vms' => true,
                                     'timeout' => 0,
                                     'transport' => 'Transport[vcenter]',
                                     'vsan_action' => 'noAction',
                                     'require' => 'Vc_vsan[vcenter-env10-vcenter.aidev.com]'}},
                           'vc_vsan_disk_initialize' =>
                               {'vcenter-env10-vcenter.aidev.com' =>
                                    {'ensure' => 'absent',
                                     'cluster' => 'M830Cluster',
                                     'datacenter' => 'M830Datacenter',
                                     'transport' => 'Transport[vcenter]',
                                     'cleanup_hosts' => ['rspec-testhost'],
                                     'require' => 'Esx_maintmode[rspec-testhost]'}},
                           'transport' =>
                               {'vcenter' =>
                                    {'name' => 'vcenter-env10-vcenter.aidev.com',
                                     'options' =>
                                         {'insecure' => true}, 'provider' => 'device_file'}}}}
  let(:vds_hash)  { {
      "vcenter::vmknic" => {
          "rspec-testhost:[\"vds\", \"vdsmanagement-vds\"]" => {
              "ensure" => "absent",
              "transport" =>
                  "Transport[vcenter]"
          },
          "rspec-testhost:[\"vmk_nic\", \"vmk0\"]" => {
              "ensure" => "absent",
              "transport" =>
                  "Transport[vcenter]"
          }
      }, "esx_maintmode" => {
          "rspec-testhost" => {
              "ensure" => "present",
              "evacuate_powered_off_vms" =>
                  true, "timeout" => 0,
              "transport" =>
                  "Transport[vcenter]", "require" => [
                  "Vcenter::Vmknic[rspec-testhost:[\"vds\", \"vdsmanagement-vds\"]]",
                  "Vcenter::Vmknic[rspec-testhost:[\"vmk_nic\", \"vmk0\"]]"
              ]
          }
      }, "vcenter::dvswitch" => {
          "/M830Datacenter/[\"vds\", \"vdsmanagement-vds\"]" => {
              "ensure" => "present",
              "transport" =>
                  "Transport[vcenter]", "spec" => {
                  "host" => [{
                                 "host" => "rspec-testhost",
                                 "operation" => "remove"
                             }]
              }, "require" =>
                  "Esx_maintmode[rspec-testhost]"
          }
      }, "transport" => {
          "vcenter" => {
              "name" =>
                  "vcenter-env10-vcenter.aidev.com",
              "options" => {
                  "insecure" => true
              }, "provider" => "device_file"
          }
      }
  }
  }



  before(:each) do
    ASM::NetworkConfiguration.any_instance.stubs(:add_nics!)
    deployment.stubs(:lookup_hostname).with(server.hostname, server.static_network_config).returns("rspec-testhost")

    type.stubs(:related_servers).returns([server])
    provider.stubs(:host_username).returns("root")
  end

  describe "#to_puppet" do
    context "when ensure = present" do
      it "should create the right resources" do
        type.provider.stubs(:ensure).returns("present")
        type.provider.stubs(:sdrs_config).returns(true)
        type.provider.expects(:sdrs_resources).returns({})
        expected = {
          "asm::cluster"=> {
            "vcenter-env10-vcenter.aidev.com"=>{
              "cluster"=>"M830Cluster",
              "datacenter"=>"M830Datacenter",
              "ensure"=>"absent",
              "vcenter_options"=>{"insecure"=>true}, "vsan_enabled"=>false}}}

        resources = type.provider.to_puppet
        expect(resources).to eq(expected)
      end
    end
  end

  describe "#should_inventory?" do
    it "should only do inventories when there is a guid" do
      expect(provider.should_inventory?).to be(true)

      type.expects(:guid).returns(nil)
      expect(provider.should_inventory?).to be(false)
    end
  end

  describe "#update_inventory" do
    it "should update using update_asm_inventory" do
      ASM::PrivateUtil.expects(:update_asm_inventory).with(cluster_component.guid)
      provider.update_inventory
    end

    it "should fail without a guid" do
      type.expects(:guid).returns(nil)
      expect { provider.update_inventory }.to raise_error("Cannot update inventory for vcenter-env10-vcenter.aidev.com without a guid")
    end
  end

  describe "#virtualmachine_supported?" do
    it "should support vmware virtual machines" do
      expect(provider.virtualmachine_supported?(stub(:provider_path => "virtualmachine/vmware"))).to be(true)
    end

    it "should not support other virtual machines" do
      expect(provider.virtualmachine_supported?(stub(:provider_path => "rspec/rspec"))).to be(false)
    end
  end

  describe "#asm_host_hash" do
    it "should create just a asm::host hash by default without a transport" do
      server = stub(:puppet_certname => "cert", :lookup_hostname => "host", :admin_password => "pass")

      hash = provider.asm_host_hash(server, "present")

      expected_properties = {
        "datacenter"=>"M830Datacenter",
        "cluster"=>"M830Cluster",
        "hostname"=> "host",
        "username"=>ASM::ServiceDeployment::ESXI_ADMIN_USER,
        "password"=>"pass",
        "decrypt"=>true,
        "timeout"=>90,
        "ensure" => "present"
      }

      expect(hash).to include("asm::host")
      expect(hash).to_not include("transport")
      expect(hash["asm::host"]["cert"]).to eq(expected_properties)
    end

    it "should be able to include the transport" do
      server = stub(:puppet_certname => "cert", :lookup_hostname => "host", :admin_password => "pass")
      hash = provider.asm_host_hash(server, "present", true)
      expect(hash).to include("transport")
    end
  end

  describe "#transport_config" do
    it "should create a valid transport config" do
      hash = provider.transport_config

      expected = {
        "transport"=> {
          "vcenter"=>{
            "name"=>"vcenter-env10-vcenter.aidev.com",
            "options"=>{"insecure"=>true},
            "provider"=>"device_file"
          }
        }
      }

      expect(hash).to eq(expected)
    end
  end

  describe "#evict_volume!" do
    it "should not remove servers being torn down" do
      servers = [mock(:teardown? => true), mock(:teardown? => true)]
      type.expects(:related_servers).returns(servers)
      type.expects(:process_generic).never
      provider.evict_volume!(stub)
    end

    it "should remove the volume from every server not being torn down" do
      volume = volume_components.first.to_resource(deployment, logger)
      server.expects(:teardown?).returns(false)
      volume.expects(:esx_datastore).returns({"esx_datastore" => "rspec"})

      expected = {"esx_datastore" => "rspec",
                  "transport" =>
                    {"vcenter" =>
                      {"name" => "vcenter-env10-vcenter.aidev.com", "options" =>
                        {"insecure" => true},"provider" => "device_file"
                      }
                    }
      }

      type.expects(:process_generic).with("vcenter-env10-vcenter.aidev.com", expected, "apply", true, nil, "ff8080814dbf2d1d014dc2a280fd011f")

      provider.evict_volume!(volume)
    end
  end

  describe "#evict_server!" do
    it "should evict the host from the cluster via process_generic" do
      server_hash = {'asm::host' => {},
        'transport' => {
          'vcenter' => {
          'name' => "vcenter-env10-vcenter.aidev.com",
          'options' => {'insecure' => true},
          'provider' => 'device_file'}}
      }

      server_hash['asm::host'][server.puppet_certname] = {
        'datacenter' => 'M830Datacenter',
        'cluster' => 'M830Cluster',
        'hostname' => "rspec-testhost",
        'username' => 'root',
        'password' => 'ff8080814dbf2d1d014ddcc519673595',
        'decrypt' => true,
        'timeout' => 90,
        'ensure' => 'absent'
      }

      type.expects(:process_generic).with(server.puppet_certname, server_hash, "apply", true, nil, nil)

      type.evict_server!(server)
    end
  end

  describe "#evict_vds!" do
    it "should not perform process_generic when vds_enabled is not distributed" do
      type.provider.vds_enabled = "rspec"
      type.expects(:process_generic).never

      type.evict_vds!(server)
    end
  end

  describe "#vds_hash" do
    it "should return vds Hash" do
      type.provider.vds_enabled = "rspec"
      type.provider.expects(:vds_vmk_nics).with(server).returns([{"vds"=>"vdsmanagement-vds"},{"vds"=>"vdsmanagement-vds","vmk_nic" => "vmk0"}])
      type.provider.expects(:vds_name).with(any_parameters).returns("rspec_vds")

     expect(type.provider.vds_hash(server,true)).to eq(vds_hash)
    end
  end

  describe "#evict_vsan!" do
    it "should perform process_generic when vsan_enabled is true while evicting server from cluster" do
      type.provider.vsan_enabled = true
      type.expects(:process_generic).with(server.puppet_certname, vsan_server_hash, "apply", true)

      type.evict_vsan!(server)
    end

    it "should perform process_generic when vsan_enabled is true while evicting cluster" do
      type.provider.vsan_enabled = true
      type.expects(:process_generic).with(type.puppet_certname, vsan_cluster_hash, "apply", true)

      type.evict_vsan!()
    end
  end


  describe "#evict_vds!" do
    it "should perform process_generic when vds_enabled is true" do
      type.provider.vds_enabled = "distributed"

      type.deployment.stubs("lookup_hostname").returns('127.0.0.1')
      type.provider.stubs(:vds_vmk_nics).returns([["vdsstorage-iSCSICompellentDC_VDS",
                                                   "vdsmanagement-iSCSICompellentDC_VDS",
                                                   "vdsmigration-iSCSICompellentDC_VDS",
                                                   "vdsworkload-iSCSICompellentDC_VDS"],
                                                  ["vmk2", "vmk3", "vmk0", "vmk1"]])
      resource_hash = {"vcenter::vmknic"=>
                           {"127.0.0.1:vmk2"=>{"ensure"=>"absent", "transport"=>"Transport[vcenter]"},
                            "127.0.0.1:vmk3"=>{"ensure"=>"absent", "transport"=>"Transport[vcenter]"},
                            "127.0.0.1:vmk1"=>{"ensure"=>"absent", "transport"=>"Transport[vcenter]"},
                            "127.0.0.1:vmk0"=>
                                {"ensure"=>"present",
                                 "hostVirtualNicSpec"=>{"portgroup"=>"Management Network", "vlanid"=>28},
                                 "transport"=>"Transport[vcenter]",
                                 "require"=>"Esx_portgroup[127.0.0.1:Management Network]"}},
                       "esx_maintmode"=>
                           {"127.0.0.1"=>
                                {"ensure"=>"present",
                                 "evacuate_powered_off_vms"=>true,
                                 "timeout"=>0,
                                 "transport"=>"Transport[vcenter]",
                                 "require"=>
                                     ["Vcenter::Vmknic[127.0.0.1:vmk2]",
                                      "Vcenter::Vmknic[127.0.0.1:vmk3]",
                                      "Vcenter::Vmknic[127.0.0.1:vmk1]"]}},
                       "vcenter::dvswitch"=>
                           {"/M830Datacenter/vdsstorage-iSCSICompellentDC_VDS"=>
                                {"ensure"=>"present",
                                 "transport"=>"Transport[vcenter]",
                                 "spec"=>{"host"=>[{"host"=>"127.0.0.1", "operation"=>"remove"}]},
                                 "require"=>"Esx_maintmode[127.0.0.1]"},
                            "/M830Datacenter/vdsmigration-iSCSICompellentDC_VDS"=>
                                {"ensure"=>"present",
                                 "transport"=>"Transport[vcenter]",
                                 "spec"=>{"host"=>[{"host"=>"127.0.0.1", "operation"=>"remove"}]},
                                 "require"=>
                                     "Vcenter::Dvswitch[/M830Datacenter/vdsstorage-iSCSICompellentDC_VDS]"},
                            "/M830Datacenter/vdsworkload-iSCSICompellentDC_VDS"=>
                                {"ensure"=>"present",
                                 "transport"=>"Transport[vcenter]",
                                 "spec"=>{"host"=>[{"host"=>"127.0.0.1", "operation"=>"remove"}]},
                                 "require"=>
                                     "Vcenter::Dvswitch[/M830Datacenter/vdsmigration-iSCSICompellentDC_VDS]"},
                            "/M830Datacenter/vdsmanagement-iSCSICompellentDC_VDS:run1"=>
                                {"ensure"=>"present",
                                 "transport"=>"Transport[vcenter]",
                                 "require"=>
                                     "Vcenter::Dvswitch[/M830Datacenter/vdsworkload-iSCSICompellentDC_VDS]",
                                 "spec"=>
                                     {"host"=>
                                          [{"host"=>"127.0.0.1",
                                            "operation"=>"edit",
                                            "backing"=>
                                                {"pnicSpec"=>
                                                     [{"pnicDevice"=>"vmnic0",
                                                       "uplinkPortgroupKey"=>
                                                           "vdsmanagement-iSCSICompellentDC_VDS-uplink-pg"}]}}]}},
                            "/M830Datacenter/vdsmanagement-iSCSICompellentDC_VDS:run2"=>
                                {"ensure"=>"present",
                                 "transport"=>"Transport[vcenter]",
                                 "require"=>"vcenter::vmknic[127.0.0.1:vmk0]",
                                 "spec"=>{"host"=>[{"host"=>"127.0.0.1", "operation"=>"edit"}]}},
                            "/M830Datacenter/vdsmanagement-iSCSICompellentDC_VDS:run3"=>
                                {"ensure"=>"present",
                                 "transport"=>"Transport[vcenter]",
                                 "spec"=>{"host"=>[{"host"=>"127.0.0.1", "operation"=>"remove"}]},
                                 "require"=>
                                     "Vcenter::Dvswitch[/M830Datacenter/vdsmanagement-iSCSICompellentDC_VDS:run2]"}},
                       "esx_vswitch"=>
                           {"127.0.0.1:vSwitch0"=>
                                {"path"=>"/M830Datacenter",
                                 "nics"=>["vmnic1"],
                                 "nicorderpolicy"=>{"activenic"=>["vmnic1"]},
                                 "transport"=>"Transport[vcenter]",
                                 "require"=>
                                     "Vcenter::Dvswitch[/M830Datacenter/vdsmanagement-iSCSICompellentDC_VDS:run1]"}},
                       "esx_portgroup"=>
                           {"127.0.0.1:Management Network"=>
                                {"vswitch"=>"vSwitch0",
                                 "path"=>"/M830Datacenter/M830Cluster/",
                                 "vlanid"=>28,
                                 "transport"=>"Transport[vcenter]",
                                 "require"=>"Esx_vswitch[127.0.0.1:vSwitch0]"}},
                       "transport"=>
                           {"vcenter"=>
                                {"name"=>"vcenter-env10-vcenter.aidev.com",
                                 "options"=>{"insecure"=>true},
                                 "provider"=>"device_file"}}}


      type.provider.stubs(:vds_name).returns('vdsmanagement-iSCSICompellentDC_VDS')
      type.provider.stubs(:vds_uplinks).returns(['vmnic0','vmnic1'])
      type.expects(:process_generic).with(server.puppet_certname, resource_hash, "apply", true)

      type.evict_vds!(server)
    end
  end

  describe "#prepare_for_teardown!" do
    it "should return true for non vds deployment teardown" do
      type.provider.vds_enabled = "standard"
      type.provider.expects(:evict_related_servers!).never
      expect(type.prepare_for_teardown!).to be(true)
    end

    it "should invoke evict_vds! vds deployment teardown" do
      type.provider.vds_enabled = "distributed"
      type.provider.stubs(:evict_related_servers!).returns(true)
      expect(type.prepare_for_teardown!).to be(true)
    end

    it "should invoke evict_vsan! when vsan_enabled is true" do
      type.provider.vds_enabled = "distributed"
      type.provider.vsan_enabled = true
      type.provider.stubs(:evict_related_servers!).returns(true)
      type.expects(:process_generic).with(type.puppet_certname, vsan_cluster_hash, "apply", true)
      expect(type.prepare_for_teardown!).to be(true)
    end
  end

  describe "#vds_uplinks" do
    it 'should return esxi version' do
      esx_vds_info = SpecHelper.load_fixture("esxcli/vds_vmnic.txt")
      ASM::Util.stubs(:esxcli).returns(esx_vds_info)
      ASM::Cipher.stubs(:decrypt_string).with('password').returns('password')

      server = stub(:lookup_hostname => "127.0.0.1", :admin_password => "password")
      type.provider.vds_uplinks(server, 'vdsmanagement-vds').should == ['vmnic0','vmnic1']
    end
  end

  describe "#sdrs_resource" do
    it "should return the sdrs resource" do
      type.provider.stubs(:datacenter).returns("RSPECDC")
      type.provider.stubs(:sdrs_config).returns(true)
      type.provider.stubs(:sdrs_name).returns("RSPECPOD")
      type.provider.stubs(:sdrs_member_names).returns(["VOL1","VOL2"])
      type.stubs(:teardown?).returns(false)
      require_list = [
        "Esx_datastore[192.168.1.1:VOL1]",
        "Esx_datastore[192.168.1.1:VOL2]",
        "Esx_datastore[192.168.1.2:VOL1]",
        "Esx_datastore[192.168.1.2:VOL2]"
      ]
      expected_hash = {
        "vc_storagepod" => {
          "RSPECPOD" => {
            "ensure" => "present",
            "datacenter" => "RSPECDC",
            "drs" => true,
            "datastores" => ["VOL1", "VOL2"],
            "transport" => "Transport[vcenter]",
            "require" => require_list
          }
        }
      }
      returned_hash = type.provider.sdrs_resource(require_list)
      expect(returned_hash).to eq(expected_hash)
    end
  end

  describe "#sdrs_resources" do
    it "should call sdrs_resource with the correct require list" do
      type.provider.stubs(:sdrs_members).returns("6012D791-4EBF-4684-A6BC-B44CF0D56F20,24BFB5FC-6CF3-4982-A4AB-F7AF7EFBF0B9")
      ASM::PrivateUtil.stubs(:find_equallogic_iscsi_ip).returns("172.16.1.10")
      require_list =  ["Asm::Datastore[172.28.10.63:M830-01:datastore_172.16.1.10]",
                       "Asm::Datastore[172.28.10.63:M830-02:datastore_172.16.1.10]"]

      type.provider.expects(:sdrs_resource).with(require_list)
      type.provider.sdrs_resources
    end
  end

  describe "#sdrs_member_names" do
    it "should return list of volume titles" do
      type.provider.stubs(:sdrs_members).returns("6012D791-4EBF-4684-A6BC-B44CF0D56F20,24BFB5FC-6CF3-4982-A4AB-F7AF7EFBF0B9")
      expect(type.provider.sdrs_member_names).to eq(["M830-01","M830-02"])
    end
  end
end

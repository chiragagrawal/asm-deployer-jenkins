require "spec_helper"
require "asm/processor/win_post_os"
require "asm/processor/windows_vm_post_os"
require "asm/private_util"
require "asm/service"
require "asm/resource"

describe ASM::Processor::WindowsVMPostOS do
  let(:puppetdb) { stub(:successful_report_after? => true) }

  before do
    @service_deployment = SpecHelper.json_fixture("processor/win_post_os/win_vm_post_os.json")
    @sd = mock("service_deployment")
    @sd = ASM::ServiceDeployment.new("8000", nil)
    @sd.stubs(:logger).returns(stub(:debug => nil, :warn => nil, :info => nil))
    @sd.components(@service_deployment)
  end

  describe "should configure windows vm post installation" do

    let(:cluster_params) do
      cluster_comp = @sd.components_by_type("CLUSTER")[0]
      cluster_resource = ASM::PrivateUtil.build_component_configuration(cluster_comp, :decrypt => true)
      clusters = ASM::Resource::Cluster.create(cluster_resource)
      title, cluster_params = clusters.first.shift
      cluster_params.title = title
      cluster_params.vds_info = clusters[1] if clusters[1]
      cluster_params
    end

    let(:processor1) do
      vm1_component = @sd.components_by_type("VIRTUALMACHINE")[0]
      vm1_resource_hash = ASM::PrivateUtil.build_component_configuration(vm1_component, :decrypt => true)
      vm_object_1 = ASM::Resource::VM.create(vm1_resource_hash).first
      vm_object_1.stubs(:vm_net_mac_address).returns('aa-bb-cc-dd-ee-ff')
      ASM::Processor::WindowsVMPostOS.new(@sd, vm1_component, vm_object_1, cluster_params)
    end

    let(:processor2) do
      vm2_component = @sd.components_by_type("VIRTUALMACHINE")[1]
      vm2_resource_hash = ASM::PrivateUtil.build_component_configuration(vm2_component, :decrypt => true)
      vm_object_2 = ASM::Resource::VM.create(vm2_resource_hash).first
      vm_object_2.stubs(:vm_net_mac_address).returns('aa-bb-cc-dd-ee-ff')
      ASM::Processor::WindowsVMPostOS.new(@sd, vm2_component, vm_object_2, cluster_params)
    end

    it "with no static network adapter" do
      processor1.stubs(:vm_networks).returns([])
      expect(processor1.post_os_classes).to eql({})
    end

    it "with one static network adapter" do
      static_network = {"windows_postinstall::nic::adapter_nic_ip_settings"=>
                         {"ipaddress_info"=>
                          {"NICIPInfo"=>
                           [{"adapter_name"=>"Workload-22-Static",
                             "ip_address"=>"172.22.10.65",
                             "subnet"=>"255.255.0.0",
                             "primaryDns"=>"172.20.0.8",
                             "mac_address"=>"aa-bb-cc-dd-ee-ff",
                             "gateway"=>"172.22.0.1",
                             "adapter_type"=>"vm_network"}]}}}

      expect(processor1.post_os_classes).to eql(static_network)
    end

    it "with two static network adapters" do
      static_two_networks = {"windows_postinstall::nic::adapter_nic_ip_settings"=>
                              {"ipaddress_info"=>
                               {"NICIPInfo"=>
                                [{"adapter_name"=>"Workload-22-Static",
                                  "ip_address"=>"172.22.10.66",
                                  "subnet"=>"255.255.0.0",
                                  "primaryDns"=>"172.20.0.8",
                                  "mac_address"=>"aa-bb-cc-dd-ee-ff",
                                  "gateway"=>"172.22.0.1",
                                  "adapter_type"=>"vm_network"},
                                 {"adapter_name"=>"Workload-25-static",
                                  "ip_address"=>"172.25.10.64",
                                  "subnet"=>"255.255.0.0",
                                  "primaryDns"=>"172.20.0.8",
                                  "mac_address"=>"aa-bb-cc-dd-ee-ff",
                                  "adapter_type"=>"vm_network"}]}}}
      expect(processor2.post_os_classes).to eql(static_two_networks)
    end

    it "with no default gateway" do
      static_without_gateway =  {"windows_postinstall::nic::adapter_nic_ip_settings"=>
                                  {"ipaddress_info"=>
                                   {"NICIPInfo"=>
                                    [{"adapter_name"=>"Workload-22-Static",
                                      "ip_address"=>"172.22.10.65",
                                      "subnet"=>"255.255.0.0",
                                      "primaryDns"=>"172.20.0.8",
                                      "mac_address"=>"aa-bb-cc-dd-ee-ff",
                                      "adapter_type"=>"vm_network"}]}}}
      processor1.stubs(:default_gateway_network).returns("")
      expect(processor1.post_os_classes).to eql(static_without_gateway)
    end


    it "with no static network" do
      dhcp_vm_network = [
          {"id"=>"ff80808150b4e04d0150b4f1394800a4",
           "name"=>"Workload-22-Static",
           "description"=>"",
           "type"=>"PUBLIC_LAN",
           "vlanId"=>20,
           "static"=>false,
           "staticNetworkConfiguration"=>{} }
      ]

      dhcp_nework = {"windows_postinstall::nic::adapter_nic_ip_settings"=>
                      {"ipaddress_info"=>
                       {"NICIPInfo"=>
                        [{"adapter_name"=>"Workload-22-Static",
                          "ip_address"=>"dhcp",
                          "subnet"=>"",
                          "gateway"=>"",
                          "primaryDns"=>"",
                          "mac_address"=>"aa-bb-cc-dd-ee-ff",
                          "adapter_type"=>"vm_network"}]}}}
      processor1.stubs(:vm_networks).returns(dhcp_vm_network)
      expect(processor1.post_os_classes).to eql(dhcp_nework)
    end

  end
end

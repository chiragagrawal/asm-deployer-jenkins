require "spec_helper"
require "asm/type"
require "rbvmomi"
require "asm/provider/virtualmachine/vmware"
require "asm/service/component/generator"

ASM::Type.load_providers!

describe ASM::Provider::Virtualmachine::Vmware do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:service) { SpecHelper.service_from_fixture("Teardown_CMPL_VMware_Cluster.json") }
  let(:deployment) { stub(:id => "1234", :is_teardown? => true, :debug? => false, :log => nil) }
  let(:vm_component) { service.components_by_type("VIRTUALMACHINE")[0] }
  let(:cluster_components) { service.components_by_type("CLUSTER") }

  let(:type) { vm_component.to_resource(deployment, logger) }
  let(:provider) { type.provider }

  describe "#lazy_configure_related_cluster" do
    it "should configure the related cluster once" do
      provider.expects(:configure_related_cluster!).once
      provider.lazy_configure_related_cluster
      provider.lazy_configure_related_cluster
    end
  end

  ["cluster", "datacenter", "vcenter_id", "vcenter_options"].each do |lazy_property|
    describe "#%s" % lazy_property do
      it "should lazy initialize the related cluster" do
        provider.expects(:lazy_configure_related_cluster)
        provider.send(lazy_property)
      end
    end
  end

  describe "#vim" do
    it "should attempt to connect to vCenter but fail since there is no conf set" do
      provider.stubs(:cluster_conf).returns(nil)
      expect{provider.vim}.to raise_error("Resource has not been processed.")
    end

    it "should attempt to connect to vCenter and swallow errors" do
      provider.stubs(:cluster_conf).returns(Hashie::Mash.new({
                                                         :cert_name => "vCenter_CERT",
                                                         :host => "test-vcenter.dell.com",
                                                         :port => "443",
                                                         :path => "",
                                                         :scheme => "",
                                                         :arguments => "",
                                                         :user => "administrator@vsphere.local",
                                                         :enc_password => "enc_password",
                                                         :password => "password",
                                                         :url => "uri",
                                                         :provider => "provider",
                                                         :conf_file_data => "conf_file_data"
                                                     }))
      expect{provider.vim}.to raise_error(SocketError)
    end

    it "should attempt to find the datacenter" do
      provider.stubs(:cluster_conf).returns(nil)
      provider.stubs(:vim).returns(nil)
      expect{provider.dc}.to raise_error(NoMethodError, "undefined method `serviceInstance' for nil:NilClass")
    end

    it "should attempt to find the vm" do
      provider.stubs(:cluster_conf).returns(nil)
      provider.stubs(:vim).returns(nil)
      provider.stubs(:dc).returns(nil)
      expect{provider.vm}.to raise_error(NoMethodError, "undefined method `vmFolder' for nil:NilClass")
    end
  end

  describe "#delete_vm_cert!" do
    it "should clean the cloned VM certificate" do
      provider.server = nil
      provider.expects(:macaddress).returns("00000000000f")
      ASM::DeviceManagement.expects(:clean_cert).with("vm00000000000f")
      provider.delete_vm_cert!
    end
  end

  describe "#prepare_for_teardown!" do
    it "should attempt to clean the server certificate and swallow errors" do
      provider.server.expects(:delete_server_cert!).raises("rspec")
      provider.prepare_for_teardown!
    end

    it "should call delete_vm_cert! when the VM is cloned" do
      provider.server = nil
      provider.expects(:delete_vm_cert!)
      provider.prepare_for_teardown!
    end
  end

  describe "#cluster_supported?" do
    it "should support vmare clusters" do
      expect(provider.cluster_supported?(cluster_components.first.to_resource(deployment, logger))).to be(true)
    end

    it "should not support other clusters do" do
      expect(provider.cluster_supported?(stub(:provider_path => "rspec/rspec"))).to be(false)
    end
  end

  describe "#hostname" do
    it "should take the configured hostname if it has one" do
      provider.hostname = "rspec"
      expect(provider.hostname).to eq("rspec")
    end

    it "should allow overriding by the associated server" do
      provider.hostname = nil
      provider.server.stubs(:hostname).returns("rspec")
      expect(provider.hostname).to eq("rspec")
    end

    it "should use the hostname otherwise" do
      provider.server = nil
      provider.hostname = "rspec"
      expect(provider.hostname).to eq("rspec")
    end
  end

  describe "#additional_resources" do
    it "should include the modified asm::server when a server exist" do
      provider.server.stubs(:to_puppet).returns({"asm::server" => {"rspec" => {}}})
      expect(provider.additional_resources).to eq({"asm::server" => {"rspec" => {}}})
    end

    it "should add no additional resources otherwise" do
      provider.server = nil
      expect(provider.additional_resources).to eq({})
    end
  end

  describe "#configure_guest_type!" do
    before(:each) do
      provider.os_type = nil
      provider.os_guest_id = nil
      provider.scsi_controller_type = "BusLogic Parallel"
    end

    it "should set the correct windows options" do
      provider.server.stubs(:os_image_type).returns("rspec_windows_rspec")
      provider.configure_guest_type!

      expect(provider.os_type).to eq("windows")
      expect(provider.os_guest_id).to eq("windows8Server64Guest")
      expect(provider.scsi_controller_type).to eq("LSI Logic SAS")
    end

    it "should set the correct linux options" do
      provider.server.stubs(:os_image_type).returns("rspec_linux_rspec")
      provider.configure_guest_type!

      expect(provider.os_type).to eq("linux")
      expect(provider.os_guest_id).to eq("rhel6_64Guest")
      expect(provider.scsi_controller_type).to eq("VMware Paravirtual")
    end
  end

  describe "#configure_related_cluster!" do
    it "should configure the cluster properties from the related cluster" do
      provider.cluster = nil
      provider.datacenter = nil
      provider.vcenter_id = nil
      provider.vcenter_options = {}

      provider.configure_related_cluster!

      cluster = type.related_cluster

      expect(provider.cluster).to eq(cluster.provider.cluster)
      expect(provider.datacenter).to eq(cluster.provider.datacenter)
      expect(provider.vcenter_id).to eq(cluster.puppet_certname)
      expect(provider.vcenter_options).to eq({"insecure" => true})
    end
  end

  describe "#configure_network!" do
    it "should clear the network_interfaces on teardown" do
      provider.network_interfaces = []
      provider.configure_network!
      expect(provider.network_interfaces).to eq(nil)
    end

    it "should warn otherwise" do
      provider.ensure = "present"
      type.stubs(:teardown?).returns(false)
      logger.expects(:warn).with("Cannot configure networking for Virtual Machine vm-linuxvm1 as it only supports teardown")
      provider.configure_network!
    end
  end

  describe "#create_server_resource" do
    it "should create a server resource" do
      expect(provider.create_server_resource).to be_a(ASM::Type::Server)
    end

    it "should return nil when it fails" do
      ASM::Service::Component::Resource.any_instance.stubs(:to_component).raises("rspec simulation")
      expect(provider.create_server_resource).to eq(nil)
    end
  end

  describe "#configure_hook" do
    before(:each) do
      provider.stubs(:configure_server!).returns(true)
      provider.stubs(:configure_guest_type!)
      provider.stubs(:configure_related_cluster!)
      provider.stubs(:configure_network!)
    end

    it "should configure the guest type when a server was found" do
      provider.expects(:configure_server!).returns(true)
      provider.expects(:configure_guest_type!)
      provider.configure_hook
    end

    it "should not configure the guard type when a server was not found" do
      provider.expects(:configure_server!).returns(false)
      provider.expects(:configure_guest_type!).never
      provider.configure_hook
    end
  end

  describe "#configure_server!" do
    it "should configure the types when a server is found" do
      provider.server.serial_number = "rspec"
      provider.server.stubs(:hostname).returns("rspec")
      provider.hostname = nil

      provider.configure_server!

      expect(provider.server.serial_number).to eq("")
      expect(provider.hostname).to eq("rspec")
      expect(provider.uuid).to eq("rspec")
      expect(provider.server.provider.uuid).to eq("rspec")
    end

    it "should set uuid from server hostname" do
      provider.server = nil
      provider[:hostname] = nil
      provider.configure_server!
      expect(provider.uuid).to eq("linuxvm1")
    end

    it "should set uuid from vm hostname for clone vms" do
      generated = ASM::Service::Component::Generator.new("44FAA505-A3CC-4EC8-B4A5-3B20C33A4E44")
      generated.type = "VIRTUALMACHINE"
      generated.add_resource("asm::vm::vcenter", "Virtual Machine Settings", [
          {:id=>"title", :value=>"44FAA505-A3CC-4EC8-B4A5-3B20C33A4E44"},
          {:id=>"hostname", :value=>"cloned-vm1"}
      ])
      component_hash = generated.to_component_hash
      component = ASM::Service::Component.new(component_hash, true, service)
      type = component.to_resource(deployment, logger)
      provider = type.provider
      provider.configure_server!
      expect(provider.uuid).to eq("cloned-vm1")
    end

    it "should do nothing otherwise" do
      provider.server = nil
      provider.expects(:create_server_resource).returns(false)
      expect(provider.configure_server!).to eq(false)
    end
  end

  describe "#clone?" do
    it "should return true if clone_type property set" do
      provider.expects(:clone_type).returns("vm")
      expect(provider.clone?).to eq(true)
    end

    it "should return false if clone_type property is not set" do
      expect(provider.clone?).to eq(false)
    end
  end

  describe "#agent_certname" do
    context "when it is a cloned vm" do
      it "should return the correct agent certname" do
        provider.expects(:clone_type).returns("vm")
        provider.expects(:macaddress).returns("00:1D:D8:B7:1C:78")
        expect(provider.agent_certname).to eq("vm001dd8b71c78")
      end
    end

    context "when it is not a cloned vm" do
      it "sould return the correct agent certname" do
        expect(provider.agent_certname).to eq("agent-linuxvm1")
      end
    end
  end
end

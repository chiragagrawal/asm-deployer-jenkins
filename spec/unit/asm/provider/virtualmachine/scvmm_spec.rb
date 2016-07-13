require 'spec_helper'
require 'asm/type'

ASM::Type.load_providers!

describe ASM::Provider::Virtualmachine::Scvmm do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:service) { SpecHelper.service_from_fixture("Teardown_EQL_Scvmm_Cluster.json") }
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

  ["scvmm_server", "vm_cluster"].each do |lazy_property|
    describe "#%s" % lazy_property do
      it "should lazy initialize the related cluster" do
        provider.expects(:lazy_configure_related_cluster)
        provider.send(lazy_property)
      end
    end
  end

  describe "#prepare_for_teardown!" do
    it "should clean the certs" do
      provider.expects(:delete_vm_cert!)
      provider.prepare_for_teardown!
    end
  end

  describe "#agent_certname" do
    it "should return the puppet agent certname" do
      provider.expects(:macaddress).returns("00:1D:D8:B7:1C:78")
      expect(provider.agent_certname).to eq("vm001dd8b71c78")
    end
  end

  describe "#delete_vm_cert!" do
    it "should delete the cert" do
      provider.expects(:agent_certname).returns("vm001dd8b71c78").twice
      ASM::DeviceManagement.expects(:clean_cert).with("vm001dd8b71c78")
      provider.delete_vm_cert!
    end

    it "should squash errors" do
      provider.expects(:macaddress).raises("rspec")
      logger.expects(:warn).with("Could not delete certificate for vm-centosvm: RuntimeError: rspec")
      provider.delete_vm_cert!
    end
  end

  describe "#macaddress" do
    it "should try and sleep the correct amount of times on failures" do
      provider.expects(:scvmm_macaddress_lookup).times(3).returns(nil)
      provider.expects(:sleep).twice.with(120)

      sequence("tries")

      expect{ provider.macaddress(3, 120) }.to raise_error("Could not lookup the mac address for vm vm-centosvm, it might not exist")
    end

    it "should fail when the mac address is 00000000000000" do
      provider.expects(:scvmm_macaddress_lookup).returns("00000000000000")
      expect { provider.macaddress }.to raise_error("Virtual machine vm-centosvm is not powered on cannot look up it's mac address")
    end

    it "should cache the result" do
      provider.expects(:scvmm_macaddress_lookup).returns("00:1D:D8:B7:1C:78").once

      provider.macaddress
      provider.macaddress
    end
  end

  describe "#scvmm_macaddress_lookup" do
    before(:each) do
      config = stub(:user => 'rspec\\admin', :password => "password", :host => "172.1.1.1")
      ASM::Type::Cluster.any_instance.stubs(:device_config).returns(config)
    end

    it "should return the macaddress on success" do
      result = stub(:exit_status => 0, :stdout => SpecHelper.load_fixture("scvmm_macaddress.txt"))
      ASM::Util.expects(:run_with_clean_env).returns(result)

      expect(provider.scvmm_macaddress_lookup).to eq("00:1D:D8:B7:1C:78")
    end

    it "should return nil on failures" do
      ASM::Util.expects(:run_with_clean_env).raises("rspec")
      expect(provider.scvmm_macaddress_lookup).to be(nil)
    end
  end

  describe "#scvmm_macaddress_command" do
    it "should generate the correct command" do
      config = stub(:user => 'rspec\\admin', :password => "password", :host => "172.1.1.1")
      ASM::Type::Cluster.any_instance.expects(:device_config).returns(config)

      cmd, args = provider.scvmm_macaddress_command

      expect(File.exists?(cmd)).to be(true)
      expect(cmd.end_with?("lib/asm/scvmm_macaddress.rb")).to be(true)
      expect(args).to eq(%w{-u admin -d rspec -p password -s 172.1.1.1 -v CentOSVM})
    end
  end

  describe "#scvmm_macaddress_parse" do
    it "should turn valid data into a hash" do
      output = SpecHelper.load_fixture("scvmm_macaddress.txt")
      data = provider.scvmm_macaddress_parse(output)

      expect(data).to be_a(Hash)
      expect(data["MACAddress"]).to eq("00:1D:D8:B7:1C:78")
    end

    it "should return a empty hash on invalid data" do
      expect(provider.scvmm_macaddress_parse(nil)).to eq({})
    end
  end

  describe "#cluster_supported?" do
    it "should support hyperv clusters" do
      expect(provider.cluster_supported?(cluster_components.first.to_resource(deployment, logger))).to be(true)
    end

    it "should not support other clusters" do
      expect(provider.cluster_supported?(stub(:provider_path => "rspec/rspec"))).to be(false)
    end
  end

  describe "#configure_certname!" do
    it "should set the certname" do
      type.puppet_certname = "rspec"
      provider.configure_certname!
      expect(type.puppet_certname).to eq("vm-centosvm")
    end
  end

  describe "#hostname" do
    it "should allow overriding by the :name property" do
      provider.name = "rspec"
      provider.hostname = "x"
      provider.uuid = "x"
      expect(provider.hostname).to eq("rspec")
    end

    it "should allow overriding by the :hostname property" do
      provider.name = nil
      provider.hostname = "rspec"
      provider.uuid = "x"
      expect(provider.hostname).to eq("rspec")
    end

    it "should use the uuid otherwise" do
      provider.name = nil
      provider.hostname = nil
      provider.uuid = "rspec"
      expect(provider.hostname).to eq("rspec")
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
      logger.expects(:warn).with("Cannot configure networking for Virtual Machine vm-centosvm as it only supports teardown")
      provider.configure_network!
    end
  end

  describe "#configure_cluster!" do
    it "should configure the related cluster properties" do
      provider.scvmm_server = nil
      provider.vm_cluster = nil
      provider.configure_related_cluster!

      cluster = type.related_cluster

      expect(provider.scvmm_server).to eq(cluster.puppet_certname)
      expect(provider.vm_cluster).to eq(cluster.provider.name)
    end
  end

  describe "#configure_uuid!" do
    it "should set the hostname if an override is supplied" do
      provider.stubs(:hostname).returns("rspec")
      provider.configure_uuid!
      expect(provider.uuid).to eq("rspec")
    end

    it "should do nothing if no override is supplied" do
      provider.stubs(:hostname).returns(nil)
      self.expects(:uuid).never
      provider.configure_uuid!
    end
  end
end

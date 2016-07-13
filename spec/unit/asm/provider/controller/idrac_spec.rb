require 'spec_helper'
require 'asm/type'

ASM::Type.load_providers!

describe ASM::Provider::Controller::Idrac do
  let(:service) { SpecHelper.service_from_fixture("Teardown_EQL_VMware_Cluster.json") }
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:deployment) { stub(:id => "1234", :is_teardown? => true, :debug? => false, :log => nil) }
  let(:server_components) { service.components_by_type("SERVER") }
  let(:server_component) { server_components.first }
  let(:server) { server_component.to_resource(deployment, logger) }

  let(:type) { server.provider.create_idrac_resource }
  let(:provider) { type.provider }

  before(:each) do
    ASM::NetworkConfiguration.any_instance.stubs(:add_nics!)
  end

  describe "#configure_force_reboot" do
    it "should correctly set the force_reboot setting" do
      service.stubs(:retry?).returns(true)
      provider.configure_force_reboot
      expect(provider.force_reboot).to be_falsey

      service.stubs(:retry?).returns(false)
      provider.configure_force_reboot
      expect(provider.force_reboot).to be_truthy
    end
  end

  describe "#configure_hook" do
    it "should set force_reboot" do
      provider.expects(:configure_force_reboot)
      provider.configure_hook
    end
  end

  describe "#configure_for_server" do
    it "should not configure when there are no device configuration" do
      server.stubs(:device_config).returns(nil)
      expect(provider.configure_for_server(server)).to be(false)
    end

    it "should configure the idrac based on the server settings" do
      server.expects(:device_config).twice.returns(stub(:host => "rspec"))
      server.expects(:model).returns("rspec model 123")
      server.expects(:bios_settings).returns(:rspec => 1)

      expect(provider.bios_settings).to eq(:rspec => 1)
      expect(provider.nfsipaddress).to be_nil
      expect(provider.network_configuration).to eq(server.network_config.to_hash)
      expect(provider.servicetag).to eq("15KVD42")
      expect(type.puppet_certname).to eq(server.puppet_certname)
      expect(provider.model).to eq("123")
    end
  end
end

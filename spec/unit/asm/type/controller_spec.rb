require 'spec_helper'
require 'asm/type/controller'

describe ASM::Type::Controller do
  let(:service) { SpecHelper.service_from_fixture("Teardown_EQL_VMware_Cluster.json") }
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:deployment) { stub(:id => "1234", :debug? => false) }

  let(:server) { service.components[1].to_resource(deployment, logger) }
  let!(:type) { ASM::NetworkConfiguration.any_instance.stubs(:add_nics!); server.provider.create_idrac_resource }

  describe "#configure_for_server" do
    it "should check compatability and fail when not compatible" do
      server.expects(:supports_resource?).with(type).returns(false)
      expect {
        type.configure_for_server(server)
      }.to raise_error("Cannot configure the controller controller/idrac using Server bladeserver-15kvd42 as it's not one that support supported by it")
    end

    it "should delegate to the provider" do
      type.provider.expects(:configure_for_server).with(server)
      type.configure_for_server(server)
    end
  end
end

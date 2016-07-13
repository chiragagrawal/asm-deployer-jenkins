require 'spec_helper'
require 'asm/type/volume'

describe ASM::Type::Volume do
  let(:service) { SpecHelper.service_from_fixture("Teardown_EQL_VMware_Cluster.json") }
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:deployment) { stub }

  let(:server) { service.components[1].to_resource(deployment, logger) }
  let(:cluster) { service.components[0].to_resource(deployment, logger) }

  let(:volume_component) { service.components[2] }
  let(:volume) { ASM::Type::Volume.new(volume_component, "rspec", {}, logger) }
  let(:provider) { stub }
  let(:switch){ stub }

  before do
    volume.stubs(:provider).returns(provider)
  end

  describe "#leave_cluster!" do
    it "should remove itself from any clusters that are not being torn down" do
      cluster.stubs(:teardown?).returns(false)
      cluster.expects(:evict_volume!).with(volume)

      volume.stubs(:related_cluster).returns(cluster)

      volume.leave_cluster!
    end

    it "should skip clusters that are being torn down" do
      cluster.stubs(:teardown?).returns(true)
      volume.stubs(:related_cluster).returns(cluster)
      cluster.expects(:evict_volume!).never

      volume.leave_cluster!
    end
  end

  describe "#remove_server_from_volume!" do
    it "should delegate to the provider" do
      volume.expects(:delegate).with(provider, :remove_server_from_volume!, server)
      volume.remove_server_from_volume!(server)
    end
  end

  describe "#fault_domain" do
    it "should delegate to fault domain of perticular provider" do
      volume.expects(:delegate).with(provider,:fault_domain, switch)
      volume.fault_domain(switch)
    end
  end

  describe "#related_cluster" do
    it "should return the related cluster" do
      volume.expects(:related_server).returns(server)
      server.expects(:related_cluster).returns(cluster)
      expect(volume.related_cluster).to eq(cluster)
    end

    it "should return nil when no related server can be found" do
      volume.expects(:related_server).returns(nil)
      expect(volume.related_cluster).to eq(nil)
    end

    it "should return nil when no related cluster can be found" do
      volume.expects(:related_server).returns(server)
      server.expects(:related_cluster).returns(nil)
      expect(volume.related_cluster).to eq(nil)
    end
  end
end

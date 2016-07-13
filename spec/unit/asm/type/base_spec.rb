require 'spec_helper'
require 'asm/type'
require 'asm/type/server'

describe ASM::Type::Base do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }

  let(:provider_name) { "rspec" }
  let(:provider_config) { {} }
  let(:provider_instance) { stub }

  let(:service) { SpecHelper.service_from_fixture("Teardown_NetApp_VMware_Cluster_Server_VM.json") }
  let(:deployment) { service.deployment }
  let(:component) { service.components[1] }

  let(:type) { ASM::Type::Base.new(component, provider_name, provider_config, logger) }
  let(:provider) { stub }
  let(:db) { stub }

  before :each do
    type.stubs(:provider).returns(provider)
    deployment.stubs(:db).returns(db)
    type.deployment = deployment
    service.deployment = deployment
  end

  describe "#do_with_retry" do
    it "should fail without a block" do
      expect {
        type.do_with_retry(1, 1, "")
      }.to raise_error("A block is required for do_with_retry on bladeserver-cdqsgt1")
    end

    it "should run the given block the right amount of times" do
      thing = stub
      thing.stubs(:do_it).raises("fail1").then.raises("fail2").then.raises("fail3").then.raises("fail4")
      type.expects(:sleep).with(0.1).twice
      logger.expects(:warn).with("rspec message sleeping for 0.1: RuntimeError: fail1")
      logger.expects(:warn).with("rspec message sleeping for 0.1: RuntimeError: fail2")
      logger.expects(:warn).with("rspec message sleeping for 0.1: RuntimeError: fail3")

      expect {
        type.do_with_retry(3, 0.1, "rspec message") do
          thing.do_it
        end
      }.to raise_error("fail3")
    end

    it "should return the last result" do
      thing = stub
      thing.stubs(:do_it).raises("fail1").then.returns("success")

      expect(
        type.do_with_retry(3, 0.1, "x") do
          thing.do_it
        end
      ).to eq("success")
    end
  end

  describe "#initialize" do
    it "should call the startup hook" do
      ASM::Type::Base.any_instance.expects(:startup_hook).once
      ASM::Type::Base.new(component, provider_name, provider_config, logger)
    end
  end

  it "should set up the forwardable module" do
    expect(ASM::Type::Base).to respond_to(:def_delegators)
  end

  describe "#db_execution_status" do
    it "should return the found status otherwise nil" do
      db.expects(:get_component_status).with(type.id).returns({:status => "rspec"})
      expect(type.db_execution_status).to eq("rspec")

      db.expects(:get_component_status).with(type.id).returns(nil)
      expect(type.db_execution_status).to eq(nil)
    end
  end

  describe "#valid_inventory?" do
    it "should detect valid inventories" do
      type.stubs(:retrieve_inventory!).returns({"valid" => true})
      expect(type.valid_inventory?).to be_truthy
    end

    it "should detect invalid inventories" do
      type.stubs(:retrieve_inventory!).returns({})
      expect(type.valid_inventory?).to be_falsey
    end
  end

  describe "#managed?" do
    context "when the device is managed" do
      it "returns true" do
        type.stubs(:retrieve_inventory).returns({"state" => "DISCOVERED"})
        expect(type.managed?).to be_truthy
      end

      it "should return false when the device inventory has no state" do
        type.stubs(:retrieve_inventory).returns({})
        expect(type.managed?).to be_falsey
      end
    end

    context "when the device is unmanaged" do
      it "returns false" do
        type.stubs(:retrieve_inventory).returns({"state" => "UNMANAGED"})
        expect(type.managed?).to be_falsey
      end
    end
  end

  describe "#retrieve_inventory!" do
    it "should fetch the correct device inventory" do
      ASM::PrivateUtil.expects(:fetch_managed_device_inventory).with("bladeserver-cdqsgt1").returns(["rspec" => 1])
      expect(type.retrieve_inventory!).to eq("rspec" => 1)
    end

    it "should set an empty hash when no inventory was found" do
      ASM::PrivateUtil.expects(:fetch_managed_device_inventory).with("bladeserver-cdqsgt1").returns([])
      expect(type.retrieve_inventory!).to eq({})
    end
  end

  describe "#service_teardown?" do
    it "should report the service teardown via the component" do
      service.expects(:teardown?)
      type.service_teardown?
    end
  end

  describe "#process_generic" do
    it "should return the result from process_generic" do
      deployment.expects(:process_generic).returns({"rspec" => 1})
      expect(type.process_generic("x", {"rspec" => 1}, "apply")).to eq({"rspec" => 1})
    end

    it "should not do pointless puppet runs" do
      deployment.expects(:process_generic).never
      expect(type.process_generic("x", {}, "apply")).to eq({})
    end
  end

  describe "#update_inventory" do
    it "should update the inventory if it should" do
      provider.expects(:should_inventory?).returns(true)
      provider.expects(:update_inventory)
      type.expects(:retrieve_inventory!)
      type.update_inventory
    end

    it "should not when it shouldnt" do
      provider.expects(:should_inventory?).returns(false)
      provider.expects(:update_inventory).never
      type.update_inventory
    end
  end

  describe "#supports_resource?" do
    it "should support volumes" do
      provider.expects(:volume_supported?)
      type.supports_resource?(stub(:type_name => "volume", :provider_path => "rspec/rspec"))
    end

    it "should support servers" do
      provider.expects(:server_supported?)
      type.supports_resource?(stub(:type_name => "server", :provider_path => "rspec/rspec"))
    end

    it "should support clusters" do
      provider.expects(:cluster_supported?)
      type.supports_resource?(stub(:type_name => "cluster", :provider_path => "rspec/rspec"))
    end

    it "should support virtualmachines" do
      provider.expects(:virtualmachine_supported?)
      type.supports_resource?(stub(:type_name => "virtualmachine", :provider_path => "rspec/rspec"))
    end

    it "should support controllers" do
      provider.expects(:controller_supported?)
      type.supports_resource?(stub(:type_name => "controller", :provider_path => "rspec/rspec"))
    end

    it "should support switches" do
      provider.expects(:switch_supported?)
      type.supports_resource?(stub(:type_name => "switch", :provider_path => "rspec/rspec"))
    end
  end

  describe "#provider_path" do
    it "should give the correct path" do
      expect(type.provider_path).to eq("base/rspec")
    end
  end

  describe "#initialize" do
    it "should set the puppet_certname from the service component" do
      expect(type.puppet_certname).to eq(component.puppet_certname)
    end
  end

  describe "#get_provider_class" do
    it "should be able to fetch provider class constants" do
      provider_klass = mock
      ASM::Provider::Base.expects(:const_get).with("Rspec").returns(provider_klass)

      type.get_provider_class("rspec")
    end
  end

  describe "#delegate" do
    it "should delegate to the right object and log it" do
      (object = stub).expects(:delegated_call).with(1,2,3,4).once
      object.stubs(:to_s).returns("#<rspec mock>")
      logger.expects(:debug).with(regexp_matches(/calling delegated method delegated_call on #<rspec mock>/))

      type.delegate(object, :delegated_call, 1, 2, 3, 4)
    end
  end

  describe "#cert2serial" do
    it "should convert the supplied certname" do
      expect(type.cert2serial("rackserver-rspec")).to eq("RSPEC")
    end

    it "should default to the server certname" do
      expect(type.cert2serial).to eq("CDQSGT1")
    end
  end

  describe "#related_components" do
    it "should find all related servers" do
      type = ASM::Type::Base.new(service.components[0], provider_name, provider_config, logger)

      servers = type.related_components("SERVER")
      expect(servers.size).to eq(2)

      expect(servers[0].puppet_certname).to eq("bladeserver-5qykcy1")
      expect(servers[1].puppet_certname).to eq("bladeserver-cdqsgt1")
    end
  end

  describe "#related_volumes" do
    it "should find all volumes" do
      type.expects(:related_components).with("STORAGE")
      type.related_volumes
    end
  end

  describe "#related_clusters" do
    it "should find all clusters" do
      type.expects(:related_components).with("CLUSTER")
      type.related_clusters
    end
  end

  describe "#related_servers" do
    it "should find all servers" do
      type.expects(:related_components).with("SERVER")
      type.related_servers
    end
  end

  describe "#related_cluster" do
    it "should return the first found cluster" do
      type.expects(:related_clusters).returns(["rspec0", "rspec1"])
      expect(type.related_cluster).to eq("rspec0")
    end
  end

  describe "#related_server" do
    it "should return the first found server" do
      type.expects(:related_servers).returns(["rspec0", "rspec1"])
      expect(type.related_server).to eq("rspec0")
    end
  end

  describe "#related_vms" do
    it "should find all vms" do
      type.expects(:related_components).with("VIRTUALMACHINE")
      type.related_vms
    end
  end

  describe "#related_vm" do
    it "should return the first found vm" do
      type.expects(:related_vms).returns(["vm_1", "vm_2"])
      expect(type.related_vm).to eq("vm_1")
    end
  end

  describe "#db_log" do
    it "should log to database when deployment isn't debug" do
      db.expects(:log).with(:info, "message", {:override_debug => false})
      type.db_log(:info, "message")
    end

    it "should not log to database in debug mode" do
      db.expects(:log).with(:info, "message", {:override_debug => false}).never
      deployment.stubs(:debug?).returns(true)
      type.db_log(:info, "message")
    end
  end
end

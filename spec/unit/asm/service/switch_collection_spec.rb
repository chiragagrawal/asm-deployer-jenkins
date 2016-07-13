require 'spec_helper'
require 'asm/service'

describe ASM::Service::SwitchCollection do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil, :error => nil) }
  let(:raw_switches) { SpecHelper.json_fixture("switch_providers/switch_inventory.json") }

  let(:deployment) { stub }
  let(:service) { stub(:deployment => deployment, :debug? => true) }
  let(:collection) { ASM::Service::SwitchCollection.new(logger) }
  let(:configurable_switches) { collection.reject{|s| s.provider_name == "brocade"} }

  before(:each) do
    collection.stubs(:managed_inventory).returns(raw_switches)
    deployment.stubs(:logger).returns(logger)
    collection.stubs(:service).returns(service)
  end

  describe "#switch_for_mac" do
    it "should find the right switches" do
      collection.switches.each do |switch|
        facts_fixture = "switch_providers/%s_facts.json" % switch.puppet_certname
        ASM::PrivateUtil.stubs(:facts_find).with(switch.puppet_certname).returns(SpecHelper.json_fixture(facts_fixture))
      end

      expect(collection.switch_for_mac("00:01:e8:8b:13:c7").puppet_certname).to eq("dell_iom-172.17.9.174")
      expect(collection.switch_for_mac("e0:db:55:21:12:dc").puppet_certname).to eq("dell_iom-172.17.9.171")
    end

    it "should gracefully handle a nil mac" do
      collection.expects(:find).never
      expect(collection.switch_for_mac(nil)).to be_nil
    end
  end

  describe "#update_inventory" do
    it "should update inventories and facts for selected switches" do
      matched = collection.select {|s| s.puppet_certname.match(/dell_iom/)}

      expect(matched.size).to be(2)

      matched.each do |sw|
        sw.expects(:update_inventory)
        sw.expects(:retrieve_facts!)
      end

      collection.update_inventory do |switch|
        switch.puppet_certname.match(/dell_iom/)
      end
    end
  end

  describe "#await_inventory" do
    let(:server1) { stub("rspec-server1", :puppet_certname => "rspec-server1") }
    let(:servers) { [ server1 ] }

    it "should return true immediately if all servers have topology" do
      collection.expects(:sleep).never
      collection.expects(:update_inventory).never
      expect(collection.await_inventory([])).to eq(true)
    end

    it "should update inventory and return true when connectivity found" do
      collection.expects(:missing_topology).returns([])
      collection.expects(:sleep).once
      collection.each do |switch|
        switch.expects(:update_inventory)
        switch.expects(:retrieve_facts!)
      end
      expect(collection.await_inventory(servers, :sleep_secs => 0)).to eq(true)
    end

    it "should update inventory and return false when connectivity not found" do
      # Simulate five loops of missing inventory.
      collection.expects(:missing_topology).times(5).returns(servers)
      collection.expects(:missing_ports).at_least_once.returns("rspec-nic-port-1")
      collection.expects(:sleep).times(5)
      collection.each do |switch|
        switch.expects(:update_inventory).times(5)
        switch.expects(:retrieve_facts!).times(5)
      end
      expect(collection.await_inventory(servers, :sleep_secs => 0, :max_tries => 5)).to eq(false)
    end
  end

  describe "#configure_server_networking!" do
    let(:server1) { stub("rspec-server1",
                         :id => "rspec-server-id-1",
                         :serial_number => "rspec-serialno-1",
                         :device_config => {:host => "172.x.y.z"},
                         :puppet_certname => "rspec-server1",
                         :valid_fc_target? => false,
                         :brownfield? => false) }
    let(:servers) { [server1] }

    before(:each) do
      service.stubs(:servers).returns(servers)
      collection.stubs(:debug?).returns(true)
    end

    it "should call enable_switch_inventory! and await_inventory if missing topology" do
      collection.expects(:await_inventory).returns(true)

      server1.expects(:missing_network_topology?).at_least_once.returns(true).returns(false)
      server1.expects(:deployment_completed?).returns(false)
      server1.expects(:db_log).with(:info, "Checking switch connectivity for server rspec-server1", :server_log => true)
      server1.expects(:enable_switch_inventory!)
      server1.expects(:disable_switch_inventory!)

      collection.expects(:configure_server_switches!).with(false)
      collection.stubs(:write_portview_cache).returns(nil)
      collection.configure_server_networking!
    end

    it "should not call enable_switch_inventory! on already deployed servers" do
      collection.expects(:await_inventory).returns(true)

      server1.expects(:missing_network_topology?).at_least_once.returns(true).returns(false)
      server1.expects(:deployment_completed?).returns(true)
      server1.expects(:db_log).with(:info, "Checking switch connectivity for server rspec-server1", :server_log => true)
      server1.expects(:enable_switch_inventory!).never
      server1.expects(:disable_switch_inventory!)

      collection.expects(:configure_server_switches!).with(false)
      collection.stubs(:write_portview_cache).returns(nil)
      collection.configure_server_networking!
    end

    it "should not call disable_inventory! on servers with missing connectivity" do
      collection.expects(:await_inventory).returns(true)

      server1.expects(:missing_network_topology?).at_least_once.returns(true)
      server1.expects(:deployment_completed?).returns(false).twice
      server1.expects(:db_log).with(:info, "Checking switch connectivity for server rspec-server1", :server_log => true)
      server1.expects(:enable_switch_inventory!)
      server1.expects(:disable_switch_inventory!).never

      #collection.expects(:configure_server_switches!).with(false)
      collection.stubs(:write_portview_cache).returns(nil)
      expect { collection.configure_server_networking! }.to raise_error(ASM::UnconnectedServerException, "Failed to determine switch connectivity for rspec-server1")

    end

    it "should not call enable_switch_inventory! and await_inventory if no missing topology" do
      collection.expects(:missing_topology).at_least_once.returns([])
      collection.expects(:await_inventory).never
      server1.stubs(:dell_server?).returns(true)
      server1.stubs(:os_only?).returns(false)
      server1.expects(:enable_switch_inventory!).never
      server1.expects(:db_log).with(:info, "Checking switch connectivity for server rspec-server1", :server_log => true).never
      server1.expects(:disable_switch_inventory!).never
      collection.stubs(:write_portview_cache).returns(nil)
      collection.expects(:configure_server_switches!).with(true)
      collection.configure_server_networking!
    end

    it "should not fail if inventory not found and server already deployed" do
      collection.expects(:missing_ports).at_least_once.returns("rspec-nic-port-1")
      collection.expects(:await_inventory).returns(false)
      server1.expects(:deployment_completed?).returns(true).twice
      server1.expects(:missing_network_topology?).at_least_once.returns(true)
      server1.expects(:db_log).with(:info, "Checking switch connectivity for server rspec-server1", :server_log => true)
      server1.expects(:enable_switch_inventory!).never
      db = mock("rspec-db")
      db.expects(:log).with(:error, "Unable to find switch connectivity for server rspec-serialno-1 172.x.y.z on NICs: rspec-nic-port-1")
      service.stubs(:database).returns(db)
      collection.expects(:configure_server_switches!)
      collection.configure_server_networking!
    end

    it "should fail if inventory not found" do
      collection.expects(:missing_ports).at_least_once.returns("rspec-nic-port-1")
      collection.expects(:await_inventory).returns(false)
      server1.expects(:deployment_completed?).returns(false).twice
      server1.expects(:missing_network_topology?).at_least_once.returns(true)
      server1.expects(:db_log).with(:info, "Checking switch connectivity for server rspec-server1", :server_log => true)
      server1.expects(:enable_switch_inventory!)
      server1.expects(:disable_switch_inventory!).never
      db = mock("rspec-db")
      db.expects(:log).with(:error, "Unable to find switch connectivity for server rspec-serialno-1 172.x.y.z on NICs: rspec-nic-port-1")
      service.stubs(:database).returns(db)
      collection.expects(:configure_server_switches!).never
      expect do
        collection.configure_server_networking!
      end.to raise_error(ASM::UnconnectedServerException, "Failed to determine switch connectivity for rspec-server1")
    end

    it "should raise ASM::UserException if a switch configuration fails" do
      server1.stubs(:missing_network_topology?).returns(true)
      configurable_switches.each { |s| s.stubs(:related_servers).returns([server1]) }
      collection.expects(:missing_topology).at_least_once.returns([])
      configurable_switches.each { |switch|
        switch.expects(:valid_inventory?).returns(true)
        switch.expects(:managed?).returns(true)
        switch.expects(:process!).raises("Switch configuration failed")
      }
      expect do
        collection.configure_server_networking!
      end.to raise_error(ASM::UserException, "Switch configuration failed for dell_iom-172.17.9.174, dell_ftos-172.17.9.13, dell_ftos-172.17.9.14, dell_iom-172.17.9.171")
    end

    context "when servers fail connectivity checks" do
      let(:server2) { stub("rspec-server2",
                           :id => "rspec-server-id-2",
                           :serial_number => "rspec-serialno-2",
                           :device_config => {:host => "172.2x.2y.2z"},
                           :puppet_certname => "rspec-server2",
                           :valid_fc_target? => false,
                           :brownfield? => false) }
      before(:each) do
        ASM::PrivateUtil.stubs(:fetch_managed_inventory)
        collection.expects(:missing_ports).at_least_once.returns("rspec-nic-port-1")
        collection.expects(:await_inventory).returns(false)
        collection.stubs(:write_portview_cache).returns(nil)
        server1.expects(:missing_network_topology?).at_least_once.returns(true)
        server1.expects(:deployment_completed?).returns(false).at_least(1)
        server2.expects(:deployment_completed?).returns(false).at_least(1)
        server1.expects(:db_log).with(:info, "Checking switch connectivity for server rspec-server1", :server_log => true)
        server1.expects(:enable_switch_inventory!)
        server2.expects(:db_log).with(:info, "Checking switch connectivity for server rspec-server2", :server_log => true)
        server2.expects(:enable_switch_inventory!)
        service.stubs(:servers).returns([server1, server2])
      end

      it "should still configure another server that didn't fail the check" do
        server2.expects(:disable_switch_inventory!)
        server2.expects(:missing_network_topology?).at_least_once.returns(true).returns(false)
        db = mock("rspec-db")
        db.expects(:log).with(:error, "Unable to find switch connectivity for server rspec-serialno-1 172.x.y.z on NICs: rspec-nic-port-1")
        service.stubs(:database).returns(db)
        collection.expects(:configure_server_switches!).with(false)
        expect do
          collection.configure_server_networking!
        end.to raise_error(ASM::UnconnectedServerException, "Failed to determine switch connectivity for rspec-server1")
      end

      it "should raise an exception with every server that failed connectivity" do
        server2.expects(:missing_network_topology?).at_least_once.returns(true)
        server1.expects(:disable_switch_inventory!).never
        server2.expects(:disable_switch_inventory!).never
        db = mock("rspec-db")
        db.expects(:log).with(:error, "Unable to find switch connectivity for server rspec-serialno-1 172.x.y.z on NICs: rspec-nic-port-1")
        db.expects(:log).with(:error, "Unable to find switch connectivity for server rspec-serialno-2 172.2x.2y.2z on NICs: rspec-nic-port-1")
        service.stubs(:database).returns(db)
        collection.expects(:configure_server_switches!).never
        expect do
          collection.configure_server_networking!
        end.to raise_error(ASM::UnconnectedServerException, "Failed to determine switch connectivity for rspec-server1, rspec-server2")
      end
    end

  end

  describe "#each" do
    it "should yield each switch" do
      switches = []
      collection.switches.each {|s| switches << s}
      expect(switches.size).to be(6)
    end
  end

  describe "#switches" do
    it "should populate the switches when not populated" do
      collection.expects(:populate!).once
      collection.switches
    end

    it "should not re-populate the switches" do
      collection.populate!
      collection.expects(:populate!).never
      collection.switches
    end

    it "should re-populate after reset" do
      collection.populate!
      collection.reset!
      collection.expects(:populate!).once
      collection.switches
    end

    it "should return the populated switches" do
      expect(collection.switches.size).to be(6)
    end
  end

  describe "#managed_inventory" do
    it "should fetch and cache the inventory" do
      collection.unstub(:managed_inventory)

      ASM::PrivateUtil.expects(:fetch_managed_inventory).once.returns([])

      collection.managed_inventory
      collection.managed_inventory
    end
  end

  describe "#reset!" do
    it "should reset everything" do
      collection.switches

      expect(collection.inventories).to_not be_empty
      expect(collection.managed_inventory).to_not be_nil
      expect(collection.switches).to_not be_empty

      collection.reset!

      expect(collection.inventory).to be_nil
      expect(collection.inventories).to be_empty
      expect(collection.instance_variable_get("@switches")).to be_empty
    end
  end

  describe "#populate!" do
    it "should correctly populate the switches" do
      collection.populate!

      expect(collection.switches.size).to be(6)

      certs = collection.map {|switch| switch.puppet_certname}

      ["dell_iom-172.17.9.174", "dell_iom-172.17.9.171", "dell_ftos-172.17.9.13", "dell_ftos-172.17.9.14"].each do |cert|
        expect(certs).to include(cert)
      end
    end
  end

  describe "#switch_inventories" do
    it "should correctly select switch inventories" do
      inventories = collection.switch_inventories

      expect(inventories.size).to be(6)
    end

    it "should cache the inventories" do
      collection.expects(:managed_inventory).returns(raw_switches).once

      collection.switch_inventories
      collection.switch_inventories
    end
  end

  describe "#configure_server_switches!" do
    let(:server1){ stub("rspec-server1", :puppet_certname => "rspec-server1")}
    before(:each) do
      server1.stubs(:missing_topology?).returns(true)
      configurable_switches.each { |s| s.stubs(:related_servers).returns([server1])}
    end
    context "when switch is not connected to any server" do
      it "should not configure the switch" do
        configurable_switches.each do |s|
          s.expects(:valid_inventory?).returns(true)
          s.expects(:managed?).returns(true)
          s.expects(:configure_server_networking!).with(true)
        end
        collection.configure_server_switches!
      end
    end

    context "when switch inventory is invalid" do
      it "should skip the switch" do
        configurable_switches.each do |s|
          s.expects(:valid_inventory?).returns(false)
          s.expects(:managed?).never
          s.expects(:configure_server_networking!).never
        end
        collection.configure_server_switches!
      end
    end

    context "when switch is managed" do
      it "should call #configure_server_networking!" do
        configurable_switches.each do |s|
          s.expects(:valid_inventory?).returns(true)
          s.expects(:managed?).returns(true)
          s.expects(:configure_server_networking!).with(true)
        end
        collection.configure_server_switches!
      end
    end

    context "when switch is unmanaged" do
      it "should call #validate_server_networking!" do
        configurable_switches.each do |s|
          s.expects(:valid_inventory?).returns(true)
          s.expects(:managed?).returns(false)
          s.expects(:validate_server_networking!)
        end

        expect do
          collection.configure_server_switches!
        end.to raise_error(ASM::UserException, "Invalid switch configurations found on unmanaged switches: dell_iom-172.17.9.174, dell_ftos-172.17.9.13, dell_ftos-172.17.9.14, dell_iom-172.17.9.171")
      end
    end
  end
end

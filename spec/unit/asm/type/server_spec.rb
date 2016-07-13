require "spec_helper"
require "asm/type"

ASM::Type.load_providers!

describe ASM::Type::Server do
  let(:raw_switches) do
    SpecHelper.json_fixture("switch_providers/switch_inventory.json")
  end

  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }

  let(:collection) { ASM::Service::SwitchCollection.new(logger) }
  let(:switch_type) { collection.switches.first }

  let(:service) { SpecHelper.service_from_fixture("Teardown_EQL_VMware_Cluster.json", logger) }
  let(:db) { stub }
  let(:deployment) { stub(:id => "1234", :db => db, :debug? => false, :logger => logger, :decrypt? => true) }
  let(:server_component) { service.components_by_type("SERVER").first }

  let(:provider) { stub(
    :hostname => "rspec.host",
    :policy_name => "policy-rspec.host-1234",
    :agent_certname => "rspec.agent.certname")
  }

  let(:type) { server_component.to_resource(deployment, logger) }
  let(:raw_network_params) { server_component.configuration["asm::esxiscsiconfig"]["bladeserver-15kvd42"] }

  before(:each) do
    collection.stubs(:managed_inventory).returns(raw_switches)
    type.stubs(:provider).returns(provider)
    type.stubs(:dell_server?).returns(true)
    ASM::NetworkConfiguration.any_instance.stubs(:add_nics!)
  end

  describe "#razor_block_until" do
    it "should delegate to razor" do
      type.stubs(:management_ip).returns("1.2.3.4")
      type.stubs(:database).returns(db = stub)

      type.razor.expects(:block_until_task_complete).with("15KVD42", "1.2.3.4", "policy-rspec.host-1234", "rspec_task", "rspec_terminal", db).returns(:rspec)
      expect(type.razor_block_until("rspec_task", "rspec_terminal")).to be(:rspec)
    end
  end

  describe "#wait_for_puppet_success" do
    it "should check up to the given time" do
      time = Time.now
      type.expects(:puppet_checked_in_since?).with(time).times(5).returns(false)
      expect {
        type.wait_for_puppet_success(time, 0.5, 0.1)
      }.to raise_error("execution expired")
    end

    it "should break on success" do
      type.stubs(:puppet_checked_in_since?).returns(false).then.returns(true)
      expect(type.wait_for_puppet_success(Time.now, 0.5, 0.1)).to be_truthy
    end
  end

  describe "#puppet_checked_in_since?" do
    it "should return the result from puppetdb" do
      time = Time.now
      type.puppetdb.expects(:successful_report_after?).with("bladeserver-15kvd42", time, :verbose => true).returns(true)
      expect(type.puppet_checked_in_since?(time)).to be_truthy
    end

    it "should be false on exception" do
      time = Time.now
      type.puppetdb.expects(:successful_report_after?).with("bladeserver-15kvd42", time, :verbose => true).raises(ASM::CommandException, "rspec")
      expect(type.puppet_checked_in_since?(time)).to be_falsey
    end
  end

  describe "#enable_razor_boot" do
    let(:razor) { stub }

    before(:each) do
      type.stubs(:razor).returns(razor)

      # fixture does not have add_nics! on it
      pxe_partitions = type.pxe_partitions
      pxe_partitions[0][:mac_address] = "02:42:bf:f9:26:65"
      pxe_partitions[1][:mac_address] = "02:42:bf:f9:26:66"
      type.stubs(:pxe_partitions).returns(pxe_partitions)
    end

    it "should only enable boot when there are PXE partitions" do
      type.expects(:pxe_partitions).returns([])
      expect {
        type.enable_razor_boot
      }.to raise_error("No PXE networks are configured or add_nics! failed for bladeserver-15kvd42, cannot enable Razor booting")
    end

    it "should register when the node is not known" do
      razor.stubs(:find_node).with("15KVD42").returns(nil)

      razor.expects(:register_node).with(
        :mac_addresses => ["02:42:bf:f9:26:65", "02:42:bf:f9:26:66"],
        :serial => "15KVD42",
        :installed => false
      ).returns("name" => "rspec_node").twice

      razor.expects(:get).with("nodes", "rspec_node").returns("name" => "rspec_node", "facts" => {})
      razor.expects(:checkin_node).with("rspec_node", ["02:42:bf:f9:26:65", "02:42:bf:f9:26:66"], {})

      type.enable_razor_boot

      razor.expects(:get).with("nodes", "rspec_node").returns("name" => "rspec_node")
      razor.expects(:checkin_node).with("rspec_node", ["02:42:bf:f9:26:65", "02:42:bf:f9:26:66"], :serialnumber => "15KVD42")

      type.enable_razor_boot
    end

    it "should not attempt to register known nodes" do
      razor.expects(:find_node).with("15KVD42").returns("name" => "rspec_node", "facts" => {})
      razor.expects(:register_node).never
      razor.expects(:checkin_node).with("rspec_node", ["02:42:bf:f9:26:65", "02:42:bf:f9:26:66"], {})
      type.enable_razor_boot
    end
  end

  describe "#delete_stale_policy!" do
    it "should request the deletion via razor" do
      ASM::Razor.expects(:new).returns(razor = stub)
      razor.expects(:delete_stale_policy!).with("15KVD42", "policy-rspec.host-1234")
      type.delete_stale_policy!
    end
  end

  describe "#node_data_time" do
    it "should return the time of the data file" do
      type.expects(:node_data_file).returns(__FILE__)
      expect(type.node_data_time).to eq(File.mtime(__FILE__))
    end

    it "should fail for unreadable node data" do
      File.expects(:readable?).with("/etc/puppetlabs/puppet/node_data/rspec.agent.certname.yaml").returns(false)

      expect {
        type.node_data_time
      }.to raise_error("Node data for bladeserver-15kvd42 not found in /etc/puppetlabs/puppet/node_data/rspec.agent.certname.yaml")
    end
  end

  describe "#node_data" do
    let(:n_file) { "/etc/puppetlabs/puppet/node_data/rspec.agent.certname.yaml" }

    it "should return nil for missing data" do
      File.expects(:readable?).with(n_file).returns(false)
      expect(type.node_data).to be_nil
    end

    it "should load and yaml parse the data" do
      File.expects(:readable?).with(n_file).returns(true)
      YAML.expects(:load_file).with(n_file).returns(:rspec => 1)
      expect(type.node_data).to eq(:rspec => 1)
    end
  end

  describe "#write_node_data" do
    let(:n_file) { "/etc/puppetlabs/puppet/node_data/rspec.agent.certname.yaml" }

    it "should not write identical data" do
      File.expects(:readable?).with(n_file).returns(true)
      YAML.expects(:load_file).with(n_file).returns(:rspec => 1)
      File.expects(:write).never
      type.write_node_data(:rspec => 1)
    end

    it "should write data to the write place" do
      File.expects(:readable?).with(n_file).returns(true)
      YAML.expects(:load_file).with(n_file).returns(:rspec => 1)
      File.expects(:write).with(n_file, {:rspec => 2}.to_yaml)
      type.write_node_data(:rspec => 2)
    end
  end

  describe "#write_post_install_config!" do
    it "should write the correct data"do
      type.stubs(:post_install_config).returns(:rspec => :post_data)
      type.expects(:write_node_data).with("rspec.agent.certname" => {:rspec => :post_data})
      type.write_post_install_config!
    end

    it "should not write empty data" do
      type.stubs(:post_install_config).returns({})
      type.expects(:write_node_data).never
      type.write_post_install_config!
    end
  end

  describe "#node_data_file" do
    it "should determine the correct file name" do
      expect(type.node_data_file).to eq("/etc/puppetlabs/puppet/node_data/rspec.agent.certname.yaml")
    end
  end

  describe "#post_install_config" do
    it "should handle unsupported post installs" do
      type.expects(:post_install_processor).returns(nil)
      expect(type.post_install_config).to eq({})
    end

    it "should support processors with post_os_config" do
      processor = stub(:post_os_config => {"rspec" => true}, :post_os_services => {})
      type.stubs(:post_install_processor).returns(processor)
      expect(type.post_install_config).to eq("rspec" => true)
    end

    it "should support ones without post_os_config" do
      processor = stub(
        :post_os_classes => {"rspec_classes" => {:c => 1}},
        :post_os_resources => {"rspec_resources" => {:r => 1}},
        :post_os_services => {"rspec_services" => {:s => 1}})
      type.stubs(:post_install_processor).returns(processor)

      expect(type.post_install_config).to eq(
        "classes" => {"rspec_classes" => {:c => 1}},
        "resources" => {"rspec_resources" => {:r => 1}},
        "rspec_services" => {:s => 1}
      )
    end
  end

  describe "#post_install_processor" do
    it "should handle cases that does not support postinstall" do
      type.expects(:can_post_install?).returns(false)
      type.expects(:windows?).never
      expect(type.post_install_processor).to be_nil
    end

    it "should support windows" do
      type.stubs(:can_post_install?).returns(true)
      type.stubs(:windows?).returns(true)
      type.stubs(:linux?).returns(false)
      type.expects(:windows_post_processor).returns(post = stub)
      expect(type.post_install_processor).to eq(post)
    end

    it "should support linux" do
      type.stubs(:can_post_install?).returns(true)
      type.stubs(:windows?).returns(false)
      type.stubs(:linux?).returns(true)
      type.expects(:linux_post_processor).returns(post = stub)
      expect(type.post_install_processor).to eq(post)
    end

    it "should handle unknowns" do
      type.stubs(:can_post_install?).returns(true)
      type.stubs(:windows?).returns(false)
      type.stubs(:linux?).returns(false)
      expect(type.post_install_processor).to be_nil
    end
  end

  describe "#can_postinstall?" do
    it "should correctly handle a case with no OS" do
      provider.stubs(:has_os?).returns(false)
      type.expects(:os_image_type).never
      expect(type.can_post_install?).to be_falsey
    end

    it "should correctly report the post install ability" do
      provider.stubs(:has_os?).returns(true)
      type.stubs(:os_image_type).returns("RspecOS")
      expect(type.can_post_install?).to be_truthy

      ["vmware_esxi", "hyperv", "suse11", "suse12"].each do |os|
        type.stubs(:os_image_type).returns(os.upcase)
        expect(type.can_post_install?).to be_falsey
      end
    end
  end

  describe "#linux?" do
    it "should determine os based on common linux names" do
      type.stubs(:has_os?).returns(true)

      ["suse", "redhat", "ubuntu", "debian", "centos", "fedora"].each do |os|
        type.stubs(:os_image_type).returns(os.upcase)
        expect(type.linux?).to be_truthy
      end

      type.stubs(:os_image_type).returns("Rspec OS")
      expect(type.linux?).to be_falsey
    end
  end

  describe "#windows?" do
    it "should correctly handle OSless machines" do
      type.stubs(:has_os?).returns(false)
      type.expects(:os_image_type).never
      expect(type.windows?).to be_falsey
    end

    it "should correctly detect the OS type" do
      provider.stubs(:has_os?).returns(true)

      type.expects(:os_image_type).returns("Rspec Linux")
      expect(type.windows?).to be_falsey

      type.expects(:os_image_type).returns("Rspec Windows")
      expect(type.windows?).to be_truthy
    end
  end

  describe "#baremetal?" do
    before(:each) do
      type.stubs(:related_volumes).returns([])
      type.stubs(:related_clusters).returns([])
    end

    context "when managing dell servers" do
      before(:each) do
        type.stubs(:dell_server?).returns(true)
        type.stubs(:related_switches).returns([stub])
      end

      it "should detect bare servers" do
        expect(type.baremetal?).to be_truthy
      end

      it "should not consider machines without switches" do
        type.stubs(:related_switches).returns([])
        expect(type.baremetal?).to be_falsey
      end

      it "should not consider machines with volumes" do
        type.stubs(:related_volumes).returns([stub])
        expect(type.baremetal?).to be_falsey
      end

      it "should not consider machines with clusters" do
        type.stubs(:related_clusters).returns([stub])
        expect(type.baremetal?).to be_falsey
      end
    end

    context "when managing non dell servers" do
      before(:each) do
        type.stubs(:dell_server?).returns(false)
      end

      it "should detect bare servers" do
        expect(type.baremetal?).to be_truthy
      end

      it "should not consider machines with volumes" do
        type.stubs(:related_volumes).returns([stub])
        expect(type.baremetal?).to be_falsey
      end

      it "should not consider machines with clusters" do
        type.stubs(:related_clusters).returns([stub])
        expect(type.baremetal?).to be_falsey
      end
    end
  end

  describe "#related_storage_volumes" do
    it "should find the correct storage volumes" do
      type.expects(:related_volumes).returns([
        stub(:provider_name => "rspec"),
        stub(:provider_name => "compellent")
      ])

      expect(type.related_storage_volumes.size).to be(1)
    end
  end

  describe "#fcoe_wwpns" do
    it "should return [] when there are no fcoe san networks" do
      ASM::WsMan.expects(:get_fcoe_wwpn).never
      expect(type.fcoe_wwpns).to eq([])
    end

    it "should return the correct wwpns" do
      type.expects(:fcoe_san_partitions).returns([
        {"id" => "373ED367-028D-4DF7-8176-0DF26C263963", "fqdd" => "NIC.Integrated.1-1-4"},
        {"id" => "39314B90-BDC0-4093-81E5-9A9A121ED8D1", "fqdd" => "NIC.Integrated.1-2-4"}
      ])

      ASM::WsMan.expects(:get_fcoe_wwpn).returns({
        "NIC.Integrated.1-1-4" => {"fcoe_offload_mode"=>"2", "fcoe_wwnn"=>"00:00:00:00:00:00", "fcoe_permanent_fcoe_macaddress"=>"00:00:00:00:00:00", "virt_wwn"=>"20:00:74:86:7A:EF:48:3D", "virt_wwpn"=>"20:01:74:86:7A:EF:48:3D", "wwn"=>"20:00:74:86:7A:EF:48:3D", "wwpn"=>"20:01:74:86:7A:EF:48:3D"},
        "NIC.Integrated.1-2-4" => {"fcoe_offload_mode"=>"2", "fcoe_wwnn"=>"00:00:00:00:00:00", "fcoe_permanent_fcoe_macaddress"=>"00:00:00:00:00:00", "virt_wwn"=>"20:00:74:86:7A:EF:48:3F", "virt_wwpn"=>"20:01:74:86:7A:EF:48:3F", "wwn"=>"20:00:74:86:7A:EF:48:3F", "wwpn"=>"20:01:74:86:7A:EF:48:3F"},
        "NIC.Integrated.1-1-1" => {"fcoe_offload_mode"=>"3", "fcoe_wwnn"=>"00:00:00:00:00:00", "fcoe_permanent_fcoe_macaddress"=>"00:00:00:00:00:00", "virt_wwn"=>"20:00:74:86:7A:EF:48:31", "virt_wwpn"=>"20:01:74:86:7A:EF:48:31", "wwn"=>"20:00:74:86:7A:EF:48:31", "wwpn"=>"20:01:74:86:7A:EF:48:31"}
      })

      expect(type.fcoe_wwpns).to eq(["20:01:74:86:7A:EF:48:3D", "20:01:74:86:7A:EF:48:3F"])
    end
  end

  describe "#fc_wwpns" do
    it "should retrieve the wwpns from wsman" do
      provider.expects(:fc_wwpns).returns(["21:00:00:24:FF:46:63:5A", "21:00:00:24:FF:46:63:5B"])
      expect(type.fc_wwpns).to eq(["21:00:00:24:FF:46:63:5A", "21:00:00:24:FF:46:63:5B"])
    end
  end

  describe "#fc?" do
    it "should detect fc enabled volumes" do
      type.expects(:related_volumes).returns([stub(:fc? => true), stub(:fc? => false)])
      type.expects(:fc_wwpns).returns(["21:00:00:24:FF:46:63:5A", "21:00:00:24:FF:46:63:5B"])
      expect(type.fc?).to be_truthy

      type.expects(:related_volumes).returns([stub(:fc? => true), stub(:fc? => false)])
      type.expects(:fc_wwpns).returns([])
      expect(type.fc?).to be_falsey

      type.expects(:related_volumes).returns([stub(:fc? => false), stub(:fc? => false)])
      expect(type.fc?).to be_falsey
    end
  end

  describe "#is_hypervisor?" do
    it "sould check the current os" do
      provider.expects(:os_image_type).returns("rspec")
      type.expects(:is_hypervisor_os?).with("rspec").returns(true)

      expect(type.is_hypervisor?).to be_truthy
    end
  end

  describe "#is_hypervisor_os?" do
    it "should support the known good OSes" do
      ["hyperv", "HyPerV", "vmware_esxi", "vmware_ESXI"].each do |os|
        expect(type.is_hypervisor_os?(os)).to be_truthy
      end
    end

    it "should not support unknown OSes" do
      expect(type.is_hypervisor_os?("rspec")).to be_falsey
    end
  end

  describe "#configure_networking!" do
    before(:each) do
      type.stubs(:management_ip).returns("172.14.3.4")
    end
    it "should not fail when no switches are found" do
      type.stubs(:related_switches).returns([])
      logger.expects(:warn).with("Could not find any switches to configure for server bladeserver-15kvd42")
      ASM::Type::Switch.any_instance.expects(:configure_server).never
      type.configure_networking!
    end

    it "should configure the server on related switches" do
      switches = [stub(:puppet_certname => "switch1"), stub(:puppet_certname => "switch2")]

      type.stubs(:related_switches).returns(switches)
      switches.each do |s|
        s.stubs(:managed?).returns(true)
        s.stubs(:model).returns("MXL")
        s.stubs(:management_ip).returns("10.100.2.1")
      end

      switches[0].expects(:configure_server).with(type, false)
      switches[1].expects(:configure_server).with(type, false)
      type.expects(:db_log).twice

      type.configure_networking!
    end

    it "should configure the server for only one switch" do
      selected_switch = stub(:puppet_certname => "switch")
      selected_switch.stubs(:managed?).returns(true)
      switches = [selected_switch, stub(:puppet_certname => "switch2"), stub(:puppet_certname => "switch3")]
      type.stubs(:related_switches).returns(switches)
      switches.each do |s|
        s.stubs(:managed?).returns(true)
        s.stubs(:model).returns("MXL")
        s.stubs(:management_ip).returns("10.100.2.1")
      end
      switches[0].expects(:configure_server).never
      switches[1].expects(:configure_server).never
      selected_switch.expects(:configure_server).with(type, false)
      type.expects(:db_log)
      type.configure_networking!(false, :switch => selected_switch)
    end

    it "should not configure an unrelated switch" do
      selected_switch = stub(:puppet_certname => "switch")
      selected_switch.stubs(:managed?).returns(true)
      switches = [stub(:puppet_certname => "switch1"), stub(:puppet_certname => "switch2")]
      type.stubs(:related_switches).returns(switches)
      expect do
        type.configure_networking!(false, :switch => selected_switch)
      end.to raise_error("Switch switch not connected to bladeserver-15kvd42")
    end

    it "should display the correct logging message" do
      switch = stub(:puppet_certname => "switch", :supports_resource? => true)
      switch.stubs(:model).returns("MXL")
      switch.stubs(:management_ip).returns("10.100.2.1")
      switch.stubs(:managed?).returns(true)

      type.stubs(:related_switches).returns([switch])
      type.expects(:db_log).with(:info, "Configuring server 15KVD42 172.14.3.4 networking on MXL 10.100.2.1")
      switch.expects(:configure_server).with(type, false)
      type.configure_networking!(false)
    end
  end

  describe "#powered_on?" do
    it "should return the correct on state" do
      type.expects(:power_state).returns(:on)
      expect(type.powered_on?).to be_truthy

      type.expects(:power_state).returns(:off)
      expect(type.powered_on?).to be_falsey
    end
  end

  describe "#network_interfaces" do
    before(:each) do
      network_config = ASM::NetworkConfiguration.new(
        SpecHelper.json_fixture("switch_providers/bladeserver-gp181y1_network_config.json")
      )
      type.stubs(:network_config).returns(network_config)
    end

    it "should return all interfaces by default" do
      interfaces = type.network_interfaces

      expect(interfaces.size).to be(2)

      expect(interfaces.map{|i| i.partitions.first.fqdd}).to eq(["NIC.Integrated.1-1-1", "NIC.Integrated.1-2-1"])
    end
  end

  describe "#configured_interfaces" do
    before(:each) do
      network_config = ASM::NetworkConfiguration.new(
          SpecHelper.json_fixture("switch_providers/bladeserver-gp181y1_network_config.json")
      )
      network_config.cards.first.interfaces.first.partitions.each do |partition|
        partition.networkObjects = []
      end
      type.stubs(:network_config).returns(network_config)
    end

    it "should skip interfaces without networks" do
      interfaces = type.configured_interfaces
      expect(interfaces.size).to be(1)
      expect(interfaces.map { |i| i.partitions.first.fqdd }).to eq(["NIC.Integrated.1-2-1"])
    end
  end

  describe "#switches" do
    before(:each) do
      ASM::Service::SwitchCollection.any_instance.stubs(:managed_inventory).returns(raw_switches)
      ASM::Service::SwitchCollection.any_instance.stubs(:deployment).returns(deployment)

      type.switch_collection.switches.each do |sw|
        facts_fixture = "switch_providers/%s_facts.json" % sw.puppet_certname
        sw.stubs(:facts_find).returns(
          SpecHelper.json_fixture(facts_fixture)
        )
      end
      ASM::PrivateUtil.stubs(:facts_find).with("bladeserver-15kvd42").returns({})
      ASM::PrivateUtil.stubs(:facts_find).with("bladeserver-gp181y1").returns({})

      network_config = ASM::NetworkConfiguration.new(
        SpecHelper.json_fixture("switch_providers/bladeserver-gp181y1_network_config.json")
      )
      type.stubs(:network_config).returns(network_config)
      type.stubs(:save_facts!)
      type.stubs(:fc_interfaces).returns([])
      provider.stubs(:facts=)
      provider.stubs(:facts).returns(type.facts_find)
    end

    it "should correctly identify connected switches" do
      interfaces = type.network_interfaces

      expect(type.related_switches[0]).to be_a(ASM::Type::Switch)
      expect(type.related_switches[0].provider_name).to eq("force10")
      expect(type.related_switches[0].puppet_certname).to eq("dell_iom-172.17.9.171")
      expect(type.related_switches[0].find_mac(interfaces[0].partitions.first["mac_address"])).to eq("Te 0/2")

      expect(type.related_switches[1]).to be_a(ASM::Type::Switch)
      expect(type.related_switches[1].provider_name).to eq("force10")
      expect(type.related_switches[1].puppet_certname).to eq("dell_iom-172.17.9.174")
      expect(type.related_switches[1].find_mac(interfaces[1].partitions.first["mac_address"])).to eq("Te 0/2")
    end
  end

  describe "#network_topology_cache" do
    let(:switch1) { mock(:puppet_certname => "dell_iom-172.17.9.171")}
    let(:switch2) { mock(:puppet_certname => "dell_iom-172.17.9.174")}

    before(:each) do
      facts = {"network_topology" => [["e0:db:55:22:f9:a0", "dell_iom-172.17.9.171", "Te 0/2"],
                                      ["e0:db:55:22:f9:a2", "dell_iom-172.17.9.174", "Te 0/3"]].to_json}
      provider.stubs(:facts).returns(facts)
    end

    it "should create a hash of macs to [switch, port] and add relations" do
      ASM::Service::SwitchCollection.any_instance.expects(:switch_by_certname)
          .with("dell_iom-172.17.9.171").returns(switch1).twice
      ASM::Service::SwitchCollection.any_instance.expects(:switch_by_certname)
          .with("dell_iom-172.17.9.174").returns(switch2).twice
      type.expects(:add_relation).with(switch1)
      switch1.expects(:add_relation).with(type)
      type.expects(:add_relation).with(switch2)
      switch2.expects(:add_relation).with(type)
      expect(type.network_topology_cache).to eq({"e0:db:55:22:f9:a0" => [switch1.puppet_certname, "Te 0/2"],
                                                 "e0:db:55:22:f9:a2" => [switch2.puppet_certname, "Te 0/3"]})
    end

    it "should reject switches not in switch_collection" do
      ASM::Service::SwitchCollection.any_instance.expects(:switch_by_certname)
          .with("dell_iom-172.17.9.171").returns(switch1).twice
      ASM::Service::SwitchCollection.any_instance.expects(:switch_by_certname)
          .with("dell_iom-172.17.9.174").returns(nil)
      type.expects(:add_relation).with(switch1)
      switch1.expects(:add_relation).with(type)
      expect(type.network_topology_cache).to eq({"e0:db:55:22:f9:a0" => [switch1.puppet_certname, "Te 0/2"]})
    end
  end

  describe "#add_network_topology_cache" do
    let(:cache) { {} }
    let(:switch1) { stub(:puppet_certname => "dell_iom-172.17.9.171") }

    before(:each) do
      type.stubs(:network_topology_cache).returns(cache)
      type.expects(:add_relation).with(switch1)
      switch1.expects(:add_relation).with(type)
    end

    it "should add relation between server and switch" do
      type.add_network_topology_cache("rspec-mac", switch1, "rspec-port")
      expect(cache).to eq({"rspec-mac" => [switch1.puppet_certname, "rspec-port"]})
    end

    it "should downcase the mac address" do
      type.add_network_topology_cache("RSPEC-MAC", switch1, "rspec-port")
      expect(cache).to eq({"rspec-mac" => [switch1.puppet_certname, "rspec-port"]})
    end
  end

  describe "#network_topology" do
    let(:network_config) do
      ASM::NetworkConfiguration.new(
          SpecHelper.json_fixture("switch_providers/bladeserver-gp181y1_network_config.json")
      )
    end

    let(:fc_interfaces) { SpecHelper.json_fixture("switch_providers/bladeserver-gp181y1_fc_interfaces.json") }

    let(:interface1) { network_config.cards[0].interfaces[0] }
    let(:interface2) { network_config.cards[0].interfaces[1] }
    let(:mac1) { interface1.partitions.first.mac_address }
    let(:mac2) { interface2.partitions.first.mac_address }
    let(:mac3) { fc_interfaces[0]["wwpn"] }
    let(:mac4) { fc_interfaces[1]["wwpn"] }
    let(:switch1) { stub(:puppet_certname => "rspec-switch1")}
    let(:switch2) { stub(:puppet_certname => "rspec-switch2")}
    let(:switch3) { stub(:puppet_certname => "rspec-fcswitch1")}
    let(:switch4) { stub(:puppet_certname => "rspec-fcswitch2")}

    before(:each) do
      type.stubs(:network_config).returns(network_config)
      provider.stubs(:fc_interfaces).returns(fc_interfaces.map{|f| Hashie::Mash.new(f)})
    end

    it "should retrieve connectivity and cache them" do
      ASM::Service::SwitchCollection.any_instance.expects(:switch_port_for_mac)
          .with(mac1).returns([switch1, "Te 0/2"])
      ASM::Service::SwitchCollection.any_instance.expects(:switch_port_for_mac)
          .with(mac2).returns([switch2, "Te 0/3"])
      ASM::Service::SwitchCollection.any_instance.expects(:switch_port_for_mac)
          .with(mac3).returns([switch3, "port1"])
      ASM::Service::SwitchCollection.any_instance.expects(:switch_port_for_mac)
          .with(mac4).returns([switch4, "port2"])
      type.stubs(:network_topology_cache).returns({})
      type.expects(:add_network_topology_cache).with(mac1, switch1, "Te 0/2")
      type.expects(:add_network_topology_cache).with(mac2, switch2, "Te 0/3")
      type.expects(:add_network_topology_cache).with(mac3, switch3, "port1")
      type.expects(:add_network_topology_cache).with(mac4, switch4, "port2")
      type.expects(:save_facts!)

      expect(type.network_topology).to eq([{:interface => interface1,
                                            :interface_type => "ethernet",
                                            :switch => switch1,
                                            :port => "Te 0/2"},
                                           {:interface => interface2,
                                            :interface_type => "ethernet",
                                            :switch => switch2,
                                            :port => "Te 0/3"},
                                           {:interface => fc_interfaces[0],
                                            :interface_type => "fc",
                                            :switch => switch3,
                                            :port => "port1"},
                                           {:interface => fc_interfaces[1],
                                            :interface_type => "fc",
                                            :switch => switch4,
                                            :port => "port2"} ])
    end

    it "should retrieve cached connectivity" do
      ASM::Service::SwitchCollection.any_instance.expects(:switch_by_certname)
          .with(switch1.puppet_certname).returns(switch1)
      ASM::Service::SwitchCollection.any_instance.expects(:switch_by_certname)
          .with(switch2.puppet_certname).returns(switch2)
      ASM::Service::SwitchCollection.any_instance.expects(:switch_by_certname)
          .with(switch3.puppet_certname).returns(switch3)
      ASM::Service::SwitchCollection.any_instance.expects(:switch_by_certname)
          .with(switch4.puppet_certname).returns(switch4)
      type.stubs(:network_topology_cache).returns({mac1.downcase => [switch1.puppet_certname, "Te 0/2"],
                                                   mac2.downcase => [switch2.puppet_certname, "Te 0/3"],
                                                   mac3.downcase => [switch3.puppet_certname, "port1"],
                                                   mac4.downcase => [switch4.puppet_certname, "port2"]})
      expect(type.network_topology).to eq([{:interface => interface1,
                                            :interface_type => "ethernet",
                                            :switch => switch1,
                                            :port => "Te 0/2"},
                                           {:interface => interface2,
                                            :interface_type => "ethernet",
                                            :switch => switch2,
                                            :port => "Te 0/3"},
                                           {:interface => fc_interfaces[0],
                                            :interface_type => "fc",
                                            :switch => switch3,
                                            :port => "port1"},
                                           {:interface => fc_interfaces[1],
                                            :interface_type => "fc",
                                            :switch => switch4,
                                            :port => "port2"} ])
    end
  end

  describe "#missing_network_topology" do
    let(:network_config) do
      ASM::NetworkConfiguration.new(
          SpecHelper.json_fixture("switch_providers/bladeserver-gp181y1_network_config.json")
      )
    end
    let(:interface1) { network_config.cards[0].interfaces[0] }
    let(:interface2) { network_config.cards[0].interfaces[1] }
    let(:mac1) { interface1.partitions.first.mac_address }
    let(:mac2) { interface2.partitions.first.mac_address }
    let(:switch1) { mock("rspec-switch1")}

    before(:each) do
      type.stubs(:network_config).returns(network_config)
      provider.stubs(:fc_interfaces).returns([])
      ASM::Service::SwitchCollection.any_instance.expects(:switch_port_for_mac)
          .with(mac1).returns([switch1, "Te 0/2"])
      ASM::Service::SwitchCollection.any_instance.expects(:switch_port_for_mac)
          .with(mac2).returns(nil)
      type.stubs(:network_topology_cache).returns({})
      type.expects(:add_network_topology_cache).with(mac1, switch1, "Te 0/2")
      type.expects(:save_facts!)
    end


    it "should find interfaces without switch ports" do
      expect(type.missing_network_topology).to eq([interface2.partitions.first, ])
    end

    it "should skip unconfigured interfaces" do
      type.expects(:configured_interface?).with(interface2).returns(false)
      expect(type.missing_network_topology).to eq([])
    end
  end

  describe "#deployment_completed?" do
    it "should return true if the db says its done" do
      type.expects(:db_execution_status).returns("complete")
      expect(type.deployment_completed?).to be_truthy
    end

    it "should return if not completed in the db and its a bfs machine" do
      type.expects(:db_execution_status).returns(nil)
      type.expects(:boot_from_san?).returns(true)
      type.expects(:razor_status).never
      expect(type.deployment_completed?).to be_falsey
    end

    it "should check razor otherwise" do
      type.stubs(:db_execution_status).returns(nil)
      type.stubs(:boot_from_san?).returns(false)
      type.stubs(:has_os?).returns(true)
      type.stubs(:os_image_type).returns("redhat7")

      type.expects(:razor_status).returns({:status=> :rspec})
      expect(type.deployment_completed?).to be_falsey

      type.expects(:razor_status).returns({:status => :boot_local})
      expect(type.deployment_completed?).to be_truthy

      type.expects(:razor_status).returns(:status => :boot_local_2)
      expect(type.deployment_completed?).to be_truthy
    end
  end

  describe "#razor_status" do
    it "should report the razor status when the node is found" do
      ASM::Razor.expects(:new).returns(razor = stub)
      razor.expects(:find_node).with("15KVD42").returns({"name" => "rspec"})
      razor.expects(:task_status).with("rspec", "policy-rspec.host-1234").returns({:status => "rspec"})

      expect(type.razor_status).to eq({:status => "rspec"})
    end
  end

  describe "#rackserver?" do
    it "should detect rack servers correctly" do
      type.expects(:physical_type).returns("RACK")
      expect(type.rackserver?).to be_truthy

      type.expects(:physical_type).returns("BLADE")
      expect(type.rackserver?).to be_falsey
    end
  end
  describe "#fcoe?" do
    it "should report false when there are no fcoe networks" do
      type.expects(:fcoe_san_networks).returns({})
      expect(type.fcoe?).to be_falsey
    end

    it "should report false when there are no fcoe networks" do
      type.expects(:fcoe_san_networks).returns({1=>2})
      expect(type.fcoe?).to be_truthy
    end
  end

  describe "#fcoe_san_networks" do
    it "should retrieve the STORAGE_FCOE_SAN networks" do
      type.expects(:network_config).returns(nc = stub)
      nc.expects(:get_networks).with("STORAGE_FCOE_SAN").returns({"rspec" => 1})
      expect(type.fcoe_san_networks).to eq({"rspec" => 1})
    end
  end

  describe "#fabric_info" do
    let(:rack_network_config_json) { SpecHelper.json_fixture("network_configuration/rack_partitioned.json") }
    let(:rack_network_config) { ASM::NetworkConfiguration.new(rack_network_config_json) }

    it "should create correct rack server info based on cards" do
      type.stubs(:network_config).returns(rack_network_config)
      expect(type.fabric_info).to eq({"Fabric A"=>2})
    end
  end

  describe "#network_params" do
    it "should fetch asm::esxiscsiconfig from the component" do
      expect(type.network_params).to eq(raw_network_params)
    end

    it "should return an empty hash when none is found" do
      server_component.expects(:resource_by_id).with("asm::esxiscsiconfig").returns(nil)
      expect(type.network_params).to eq({})
    end
  end

  describe "#network_config" do
    let(:config) { mock }

    before(:each) do
      ASM::NetworkConfiguration.stubs(:new).with(raw_network_params["network_configuration"]).returns(config)
      type.stubs(:device_config).returns({"rspec" => "device"})
    end

    it "should create instances of ASM::NetworkConfiguration" do
      config.expects(:add_nics!).with({"rspec" => "device"}, {:add_partitions => true})
      type.network_config
    end
  end

  describe "#management_network" do
    it "should retrieve the management network from the network config" do
      config = ASM::NetworkConfiguration.new(raw_network_params["network_configuration"])

      expect(type.management_network).to eq(config.get_network('HYPERVISOR_MANAGEMENT'))
      expect(type.management_network.name).to eq("HypervisorManagement")
      expect(type.management_network.id).to eq("ff8080814dbf2d1d014dc298d147006f")
      expect(type.management_network.staticNetworkConfiguration["ipAddress"]).to eq("172.28.10.63")
    end
  end

  describe "#static_network_config" do
    it "should retrieve the management network static config" do
      expect(type.static_network_config).to eq(type.management_network["staticNetworkConfiguration"])
    end
  end

  describe "#primary_dnsserver" do
    it "should retrieve the primaryDns" do
      expect(type.primary_dnsserver).to eq("172.20.0.8")
    end
  end

  describe "#secondary_dnsserver" do
    it "should retrieve the secondaryDns" do
      type.stubs(:static_network_config).returns("secondaryDns" => "8.8.8.8")
      expect(type.secondary_dnsserver).to eq("8.8.8.8")
    end
  end

  describe "#hostip" do
    it "should supply the hosts ip in the static network" do
      expect(type.hostip).to eq(type.static_network_config["ipAddress"])
    end
  end

  describe "#hostname" do
    it "should get the hostname from the provider" do
      type.expects(:provider).returns(mock(:hostname))
      type.hostname
    end
  end

  describe "#hyperv_config" do
    it "should return the data from the provider" do
      provider.stubs(:to_hash).with(true, :hyperv).returns({"rspec" => true})
      expect(type.hyperv_config).to eq({"rspec" => true})
    end
  end

  [:delete_server_cert!, :leave_cluster!, :clean_related_volumes!, :clean_virtual_identities!, :power_off!, :delete_server_node_data!].each do |m|
    describe "#%s" % m do
      it "should delegate to the provider" do
        type.expects(:delegate).with(provider, m).once
        type.send(m)
      end
    end
  end

  describe "#interface_in_vlan?" do
    context "when vlan is found" do
      it "should return true" do
        port_interface = "Eth1/21"
        facts = SpecHelper.json_fixture("switch_providers/vlan_information.json")
        switch_type.stubs(:facts).returns(facts)
        expect(type.interface_in_vlan?(switch_type, port_interface, "50", false)).to eq(true)
      end
    end

    context "when vlan is not found" do
      it "should return false" do
        port_interface = "Eth1/4"
        facts = SpecHelper.json_fixture("switch_providers/vlan_information.json")
        switch_type.stubs(:facts).returns(facts)
        expect(type.interface_in_vlan?(switch_type, port_interface,"50", true)).to eq(false)
      end
    end
  end

  describe "#parse_interface" do
    it "should parse group without range or letters or stack" do
      pg = "3"
      expect(type.parse_interface(pg)).to eq([[],"3",""])
    end
    it "should parse with range" do
      pg = "1-12"
      expect(type.parse_interface(pg)).to eq([[],"1-12",""])
    end
    it "should parse with single stack and range" do
      pg = "1/2-3"
      expect(type.parse_interface(pg)).to eq([["1"],"2-3","1"])
    end
    it "should parse with double stack and range" do
      pg = "1/2/3-4"
      expect(type.parse_interface(pg)).to eq([["1", "2"],"3-4","1/2"])
    end
    it "should parse with double stack and no range" do
      pg = "1/2/4"
      expect(type.parse_interface(pg)).to eq([["1", "2"],"4","1/2"])
    end
    it "should parse with single stack, letters, speed" do
      pg = "Te1/2-3"
      expect(type.parse_interface(pg)).to eq([["1"],"2-3","1"])
    end
    it "should parse with double stack, range, speed" do
      pg = "Po1/2/3-4"
      expect(type.parse_interface(pg)).to eq([["1","2"],"3-4","1/2"])
    end
  end
end

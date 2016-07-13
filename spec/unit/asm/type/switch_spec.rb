require 'spec_helper'
require 'asm/type/switch'

describe ASM::Type::Switch do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:raw_switches) { SpecHelper.json_fixture("switch_providers/switch_inventory.json") }

  let(:collection) { ASM::Service::SwitchCollection.new(logger) }
  let(:switch) { collection.switches.first }
  let(:provider) { switch.provider }

  let(:service) { SpecHelper.service_from_fixture("switch_providers/deployment.json") }
  let(:server_component) { service.components_by_type("SERVER").first }
  let(:server) { server_component.to_resource(nil, logger) }
  let(:dhcp_management_ip) { SpecHelper.load_fixture("switch_providers/dhcp_management_ip_snippet.txt") }
  let(:static_management_ip) { SpecHelper.load_fixture("switch_providers/static_management_ip_snippet.txt") }

  before(:each) do
    collection.stubs(:managed_inventory).returns(raw_switches)

    switch.stubs(:facts_find).returns(SpecHelper.json_fixture("switch_providers/%s_facts.json" % switch.puppet_certname))

    ASM::Service::SwitchCollection.stubs(:new).returns(collection)
  end

  describe "#hyperv_with_dedicated_intel_iscsi?" do
    it "should be false for non ISCSI SAN networks" do
      server.expects(:network_cards).never
      expect(switch.hyperv_with_dedicated_intel_iscsi?(stub(:type => "rspec"), server)).to be_falsey
    end

    it "should be false for non hyperv machines" do
      server.expects(:network_cards).never
      server.provider.os_image_type = "rspec"
      expect(switch.hyperv_with_dedicated_intel_iscsi?(stub(:type => "STORAGE_ISCSI_SAN"), server)).to be_falsey
    end

    it "should be false on machines with just 1 card" do
      server.stubs(:is_hyperv?).returns(true)
      network = stub(:type => "STORAGE_ISCSI_SAN")
      server.expects(:network_cards).returns([
        stub(:nic_info => stub(:product => "Intel Card"))
      ])

      expect(switch.hyperv_with_dedicated_intel_iscsi?(network, server)).to be_falsey
    end

    it "should be false on machines with non intel cards" do
      server.stubs(:is_hyperv?).returns(true)
      network = stub(:type => "STORAGE_ISCSI_SAN")
      server.expects(:network_cards).returns([
        stub(:nic_info => stub(:product => "Intel Card")),
        stub(:nic_info => stub(:product => "Rspec"))
      ])

      expect(switch.hyperv_with_dedicated_intel_iscsi?(network, server)).to be_falsey
    end

    it "should be true for intel on card 1" do
      server.stubs(:is_hyperv?).returns(true)
      network = stub(:type => "STORAGE_ISCSI_SAN")
      server.expects(:network_cards).returns([
        stub(:nic_info => stub(:product => "Intel Card")),
        stub(:nic_info => stub(:product => "Intel Card"))
      ])

      expect(switch.hyperv_with_dedicated_intel_iscsi?(network, server)).to be_truthy
    end
  end

  describe "#configured_boot" do
    it "should collect the correct boot lines" do
      expect(switch.configured_boot).to eq("boot system stack-unit 0 primary system: A:\nboot system stack-unit 0 secondary system: B:\nboot system stack-unit 0 default system: B:\nboot-type normal-reload")
    end
  end

  describe "#configured_credentials" do
    it "should collect the correct credetials" do
      expect(switch.configured_credentials).to eq(["username root password 7 d7acc8a1dcd4f698 privilege 15 role sysadmin"])
    end
  end

  describe "#configured_management_ip_information" do
    it "should detect the correct IP" do
      provider.stubs(:facts).returns({"running_config" => static_management_ip})
      expect(switch.configured_management_ip_information).to eq(["1.2.3.4", "24"])
    end

    it "should return nil when it cant detect it" do
      provider.stubs(:facts).returns({"running_config" => dhcp_management_ip})
      expect(switch.configured_management_ip_information).to be(nil)
    end
  end

  describe "#appliance_preferred_ip" do
    it "should request the IP via ASM::Util" do
      ASM::Util.expects(:get_preferred_ip).with("172.17.9.174").once.returns("1.2.1.2")
      expect(switch.appliance_preferred_ip).to eq("1.2.1.2")
    end
  end

  describe "#management_ip_configured?" do
    it "should find the existing configuration" do
      provider.stubs(:facts).returns({"running_config" => dhcp_management_ip})
      expect(switch.management_ip_configured?).to be_truthy

      provider.stubs(:facts).returns({"running_config" => static_management_ip})
      expect(switch.management_ip_configured?).to be_truthy
    end

    it "should correctly detect missing configs" do
      provider.stubs(:facts).returns({"running_config" => "rspec"})
      expect(switch.management_ip_configured?).to be_falsey
    end
  end

  describe "#management_ip_dhcp_configured?" do
    it "should find the existing configuration" do
      provider.stubs(:facts).returns({"running_config" => dhcp_management_ip})
      expect(switch.management_ip_dhcp_configured?).to be_truthy
    end

    it "should correctly detect missing configs" do
      provider.stubs(:facts).returns({"running_config" => static_management_ip})
      expect(switch.management_ip_dhcp_configured?).to be_falsey
    end
  end

  describe "#management_ip_static_configured?" do
    it "should find the existing configuration" do
      provider.stubs(:facts).returns({"running_config" => static_management_ip})
      expect(switch.management_ip_static_configured?).to be_truthy
    end

    it "should correctly detect missing configs" do
      provider.stubs(:facts).returns({"running_config" => dhcp_management_ip})
      expect(switch.management_ip_static_configured?).to be_falsey
    end
  end

  describe "#cert2ip" do
    it "should extract the correct desired ip" do
      expect(switch.cert2ip).to eq("172.17.9.174")
    end

    it "should return nil when the certname is not in the desired format" do
      switch.stubs(:puppet_certname).returns("rspec")
      expect(switch.cert2ip).to be(nil)
    end
  end

  describe "#configured_hostname" do
    it "should get the hostname from the running config" do
      expect(switch.configured_hostname).to eq("FTOS")
    end

    it "should return nil when not found" do
      provider.expects(:facts).returns({"running_config" => "rspec"})
      expect(switch.configured_hostname).to be(nil)
    end
  end

  describe "#iom_mode" do
    it "should fetch the iom mode" do
      provider.expects(:facts).returns("iom_mode" => "rspec")
      expect(switch.iom_mode).to eq("rspec")
    end

    it "should return an empty string when not known" do
      provider.expects(:facts).returns({})
      expect(switch.iom_mode).to eq("")
    end
  end

  describe "#vlt_mode?" do
    it "should correctly determine the vlt mode" do
      expect(switch.vlt_mode?).to be_falsey

      switch.expects(:iom_mode).returns("rspec_vlt")
      expect(switch.vlt_mode?).to be_truthy
    end
  end

  describe "#model" do
    it "should determine the correct model" do
      expect(switch.model).to eq("I/O-Aggregator")
    end
  end

  describe "#portchannel_members" do
    it "should retrieve the port channel memebers" do
      members = switch.portchannel_members

      expect(members).to be_a(Hash)
      expect(members.size).to be(1)
      expect(members).to include("128")
    end
  end

  describe "#vlan_information" do
    it "should retrieve the VLAN information" do
      vlans = switch.vlan_information

      expect(vlans).to be_a(Hash)
      expect(vlans.size).to be(4094)
    end
  end

  describe "#configured_network?" do
    let (:network) { stub(:type => "rspec") }
    let (:server) { stub(
        :boot_from_iscsi? => false,
        :is_hypervisor? => false,
        :razor_status => "rspec",
        :fcoe => false,
        :os_image_type => "rspec"
    )}

    it "should return false for FIP_SNOOPING" do
      network.expects(:type).returns("FIP_SNOOPING")
      expect(switch.configured_network?(network, server)).to eq(false)
    end

    it "should return true for non-FIP_SNOOPING" do
      network.expects(:type).returns("PUBLIC_LAN")
      expect(switch.configured_network?(network, server)).to eq(true)
    end
  end

  describe "#tagged_network?" do
    let (:server) { stub(
      :boot_from_iscsi? => false,
      :is_hypervisor? => false,
      :os_installed? => false,
      :fcoe? => false,
      :os_image_type => "rspec"
    )}

    let (:network) { stub(:type => "rspec") }

    it "should untag iscsi storage networks when booting from iscsi" do
      network.expects(:type).returns("STORAGE_ISCSI_SAN").twice
      server.expects(:boot_from_iscsi?).returns(true)
      expect(switch.tagged_network?(network, server)).to be_falsey
    end

    it "should untag non post installable servers" do
      server.expects(:is_hypervisor?).returns(false)
      server.stubs(:workload_network_vlans).returns(['20'])
      switch.stubs(:workload_network_count).returns(1)
      switch.stubs(:workload_with_pxe?).returns(false)
      expect(switch.tagged_network?(network, server)).to be_falsey
    end

    it "should tag non post installable servers" do
      server.expects(:is_hypervisor?).returns(false)
      server.stubs(:workload_network_vlans).returns(['20'])
      switch.stubs(:workload_network_count).returns(2)
      expect(switch.tagged_network?(network, server)).to be_truthy
    end

    it "should tag PXE networks for vmware fcoe servers post install" do
      network.expects(:type).returns("PXE").twice
      server.expects(:os_installed?).at_least_once.returns(true)
      server.expects(:is_hypervisor?).returns(true)
      server.expects(:fcoe?).returns(true)
      server.expects(:os_image_type).at_least_once.returns("vmware_esxi")
      expect(switch.tagged_network?(network, server)).to be_truthy
    end

    it "should untag all other PXE networks for non post OS installation" do
      network.expects(:type).returns("PXE").twice
      server.expects(:is_hypervisor?).returns(true)
      server.expects(:os_installed?).at_least_once.returns(false)
      expect(switch.tagged_network?(network, server)).to be_falsey
    end

    it "should tag non FIP SNOOPING based networks" do
      server.expects(:is_hypervisor?).returns(true)
      expect(switch.tagged_network?(network, server)).to be_truthy
    end

    it "should should fail on FIP_SNOOPING" do
      network = mock(:type => "FIP_SNOOPING", :name => "FIP", :vlanId => 1)
      expect { switch.tagged_network?(network, server) }.to raise_error("Network FIP VLAN 1 should not be configured")
    end
  end

  describe "#supported_post_os_tagged_network?" do
    let (:server) { stub(
        :boot_from_iscsi? => false,
        :is_hypervisor? => true,
        :os_installed? => false,
        :fcoe? => false,
        :os_image_type => "rspec"
    )}

    let (:network) { stub(:type => "rspec") }

    it "should tag PXE networks for vmware fcoe servers when server is installed" do
      network.expects(:type).returns("PXE")
      server.expects(:os_image_type).returns("vmware_esxi")
      server.expects(:fcoe?).returns(true)
      server.expects(:os_installed?).returns(true)
      expect(switch.supported_post_os_tagged_network?(network, server)).to be_truthy
    end

    it "should untag PXE networks for vmware fcoe servers when server is not installed" do
      network.expects(:type).returns("PXE")
      server.expects(:os_installed?).returns(false)
      server.stubs(:fcoe?).returns(true)
      server.stubs(:os_image_type).returns("vmware_esxi")
      expect(switch.supported_post_os_tagged_network?(network, server)).to be_falsey
    end

    it "should always untag PXE networks for non-vmware fcoe servers" do
      network.expects(:type).returns("PXE")
      expect(switch.supported_post_os_tagged_network?(network, server)).to be_falsey

      network.expects(:type).returns("PXE")
      server.stubs(:os_installed?).returns(true)
      expect(switch.supported_post_os_tagged_network?(network, server)).to be_falsey
    end

    it "should tag public network all networks when VMware in installed" do
      network.expects(:type).returns("PUBLIC_LAN")
      expect(switch.tagged_network?(network, server)).to be_truthy
    end

    it "should tag public network all networks when HyperV in installed" do
      network.expects(:type).returns("PUBLIC_LAN")
      expect(switch.tagged_network?(network, server)).to be_truthy
    end

    it "should untag iscsi network for hyperv diverged with Intel NIC configuration" do
      switch.expects(:hyperv_with_dedicated_intel_iscsi?).returns(true)
      expect(switch.tagged_network?(network, server)).to be_falsey
    end

    it "should tag iscsi network for hyperv diverged with non-Intel configuration" do
      switch.stubs(:hyperv_with_dedicated_intel_iscsi?).returns(false)
      expect(switch.tagged_network?(network, server)).to be_truthy
    end
  end

  describe "#bare_metal_tagged_network?" do
    let (:server) { stub(
        :boot_from_iscsi? => false,
        :is_hypervisor? => false,
        :razor_status => "rspec",
        :os_image_type => "rspec"
    )}

    let (:network) { stub(:type => "rspec") }

    it "should untag PXE network" do
      network.expects(:type).returns("PXE")
      server.expects(:os_installed?).returns(false)
      expect(switch.bare_metal_tagged_network?(network, server)).to be_falsey
    end

    it "should tag PXE network after OS installed" do
      network.expects(:type).returns("PXE")
      server.expects(:os_installed?).returns(true)
      expect(switch.bare_metal_tagged_network?(network, server)).to be_truthy
    end

    it "should tag workload network when server has multiple public networks" do
      network.expects(:type).returns("PUBLIC_LAN")
      server.stubs(:workload_network_vlans).returns(['2','3'])
      expect(switch.bare_metal_tagged_network?(network, server)).to be_truthy
    end

    it "should tag workload network when server has public networks mapped to multiple interfaces" do
      network.expects(:type).returns("PUBLIC_LAN")
      network.expects(:vlanId).returns('2').at_least(2)
      server.stubs(:workload_network_vlans).returns(['2'])
      server.stubs(:nic_teams).returns([{:networks => [network], :mac_addresses => ['mac1','mac2']}])
      expect(switch.bare_metal_tagged_network?(network, server)).to be_truthy
    end

    it "should untag workload network when server has public networks mapped to multiple interfaces" do
      network.expects(:type).returns("PUBLIC_LAN")
      network.expects(:vlanId).returns('2').at_least(2)
      server.stubs(:workload_network_vlans).returns(['2'])
      server.stubs(:nic_teams).returns([{:networks => [network], :mac_addresses => ['mac1']}])
      switch.stubs(:workload_with_pxe?).returns(false)
      expect(switch.bare_metal_tagged_network?(network, server)).to be_falsey
    end

    it "should tag workload network when PXE network is mapped " do
      network.expects(:type).returns("PUBLIC_LAN")
      network.expects(:vlanId).returns('2').at_least(2)
      server.stubs(:workload_network_vlans).returns(['2'])
      server.stubs(:nic_teams).returns([{:networks => [network], :mac_addresses => ['mac1']}])
      switch.stubs(:workload_with_pxe?).returns(true)
      expect(switch.bare_metal_tagged_network?(network, server)).to be_truthy
    end

  end

  describe "#workload_with_pxe?" do
    let (:server) { stub(
        :boot_from_iscsi? => false,
        :is_hypervisor? => false,
        :razor_status => "rspec",
        :os_image_type => "rspec",
        :network_config => "rspec"
    )}

    let (:network1) { stub(:type => "rspec") }
    let (:network2) { stub(:type => "rspec") }
    let (:public_partition) { stub(:type => "rspec") }
    let (:pxe_partition) { stub(:type => "rspec") }

    it "should return true when workload network is more than one partition" do
      network1.expects(:type).returns("PUBLIC_LAN")

      server.stubs(:workload_network_vlans).returns(['1'])
      server.stubs(:nic_teams).returns([{:networks => [network1, network2], :mac_addresses => ['mac1']}])
      server.network_config.stubs(:get_partitions).with("PUBLIC_LAN").returns([public_partition, public_partition])

      public_partition.stubs(:mac_address).returns('aa-bb-cc-dd-ee-ff')
      expect(switch.workload_with_pxe?(network1, server)).to be_truthy
    end

    it "should return false when there is no PXE network on any of the partitions" do
      network1.expects(:type).returns("PUBLIC_LAN")

      server.stubs(:workload_network_vlans).returns(['1'])
      server.stubs(:nic_teams).returns([{:networks => [network1], :mac_addresses => ['mac1']}])
      server.network_config.stubs(:get_partitions).with("PXE").returns([])
      server.network_config.stubs(:get_partitions).with("PUBLIC_LAN").returns([public_partition])

      expect(switch.workload_with_pxe?(network1, server)).to be_falsey
    end

  end

  describe "#workload_network_count" do
    let (:network) { stub(:type => "rspec") }

    it "should return count of public networks" do
      server.stubs(:nic_teams).returns([{:networks => [network], :mac_addresses => ['mac1']}])
      network.expects(:vlanId).returns('2').at_most(2)
      expect(switch.workload_network_count(network,server)).to be(1)
    end
  end

  describe "#find_mac" do
    before(:each) do
      switch.stubs(:update_inventory!)
      switch.stubs(:retrieve_facts!)
    end

    it "should not update the inventory when no inventory has been run and :update_inventory is not set" do
      switch.instance_variable_set("@inventory", nil)
      switch.expects(:update_inventory!).never
      provider.expects(:find_mac).with("rspec")
      switch.find_mac("rspec", :update_inventory => false)
    end

    it "should update the inventory when :update_inventory is set" do
      switch.instance_variable_set("@inventory", {})
      switch.expects(:update_inventory!)
      provider.expects(:find_mac).with("rspec")
      switch.find_mac("rspec", :update_inventory => true)
    end

    it "should not update inventory when inventory is set and update_inventory is false" do
      switch.instance_variable_set("@inventory", {})
      switch.expects(:update_inventory!).never
      provider.expects(:find_mac).with("rspec")
      switch.find_mac("rspec", :update_inventory => false)
    end

    it "should update the facts when :update_facts is set" do
      switch.expects(:retrieve_facts!)
      provider.expects(:find_mac).with("rspec")
      switch.find_mac("rspec", :update_facts => true)
    end

    it "should not update facts when :update_inventory or :update_facts is set" do
      switch.expects(:retrieve_facts!).never
      provider.expects(:find_mac).with("rspec")
      switch.find_mac("rspec", :update_facts => false)
    end

    it "should first update inventory then facts" do
      process = sequence("process")
      switch.expects(:update_inventory!).in_sequence(process)
      switch.expects(:retrieve_facts!).in_sequence(process)

      switch.find_mac("rspec", :update_inventory => true, :update_facts => false)
    end

    it "should delegate to the provider" do
      provider.expects(:find_mac).with("rspec")
      switch.find_mac("rspec")
    end

    context "should search server network_topology if server passed" do
      let(:mac) { "rspec-mac" }
      let(:server) { mock("rspec-server") }

      before(:each) do
        provider.expects(:find_mac).with(mac).returns(nil)
      end

      it "should return nil if not found in network_topology" do
        server.expects(:network_topology_cache).returns({})
        expect(switch.find_mac(mac, :server => server)).to be_nil
      end

      it "should return mac if found in network_topology" do
        interface = Hashie::Mash.new({:partitions => [{:mac_address => mac}]})
        server.expects(:network_topology_cache).returns({mac => [switch.puppet_certname, "Te 0/2"]})
        expect(switch.find_mac(mac, :server => server)).to eq("Te 0/2")
      end

      it "should not fail due to nil connectivity in network_topology" do
        server.expects(:network_topology_cache).returns({mac => nil})
        expect(switch.find_mac(mac, :server => server)).to be_nil
      end

      it "should return nil if mac found in different switch" do
        server.expects(:network_topology_cache).returns({"other-mac" => ["other-switch-cert", "Te 0/2"]})
        expect(switch.find_mac(mac, :server => server)).to be_nil
      end
    end
  end

  describe "#has_mac?" do
    it "should delegate all arguments to find_mac" do
      switch.expects(:find_mac).with("rspec", {"rspec" => 1})
      switch.has_mac?("rspec", {"rspec" => 1})
    end

    it "should turn the result into a boolean" do
      switch.expects(:find_mac).with("rspec").returns("rspec")
      expect(switch.has_mac?("rspec")).to be_truthy

      switch.expects(:find_mac).with("rspec").returns(nil)
      expect(switch.has_mac?("rspec")).to be_falsey
    end
  end

  describe "#validate_server_networking!" do
    it "should return true if switch is valid for all servers" do
      switch.expects(:connected_servers).returns([server])
      switch.expects(:validate_network_config).with(server).returns(true)
      expect(switch.validate_server_networking!).to be(true)
    end

    it "should return false if switch is invlaid for any of the servers" do
      validate = sequence("validate")
      second_server = server.dup
      switch.expects(:connected_servers).returns([server,second_server])
      switch.expects(:validate_network_config).with(server).returns(false)
      switch.expects(:validate_network_config).with(second_server).returns(true)
      expect(switch.validate_server_networking!).to be(false)
    end
  end
end

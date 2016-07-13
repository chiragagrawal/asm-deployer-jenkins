require "spec_helper"
require "asm/type"

ASM::Type.load_providers!

describe ASM::Provider::Configuration::Force10 do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:deployment) { stub(:id => "1234", :is_teardown? => true, :debug? => false, :log => nil) }
  let(:raw_network_info) { SpecHelper.json_fixture("configuration_swimlane_deployment_get_network_info.json") }
  let(:chassis_inventory) { SpecHelper.json_fixture("switch_providers/chassis_inventory.json") }
  let(:iomsdata) {SpecHelper.json_fixture("switch_providers/iomsdata.json")}
  let(:service) { SpecHelper.service_from_fixture("configuration_swimlane_deployment.json") }
  let(:force10_components) { service.components.select { |c| c.resource_ids.include?("asm::iom::uplink") } }
  let(:type) { force10_components[0].to_resource(deployment, logger) }
  let(:provider) { type.provider }
  let (:facts) { {"chassis_service_tag" => "ENV05C1", "m " => "172.17.2.190"} }
  let(:uplinks) { [{"uplinkId" => "42BB181B-C357-4777-9AD9-493A5987EB79", "uplinkName" => "Uplink 1", "portChannel" => "128", "portMembers" => ["Te 0/44"], "portNetworks" => ["ff80808153d35b230153d365d8210000"]}, {"uplinkId" => "EDDD31B2-15E8-4552-8D33-A5D076D15740", "uplinkName" => "Uplink 2", "portChannel" => "18", "portMembers" => ["Te 0/37"], "portNetworks" => ["ff80808153d35b230153d3663d220001"]}]
  }

  context "when managing desired vlans and port channels" do
    let(:switch_provider) { stub(:portchannel_resource => nil, :mxl_interface_resource => nil) }
    let(:switch) {
      stub(
          :portchannel_members => {
              "128" => {:interfaces => ["TenGigabitEthernet 0/33", "TenGigabitEthernet 0/1"], :vlans => ["18", "20"], :fcoe => false},
              "129" => {:interfaces => ["TenGigabitEthernet 0/10", "TenGigabitEthernet 0/11"], :vlans => ["20", "22"], :fcoe => false},
              "128" => {:interfaces => ["TenGigabitEthernet 0/33", "TenGigabitEthernet 0/1"], :vlans => ["18", "20"], :fcoe => false, :vltpeer => true}
          },
          :vlan_information => {
              "1" => {}, # only the keys are used not hash contents
              "18" => {},
              "20" => {},
              "22" => {},
          },
          :facts => {"quad_port_interfaces" => ["33", "37"]},
          :provider => switch_provider
      )
    }

    before(:each) do
      ASM::PrivateUtil.stubs(:get_network_info).returns(raw_network_info)
      provider.stubs(:switch).returns(switch)
    end

    describe "add port-channel and back-up link ip for vlt " do
      let(:chassis_service_tag) { "ENV05C1" }
      let(:device_ip) { "172.17.2.190" }
      let(:iomresult) { {"id" => "ff808081548816b40154c96e4bdd2344", "managementIP" => "172.17.2.190", "managementIPStatic" => false, "serviceTag" => "9BQQTS1", "health" => "GREEN", "model" => "PowerEdge M I/O Aggregator", "slot" => 4, "location" => "B2", "supported" => true} }
      it "should add port-channel for vltdata " do
        port_channel = provider.vlt_port_channel
        expect(port_channel).to eq(127)
      end

      it "should get backup ip address and device_id" do
        provider.stubs(:cmc_inventory).with(chassis_service_tag).returns(chassis_inventory)
        provider.stubs(:iom).returns(iomresult)
        provider.stubs(:chassis_ioms).returns(iomsdata)
        expect(provider.backup_link_ip_for_vlt).to eq (["0","172.17.2.223"])
      end

      it "should get current iom infromation in hash" do
      provider.stubs(:switch).returns(stub(:facts => {"management_ip" => device_ip, "chassis_service_tag" => chassis_service_tag}))
      provider.stubs(:cmc_inventory).with(chassis_service_tag).returns(chassis_inventory)
      expect(provider.iom).to eq (iomresult)
      end

      it "should get chassis_iom infromation in hash excluding current" do
        provider.stubs(:switch).returns(stub(:facts => {"management_ip" => device_ip, "chassis_service_tag" => chassis_service_tag}))
        provider.stubs(:cmc_inventory).with(chassis_service_tag).returns(chassis_inventory)
        expect(provider.chassis_ioms).to eq (iomsdata)
      end

    end

    describe "#pmux_mode?" do
      it "should be false when there are no uplinks" do
        provider.uplinks = []
        expect(provider.pmux_mode?).to be(false)

        provider.uplinks = nil
        expect(provider.pmux_mode?).to be(false)
      end

      it "should be false when vlt mode is requested" do
        provider.expects(:vlt_mode?).returns(true)
        expect(provider.pmux_mode?).to be(false)
      end

      it "should be true for IOA blade models" do
        switch_provider.stubs(:blade_ioa_switch?).returns(true)
        expect(provider.pmux_mode?).to be(true)
      end
    end

    describe "#configure_quadportmode" do
      it "should support unconfiguring quadmode" do
        provider.quadportmode = false
        provider.uplinks = nil
        switch_provider.expects(:configure_quadmode).with(nil, false, true)
        provider.configure_quadportmode
      end

      it "should support configuring quadmode with specific uplinks" do
        provider.quadportmode = true
        provider.uplinks = [{"portMembers" => ["1"]}, {"portMembers" => ["2"]}]
        switch_provider.expects(:configure_quadmode).with(["1", "2"], true, true)
        provider.configure_quadportmode
      end

      it "should support configuring quadmode based on facts when uplinks are not given" do
        provider.quadportmode = true
        provider.uplinks = nil
        switch_provider.expects(:configure_quadmode).with(nil, true, true)
        provider.configure_quadportmode
      end
    end

    describe "#vlans_from_desired" do
      it "should get the correct vlans" do
        expect(provider.vlans_from_desired(provider.desired_port_channels)).to eq(["20", "22", "23", "25"])
      end
    end

    describe "#vlan_portchannels_from_desired" do
      it "should get the correct port channels" do
        expect(provider.vlan_portchannels_from_desired(provider.desired_port_channels, "22")).to eq(["128"])
        expect(provider.vlan_portchannels_from_desired(provider.desired_port_channels, "10")).to eq([])
      end
    end

    describe "#configure_vlans" do
      it "should add desired VLANs and remove undesired ones from MXLs" do
        switch.stubs(:model).returns("MXL")
        switch_provider.expects(:mxl_vlan_resource).with("20", "PXE", "PXE", ["128"])
        switch_provider.expects(:mxl_vlan_resource).with("22", "Workload-22", "Workload-22", ["128"])
        switch_provider.expects(:mxl_vlan_resource).with("23", "LiveMigration", "LiveMigration", ["128"])
        switch_provider.expects(:mxl_vlan_resource).with("25", "PXE_Env04", "PXE_Env04", ["128"])
        switch_provider.expects(:mxl_vlan_resource).with("18", "", "", [], true)

        switch_provider.expects(:ioa_interface_resource).with("po 128", ["20", "22", "23", "25"], [])

        provider.configure_vlans
      end

      it "should add desired VLANs and interfaces on IOAs" do
        switch.stubs(:model).returns("Aggregator")
        switch_provider.expects(:mxl_vlan_resource).with("20", "PXE", "PXE", [])
        switch_provider.expects(:mxl_vlan_resource).with("22", "Workload-22", "Workload-22", [])
        switch_provider.expects(:mxl_vlan_resource).with("23", "LiveMigration", "LiveMigration", [])
        switch_provider.expects(:mxl_vlan_resource).with("25", "PXE_Env04", "PXE_Env04", [])

        switch_provider.expects(:ioa_interface_resource).with("po 128", ["20", "22", "23", "25"], [])

        provider.configure_vlans
      end

      it "should add desired vlans for fnioa when it is in full_switch_mode" do
        switch.stubs(:model).returns("PE-FN-410S-IOM")
        provider.stubs(:vlt_mode?).returns(true)
        switch_provider.expects(:mxl_vlan_resource).with("20", "PXE", "PXE", ["128"])
        switch_provider.expects(:mxl_vlan_resource).with("22", "Workload-22", "Workload-22", ["128"])
        switch_provider.expects(:mxl_vlan_resource).with("23", "LiveMigration", "LiveMigration", ["128"])
        switch_provider.expects(:mxl_vlan_resource).with("25", "PXE_Env04", "PXE_Env04", ["128"])
        provider.configure_vlans
      end

      it "should remove unused vlans when uplinks is not requested" do
        provider.uplinks = nil
        switch.stubs(:model).returns("MXL")
        switch_provider.expects(:mxl_vlan_resource).with("18", "", "", [], true)
        switch_provider.expects(:mxl_vlan_resource).with("20", "", "", [], true)
        switch_provider.expects(:mxl_vlan_resource).with("22", "", "", [], true)
        provider.configure_vlans
      end

    end

    describe "#configure_port_channels" do

      let(:fnioaswitch_provider){stub(:portchannel_resource => nil)}
      let(:fnioaswitch){ stub(
          :portchannel_members => {"1"=>["TenGigabitEthernet 0/11", "TenGigabitEthernet 0/35"]},
          :provider => fnioaswitch_provider
      )}

      it "Should not remove interface port if it is reused with other port-channel" do
        provider.stubs(:switch).returns(fnioaswitch)
        provider.expects(:desired_port_channels).returns({"1"=>{:interfaces=>["TenGigabitEthernet 0/12"], :vlans=>["26", "20"], :fcoe=>false}, "110"=>{:interfaces=>["TenGigabitEthernet 0/11"], :vlans=>["28", "16"], :fcoe=>false}})
        fnioaswitch_provider.expects(:mxl_interface_resource).with('TenGigabitEthernet 0/12', '1')
        fnioaswitch_provider.expects(:mxl_interface_resource).with('TenGigabitEthernet 0/11', '110')
        fnioaswitch_provider.expects(:mxl_interface_resource).with('TenGigabitEthernet 0/35', '0')
        fnioaswitch_provider.expects(:mxl_interface_resource).never.with('TenGigabitEthernet 0/11', '0')
        provider.configure_port_channels
      end

      it "should create portchannel resources for every port channel" do
        switch_provider.expects(:portchannel_resource).with("128", false, false, false)
        provider.configure_port_channels
      end

      it "should create portchannel resources for every port channel when vltmode is true" do
        provider.stubs(:vlt_mode?).returns(true)
        switch_provider.expects(:portchannel_resource).with("128", false, false, true)
        provider.configure_port_channels
      end

      it "should create and remove interface resources for Port Channel members" do
        (33..40).each do |i|
          switch_provider.expects(:mxl_interface_resource).with("TenGigabitEthernet 0/%s" % i, "128")
        end

        switch_provider.expects(:mxl_interface_resource).with("TenGigabitEthernet 0/1", "0")

        provider.configure_port_channels
      end

      it "should remove unmanaged port channels" do
        switch_provider.expects(:portchannel_resource).with("129", false, true)
        provider.configure_port_channels
      end

      it "should not do anything when no uplinks is specified" do
        provider.uplinks = nil
        provider.expects(:desired_port_channels).never
        provider.configure_port_channels
      end
    end
  end

  describe "#uplink_networks" do
    it "should collect the correct networks" do
      ASM::PrivateUtil.stubs(:get_network_info).returns(raw_network_info)
      networks = provider.uplink_networks(provider.uplinks[0])
      expect(networks.map { |n| n["vlanId"] }).to eq([20, 23, 22, 25])
    end
  end

  describe "#uplink_vlans" do
    it "should collect the right VLAN IDs" do
      ASM::PrivateUtil.stubs(:get_network_info).returns(raw_network_info)
      expect(provider.uplink_vlans(provider.uplinks[0])).to eq(["20", "23", "22", "25"])
    end
  end

  describe "#nonquadport_member_interfaces" do
    it "should return parsed data from the quad_port_interfaces fact" do
      provider.stubs(:switch).returns(stub(:facts => {"quad_port_interfaces" => ["33", "37"]}))
      expect(provider.nonquadport_member_interfaces(["Fo 0/33", "Fo 0/37"])).to eq(["Te 0/33", "Te 0/34", "Te 0/35", "Te 0/36", "Te 0/37", "Te 0/38", "Te 0/39", "Te 0/40"])
    end

    it "should keep non member interfaces on the list" do
      provider.stubs(:switch).returns(stub(:facts => {"quad_port_interfaces" => ["33", "37"]}))
      expect(provider.nonquadport_member_interfaces(["Fo 0/33", "Te 0/1"])).to eq(["Te 0/1", "Te 0/33", "Te 0/34", "Te 0/35", "Te 0/36"])
    end
  end

  describe "#member_interfaces" do
    it "should support quad port mode" do
      provider.quadportmode = true
      provider.expects(:quadport_member_interfaces).with(["Te 0/1"])
      provider.member_interfaces(["Te 0/1"])
    end

    it "should support non quad port mode" do
      provider.quadportmode = false
      provider.expects(:nonquadport_member_interfaces).with(["Te 0/1"])
      provider.member_interfaces(["Te 0/1"])
    end
  end

  describe "#desired_port_channels" do
    let(:expected) { {"128" => {:interfaces => (33..40).map { |i| "TenGigabitEthernet 0/%s" % i }, :vlans => ["20", "23", "22", "25"], :fcoe => false}} }
    let(:expectedvlt) { {"128" => {:interfaces => (33..40).map { |i| "TenGigabitEthernet 0/%s" % i }, :vlans => ["20", "23", "22", "25"], :fcoe => false}} }

    before(:each) do
      ASM::PrivateUtil.stubs(:get_network_info).returns(raw_network_info)
      provider.stubs(:switch).returns(stub(:facts => {"quad_port_interfaces" => ["33", "37"]}))
    end

    it "should set interfaces by parsing existing quad interfaces" do
      provider.expects(:member_interfaces).with(["Fo 0/37", "Fo 0/33"]).returns(["Te 0/33", "Te 0/34", "Te 0/35", "Te 0/36", "Te 0/37", "Te 0/38", "Te 0/39", "Te 0/40"])
      provider.desired_port_channels
    end

    it "should calculate the correct desired interfaces" do
      expect(provider.desired_port_channels).to eq(expected)
    end

    it "should calculate the correct desired interfaces" do
      provider.stubs(:vlt_mode?).returns(true)
      expect(provider.desired_port_channels).to eq(expectedvlt)
    end

    it "should detect fcoe networks" do
      provider.expects(:uplink_has_network_of_type?).with(provider.uplinks[0], "storage_fcoe_san").returns(true)
      expected["128"][:fcoe] = true
      expect(provider.desired_port_channels).to eq(expected)
    end

    it "should support network interfaces not in quad groups" do
      provider.stubs(:switch).returns(stub(:facts => {"quad_port_interfaces" => []}))
      desired = provider.desired_port_channels
      expect(desired["128"][:interfaces]).to eq(["fortyGigE 0/33", "fortyGigE 0/37"])
    end

    it "should return a empty hash when uplinks isnt set" do
      provider.uplinks = nil
      expect(provider.desired_port_channels).to eq({})
    end
  end

  describe "#vlan_name" do
    it "should get the right name" do
      ASM::PrivateUtil.stubs(:get_network_info).returns(raw_network_info)

      expect(provider.vlan_name(20)).to eq("PXE")
      expect(provider.vlan_name("20")).to eq("PXE")

      expect(provider.vlan_name(23)).to eq("LiveMigration")
      expect(provider.vlan_name("23")).to eq("LiveMigration")
    end
  end

  describe "#vlan_description" do
    it "should get the right name" do
      ASM::PrivateUtil.stubs(:get_network_info).returns(raw_network_info)

      provider.asm_networks.first["description"] = "rspec"

      expect(provider.vlan_description(20)).to eq("rspec")
      expect(provider.vlan_description("20")).to eq("rspec")

      expect(provider.vlan_description(23)).to eq("LiveMigration")
      expect(provider.vlan_description("23")).to eq("LiveMigration")
    end
  end

  describe "#parse_interface" do
    it "should return correct match data" do
      int = provider.parse_interface("Fo 1/10")

      expect(int[:type]).to eq("Fo")
      expect(int[:unit]).to eq("1")
      expect(int[:interface]).to eq("10")
    end
  end

  describe "#quadport_for_members" do
    it "should calculate the correct interface" do
      [(33..36), (37..40), (41..44), (45..48), (49..52), (53..56)].each do |group|
        group.each do |int|
          expect(provider.quadport_for_members("Te 0/%s" % int.to_s)).to eq(["Fo 0/%s" % group.first])
          expect(provider.quadport_for_members("Te 1/%s" % int.to_s)).to eq(["Fo 1/%s" % group.first])
        end
      end

      expect(provider.quadport_for_members(["Te 0/1", "Te 0/33"])).to eq(["Fo 0/1", "Fo 0/33"])
    end
  end

  describe "#quadport_member_interfaces" do
    it "should correctly convert quad port names" do
      fo_1 = ["Te 0/1", "Te 0/2", "Te 0/3", "Te 0/4"]
      fo_2 = ["Te 0/2", "Te 0/3", "Te 0/4", "Te 0/5"]
      fo_37 = ["Te 0/37", "Te 0/38", "Te 0/39", "Te 0/40"]

      combo = [fo_1 + fo_2].flatten.sort.uniq

      expect(provider.quadport_member_interfaces("Fo 0/1")).to eq(fo_1)
      expect(provider.quadport_member_interfaces("Fo 0/2")).to eq(fo_2)
      expect(provider.quadport_member_interfaces("Fo 0/37")).to eq(fo_37)

      expect(provider.quadport_member_interfaces(["Fo 0/1", "Fo 0/2"])).to eq(combo)
    end

    it "should return non conventional quad interface names verbatim" do
      expect(provider.quadport_member_interfaces("Te 0/1")).to eq(["Te 0/1"])
    end

    it "should support a mix of parsed and verbatim ports without causing dupes" do
      expect(provider.quadport_member_interfaces(["Fo 0/1", "Te 0/1"])).to eq(["Te 0/1", "Te 0/2", "Te 0/3", "Te 0/4"])
      expect(provider.quadport_member_interfaces(["Fo 0/1", "Te 0/100"])).to eq(["Te 0/1", "Te 0/100", "Te 0/2", "Te 0/3", "Te 0/4"])
    end
  end

  describe "#configure_force10_settings!" do
    it "should configure the switch settings when settings are found" do
      settings = type.component_configuration.merge({"force10_settings" => {type.puppet_certname => {"config_file" => "/some/file", "spanning_tree_mode" => "pvst"}}})
      type.stubs(:component_configuration).returns(settings)

      switch = stub(:provider => mock)
      switch.provider.expects(:configure_force10_settings).with(settings["force10_settings"][type.puppet_certname])
      provider.expects(:switch).returns(switch)
      provider.config_file = "/some/file"

      expect(provider.configure_force10_settings!).to be(true)
    end

    it "should return false when no config file was used" do
      settings = type.component_configuration.merge({"force10_settings" => {type.puppet_certname => {"hostname" => "rspec"}}})
      type.stubs(:component_configuration).returns(settings)

      switch = stub(:provider => mock)
      switch.provider.expects(:configure_force10_settings).with(settings["force10_settings"][type.puppet_certname])
      provider.expects(:switch).returns(switch)
      provider.config_file = nil

      expect(provider.configure_force10_settings!).to be(false)
    end
  end

  describe "#initialize_ports!" do
    it "should initialize the switch under configuration" do
      provider.expects(:switch).returns(mock(:initialize_ports! => true))
      expect(provider.initialize_ports!).to be(true)
    end
  end

  describe "#asm_networks" do
    it "should fetch and cache the ASM networks" do
      ASM::PrivateUtil.expects(:get_network_info).returns(raw_network_info).once
      expect(provider.asm_networks).to eq(raw_network_info)
      expect(provider.asm_networks).to eq(raw_network_info)
    end
  end

  describe "uplink_has_network_type?" do
    it "should types correctly" do
      provider.stubs(:asm_networks).returns(raw_network_info)

      ["PXE", "HYPERVISOR_MIGRATION", "PUBLIC_LAN"].each do |n_type|
        expect(provider.uplink_has_network_of_type?(provider.uplinks[0], n_type)).to eq(true)
      end

      expect(provider.uplink_has_network_of_type?(provider.uplinks[0], "rspec")).to eq(false)
    end
  end

  describe "#uplink_networks" do
    it "should fetch the correct networks from the appliance" do
      provider.stubs(:asm_networks).returns(raw_network_info)
      networks = provider.uplink_networks(provider.uplinks[0])
      network_ids = networks.map { |n| n["id"] }

      expect(network_ids.sort).to eq(provider.uplinks[0]["portNetworks"].sort)
    end
  end

  describe "#ioa_ethernet_mode?" do
    it "should be false for non pmux mode switches" do
      provider.expects(:pmux_mode?).returns(false)
      expect(provider.ioa_ethernet_mode?).to be(false)
    end

    it "should be false for non 2210 switches" do
      provider.stubs(:switch).returns(
          stub(
              :model => "IOA",
              :provider => stub(:blade_ioa_switch? => true)
          )
      )

      expect(provider.ioa_ethernet_mode?).to be(false)
    end

    # needs fixtures
    it "should detect invalid FC confiruation"
    it "should detect correct ioa mode"
  end

  describe "#vlt_update_munger" do
    it "should JSON parse strings" do
      provider.vlt = '{"rspec":1}'
      expect(provider.vlt).to eq("rspec" => 1)
    end
  end

  describe "#uplinks_update_munger" do
    it "should expand uplink information correctly" do
      uplinks = JSON.parse(type.component_configuration["asm::iom::uplink"][type.puppet_certname]["uplinks"])
      expect(uplinks).to eq(["2FD6DC51-0CBD-43B3-ACB0-C26081975E8F"])

      uplink = JSON.parse(type.component_configuration["asm::iom::uplink"][type.puppet_certname]["2fd6dc51-0cbd-43b3-acb0-c26081975e8f"])

      expect(provider.uplinks).to eq([uplink])
    end
  end

  describe "#vlt_mode?" do
    it "should correctly determine vlt mode" do
      provider.vlt = {}
      expect(provider.vlt_mode?).to be(false)
      provider.vlt = {"rspec" => 1}
      expect(provider.vlt_mode?).to be(true)
    end
  end
end

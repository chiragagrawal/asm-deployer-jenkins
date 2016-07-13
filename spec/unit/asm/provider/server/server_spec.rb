require 'spec_helper'
require 'asm/type'

ASM::Type.load_providers!

describe ASM::Provider::Server::Server do
  let(:service) { SpecHelper.service_from_fixture("Teardown_EQL_VMware_Cluster.json") }
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:deployment) { stub(:id => "1234", :is_teardown? => true, :debug? => false, :log => nil, :logger => logger) }
  let(:volume_components) { service.components_by_type("STORAGE") }
  let(:server_components) { service.components_by_type("SERVER") }
  let(:cluster_components) { service.components_by_type("CLUSTER") }
  let(:server_component) { server_components.first }

  let(:type) { server_component.to_resource(deployment, logger) }
  let(:provider) { type.provider }

  let(:server_hostname) { server_component.configuration["asm::server"].to_a[0][1]["os_host_name"] }
  let(:server_puppet_certname) { server_component.configuration["asm::server"].to_a[0][0] }
  let(:wsman) { stub(:host => "rspec.wsman.host") }

  before(:each) do
    ASM::NetworkConfiguration.any_instance.stubs(:add_nics!)
    provider.stubs(:wsman).returns(wsman)
  end

  describe "#bios_settings" do
    it "should get the correct bios settings" do
      settings = server_component.resource_by_id("asm::bios").configuration["asm::bios"][type.puppet_certname]
      settings.delete("bios_configuration")
      settings.delete("ensure")

      expect(provider.bios_settings).to eq(settings)
    end
  end

  describe "#model" do
    it "should get the model from the inventory" do
      type.expects(:retrieve_inventory).returns("model" => "rspec model 123")
      expect(provider.model).to eq("rspec model 123")
    end
  end

  describe "#enabled_cards" do
    it "should find all enabled cards" do
      enabled = stub(:disabled => false)
      disabled = stub(:disabled => true)

      provider.stubs(:nic_info).returns(stub(:cards => [enabled, disabled]))
      expect(provider.enabled_cards).to eq([enabled])
    end
  end

  describe "#static_boot_eligible?" do
    it "should only report true for all intel machines" do
      provider.stubs(:enabled_cards).returns([
        stub(:ports => [stub(:vendor => :intel)]),
        stub(:ports => [stub(:vendor => :rspec)])
      ])

      expect(provider.static_boot_eligible?).to be_falsey

      provider.stubs(:enabled_cards).returns([
        stub(:ports => [stub(:vendor => :intel)]),
        stub(:ports => [stub(:vendor => :intel)])
      ])

      expect(provider.static_boot_eligible?).to be_truthy
    end
  end

  describe "#build_ipxe!" do
    it "should build the pxe using the builder" do
      ASM::IpxeBuilder.expects(:build).with(type.network_config, 0, "/var/lib/razor/repo-store/asm/generated/ipxe-rspec.wsman.host.iso")
      wsman.stubs(:nic_views).returns([])
      provider.build_ipxe!
    end
  end

  describe "#boot_ipxe!" do
    it "should boot the given uri" do
      provider.wsman.expects(:boot_rfs_iso_image).with(:uri => "rspec:uri", :reboot_job_type => :power_cycle)
      provider.boot_ipxe!("rspec:uri")
    end
  end

  describe "#build_and_boot_from_ipxe!" do
    it "should build and boot the iso" do
      provider.expects(:build_ipxe!).returns(["path", "uri"])
      provider.expects(:boot_ipxe!).with("uri")
      provider.build_and_boot_from_ipxe!
    end
  end

  describe "#enable_pxe" do
    it "should only accept deploys with PXE" do
      type.expects(:pxe_partitions).returns([])

      expect{
        provider.enable_pxe
      }.to raise_error("No PXE partition found for OS installation on bladeserver-15kvd42")
    end

    it "should only accept static deploys on eligible hardware" do
      type.expects(:static_pxe?).returns(true)
      provider.expects(:static_boot_eligible?).returns(false)

      expect{
        provider.enable_pxe
      }.to raise_error("Static OS installation is only supported on servers with all Intel NICs, cannot enable PXE on bladeserver-15kvd42")
    end

    it "should support static boot hardware" do
      type.stubs(:static_pxe?).returns(true)
      provider.stubs(:static_boot_eligible?).returns(true)
      provider.expects(:build_and_boot_from_ipxe!)
      provider.enable_pxe
    end

    it "should require a fqdd for non static hardware" do
      type.stubs(:static_pxe?).returns(false)
      provider.stubs(:static_boot_eligible?).returns(false)
      expect {
        provider.enable_pxe
      }.to raise_error("Failed to enable PXE boot on bladeserver-15kvd42 - cannot determine FQDD for PXE partition")
    end

    it "should support non static hardware" do
      type.stubs(:static_pxe?).returns(false)
      provider.stubs(:static_boot_eligible?).returns(false)
      type.stubs(:pxe_partitions).returns([stub(:fqdd => "rspec::fqdd")])

      provider.wsman.expects(:set_boot_order).with("rspec::fqdd", :reboot_job_type => :power_cycle)

      provider.enable_pxe
    end
  end

  describe "#disable_pxe" do
    it "should set the boot order and disconnect the ido" do
      provider.wsman.expects(:set_boot_order).with(:hdd, :reboot_job_type => :graceful_with_forced_shutdown)
      provider.expects(:disconnect_rfs_iso)
      provider.disable_pxe
    end
  end

  describe "#disconnect_rfs_iso" do
    it "should not reomve the ISO if not connected" do
      provider.wsman.expects(:rfs_iso_image_connection_info).returns(:return_value => "1")
      provider.wsman.expects(:disconnect_rfs_iso_image).never
      provider.disconnect_rfs_iso
    end

    it "should remove it if connected" do
      provider.wsman.expects(:rfs_iso_image_connection_info).returns(:return_value => "0")
      provider.wsman.expects(:disconnect_rfs_iso_image)
      provider.disconnect_rfs_iso
    end
  end

  describe "#fcoe_wwpns" do
    it "should get the wwpns from the fcoe_interfaces" do
      provider.expects(:fcoe_fqdds).returns(["rspec:1", "rspec:2"])
      provider.expects(:fcoe_interfaces).returns({
        "rspec:1" => {"wwpn" => "wwpn:1"},
        "rspec:2" => {"wwpn" => "wwpn:2"},
        "rspec:3" => {"wwpn" => "wwpn:3"}
      })

      expect(provider.fcoe_wwpns).to eq(["wwpn:1", "wwpn:2"])
    end
  end

  describe "#fcoe_fqdds" do
    it "should extract the fqdd from the san partitions" do
      type.expects(:fcoe_san_partitions).returns([{"fqdd" => "rspec:1"}, {"fqdd" => "rspec:2"}])
      expect(provider.fcoe_fqdds).to eq(["rspec:1", "rspec:2"])
    end
  end

  describe "#fcoe_interfaces" do
    it "should turn each restult into a mash" do
      provider.stubs(:fcoe_views).returns({
        "NIC.Integrated.1-1-1"=>{"wwpn"=>"20:01:74:86:7A:EF:48:31"},
        "NIC.Integrated.1-2-4"=>{"wwpn"=>"20:01:74:86:7A:EF:48:3F"}
      })

      expect(provider.fcoe_interfaces.size).to be(2)
      expect(provider.fcoe_interfaces[0]).to be_a(Hashie::Mash)
      expect(provider.fcoe_interfaces[1]).to be_a(Hashie::Mash)
      expect(provider.fcoe_interfaces[0].wwpn).to eq("20:01:74:86:7A:EF:48:31")
    end
  end

  describe "#fc_wwpns" do
    it "should get the wwpns from the fc_interfaces" do
      provider.expects(:fc_interfaces).returns([stub(:wwpn => "rspec:1"), stub(:wwpn => "rspec:2")])
      expect(provider.fc_wwpns).to eq(["rspec:1", "rspec:2"])
    end
  end

  describe "#fc_interfaces" do
    it "should turn each result into a Mash" do
      wsman.stubs(:fc_views).returns([:rspec => "test"])
      expect(provider.fc_interfaces.size).to be(1)
      expect(provider.fc_interfaces[0]).to be_a(Hashie::Mash)
      expect(provider.fc_interfaces[0].rspec).to eq("test")
    end
  end

  describe "#should_inventory?" do
    it "should only do inventories when there is a guid" do
      expect(provider.should_inventory?).to be(true)

      type.expects(:guid).returns(nil)
      expect(provider.should_inventory?).to be(false)
    end
  end

  describe "#update_inventory" do
    it "should update using update_asm_inventory" do
      ASM::PrivateUtil.expects(:update_asm_inventory).with(server_component.guid)
      provider.update_inventory
    end

    it "should fail without a guid" do
      type.expects(:guid).returns(nil)
      expect { provider.update_inventory }.to raise_error("Cannot update inventory for bladeserver-15kvd42 without a guid")
    end
  end

  describe "#network_params" do
    it "should return the params when present" do
      expect(type.network_params).to eq(server_component.resource_by_id("asm::esxiscsiconfig").parameters)
    end

    it "should return empty otherwise" do
      server_component.expects(:resource_by_id).with("asm::esxiscsiconfig").returns(nil)
      expect(type.network_params).to eq({})
    end
  end

  describe "when tearing down" do
    describe "#to_puppet" do
      it "should prepare the correct teardown hash" do
        teardown_hash = {
            'asm::server' => {server_puppet_certname => {
              'admin_password' => 'ff8080814dbf2d1d014ddcc519673595',
              'broker_type' => 'noop',
              'decrypt' => true,
              'ensure' => 'absent',
              'esx_mem' => 'false',
              'installer_options' => {
                  "ntp_server" => "172.20.0.8",
                  "os_type" => "vmware_esxi",
                  "agent_certname" => "agent-esx2ip1",
                  "network_configuration" => type.network_config.to_hash.to_json,
              },
              "local_storage_vsan" => false,
              'os_host_name' => server_hostname,
              'os_image_type' => 'vmware_esxi',
              'policy_name' => 'policy-esx2ip1-1234',
              'razor_api_options' => {'url' => 'http://asm-razor-api:8080/api'},
              'razor_image' => 'esxi-5.5',
              'serial_number' => '15KVD42',}
            }
        }

        expect(provider.to_puppet["asm::server"]).to eq(teardown_hash["asm::server"])
      end
    end
  end

  describe "#create_idrac_resource" do
    it "should create the correct idrac controller resource" do
      idrac = provider.create_idrac_resource

      expect(idrac).to be_a(ASM::Type::Controller)
      expect(idrac.provider).to be_a(ASM::Provider::Controller::Idrac)
      expect(idrac.puppet_certname).to eq(type.puppet_certname)
    end
  end

  describe "#cluster_supported?" do
    it "should check hyperv is configured correctly do" do
      provider.expects(:configured_for_hyperv?).returns(false)
      expect(provider.configured_for_hyperv?).to be(false)

      provider.expects(:configured_for_hyperv?).returns(true)
      expect(provider.configured_for_hyperv?).to be(true)
    end

    it "should support other clusters by default" do
      expect(provider.cluster_supported?(stub(:provider_path => "rspec"))).to be(true)
    end
  end

  describe "#configured_for_hyperv?" do
    it "should correctly detect missing properties" do
      needed = ASM::Provider::Cluster::Scvmm::SERVER_REQUIRED_PROPERTIES

      provider.stubs(:to_hash).with(true, :hyperv).returns({needed.first => "foo"})
      logger.expects(:warn).with("Server bladeserver-15kvd42 is not supported by HyperV as it lacks these properties or they have nil values: %s" % [needed[1..-1].join(", ")])

      expect(provider.configured_for_hyperv?).to eq(false)
    end

    it "should detect nil values" do
      needed = ASM::Provider::Cluster::Scvmm::SERVER_REQUIRED_PROPERTIES
      has = Hash[needed[1..-1].map {|k| [k, "rspec"]}]

      provider.stubs(:to_hash).with(true, :hyperv).returns(has)
      logger.expects(:warn).with("Server bladeserver-15kvd42 is not supported by HyperV as it lacks these properties or they have nil values: %s" % [needed.first])

      expect(provider.configured_for_hyperv?).to eq(false)
    end

    it "should report ok when there are no missing values" do
      needed = ASM::Provider::Cluster::Scvmm::SERVER_REQUIRED_PROPERTIES
      has = Hash[needed.map {|k| [k, "rspec"]}]

      provider.stubs(:to_hash).with(true, :hyperv).returns(has)
      logger.expects(:warn).never

      expect(provider.configured_for_hyperv?).to eq(true)
    end
  end

  describe "#installer_options_prefetch_hook" do
    it "should not configure agent_certname if no hostname is set" do
      provider.expects(:hostname).returns(nil)
      expect(provider.installer_options).to_not include("agent_certname")
    end

    it "should construct installer options based on the additional properties" do
      expect(provider.installer_options).to eq({
        "ntp_server" => "172.20.0.8",
        "os_type"=>"vmware_esxi",
        "agent_certname"=>"agent-esx2ip1",
        "network_configuration"=>type.network_config.to_hash.to_json
      })
    end
  end

  describe "#to_puppet" do
    it "should remove resources that are not puppet types" do
      config = type.component_configuration
      config["asm::bios"] = {}
      config["asm::baseserver"] = {}
      type.expects(:component_configuration).returns(config)

      expect(provider.to_puppet.keys).to eq(["asm::server"])
    end
  end

  describe "#hostname" do
    it "should return the os_host_name property as hostname" do
      expect(provider.hostname).to eq(server_hostname)
    end
  end

  describe "#hostname_to_certname" do
    it "should should scrub illegal characters from the hostname" do
      expect(provider.hostname_to_certname("*'_\/!~`@#%^&()$rspec")).to eq("agent-rspec")
    end

    it "should support taking the resource hostname by default" do
      expect(provider.hostname_to_certname).to eq("agent-esx2ip1")
    end
  end

  describe "#dell_server?" do
    it "should check the server certname by default" do
      ASM::Util.expects(:dell_cert?).with(server_puppet_certname).once
      provider.dell_server?
    end

    it "should support checking a supplied certname" do
      ASM::Util.expects(:dell_cert?).with("rspec").once
      provider.dell_server?("rspec")
    end
  end

  describe "#target_boot_device" do
    it "Should be nil for servers without asm::idrac" do
      server_component.expects(:resource_by_id).with("asm::idrac").returns(nil)
      expect(provider.target_boot_device).to be(nil)
    end

    it "should be nil for servers with asm::idrac but not target_boot_device" do
      server_component.expects(:resource_by_id).with("asm::idrac").returns({})
      expect(provider.target_boot_device).to be(nil)
    end
  end

  describe "#boot_from_san?" do
    it "should be false for non dell servers" do
      provider.expects(:dell_server?).returns(false)
      provider.expects(:target_boot_device).never
      expect(provider.boot_from_san?).to be(false)
    end

    it "should be true if target_boot_device is a boot from san one" do
      provider.expects(:target_boot_device).returns(ASM::Provider::Server::Server::BOOT_FROM_SAN_TARGETS[0])
      expect(provider.boot_from_san?).to be(true)
    end

    it "should be false if target_boot_device is not a boot from san one" do
      expect(provider.boot_from_san?).to be(false)
    end
  end

  describe "#idrac?" do
    it "should correctly report a server as being idrac when asm::idrac is present" do
      expect(provider.idrac?).to eq(true)
    end

    it "should correctly report a server as not being idrac when asm::idrac is absent" do
      type.service_component.expects(:has_resource_id?).with("asm::idrac").returns(false)
      expect(provider.idrac?).to eq(false)
    end
  end

  describe "#delete_server_cert!" do
    it "should not clean servers without an os_image_type" do
      ASM::DeviceManagement.expects(:clean_cert).never

      provider.os_image_type = nil
      provider.delete_server_cert!

      provider.os_image_type = ""
      provider.delete_server_cert!
    end

    it "should clean certs via DeviceManagement" do
      ASM::DeviceManagement.expects(:clean_cert).with(provider.hostname_to_certname(server_hostname))
      provider.delete_server_cert!
    end
  end

  describe "#delete_server_node_data!" do
    it "should not clean servers without an os_image_type" do
      ASM::DeviceManagement.expects(:remove_node_data).never

      provider.os_image_type = nil
      provider.delete_server_node_data!

      provider.os_image_type = ''
      provider.delete_server_node_data!
    end

    it "should clean certs via DeviceManagement" do
      ASM::DeviceManagement.expects(:remove_node_data).with(provider.hostname_to_certname(server_hostname))
      provider.delete_server_node_data!
    end
  end

  describe "#leave_cluster!" do
    it "should request the cluster remove the server when an association is found" do
      cluster = cluster_components.first.to_resource(deployment, logger)
      type.expects(:related_cluster).returns(cluster)

      cluster.expects(:evict_server!).with(type)
      cluster.expects(:teardown?).returns(false)

      type.leave_cluster!
    end

    it "should not remove itself from a cluster that is also being removed" do
      cluster = cluster_components.first.to_resource(deployment, logger)
      type.expects(:related_cluster).returns(cluster)

      cluster.expects(:evict_server!).never
      cluster.expects(:teardown?).returns(true)

      type.leave_cluster!
    end

    it "should do nothing otherwise" do
      type.expects(:related_cluster).returns(nil)
      type.leave_cluster!
    end
  end

  describe "#clean_related_volumes!" do
    it "should do nothing when the server is not an idrac one" do
      provider.expects(:idrac?).returns(false)
      type.expects(:related_volumes).never
      provider.clean_related_volumes!
    end

    it "should remove the server associations from any related volumes that are not being torn down" do
      volumes = [
        mock(:teardown? => false, :puppet_certname => "rspec_volume"),
        mock(:teardown? => true)
      ]

      volumes[0].expects(:remove_server_from_volume!).with(type).once
      type.expects(:related_volumes).returns(volumes)

      provider.expects(:idrac?).returns(true)

      provider.clean_related_volumes!
    end

    it "should squash failures and continue trying other volumes" do
      volumes = [
        stub(:teardown? => false, :puppet_certname => "rspec_volume0"),
        stub(:teardown? => false, :puppet_certname => "rspec_volume1")
      ]

      volumes[0].expects(:remove_server_from_volume!).raises("rspec simulation")
      volumes[1].expects(:remove_server_from_volume!).returns(nil)

      type.expects(:related_volumes).returns(volumes)
      provider.expects(:idrac?).returns(true)
      logger.expects(:warn).with("Failed to remove the server bladeserver-15kvd42 from the volume rspec_volume0: RuntimeError: rspec simulation")
      logger.expects(:warn).with(regexp_matches(/Failed to remove .+ rspec_volume1/)).never

      provider.clean_related_volumes!
    end
  end

  describe "#clean_virtual_identities!" do
    it "should do nothing when the server is not an idrac one" do
      provider.expects(:create_idrac_resource).returns(false)
      provider.clean_virtual_identities!
    end

    it "should do the cleanup for idrac servers" do
      provider.expects(:wait_for_lc_ready)

      idrac = provider.create_idrac_resource
      idrac.expects(:ensure=).with("teardown")
      idrac.expects(:process!)
      provider.expects(:create_idrac_resource).returns(idrac)

      provider.clean_virtual_identities!
    end
  end

  describe "#power_state" do
    it "should correctly handle dell servers" do
      provider.expects(:dell_server?).returns(true).twice
      provider.expects(:wait_for_lc_ready).twice
      wsman.expects(:power_state).returns(:on)
      expect(provider.power_state).to be(:on)

      wsman.expects(:power_state).returns(:off)
      expect(provider.power_state).to be(:off)
    end

    it "should correctly handle non dell servers" do
      type.expects(:device_config).returns(device_config = mock).twice
      provider.expects(:dell_server?).returns(false).twice
      ASM::Ipmi.expects(:get_power_status).with(device_config, logger).returns("on")
      expect(provider.power_state).to be(:on)

      ASM::Ipmi.expects(:get_power_status).with(device_config, logger).returns("off")
      expect(provider.power_state).to be(:off)
    end
  end

  describe "#power_on!" do
    it "should not power on already powered on machines" do
      provider.expects(:power_state).returns(:on)
      wsman.expects(:reboot).never
      ASM::Ipmi.expects(:reboot).never
      provider.power_on!
    end

    it "should use wsman to power on a dell server" do
      wsman.expects(:reboot)
      provider.expects(:dell_server?).returns(true)
      provider.expects(:wait_for_lc_ready)
      provider.expects(:power_state).returns(:off)
      provider.expects(:sleep).with(30)

      provider.power_on!(30)
    end

    it "should use IPMI to power on non dell servers" do
      type.expects(:device_config).returns(device_config = mock)
      ASM::Ipmi.expects(:reboot).with(device_config, logger)
      provider.expects(:dell_server?).returns(false)
      provider.expects(:power_state).returns(:off)
      provider.expects(:sleep).with(0)

      provider.power_on!
    end
  end

  describe "#power_off!" do
    it "should use wsman to power off a dell server" do
      type.expects(:device_config).returns(device_config = mock)
      ASM::WsMan.expects(:poweroff).with(device_config, logger)
      provider.expects(:dell_server?).returns(true)
      provider.expects(:wait_for_lc_ready)

      provider.power_off!
    end

    it "should use IPMI to power off non dell servers" do
      type.expects(:device_config).returns(device_config = mock)
      ASM::Ipmi.expects(:power_off).with(device_config, logger)
      provider.expects(:dell_server?).returns(false)

      provider.power_off!
    end
  end

  describe "#delete_network_topology!" do
    it "should call deactivate_node with the puppet certname" do
      ASM::DeviceManagement.expects(:deactivate_node).with(server_puppet_certname)
      provider.delete_network_topology!
    end
  end

  describe "#enable_switch_inventory!" do
    it "should use wsman to boot ISO on a dell server" do
      wsman.expects(:boot_rfs_iso_image).with(:uri => "smb://guest:guest@localhost/razor/asm/microkernel.iso",
                                              :reboot_job_type => :power_cycle)
      provider.enable_switch_inventory!
    end

    it "should retry ISO boot once if it fails" do
      wsman.expects(:boot_rfs_iso_image)
           .with(:uri => "smb://guest:guest@localhost/razor/asm/microkernel.iso", :reboot_job_type => :power_cycle)
           .twice
           .raises("ISO boot failed")
           .returns(:status => "success")
      provider.stubs(:sleep)
      provider.enable_switch_inventory!
    end

    it "should fail if ISO boot fails twice" do
      wsman.expects(:boot_rfs_iso_image)
           .with(:uri => "smb://guest:guest@localhost/razor/asm/microkernel.iso", :reboot_job_type => :power_cycle)
           .twice
           .raises("ISO boot failed")
      provider.stubs(:sleep)
      expect { provider.enable_switch_inventory! }.to raise_error("ISO boot failed")
    end

    it "should do only power on for non-dell servers" do
      provider.expects(:dell_server?).returns(false)
      ASM::WsMan.expects(:boot_to_network_iso).never
      provider.expects(:power_on!).once
      provider.enable_switch_inventory!
    end
  end

  describe "#disable_switch_inventory!" do
    it "should use wsman to detach ISO on a dell server" do
      wsman.expects(:rfs_iso_image_connection_info).returns(:return_value => "0")
      wsman.expects(:disconnect_rfs_iso_image)
      provider.expects(:power_off!)
      provider.disable_switch_inventory!
    end

    it "should not attach ISO if not already attached" do
      wsman.expects(:rfs_iso_image_connection_info).returns(:return_value => "not-attached")
      provider.expects(:power_off!)
      provider.disable_switch_inventory!
    end

    it "should do only power off for non-dell servers" do
      provider.expects(:dell_server?).at_least_once.returns(false)
      provider.expects(:power_off!)
      provider.disable_switch_inventory!
    end
  end

  context "when calculating network overviews" do
    let(:raw_switches) { SpecHelper.json_fixture("switch_providers/switch_inventory.json") }
    let(:server_inventory) {SpecHelper.json_fixture("switch_providers/bladeserver-h4n71y1_inventory.json")}
    let(:collection) { ASM::Service::SwitchCollection.new(logger) }

    before(:each) do
      collection.stubs(:managed_inventory).returns(raw_switches)
      collection.stubs(:service).returns(service)

      ASM::PrivateUtil.stubs(:fetch_server_inventory).returns(server_inventory)

      collection.switches.each do |switch|
        facts_fixture = "switch_providers/%s_facts.json" % switch.puppet_certname
        switch.stubs(:facts_find).returns (
          SpecHelper.json_fixture(facts_fixture)
        )
      end

      provider.stubs(:fc_interfaces).returns([
        stub(:fqdd => "FC.Mezzanine.2B-1", :wwpn => "20:01:00:0E:1E:C2:9B:9E"),
        stub(:fqdd => "FC.Mezzanine.2B-2", :wwpn => "20:01:00:0E:1E:C2:9B:9F"),
      ])

      type.stubs(:switch_collection).returns(collection)
    end

    describe "#fcoe_interface_overview" do
      before(:each) do
        provider.stubs(:fcoe_views).returns({
          "NIC.Integrated.1-1-1"=>{"wwpn"=>"20:01:74:86:7A:EF:48:31"},
          "NIC.Integrated.1-2-4"=>{"wwpn"=>"20:01:74:86:7A:EF:48:3F"}
        })
        type.stubs(:fcoe?).returns(true)
      end

      it "should return empty data for non fcoe deployments" do
        type.expects(:fcoe?).returns(false)
        expect(provider.fcoe_interface_overview).to eq([])
      end

      it "should create correct data" do
        switch = stub(:puppet_certname => "rspec switch")
        switch.expects(:fc_zones).with("20:01:74:86:7A:EF:48:31").returns(["RSPEC_ZONE1", "RSPEC_ZONE2"])
        switch.expects(:active_fc_zone).with("20:01:74:86:7A:EF:48:31").returns(["ACTIVE_ZONESET"])

        type.switch_collection.expects(:switch_for_mac).with("20:01:74:86:7A:EF:48:31").returns(switch)
        type.switch_collection.expects(:switch_for_mac).with("20:01:74:86:7A:EF:48:3F").returns(nil)

        expect(provider.fcoe_interface_overview).to eq([
          {
            :fqdd=>"NIC.Integrated.1-1-1",
            :wwpn=>"20:01:74:86:7A:EF:48:31",
            :connected_switch=>"rspec switch",
            :connected_zones=>["RSPEC_ZONE1", "RSPEC_ZONE2"],
            :active_zoneset=>["ACTIVE_ZONESET"]
          }
        ])
      end
    end

    describe "#fc_interface_overview" do
      it "should return empty data for non fc deployments" do
        type.expects(:fc?).returns(false)
        expect(provider.fc_interface_overview).to eq([])
      end

      it "should create correct data" do
        type.expects(:fc?).returns(true)

        expect(provider.fc_interface_overview).to eq([
          {:fqdd=>"FC.Mezzanine.2B-1",
           :wwpn=>"20:01:00:0E:1E:C2:9B:9E",
           :connected_switch=>"brocade_fos-172.17.9.15",
           :connected_zones=>["ASM_RSPEC1"],
           :active_zoneset=>"Config_09_Top"},
          {:fqdd=>"FC.Mezzanine.2B-2",
           :wwpn=>"20:01:00:0E:1E:C2:9B:9F",
           :connected_switch=>"brocade_fos-172.17.9.16",
           :connected_zones=>["ASM_RSPEC2"],
           :active_zoneset=>"Config_09_Bottom"}
        ])
      end
    end

    describe "#network_overview" do
      let(:switch1) { collection.switch_for_mac("00:01:e8:8b:13:c7") }
      let(:switch2) { collection.switch_for_mac("e0:db:55:21:12:dc") }
      let(:interface) { stub(:fqdd => "RSPEC-FQDD") }

      before(:each) do
        type.expects(:related_switches).returns([switch1, switch2]).at_least_once
        type.expects(:network_config).returns(stub(:to_hash => "rpsec-config"))
        type.expects(:fc?).returns(true)
        type.expects(:fcoe?).returns(false)
      end

      it "should generate network overview" do
        type.expects(:network_topology).returns([{ :interface => interface, :switch => stub(:blade_switch? => true, :puppet_certname => "RSPEC-PUPPETCERTNAME"), :port => ["rspec-topology3"] }]).at_least_once

        expect(provider.network_overview).to eq(
          {:network_config=>"rpsec-config",
          :related_switches=>[switch1.puppet_certname, switch2.puppet_certname],
          :name=>"Server",
          :server=>"bladeserver-15kvd42",
          :physical_type=>"BLADE",
          :serial_number=>"15KVD42",
          :razor_policy_name=>"policy-esx2ip1-1234",
          :fcoe_interfaces => [],
          :fc_interfaces => [
            {:fqdd=>"FC.Mezzanine.2B-1",
             :wwpn=>"20:01:00:0E:1E:C2:9B:9E",
             :connected_switch=>"brocade_fos-172.17.9.15",
             :connected_zones=>["ASM_RSPEC1"],
             :active_zoneset=>"Config_09_Top"},
            {:fqdd=>"FC.Mezzanine.2B-2",
             :wwpn=>"20:01:00:0E:1E:C2:9B:9F",
             :connected_switch=>"brocade_fos-172.17.9.16",
             :connected_zones=>["ASM_RSPEC2"],
             :active_zoneset=>"Config_09_Bottom"}],
             :connected_switches=>[
               {
                :local_device=>"dell_iom-172.17.9.174",
                :local_device_type=>"blade",
                :local_ports=>["Te 0/43"],
                :remote_device=>"dell_ftos-172.17.9.14",
                :remote_device_type=>"rack",
                :remote_ports=>["Te 0/4"]
              },
              {
                :local_device=>"dell_iom-172.17.9.174",
                :local_device_type=>"blade",
                :local_ports=>["Te 0/44"],
                :remote_device=>"dell_ftos-172.17.9.13",
                :remote_device_type=>"rack",
                :remote_ports=>["Te 0/4"]
              },
              {
                :local_device=>"dell_ftos-172.17.9.13",
                :local_device_type=>"rack",
                :local_ports=>["Te 0/0"],
                :remote_device=>"dell_iom-172.17.9.171",
                :remote_device_type=>"blade",
                :remote_ports=>["Te 0/43"]
              },
              {
                :local_device=>"dell_ftos-172.17.9.13",
                :local_device_type=>"rack",
                :local_ports=>["Te 0/4"],
                :remote_device=>"dell_iom-172.17.9.174",
                :remote_device_type=>"blade",
                :remote_ports=>["Te 0/44"]
              },
              {
                :local_device=>"dell_ftos-172.17.9.14",
                :local_device_type=>"rack",
                :local_ports=>["Te 0/0"],
                :remote_device=>"dell_iom-172.17.9.171",
                :remote_device_type=>"blade",
                :remote_ports=>["Te 0/44"]
              },
              {
                :local_device=>"dell_ftos-172.17.9.14",
                :local_device_type=>"rack",
                :local_ports=>["Te 0/4"],
                :remote_device=>"dell_iom-172.17.9.174",
                :remote_device_type=>"blade",
                :remote_ports=>["Te 0/43"]
              },
              {
                :local_device=>"dell_iom-172.17.9.171",
                :local_device_type=>"blade",
                :local_ports=>["Te 0/43"],
                :remote_device=>"dell_ftos-172.17.9.13",
                :remote_device_type=>"rack",
                :remote_ports=>["Te 0/0"]
              },
              {
                :local_device=>"dell_iom-172.17.9.171",
                :local_device_type=>"blade",
                :local_ports=>["Te 0/44"],
                :remote_device=>"dell_ftos-172.17.9.14",
                :remote_device_type=>"rack",
                :remote_ports=>["Te 0/0"]
              },
              {
                :local_device=>"bladeserver-15kvd42",
                :local_device_type=>"blade",
                :local_ports=>["RSPEC-FQDD"],
                :remote_device=>"RSPEC-PUPPETCERTNAME",
                :remote_device_type=>"blade",
                :remote_ports=>[["rspec-topology3"]]
              }]})
      end

      it "should generate network overview if switches are nil" do
        type.expects(:network_topology).returns([{ :interface => interface, :switch => nil, :port => ["rspec-topology3"] }]).at_least_once
        overview = provider.network_overview
        serverport = overview[:connected_switches].find { |connection| connection[:local_ports].include? ("RSPEC-FQDD") }
        expect(serverport).to be_nil
      end
    end
  end

  describe "#reset_management_ip!" do
    it "will send an esxcli command to reset network on vmk0" do
      ASM::Cipher.stubs(:decrypt_string).with("ff8080814dbf2d1d014ddcc519673595").returns("password")
      type.stubs(:razor_status).returns({:status => :boot_local_2})
      endpoint = {:host => "172.28.10.63", :user => "root", :password => "password"}
      ASM::Util.expects(:esxcli).with(%w(network ip interface ipv4 set -i vmk0 -t none), endpoint, nil, true, 20)
      provider.reset_management_ip!
    end

    it "should not do a reset when not an esxi install" do
      type.stubs(:esxi_installed?).returns(false)
      ASM::Util.expects(:esxcli).never
      provider.reset_management_ip!
    end

    it "should not attempt to reset if esxi was not installed" do
      type.stubs(:razor_status).returns(:status => :microkernel)
      ASM::Util.expects(:esxcli).never
      provider.reset_management_ip!
    end
  end
end

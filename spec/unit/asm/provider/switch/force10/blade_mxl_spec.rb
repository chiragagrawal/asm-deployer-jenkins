require 'spec_helper'
require 'asm/provider/switch/force10/blade_mxl'

describe ASM::Provider::Switch::Force10::BladeMxl do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:type) { stub(:puppet_certname => "rspec") }
  let(:provider) { stub(:type => type, :logger => logger) }
  let(:blade) { ASM::Provider::Switch::Force10::BladeMxl.new(provider) }
  let(:dhcp_management_ip) { SpecHelper.load_fixture("switch_providers/dhcp_management_ip_snippet.txt") }
  let(:static_management_ip) { SpecHelper.load_fixture("switch_providers/static_management_ip_snippet.txt") }
  let(:vltdata) { {"uplinkId" => "vlt", "uplinkName" => "VLT", "portChannel" => nil, "portMembers" => ["Te 0/44", "Te 0/37"], "portNetworks" => []} }
  let(:vltdata2) { {"uplinkId" => "vlt", "uplinkName" => "VLT", "portChannel" => nil, "portMembers" => ["Te 0/44", "Te 0/37"], "portNetworks" => [], "model" => "PE-FN-410S-IOM"} }

  describe "#configure_force10_settings" do
    it "should just clone the settings when no config file is used" do
      blade.expects(:replace_hostname_in_config!).never
      blade.configure_force10_settings("hostname" => "rspec")
      expect(blade.port_resources).to eq("force10_settings"=>{"rspec" => {"hostname"=>"rspec"}})
    end

    it "should configure the switch" do
      config_file = Base64.encode64("!\nend")
      type.stubs(:configured_hostname).returns("rspec.host.name")
      type.stubs(:configured_management_ip_information).returns(["10.1.1.100", "24"])
      type.stubs(:cert2ip).returns("10.1.1.101")
      type.stubs(:management_ip_static_configured?).returns(true)
      type.stubs(:configured_credentials).returns(["username rspec"])
      type.stubs(:configured_boot).returns("boot rspec")
      type.stubs(:save_file_to_deployment).with(instance_of(String), "rspec_config_file.cfg").returns("/some/rspec_config_file.cfg")
      type.stubs(:appliance_preferred_ip).returns("10.1.1.10")

      blade.configure_force10_settings("config_file" => config_file)

      expected = {"force10_config" =>
                    {"rspec_apply_config_file"=>
                     {"startup_config"=>"true",
                      "force"=>"true",
                      "source_server"=>"10.1.1.10",
                      "source_file_path"=>"/some/rspec_config_file.cfg",
                      "copy_to_tftp"=>["/var/lib/tftpboot/rspec_config_file.cfg"]
                     }
                    }
                 }

      expect(blade.port_resources).to eq(expected)

    end
  end

  describe "#replace_boot_in_config!" do
    it "should preserve the boot config" do
      type.expects(:configured_boot).returns("boot rspec")
      config = "!\nend"

      blade.replace_boot_in_config!(config)
      expect(config).to eq("boot rspec\n!\nend")
    end
  end

  describe "#configure_iom_mode!" do
    it "should fail for multiple invocations" do
      blade.configure_iom_mode!(false,false,vltdata)
      expect { blade.configure_iom_mode!(false,false,vltdata) }.to raise_error("iom-mode_vlt resource is already created in this instance for switch rspec")
    end

    it "should return iom_mode vlt_ setting" do
      blade.configure_iom_mode!(false,false,vltdata)
      expect(blade.port_resources["ioa_mode"]).to include("vlt_settings")
    end
  end

  describe "#replace_credentials_in_config!" do
    it "should replace the existing credentials" do
      config = "username rspec\n!\nend"

      type.expects(:configured_credentials).returns(["username root password 7 d7acc8a1dcd4f698 privilege 15 role sysadmin"])
      blade.replace_credentials_in_config!(config)

      expect(config).to eq("\nusername root password 7 d7acc8a1dcd4f698 privilege 15 role sysadmin\n!\nend")
    end
  end

  describe "#replace_management_ethernet_in_config!" do
    before(:each) do
      type.expects(:configured_management_ip_information).returns(["1.2.3.4", "24"])
      type.expects(:cert2ip).returns("1.2.3.1")
    end

    it "should configure switches that are static" do
      type.expects(:management_ip_static_configured?).returns(true)
      blade.replace_management_ethernet_in_config!(static_management_ip)
      expect(static_management_ip).to match("ip address 1.2.3.1/24")
    end

    it "should configure switches with no management config" do
      type.expects(:management_ip_static_configured?).returns(false)
      type.expects(:management_ip_dhcp_configured?).returns(false)
      config = "!\nend"

      blade.replace_management_ethernet_in_config!(config)
      expect(config).to match("ip address 1.2.3.1/24")
    end

    it "should not change DHCP based switches" do
      type.expects(:management_ip_static_configured?).returns(false)
      type.expects(:management_ip_dhcp_configured?).returns(true)
      blade.replace_management_ethernet_in_config!(static_management_ip)
      expect(static_management_ip).to match("!\n\n\nend")
    end
  end

  describe "#replace_hostname_in_config!" do
    context "when the settings include a hostname" do
      it "should change an existing configured hostname" do
        config = "!\nhostname rspec\n!"
        blade.replace_hostname_in_config!(config, {"hostname" => "new.host.name"})
        expect(config).to eq("!\nhostname new.host.name\n!")
      end

      it "should add a missing config" do
        config = "!\nend"
        blade.replace_hostname_in_config!(config, {"hostname" => "new.host.name"})
        expect(config).to eq("hostname new.host.name\n!\nend")
      end
    end

    context "when the settings does not include a hostname" do
      it "should change an existing configured hostname" do
        provider.type.expects(:configured_hostname).returns("configured.host.name")

        config = "!\nhostname rspec\n!"
        blade.replace_hostname_in_config!(config, {})
        expect(config).to eq("!\nhostname configured.host.name\n!")
      end

      it "should add a missing config" do
        provider.type.expects(:configured_hostname).returns("configured.host.name")

        config = "!\nend"
        blade.replace_hostname_in_config!(config, {})
        expect(config).to eq("hostname configured.host.name\n!\nend")
      end
    end
  end

  describe "#configure_quadmode" do
    it "should disable quoadmode on any interface" do
      blade.configure_quadmode(["Fo 0/0", "Te 0/0"], false)
      expect(blade.port_resources["mxl_quadmode"]["Fo 0/0"]).to eq({"ensure"=>"absent"})
      expect(blade.port_resources["mxl_quadmode"]["Te 0/0"]).to eq({
        "ensure"=>"absent",
        "reboot_required"=>"true",
        "require"=>"Mxl_quadmode[Fo 0/0]"
      })
    end

    it "should not enable quad mode on non 40gb interfaces" do
      blade.configure_quadmode(["Fo 0/0", "Te 0/0"], true)
      expect(blade.port_resources["mxl_quadmode"]["Fo 0/0"]).to eq({
        "ensure" => "present",
        "reboot_required" => "true"
      })
      expect(blade.port_resources["mxl_quadmode"]).to_not include("Te 0/0")
    end
  end

  describe "#forty_gb_interface?" do
    it "should correctly determine if it's a 40Gb int" do
      expect(blade.forty_gb_interface?("Fo 0/1")).to be(true)
      expect(blade.forty_gb_interface?("Te 0/1")).to be(false)
    end
  end

  describe "#initialize_ports!" do
    it "should initialize each port" do
      blade.expects(:port_names).returns(["Te 0/0", "Te 0/1"])
      blade.expects(:configure_interface_vlan).with("Te 0/0", "1", false, true)
      blade.expects(:configure_interface_vlan).with("Te 0/0", "1", true, true)
      blade.expects(:configure_interface_vlan).with("Te 0/1", "1", false, true)
      blade.expects(:configure_interface_vlan).with("Te 0/1", "1", true, true)
      blade.expects(:populate_port_resources).with(:remove)
      blade.initialize_ports!
    end
  end

  describe "#port_names" do
    it "should correctly generate Te names" do
      blade.expects(:port_count).returns(32)
      names = blade.port_names
      expect(names.size).to be(32)
      names.each_with_index do |name, idx|
        expect(name).to eq("Te 0/%s" % (idx + 1))
      end
    end
  end

  describe "#validate_vlans!" do
    it "should allow multiple untagged vlans on different ports" do
      blade.configure_interface_vlan("1", "1", false)
      blade.configure_interface_vlan("2", "1", false)

      blade.validate_vlans!
    end

    it "should not allow multiple untagged vlans on the same port" do
      blade.configure_interface_vlan("1", "1", false)
      blade.configure_interface_vlan("1", "2", false)

      expect {
        blade.validate_vlans!
      }.to raise_error("can only have one untagged network but found multiple untagged vlan requests for the same port on rspec")
    end
  end

  describe "#configure_interface_vlan" do
    it "should add the interface correctly" do
      blade.configure_interface_vlan("1", "1", true)
      blade.configure_interface_vlan("2", "2", false)
      blade.configure_interface_vlan("3", "3", true, true)

      expect(blade.interface_map).to include({:interface => "1", :portchannel=>"", :vlan => "1", :tagged => true, :mtu => "12000", :action => :add})
      expect(blade.interface_map).to include({:interface => "2", :portchannel=>"", :vlan => "2", :tagged => false, :mtu => "12000", :action => :add})
      expect(blade.interface_map).to include({:interface => "3", :portchannel=>"", :vlan => "3", :tagged => true, :mtu => "12000", :action => :remove})
    end
  end

  describe "#populate_interface_resources" do
    it "should create the correct interface resources" do
      blade.configure_interface_vlan("Te 1/1", "10", true)
      blade.configure_interface_vlan("Te 1/2", "10", true)
      blade.configure_interface_vlan("Te 1/1", "11", true)
      blade.configure_interface_vlan("Te 1/1", "18", false)
      blade.configure_interface_vlan("Te 1/3", "18", false, true)

      blade.populate_port_resources(:add)

      expect(blade.port_resources).to include("force10_interface")
      expect(blade.port_resources["force10_interface"]).to include("Te 1/1")
      expect(blade.port_resources["force10_interface"]).to include("Te 1/2")
      expect(blade.port_resources["force10_interface"]["Te 1/1"]["ensure"]).to eq("present")
      expect(blade.port_resources["force10_interface"]["Te 1/2"]["ensure"]).to eq("present")

    end
  end

  describe "#populate_vlan_resources" do
    context "when action is :add" do
      it "should create the correct vlan resources" do
        blade.configure_interface_vlan("Te 1/1", "10", true)
        blade.configure_interface_vlan("Te 1/2", "10", true)
        blade.configure_interface_vlan("Te 1/1", "11", true)
        blade.configure_interface_vlan("Te 1/1", "18", false)
        blade.configure_interface_vlan("Te 1/3", "18", false, true)
        blade.expects(:vlan_resource).with("10", {:interface => 'Te 1/2', :portchannel => '', :vlan => '10', :tagged => true, :mtu => "12000", :action => :add})
        blade.expects(:vlan_resource).with("11", {:interface => 'Te 1/1', :portchannel => '', :vlan => '11', :tagged => true, :mtu => "12000", :action => :add})
        blade.expects(:vlan_resource).with("18", {:interface => 'Te 1/1', :portchannel => '', :vlan => '18', :tagged => false, :mtu => "12000", :action => :add})

        blade.populate_vlan_resources(:add)
      end
    end
    context "when action is :remove" do
      it "should not create any vlan resources" do
        blade.configure_interface_vlan("Te 1/3", "18", false, true)

        blade.populate_vlan_resources(:remove)
      end
    end
  end

  describe "#vlan_resource" do
    it "should create a new resource if none exist" do
      blade.configure_interface_vlan("Te 1/2", "10", true)
      blade.vlan_resource("10", {:portchannel => ""})

      expect(blade.port_resources["asm::mxl"]).to include("10")
      expect(blade.port_resources["asm::mxl"]["10"]["vlan_name"]).to eq("VLAN_10")
      expect(blade.port_resources["asm::mxl"]["10"]).to include("before")
      expect(blade.port_resources["asm::mxl"]["10"]["before"]).to eq(["Force10_interface[Te 1/2]"])
    end
  end

  describe "#to_puppet" do
    it "should join array properties to strings" do
      blade.stubs(:port_resources).returns({
                                              "force10_interface" => {
                                                  "0/12" => {
                                                      "tagged_vlan" => ["18", "20"],
                                                      "untagged_vlan" => ["18", "20"],
                                                  }
                                              }
                                          })
      provider.stubs(:model).returns("MXL")

      expect(blade.to_puppet).to eq({
                                       "force10_interface" => {
                                           "0/12" => {
                                               "tagged_vlan" => "18,20",
                                               "untagged_vlan" => "18,20",
                                           }
                                       }
                                   })
    end
  end

  describe "#prepare" do
    it "should correctly configure the internal state" do
      prepare = sequence(:prepare)
      blade.expects(:reset!).in_sequence(prepare)
      blade.expects(:validate_vlans!).in_sequence(prepare)
      blade.expects(:populate_port_resources).with(:add).in_sequence(prepare)
      blade.expects(:populate_vlan_resources).with(:add).in_sequence(prepare)

      blade.stubs(:port_resources).returns({})

      expect(blade.prepare(:add)).to be(false)
    end

    it "should correctly indicate if a process! is needed" do
      blade.stubs(:reset!)
      blade.stubs(:populate_port_resources)
      blade.stubs(:populate_vlan_resources)

      blade.stubs(:port_resources).returns({})
      expect(blade.prepare(:add)).to be(false)

      blade.stubs(:port_resources).returns({"force10_vlan" => {}})
      expect(blade.prepare(:add)).to be(true)
    end
  end
end

require "spec_helper"
require "asm/ipxe_builder"
require "asm/network_configuration"
require "asm/wsman"

describe ASM::IpxeBuilder do
  describe "render_bootstrap" do
    let(:nic_view_data) { SpecHelper.json_fixture("ipxe_builder/get_nic_view.json") }

    before(:each) do
      ASM::WsMan.stubs(:get_nic_view).returns(nic_view_data)
      ASM::WsMan.stubs(:get_bios_enumeration).returns([])
      ASM::Util.stubs(:get_preferred_ip).returns("172.25.3.100")
    end

    it "should render a static bootstrap script" do
      network_config_data = SpecHelper.json_fixture("ipxe_builder/static_pxe_network_configuration.json")
      network_config = ASM::NetworkConfiguration.new(network_config_data)
      network_config.add_nics!(:host => "host", :user => "user", :password => "password")
      expected = SpecHelper.load_fixture("ipxe_builder/static_bootstrap.ipxe")
      expect(ASM::IpxeBuilder.render_bootstrap(network_config, 4)).to eq(expected)
    end

    it "should render a dhcp bootstrap script" do
      network_config_data = SpecHelper.json_fixture("ipxe_builder/dhcp_pxe_network_configuration.json")
      network_config = ASM::NetworkConfiguration.new(network_config_data)
      network_config.add_nics!(:host => "host", :user => "user", :password => "password")
      expected = SpecHelper.load_fixture("ipxe_builder/dhcp_bootstrap.ipxe")
      expect(ASM::IpxeBuilder.render_bootstrap(network_config, 4)).to eq(expected)
    end
  end

  describe "generate_bootstrap" do
    it "should call render_bootstrap and write the file" do
      ASM::IpxeBuilder.expects(:render_bootstrap).with("network-config", 8).returns("script")
      File.expects(:write).with("/tmp/bootstrap.ipxe", "script")
      ASM::IpxeBuilder.generate_bootstrap("network-config", 8, "/tmp/bootstrap.ipxe")
    end
  end

  describe "build_dhcp" do
    before(:each) do
      Tempfile.expects(:new).with("bootstrap.ipxe").returns(stub(:path => "/tmp/bootstrap.ipxe", :unlink => nil))
      ASM::IpxeBuilder.expects(:generate_bootstrap).with("rspec-network-config", 4, "/tmp/bootstrap.ipxe")
    end

    it "should generate bootstrap and make the ISO for DHCP case" do
      FileUtils.expects(:rm).with("/var/nfs/generated.iso", :force => true)
      FileUtils.expects(:rm).with("/opt/src/ipxe/src/bin/ipxe.iso", :force => true)
      ASM::IpxeBuilder.expects(:get_static_network_info).with("rspec-network-config")
      ASM::Util.expects(:run_command)
               .with("make", "-C", "/opt/src/ipxe/src", "bin/ipxe.iso", "EMBED=/tmp/bootstrap.ipxe")
               .returns(Hashie::Mash.new(:exit_status => 0, :stdout => "", :stderr => ""))
      FileUtils.expects(:mv).with("/opt/src/ipxe/src/bin/ipxe.iso", "/var/nfs/generated.iso")
      ASM::IpxeBuilder.build("rspec-network-config", 4, "/var/nfs/generated.iso")
    end

    it "should fail if the ISO build fails for DHCP case" do
      response = Hashie::Mash.new(:exit_status => 1, :stdout => "", :stderr => "")
      FileUtils.expects(:rm).with("/var/nfs/generated.iso", :force => true)
      FileUtils.expects(:rm).with("/opt/src/ipxe/src/bin/ipxe.iso", :force => true)
      ASM::IpxeBuilder.expects(:get_static_network_info).with("rspec-network-config")
      ASM::Util.expects(:run_command)
               .with("make", "-C", "/opt/src/ipxe/src", "bin/ipxe.iso", "EMBED=/tmp/bootstrap.ipxe")
               .returns(response)
      message = "iPXE ISO build failed: %s" % response.to_s
      expect {ASM::IpxeBuilder.build("rspec-network-config", 4, "/var/nfs/generated.iso")}.to raise_error(message)
    end
  end

  describe "get_static_network_info" do
    it "should return static IP info from network config" do
      expected_ip_info = {"macAddress" => "EC:F4:BB:BF:29:7C",
                          "ipAddress" => "172.25.3.151",
                          "netmask" => "255.255.0.0",
                          "gateway" => "172.25.0.1"}
      network_config_data = SpecHelper.json_fixture("ipxe_builder/static_ip_network_configuration.json")
      network_config = ASM::NetworkConfiguration.new(network_config_data)
      expect(ASM::IpxeBuilder.get_static_network_info(network_config)).to eql(expected_ip_info)
    end

    it "should fail if MAC address is missing from network config" do
      network_config_data = SpecHelper.json_fixture("ipxe_builder/static_ip_network_configuration_no_mac_addr.json")
      network_config = ASM::NetworkConfiguration.new(network_config_data)
      message = "MAC address missing in network config. The network config must have had add_nics! run."
      expect {ASM::IpxeBuilder.get_static_network_info(network_config)}.to raise_error(message)
    end

    it "should fail if ip address is missing from network config" do
      network_config_data = SpecHelper.json_fixture("ipxe_builder/static_ip_network_configuration_no_ip_addr.json")
      network_config = ASM::NetworkConfiguration.new(network_config_data)
      message = "IP address missing in network config"
      expect {ASM::IpxeBuilder.get_static_network_info(network_config)}.to raise_error(message)
    end

    it "should fail if subnet is missing from network config" do
      network_config_data = SpecHelper.json_fixture("ipxe_builder/static_ip_network_configuration_no_subnet.json")
      network_config = ASM::NetworkConfiguration.new(network_config_data)
      message = "subnet missing in network config"
      expect {ASM::IpxeBuilder.get_static_network_info(network_config)}.to raise_error(message)
    end

    it "should succeed if gateway is missing from network config" do
      expected_ip_info = {"macAddress" => "EC:F4:BB:BF:29:7C",
                          "ipAddress" => "172.25.3.151",
                          "netmask" => "255.255.0.0",
                          "gateway" => nil}
      network_config_data = SpecHelper.json_fixture("ipxe_builder/static_ip_network_configuration_no_gateway.json")
      network_config = ASM::NetworkConfiguration.new(network_config_data)
      expect(ASM::IpxeBuilder.get_static_network_info(network_config)).to eql(expected_ip_info)
    end
  end

  describe "build_static" do
    before(:each) do
      Tempfile.expects(:new).with("bootstrap.ipxe").returns(stub(:path => "/tmp/bootstrap.ipxe", :unlink => nil))
    end

    it "should make the ISO specifying static network info in the static IP case" do
      FileUtils.expects(:rm).with("/tmp/generated.iso", :force => true)
      FileUtils.expects(:rm).with("/opt/src/ipxe/src/bin/ipxe.iso", :force => true)
      ASM::IpxeBuilder.expects(:generate_bootstrap).with("rspec-network-config", 2, "/tmp/bootstrap.ipxe")
      ASM::IpxeBuilder.expects(:get_static_network_info).with("rspec-network-config")
                      .returns("macAddress" => "EC:F4:BB:BF:29:7C",
                               "ipAddress" => "172.25.3.151",
                               "netmask" => "255.255.0.0",
                               "gateway" => "172.25.0.1")
      ASM::Util.expects(:run_command)
               .with("env", "IP_ADDRESS=172.25.3.151",
                     "MAC_ADDRESS=EC:F4:BB:BF:29:7C",
                     "NETMASK=255.255.0.0",
                     "GATEWAY=172.25.0.1",
                     "make", "-C", "/opt/src/ipxe/src", "bin/ipxe.iso", "EMBED=/tmp/bootstrap.ipxe")
               .returns(Hashie::Mash.new(:exit_status => 0, :stdout => "", :stderr => ""))
      FileUtils.expects(:mv).with("/opt/src/ipxe/src/bin/ipxe.iso", "/tmp/generated.iso")
      ASM::IpxeBuilder.build("rspec-network-config", 2, "/tmp/generated.iso")
    end

    it "should make the ISO specifying static network info in the static IP case when gateway is missing" do
      FileUtils.expects(:rm).with("/tmp/generated.iso", :force => true)
      FileUtils.expects(:rm).with("/opt/src/ipxe/src/bin/ipxe.iso", :force => true)
      ASM::IpxeBuilder.expects(:generate_bootstrap).with("rspec-network-config", 2, "/tmp/bootstrap.ipxe")
      ASM::IpxeBuilder.expects(:get_static_network_info).with("rspec-network-config")
                      .returns("macAddress" => "EC:F4:BB:BF:29:7C",
                               "ipAddress" => "172.25.3.151",
                               "netmask" => "255.255.0.0",
                               "gateway" => nil)
      ASM::Util.expects(:run_command)
               .with("env", "IP_ADDRESS=172.25.3.151",
                     "MAC_ADDRESS=EC:F4:BB:BF:29:7C",
                     "NETMASK=255.255.0.0",
                     "GATEWAY=",
                     "make", "-C", "/opt/src/ipxe/src", "bin/ipxe.iso", "EMBED=/tmp/bootstrap.ipxe")
               .returns(Hashie::Mash.new(:exit_status => 0, :stdout => "", :stderr => ""))
      FileUtils.expects(:mv).with("/opt/src/ipxe/src/bin/ipxe.iso", "/tmp/generated.iso")
      ASM::IpxeBuilder.build("rspec-network-config", 2, "/tmp/generated.iso")
    end
  end
end

require "spec_helper"
require "asm/processor/server"
require "asm/processor/linux_vm_post_os"
require "asm/device_management"
require "asm/service"

describe ASM::Processor::LinuxVMPostOS do
  let(:puppetdb) { stub(:successful_report_after? => true) }
  let(:appliance_ip) {"172.20.5.100"}
  before do
    ASM.init_for_tests
    ASM::Util.stubs(:default_routed_ip).returns("1.1.1.1")
    @service_deployment = SpecHelper.json_fixture("processor/linux_post_os/linux_vm_post_os.json")
    @sd = mock("service_deployment")

    @tmp_dir = Dir.mktmpdir
    ASM.stubs(:base_dir).returns(@tmp_dir)

    @deployment_db = mock("deploymentdb")
    @deployment_db.stub_everything
    @sd = ASM::ServiceDeployment.new("8000", @deployment_db)

    @sd.components(@service_deployment)
    @vm_component = @sd.components_by_type("VIRTUALMACHINE")[0]
    @vm_resource = stub("vm_resource")
    @vm_resource = stub_everything
    @vm_resource.stubs(:is_vm_already_deployed).returns(true)
    @processor = ASM::Processor::LinuxVMPostOS.new(@sd, @vm_component, @vm_resource)

    @vm_network1 = [
        {"id"=>"ff80808150b4e04d0150b4f1394800a4",
         "name"=>"Work Static",
         "description"=>"",
         "type"=>"PRIVATE_LAN",
         "vlanId"=>20,
         "static"=>true,
         "staticNetworkConfiguration"=>
             {"gateway"=>"172.20.0.1",
              "subnet"=>"255.255.0.0",
              "primaryDns"=>"172.20.0.8",
              "secondaryDns"=>nil,
              "dnsSuffix"=>"aidev.com",
              "ipRange"=>[
                  {"Id"=>"ff80808150b4e04d0150b4f1394800a5",
                   "StartingIp"=>"172.20.11.100",
                   "EndingIp"=>"172.20.11.110"}
              ],
              "ipAddress"=>"172.20.11.110"}}
    ]

    @vm_network2 = [
        {"id"=>"ff80808150b4e04d0150b4f1394800a4",
         "name"=>"Work DHCP",
         "description"=>"",
         "type"=>"PRIVATE_LAN",
         "vlanId"=>20,
         "static"=>false,
        }
    ]

    @vm_network3 = [
        {"id"=>"ff80808150b4e04d0150b4f1394800a4",
         "name"=>"Work DHCP",
         "description"=>"",
         "type"=>"PRIVATE_LAN",
         "vlanId"=>20,
         "static"=>false,
        },
        {"id"=>"ff80808150b4e04d0150b4f1394800a5",
         "name"=>"PUBLIC DHCP",
         "description"=>"",
         "type"=>"PUBLIC_LAN",
         "vlanId"=>22,
         "static"=>false,
        }
    ]

    @snc_1n = {"network::if::static" => {
        0 => {
            "ensure" => "up",
            "ipaddress" => "172.20.11.110",
            "netmask" => "255.255.0.0",
            "gateway" => "172.20.0.1",
            "domain" => "aidev.com",
            "defroute" => "no"
        }
    }
    }

    @snc_2n = {"network::if::static" => {
        0 => {
            "ensure" => "up",
            "ipaddress" => "172.20.11.110",
            "netmask" => "255.255.0.0",
            "gateway" => "172.20.0.1",
            "domain" => "aidev.com",
            "defroute" => "no"
        },
        1 => {
            "ensure" => "up",
            "ipaddress" => "172.22.11.110",
            "netmask" => "255.255.0.0",
            "gateway" => "172.22.0.1",
            "domain" => "aidev.com",
            "defroute" => "no"
        }
    }
    }

    @dnc_1n = {"network::if::dynamic" => {
        0 => {
            "ensure" => "up"
        }
    }
    }

    @dnc_2n = {"network::if::dynamic" => {
        0 => {
            "ensure" => "up"
        },
        1 => {
            "ensure" => "up"
        }
    }
    }

    @gateway_hash1 = {"network::global"=>{"gateway"=>"172.20.0.1"}}
    @gateway_hash2 = {"network::global"=>{"gateway"=>"172.22.0.1"}}

    @emtpy_config = {"classes" => {}, "resources" => {}}
  end

  after do
    ASM.reset
  end

  describe "should configure linux vm post installation" do
    it "with no static network adapter" do
      @processor.stubs(:vm_networks).returns([])
      expect(@processor.process_network_config).to eql({"resources" =>{}})
    end

    it "with one static network adapter" do
      @processor.stubs(:vm_networks).returns(@vm_network1)
      @processor.stubs(:default_gateway_network).returns("")
      expect(@processor.process_network_config).to eql({"resources" => @snc_1n})
    end

    it "with two static network adapters" do
      @processor.stubs(:default_gateway_network).returns("")
      expect(@processor.process_network_config).to eql({"resources" => @snc_2n})
    end

    it "with no default gateway" do
      @processor.stubs(:default_gateway_network).returns("")
      expect(@processor.default_gateway_network_config).to eql({})
    end

    it "with a default gateway" do
      expect(@processor.default_gateway_network_config).to eql(@gateway_hash1)
    end

    it "with a different default gateway" do
      @processor.stubs(:default_gateway_network).returns("ff80808150b4e04d0150b4ef67800089")
      expect(@processor.default_gateway_network_config).to eql(@gateway_hash2)
    end

    it "with no static network adapter and no default gateway" do
      @processor.stubs(:vm_networks).returns([])
      @processor.stubs(:default_gateway_network).returns("")
      expect(@processor.post_os_config).to eql(@emtpy_config)
    end

    it "with one static network adapter and no default gateway" do
      @processor.stubs(:vm_networks).returns(@vm_network1)
      @processor.stubs(:default_gateway_network).returns("")
      tmp_config = @emtpy_config
      tmp_config["resources"] = @snc_1n
      @processor.stubs(:host_ip_config).returns(appliance_ip)
      tmp_config["resources"]["host"] = {"dellasm" => {"ensure" => "present", "ip" => appliance_ip}}
      expect(@processor.post_os_config).to eql(tmp_config)
    end

    it "with one static network adapter and a default gateway" do
      @processor.stubs(:vm_networks).returns(@vm_network1)
      @processor.stubs(:default_gateway_network).returns("ff80808150b4e04d0150b4f1394800a4")
      @processor.stubs(:host_ip_config).returns(appliance_ip)
      tmp_config = @emtpy_config
      tmp_config["resources"] = @snc_1n
      tmp_config["classes"] = @gateway_hash1
      tmp_config["resources"]["network::if::static"][0]["defroute"] = "yes"
      tmp_config["resources"]["host"] = {"dellasm" => {"ensure" => "present", "ip" => appliance_ip}}
      expect(@processor.post_os_config).to eql(tmp_config)
    end

    it "with two static network adapter and no default gateway" do
      @processor.stubs(:default_gateway_network).returns("")
      @processor.stubs(:host_ip_config).returns(appliance_ip)
      tmp_config = @emtpy_config
      tmp_config["resources"] = @snc_2n
      tmp_config["resources"]["host"] = {"dellasm" => {"ensure" => "present", "ip" => appliance_ip}}
      expect(@processor.post_os_config).to eql(tmp_config)
    end

    it "with two static network adapter and a default gateway" do
      @processor.stubs(:default_gateway_network).returns("ff80808150b4e04d0150b4f1394800a4")
      @processor.stubs(:host_ip_config).returns(appliance_ip)
      tmp_config = @emtpy_config
      tmp_config["resources"] = @snc_2n
      tmp_config["classes"] = @gateway_hash1
      tmp_config["resources"]["network::if::static"][0]["defroute"] = "yes"
      tmp_config["resources"]["host"] = {"dellasm" => {"ensure" => "present", "ip" => appliance_ip}}
      expect(@processor.post_os_config).to eql(tmp_config)
    end

    it "with two static network adapter and another default gateway" do
      @processor.stubs(:default_gateway_network).returns("ff80808150b4e04d0150b4ef67800089")
      @processor.stubs(:host_ip_config).returns(appliance_ip)
      tmp_config = @emtpy_config
      tmp_config["resources"] = @snc_2n
      tmp_config["classes"] = @gateway_hash2
      tmp_config["resources"]["network::if::static"][1]["defroute"] = "yes"
      tmp_config["resources"]["host"] = {"dellasm" => {"ensure" => "present", "ip" => appliance_ip}}
      expect(@processor.post_os_config).to eql(tmp_config)
    end
  end

  describe "should configure linux vm post installation" do
    it "with one dhcp network adapter" do
      @processor.stubs(:vm_networks).returns(@vm_network2)
      @processor.stubs(:default_gateway_network).returns("")
      expect(@processor.process_network_config).to eql({"resources" => @dnc_1n})
    end

    it "with two dhcp network adapters" do
      @processor.stubs(:default_gateway_network).returns("")
      @processor.stubs(:vm_networks).returns(@vm_network3)
      expect(@processor.process_network_config).to eql({"resources" => @dnc_2n})
    end
  end
end

require "spec_helper"
require "asm/service"
require "asm/service_deployment"
describe ASM::Processor::PostOS do
  let(:sd) { ASM::ServiceDeployment.new("123456", nil) }
  let(:service_deployment) { SpecHelper.json_fixture("processor/post_os/post_os.json") }
  let(:component) { service_deployment["serviceTemplate"]["components"].last }
  let(:nw1_ip) {"172.20.3.125"}
  let(:config_network_windows_VM) {
    [{
          "id" => "ff8080815570764101557098f98233e1",
          "name" => "Workload - Static",
          "description" => "",
          "type" => "PUBLIC_LAN",
          "vlanId" => 20,
          "static" => true,
          "staticNetworkConfiguration" =>
              {
                 "gateway" => "172.20.0.1",
                 "subnet" => "255.255.0.0",
                 "primaryDns" => "172.20.0.8",
                 "secondaryDns" => nil,
                 "dnsSuffix" => "asmdev.local",
                 "ipRange" =>
                     [{
                           "Id" => "ff8080815570764101557098f98233e2",
                           "StartingIp" => "172.20.3.125",
                           "EndingIp" => "172.20.3.149"
                      }],
                 "ipAddress" => "172.20.3.125"
              }
     }]
  }

  let(:config_network_hash_linux_VM) {
    [{
         "id" => "ff8080815570764101557098f98233e1",
         "name" => "Workload - Static",
         "description" => "",
         "type" => "PUBLIC_LAN",
         "vlanId" => 20,
         "static" => true,
         "staticNetworkConfiguration" =>
             {
                 "gateway" => "172.20.0.1",
                 "subnet" => "255.255.0.0",
                 "primaryDns" => "172.20.0.8",
                 "secondaryDns" => nil,
                 "dnsSuffix" => "asmdev.local",
                 "ipRange" =>
                     [{
                          "Id" => "ff8080815570764101557098f98233e2",
                          "StartingIp" => "172.20.3.125",
                          "EndingIp" => "172.20.3.149"
                      }],
                 "ipAddress" => "172.20.3.125"
             }
     }]
  }

  let(:config_network_hash2) {
    [{:network =>
          [{"id" => "ff80808150b4e04d0150b4f1394800a4",
            "name" => "Work Static",
            "description" => "",
            "type" => "PRIVATE_LAN",
            "vlanId" => 20,
            "static" => false,
            "staticNetworkConfiguration" =>
                {"gateway" => "172.20.0.1", "subnet" => "255.255.0.0", "primaryDns" => "172.20.0.8", "secondaryDns" => nil, "dnsSuffix" => "aidev.com", "ipAddress" => nw1_ip}}],
      :mac_addresses => ["00:0A:F7:38:94:F0", "00:0A:F7:38:94:F2"]},
     {:network =>
          [{"id" => "ff80808150b4e04d0150b4ef67800089",
            "name" => "Public Static",
            "description" => "",
            "type" => "PUBLIC_LAN",
            "vlanId" => 22,
            "static" => false,
            "staticNetworkConfiguration" =>
                {"gateway" => "172.22.0.1", "subnet" => "255.255.0.0", "primaryDns" => "172.20.0.8", "secondaryDns" => nil, "dnsSuffix" => "aidev.com", "ipAddress" => "172.22.11.100"}}],
      :mac_addresses => ["00:0A:F7:38:94:F4", "00:0A:F7:38:94:F6"]}]

  }

  before do
    ASM.init_for_tests
    sd.stubs(:service_hash).returns(service_deployment)
    @post_os = ASM::Processor::PostOS.new(sd, component)
  end

  after do
    ASM.reset
  end

  describe "#host_ip_config" do
    let(:appliance_ip) { "172.20.5.100" }
    let(:default_ip) { "1.1.1.1" }
    it "should return appliance IP for given networks" do
      ASM::Util.expects(:default_routed_ip).once.returns(default_ip)
      ASM::Util.expects(:get_preferred_ip).with(nw1_ip).returns(appliance_ip)
      expect(@post_os.host_ip_config(config_network_windows_VM)).to eq(appliance_ip)
    end

    it "should return default IP for given networks when not static" do
      ASM::Util.expects(:default_routed_ip).once.returns(default_ip)
      ASM::Util.expects(:get_preferred_ip).never
      expect(@post_os.host_ip_config(config_network_hash2)).to eq(default_ip)
    end

    it "should return valid appliance IP for linux_vm post install networks" do
      ASM::Util.expects(:default_routed_ip).once.returns(default_ip)
      ASM::Util.expects(:get_preferred_ip).with(nw1_ip).returns(appliance_ip)
      expect(@post_os.host_ip_config(config_network_hash_linux_VM)).to eq(appliance_ip)
    end
  end

  describe "#post_os_services" do
    it "should call #post_os_components with both 'class' and 'type'" do
      @post_os.expects(:post_os_components).with("type").returns({})
      @post_os.expects(:post_os_components).with("class").returns({})

      @post_os.post_os_services
    end
  end

describe "#post_os_components" do
    before do
      @component1 = mock("component1")
      @component2 = mock("component2")
      @component3 = mock("component3")
      @component4 = mock("component4")
      applications = [
        {"install_order"=>"1", "name"=>"linux_postinstall", "service_type"=>"class", "component"=> @component1},
        {"install_order"=>"2", "name"=>"haproxy", "service_type"=>"class", "component" => @component2},
        {"install_order"=>"3", "name"=>"haproxy::listen", "service_type"=>"type", "component"=> @component3},
        {"install_order"=>"4", "name"=>"haproxy::balancermember", "service_type"=>"type", "component"=> @component4}
      ]
      @post_os.stubs(:applications).returns(applications)
    end
    context "when type is 'type'" do
      it "should call #post_os_component in order with the correct params" do
        s = sequence(:process_order)

        @post_os.expects(:post_os_component).with(@component3, "type").returns({}).in_sequence(s).twice
        @post_os.expects(:build_require_name).with(@component3, "type").returns("Haproxy::Listen['puppet00']").in_sequence(s)
        @post_os.expects(:post_os_component).with(@component4, "type").returns({}).in_sequence(s).twice
        @post_os.expects(:build_require_name).with(@component4, "type").returns({}).in_sequence(s)

        @post_os.post_os_components("type")
      end
    end

    context "when there are more than 1 of a type" do
      it "should add key to type" do
        s = sequence(:process_order)

        @post_os.expects(:post_os_component).with(@component3, "type").returns({"say_something"=>{"message 1"=>{"ensure"=>"present"}}}).in_sequence(s).twice
        @post_os.expects(:build_require_name).with(@component3, "type").returns("Say_something[message 1]").in_sequence(s)
        @post_os.expects(:post_os_component).with(@component4, "type").returns({"say_something"=>
                                                                                  {"message 2"=>
                                                                                     {"ensure"=>"present", "require"=>"Say_something[message 1]"}}}).in_sequence(s)
        @post_os.expects(:build_require_name).with(@component4, "type").returns({}).in_sequence(s)

        expect(@post_os.post_os_components("type")).to eq({"say_something"=>
          {"message 1" =>{"ensure"=>"present"},
          "message 2"=>{"ensure"=>"present", "require"=>"Say_something[message 1]"}}})
      end
    end

    context "when type is 'class'" do
      it "should call #post_os_component in order with the correct params" do
        s = sequence(:process_order)

        @post_os.expects(:post_os_component).with(@component1, "class").returns({}).in_sequence(s).twice
        @post_os.expects(:build_require_name).with(@component1, "class").returns("Class['linux_postinstall']").never
        @post_os.expects(:post_os_component).with(@component2, "class").returns({}).in_sequence(s).twice
        @post_os.expects(:build_require_name).with(@component2, "class").returns({}).never

        @post_os.post_os_components("class")
      end
    end
  end

  describe "#post_os_component" do
    context "when component_type is 'class'" do
      it "should create the correct puppet hash" do
        component = @post_os.applications[0]["component"]

        expect(@post_os.post_os_component(component, "class")).to eq({"linux_postinstall"=>
                                                                           {"install_packages"=>"httpd", "upload_recursive"=>false}})
      end
    end

    context "when component_type is 'type'" do
      it "should create the correct puppet hash" do
        component = @post_os.applications[2]["component"]

        expect(@post_os.post_os_component(component, "type")).to eq({"haproxy::listen"=>
                                                                          {"puppet00"=>
                                                                             {"collect_exported"=>false, "ipaddress"=>"0.0.0.0", "ports"=>"8080"}}})
      end

      it "should create the correct puppet hash with requirement" do
        component = @post_os.applications[3]["component"]
        @post_os.instance_variable_set("@required_resource", "Haproxy::Listen['puppet00']")

        expect(@post_os.post_os_component(component, "type")).to eq({"haproxy::balancermember"=>
                                                                                                     {"master00"=>
                                                                                                        {"listening_service"=>"puppet00", "require"=>"Haproxy::Listen['puppet00']", "server_names"=>"master00.example.com", "ipaddresses"=>"10.0.0.10", "ports"=>"8140"}}})
      end
    end
  end

  describe "#build_require_name" do
    context "when type is 'class'" do
      it "should build the required param value for the puppet hash" do
        component = @post_os.applications[0]["component"]

        expect(@post_os.build_require_name(component, "class")).to eq("Class[linux_postinstall]")
      end
    end

    context "when type is 'type'" do
      it "should build the required param value for the puppet hash" do
        component = @post_os.applications[2]["component"]

        expect(@post_os.build_require_name(component, "type")).to eq("Haproxy::Listen[puppet00]")
      end
    end
  end

  describe "#applications" do
    it "should return associated_applications" do
      expect(@post_os.applications).not_to be_empty
    end
  end
end

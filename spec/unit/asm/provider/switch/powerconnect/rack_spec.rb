require 'spec_helper'
require 'asm/provider/switch/powerconnect/rack'

describe ASM::Provider::Switch::Powerconnect::Rack do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:provider) { stub(:type => stub(:puppet_certname => "rspec"), :logger => logger) }
  let(:server) { ASM::Provider::Switch::Powerconnect::Rack.new(provider) }

  describe "#validate_vlans!" do
    it "should allow multiple untagged vlans on different ports" do
      server.configure_interface_vlan("18", "1", false)
      server.configure_interface_vlan("20", "1", false)

      server.validate_vlans!
    end

    it "should not allow multiple untagged vlans on the same port" do
      server.configure_interface_vlan("1", "1", false)
      server.configure_interface_vlan("1", "2", false)

      expect {
        server.validate_vlans!
      }.to raise_error("Can only have one untagged network but found multiple untagged vlan requests for the same port on rspec")
    end
  end

  describe "#configure_interface_vlan" do
    it "should add the interface correctly" do
      server.configure_interface_vlan("Te1/0/29", "28", false)
      server.configure_interface_vlan("Te1/0/29", "1", false, true)
      server.configure_interface_vlan("Te1/0/29", "20", true)
      server.configure_interface_vlan("Te1/0/29", "20", true, true)
      expect(server.interface_map).to include({:interface => "Te1/0/29", :portchannel=>"", :vlan => "28", :tagged => false, :action => :add})
      expect(server.interface_map).to include({:interface => "Te1/0/29", :portchannel=>"", :vlan => "1", :tagged => false, :action => :remove})
      expect(server.interface_map).to include({:interface => "Te1/0/29", :portchannel=>"", :vlan => "20", :tagged => true, :action => :add})
      expect(server.interface_map).to include({:interface => "Te1/0/29", :portchannel=>"", :vlan => "20", :tagged => true, :action => :remove})
    end
  end

  describe "#populate_vlan_resources" do
    context "when action is :add" do
      it "should create the correct vlan resources" do
        server.configure_interface_vlan("Te1/0/29", "28", false)
        server.expects(:populate_interface_resource).with("Te1/0/29", {:action => :add, :portchannel => "", :tagged => [], :untagged => ["28"]})
        server.populate_resources(:add)
      end
    end

    context "when action is :remove" do
      it "should create vlan resources with remove" do
        server.configure_interface_vlan("Te1/0/29", "1", false, true)

        server.expects(:populate_interface_resource).with("Te1/0/29", {:action => :remove, :portchannel => "", :tagged => [], :untagged => ["1"]})
        server.populate_resources(:remove)
      end
    end
  end

  describe "#populate_interface_resource" do
    context "when untagged" do
      it "should create a the correct resources" do
        server.populate_interface_resource("Te1/0/29", {:action => :add, :portchannel => "", :tagged => [], :untagged => ["28"]})

        expect(server.port_resources["powerconnect_interface"]).to include("Te1/0/29")
        interface = server.port_resources["powerconnect_interface"]["Te1/0/29"]
        expect(interface["untagged_general_vlans"]).to eq(["28"])
        expect(interface["portfast"]).to eq("true")

        #TODO: vlans now populated in populate_vlan_resources method, need tests for that method instead
        # expect(server.port_resources["powerconnect_vlan"]).to include("28")
        # vlan = server.port_resources["powerconnect_vlan"]["28"]
        # expect(vlan["ensure"]).to eq("present")
        # expect(vlan["require"]).to eq("Powerconnect_interface[Te1/0/29]")
      end
    end

    context "when remove" do
      it "should create the correct teardown resource" do
        server.populate_interface_resource("Te1/0/29", {:action => :remove, :tagged => [], :untagged => ["1"], :portchannel => ""})

        expect(server.port_resources["powerconnect_interface"]).to include("Te1/0/29")
        interface = server.port_resources["powerconnect_interface"]["Te1/0/29"]
        expect(interface["shutdown"]).to eq("false")
        expect(interface["untagged_general_vlans"]).to eq(["1"])
        expect(interface["tagged_general_vlans"]).to eq([])
        expect(server.port_resources["powerconnect_vlan"]).to be_nil
      end
    end
  end

  describe "#to_puppet" do
    it "should join array properties to strings when action is :add" do
      server.stubs(:port_resources).returns({
                                                "powerconnect_interface" => {
                                                    "Te1/0/29" => {
                                                        "untagged_general_vlans" => ["28"],
                                                        "tagged_general_vlans" => ["20"],
                                                        "portfast" => "true"}},
                                                "powerconnect_vlan" => {
                                                    "20" => {"ensure" => "present", "require" => "Powerconnect_interface[Te1/0/29]"},
                                                    "29" => {"ensure" => "present", "require" => "Powerconnect_interface[Te1/0/29]"}
                                                }
                                            })

      expect(server.to_puppet).to eq({
                                         "powerconnect_interface" => {
                                             "Te1/0/29" => {
                                                 "untagged_general_vlans" => "28",
                                                 "tagged_general_vlans" => "20",
                                                 "portfast" => "true"}},
                                         "powerconnect_vlan" => {
                                             "20" => {"ensure" => "present", "require" => "Powerconnect_interface[Te1/0/29]"},
                                             "29" => {"ensure" => "present", "require" => "Powerconnect_interface[Te1/0/29]"}
                                         }
                                     })
    end

    it "should join array properties to strings when action is :remove" do
      server.stubs(:port_resources).returns({
                                                "powerconnect_interface" => {
                                                    "Te1/0/29" => {
                                                        "untagged_general_vlans" => ["1"],
                                                        "tagged_general_vlans" => [],
                                                        "portfast" => "true"}}
                                            })
      expect(server.to_puppet).to eq({
                                         "powerconnect_interface" => {
                                             "Te1/0/29" => {
                                                 "untagged_general_vlans" => "1",
                                                 "tagged_general_vlans" => "",
                                                 "portfast" => "true"}}
                                     })
    end
  end

  describe "#prepare" do
    it "should correctly configure the internal state" do
      prepare = sequence(:prepare)
      server.expects(:reset!).in_sequence(prepare)
      server.expects(:validate_vlans!).in_sequence(prepare)
      server.expects(:populate_resources).with(:add).in_sequence(prepare)

      server.stubs(:port_resources).returns({})

      expect(server.prepare(:add)).to be(false)
    end

    it "should correctly indicate if a process! is needed" do
      server.stubs(:reset!)
      server.stubs(:populate_resources)

      server.stubs(:port_resources).returns({})
      expect(server.prepare(:add)).to be(false)

      server.stubs(:port_resources).returns({"powerconnect_interface" => {}})
      expect(server.prepare(:add)).to be(true)
    end
  end

  describe "#reset!" do
    it "should clear the prepared resources" do
      server.port_resources["rspec"] = true

      expect(server.port_resources).to_not be_empty
      server.reset!
      expect(server.port_resources).to be_empty
    end
  end

end

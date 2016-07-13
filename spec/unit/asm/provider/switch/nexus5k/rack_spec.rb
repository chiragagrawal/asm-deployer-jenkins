require 'spec_helper'
require 'asm/provider/switch/nexus5k/rack'

describe ASM::Provider::Switch::Nexus5k::Rack do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:provider) { stub(:type => stub(:puppet_certname => "rspec"), :logger => logger) }
  let(:rack) { ASM::Provider::Switch::Nexus5k::Rack.new(provider) }

  describe "#validate_vlans!" do
    it "should allow multiple untagged vlans on different ports" do
      rack.configure_interface_vlan("1", "1", false)
      rack.configure_interface_vlan("2", "1", false)

      rack.validate_vlans!
    end

    it "should not allow multiple untagged vlans on the same port" do
      rack.configure_interface_vlan("1", "1", false)
      rack.configure_interface_vlan("1", "2", false)

      expect {
        rack.validate_vlans!
      }.to raise_error("Can only have one untagged network but found multiple untagged vlan requests for the same port on rspec")
    end
  end

  describe "#configure_interface_vlan" do
    context "when standup" do
      it "should add the interface correctly" do
        rack.configure_interface_vlan("Eth1/21", "28", false)

        expect(rack.interface_map).to include({:interface => "Eth1/21", :mtu => "12000", :vlan => "28", :tagged => false, :action => :add})
      end
    end
    context "when teardown" do
      it "should add remove the interface correctly" do
        rack.configure_interface_vlan("Eth1/21", "28", false, true)

        expect(rack.interface_map).to include({:interface => "Eth1/21", :mtu => "12000", :vlan => "28", :tagged => false, :action => :remove})
      end
    end

  end

  describe "#configure_interface_vsan" do
    context "when standup" do
      it "should add the interface correctly" do
        rack.configure_interface_vsan("Eth1/21", "255")

        expect(rack.vsan_map).to include({:interface => "Eth1/21", :vsan => "255", :action => :add})
      end
    end

    context "when teardown" do
      it "should remove the interface correctly" do
        rack.configure_interface_vsan("Eth1/21", "255", true)

        expect(rack.vsan_map).to include({:interface => "Eth1/21", :vsan => "255", :action => :remove})
      end
    end

  end

  describe "#populate_vlan_resources" do
    context "when action is :add" do
      it "should create the correct vlan resources" do
        rack.configure_interface_vlan("Eth1/21", "28", false)

        rack.expects(:vlan_resource).with("Eth1/21", :add, {:tagged_tengigabitethernet => [], :untagged_tengigabitethernet => ["28"]})
        rack.populate_vlan_resources(:add)
      end

      it "should create the correct vlan resources" do
        rack.configure_interface_vlan("Eth1/21", "28", true)

        rack.expects(:vlan_resource).with("Eth1/21", :add, {:tagged_tengigabitethernet => ["28"], :untagged_tengigabitethernet => []})
        rack.populate_vlan_resources(:add)
      end
    end

    context "when the action is :remove" do
      it "should create the correct vlan teardown resource" do
        rack.configure_interface_vlan("Eth1/21", "1", false, true)

        rack.expects(:vlan_resource).with("Eth1/21", :remove, {:tagged_tengigabitethernet => [], :untagged_tengigabitethernet => ["1"]})
        rack.populate_vlan_resources(:remove)
      end
    end
  end

  describe "#vlan_resource" do
    context "when untagged" do
      it "should create a new resource with untagged" do
        rack.vlan_resource("Eth1/21", :add, {:tagged_tengigabitethernet => [], :untagged_tengigabitethernet => ["28"]})

        expect(rack.port_resources["cisconexus5k_interface"]).to include("Eth1/21")
        interface = rack.port_resources["cisconexus5k_interface"]["Eth1/21"]
        expect(interface["switchport_mode"]).to eq("trunk")
        expect(interface["shutdown"]).to eq("false")
        expect(interface["ensure"]).to eq("present")
        expect(interface["untagged_general_vlans"]).to eq(["28"])


        expect(rack.port_resources["cisconexus5k_vlan"]).to include("28")
        vlan = rack.port_resources["cisconexus5k_vlan"]["28"]
        expect(vlan["ensure"]).to eq("present")
        expect(vlan["require"]).to eq("Cisconexus5k_interface[Eth1/21]")
      end
    end

    context "when tagged" do
      it "should create a new resource with tagged" do
        rack.vlan_resource("Eth1/21", :add, {:tagged_tengigabitethernet => ["28"], :untagged_tengigabitethernet => []})

        expect(rack.port_resources["cisconexus5k_interface"]).to include("Eth1/21")
        interface = rack.port_resources["cisconexus5k_interface"]["Eth1/21"]
        expect(interface["switchport_mode"]).to eq("trunk")
        expect(interface["shutdown"]).to eq("false")
        expect(interface["ensure"]).to eq("present")
        expect(interface["tagged_general_vlans"]).to eq(["28"])


        expect(rack.port_resources["cisconexus5k_vlan"]).to include("28")
        vlan = rack.port_resources["cisconexus5k_vlan"]["28"]
        expect(vlan["ensure"]).to eq("present")
        expect(vlan["require"]).to eq("Cisconexus5k_interface[Eth1/21]")
      end
    end

    context "when teardown" do
      it "should create the correct tear down resource" do
        rack.vlan_resource("Eth1/21", :remove, {:tagged_tengigabitethernet => [], :untagged_tengigabitethernet => ["1"]})

        expect(rack.port_resources["cisconexus5k_interface"]).to include("Eth1/21")
        interface = rack.port_resources["cisconexus5k_interface"]["Eth1/21"]
        expect(interface["switchport_mode"]).to eq("trunk")
        expect(interface["shutdown"]).to eq("false")
        expect(interface["ensure"]).to eq("present")
        expect(interface["tagged_general_vlans"]).to eq([])
        expect(interface["untagged_general_vlans"]).to eq(["1"])
        expect(interface["interfaceoperation"]).to eq("remove")
        expect(rack.port_resources["cisconexus5k_vlan"]).to be_nil
      end
    end
  end

  describe "#populate_vsan_resources" do
    context "when action is :add" do
      it "should create the correct vsan resources" do
        rack.configure_interface_vsan("Eth1/21", "255")

        rack.expects(:vfc_resource).with("21", "Eth1/21")
        rack.expects(:vsan_resource).with("255", :add, {:membership => "vfc21", :vlan => "21"})

        rack.populate_vsan_resources(:add)
      end
    end

    context "when action is :remove" do
      it "should create the correct vsan resource" do
        rack.configure_interface_vsan("Eth1/21", "255", true)

        rack.expects(:vfc_resource).with("21", "Eth1/21")
        rack.expects(:vsan_resource).with("255", :remove, {:membership => "vfc21", :vlan => "21"})

        rack.populate_vsan_resources(:remove)
      end
    end
  end

  describe "#vfc_resource" do
    it "should create the correct vfc resource" do
      rack.vfc_resource("21", "Eth1/21")

      expect(rack.port_resources["cisconexus5k_vfc"]).to include("21")
      vfc = rack.port_resources["cisconexus5k_vfc"]["21"]

      expect(vfc["bind_interface"]).to eq("Eth1/21")
      expect(vfc["shutdown"]).to eq("false")
    end
  end

  describe "#vsan_resource" do
    it "should create the correct vsan resource" do
      rack.vsan_resource("255", :add, {:membership => "vfc21", :vlan => "21"})

      expect(rack.port_resources["cisconexus5k_vsan"]).to include("255")
      vsan = rack.port_resources["cisconexus5k_vsan"]["255"]

      expect(vsan["membership"]).to eq("vfc21")
      expect(vsan["membershipoperation"]).to eq("add")
      expect(vsan["require"]).to eq("Cisconexus5k_vfc[21]")
    end
  end

  describe "#to_puppet" do
    it "should join arry properties to strings" do
      rack.stubs(:port_resources).returns({
                                              "cisconexus5k_interface" => {
                                                  "Eth1/21" => {
                                                      "tagged_general_vlans" => [],
                                                      "untagged_general_vlans" => "1"
                                                  }
                                              },
                                              "cisconexus5k_vfc" => {
                                                  "21" => {
                                                      "bind_interface" => ["Eth1/21"],
                                                  }
                                              }
                                          })

      expect(rack.to_puppet).to eq({
                                       "cisconexus5k_interface" => {
                                           "Eth1/21" => {
                                               "tagged_general_vlans" => "",
                                               "untagged_general_vlans" => "1"
                                           }
                                       },
                                       "cisconexus5k_vfc" => {
                                           "21" => {
                                               "bind_interface" => "Eth1/21",
                                           }
                                       }
                                   })
    end
  end

  describe "#prepare" do
    it "should correctly configure the internal state" do
      prepare = sequence(:prepare)
      rack.expects(:reset!).in_sequence(prepare)
      rack.expects(:validate_vlans!).in_sequence(prepare)
      rack.expects(:populate_vlan_resources).with(:add).in_sequence(prepare)
      rack.expects(:populate_vsan_resources).with(:add).in_sequence(prepare)

      rack.stubs(:port_resources).returns({})

      expect(rack.prepare(:add)).to be(false)
    end

    it "should correctly indicate if a process! is needed" do
      rack.stubs(:reset!)
      rack.stubs(:populate_vlan_resources)
      rack.stubs(:populate_vsan_resources)

      rack.stubs(:port_resources).returns({})
      expect(rack.prepare(:add)).to be(false)

      rack.stubs(:port_resources).returns({"asm::cisconexus5k" => {}})
      expect(rack.prepare(:add)).to be(true)
    end
  end

  describe "#reset!" do
    it "should clear the prepared resources" do
      rack.port_resources["rspec"] = true

      expect(rack.port_resources).to_not be_empty
      rack.reset!
      expect(rack.port_resources).to be_empty
    end
  end
end


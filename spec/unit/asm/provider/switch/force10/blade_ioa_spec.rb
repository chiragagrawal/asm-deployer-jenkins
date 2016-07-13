require 'spec_helper'
require 'asm/provider/switch/force10/blade_ioa'

describe ASM::Provider::Switch::Force10::BladeIoa do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:provider) { stub(:type => stub(:puppet_certname => "rspec"), :logger => logger) }
  let(:blade) { ASM::Provider::Switch::Force10::BladeIoa.new(provider) }
  let(:vltdata) { {"uplinkId" => "vlt", "uplinkName" => "VLT", "portChannel" => nil, "portMembers" => ["Te 0/44", "Te 0/37"], "portNetworks" => []} }
  let(:vltdata2) { {"uplinkId" => "vlt", "uplinkName" => "VLT", "portChannel" => nil, "portMembers" => ["Te 0/44", "Te 0/37"], "portNetworks" => [], "model" => "PE-FN-410S-IOM"} }

  describe "#initialize_ports!" do
    it "should not initialize IOAs" do
      provider.stubs(:model).returns("IOA")
      blade.expects(:port_names).never
      blade.initialize_ports!
    end

    it "should initialize each port" do
      provider.stubs(:model).returns("I/O-Aggregator")
      blade.expects(:port_names).returns(["Te 0/0", "Te 0/1"])
      blade.expects(:configure_interface_vlan).with("Te 0/0", "1", false, true)
      blade.expects(:configure_interface_vlan).with("Te 0/0", "1", true, true)
      blade.expects(:configure_interface_vlan).with("Te 0/1", "1", false, true)
      blade.expects(:configure_interface_vlan).with("Te 0/1", "1", true, true)
      blade.expects(:populate_interface_resources).with(:remove)
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

  describe "#ioa_interface_resource" do
    it "should not double manage a resource" do
      blade.ioa_interface_resource("po 10", [], [])
      expect {
        blade.ioa_interface_resource("po 10", [], [])
      }.to raise_error("Ioa_interface[po 10] is already being managed on rspec")
    end

    it "should create a resource" do
      blade.ioa_interface_resource("po 10", ["10", "11"], ["12", "13"])
      blade.ioa_interface_resource("po 11", [], [])

      expect(blade.port_resources["ioa_interface"]["po 10"]).to eq({
        "vlan_tagged" => "10,11",
        "vlan_untagged" => "12,13",
        "switchport" => true,
        "portmode" => "hybrid"
      })

      expect(blade.port_resources["ioa_interface"]["po 11"]).to eq({
        "switchport" => true,
        "portmode" => "hybrid",
        "require" => "Ioa_interface[po 10]"
      })
    end
  end

  describe "#configure_iom_mode!" do
    before(:each) do
      blade.configure_interface_vlan("1", "1", false)
      blade.populate_interface_resources(:add)
    end

    it "should support setting the sequence" do
      blade.configure_iom_mode!(false, true, vltdata)
      expect(blade.port_resources["ioa_mode"]["vlt"]["require"]).to eq("Ioa_interface[1]")
    end

    it "should supprot full_switch for FNIOA without vlt" do
      provider.type.stubs(:model).returns("PE-FN-410S-IOM")
      blade.configure_iom_mode!(true, true, nil)
      expect(blade.port_resources["ioa_mode"]).to include("fullswitch")
      expect(blade.sequence).to eq("Ioa_mode[fullswitch]")
    end

    it "should fail for multiple invocations" do
      blade.configure_iom_mode!(false, true, vltdata)
      expect { blade.configure_iom_mode!(true, false, vltdata) }.to raise_error("iom mode resource is already created in this instance for switch rspec")
    end

    it "should support fullswitch mode for FNIOA" do
      blade.configure_iom_mode!(false, true, vltdata2)
      expect(blade.port_resources["ioa_mode"]).to include("fullswitch")
      expect(blade.sequence).to eq("Ioa_mode[fullswitch]")
    end

    it "should support fullswitch mode without ethernet_mode for FNIOA" do
      blade.configure_iom_mode!(false, false, vltdata2)
      expect(blade.port_resources["ioa_mode"]).to include("fullswitch")
      expect(blade.port_resources["ioa_mode"]["fullswitch"]["ioa_ethernet_mode"]).to eq("true")
      expect(blade.sequence).to eq("Ioa_mode[fullswitch]")
    end

    it "should support vlt mode" do
      blade.configure_iom_mode!(false, true, vltdata)
      expect(blade.port_resources["ioa_mode"]).to include("vlt")
      expect(blade.sequence).to eq("Ioa_mode[vlt]")
    end

    it "should support pmux mode without ethernet_mode" do
      provider.type.stubs(:model).returns("I/O-Aggregator")
      blade.configure_iom_mode!(true, false)
      expect(blade.port_resources["ioa_mode"]).to include("pmux")
      expect(blade.port_resources["ioa_mode"]["pmux"]["ioa_ethernet_mode"]).to eq("false")
      expect(blade.sequence).to eq("Ioa_mode[pmux]")
    end

    it "should support pmux mode with ethernet_mode" do
      provider.type.stubs(:model).returns("I/O-Aggregator")
      blade.configure_iom_mode!(true, true)
      expect(blade.port_resources["ioa_mode"]).to include("pmux")
      expect(blade.port_resources["ioa_mode"]["pmux"]["ioa_ethernet_mode"]).to eq("true")
      expect(blade.port_resources["ioa_mode"]["pmux"]["vlt"]).to eq(false)
      expect(blade.sequence).to eq("Ioa_mode[pmux]")
    end

    it "should support both vlt and pmux being false" do
      blade.configure_iom_mode!(false, false)
      expect(blade.port_resources).to_not include("ioa_mode")
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

      expect(blade.interface_map).to include({:interface => "1", :portchannel => "", :vlan => "1", :tagged => true, :mtu => "12000", :action => :add})
      expect(blade.interface_map).to include({:interface => "2", :portchannel => "", :vlan => "2", :tagged => false, :mtu => "12000", :action => :add})
      expect(blade.interface_map).to include({:interface => "3", :portchannel => "", :vlan => "3", :tagged => true, :mtu => "12000", :action => :remove})
    end
  end

  describe "#populate_interface_resources" do
    it "should create the correct interface resources" do
      blade.configure_interface_vlan("Te 1/1", "10", true)
      blade.configure_interface_vlan("Te 1/1", "18", false)
      blade.configure_interface_vlan("Te 1/2", "18", false)
      blade.configure_interface_vlan("Te 1/3", "18", false, true)

      blade.populate_interface_resources(:add)

      expect(blade.port_resources["ioa_interface"].keys).to eq(["Te 1/1", "Te 1/2"])
      expect(blade.port_resources["ioa_interface"]["Te 1/1"]["vlan_tagged"]).to eq(["10"])
      expect(blade.port_resources["ioa_interface"]["Te 1/1"]["vlan_untagged"]).to eq(["18"])
      expect(blade.port_resources["ioa_interface"]["Te 1/1"]).to_not include("require")
      expect(blade.port_resources["ioa_interface"]["Te 1/2"]["vlan_tagged"]).to eq([])
      expect(blade.port_resources["ioa_interface"]["Te 1/2"]["vlan_untagged"]).to eq(["18"])
      expect(blade.port_resources["ioa_interface"]["Te 1/2"]["require"]).to eq("Ioa_interface[Te 1/1]")


      blade.reset!

      blade.populate_interface_resources(:remove)

      expect(blade.port_resources["ioa_interface"].keys).to eq(["Te 1/3"])
      expect(blade.port_resources["ioa_interface"]["Te 1/3"]["vlan_tagged"]).to eq([])
      expect(blade.port_resources["ioa_interface"]["Te 1/3"]["vlan_untagged"]).to eq(["18"])
    end
  end

  describe "#to_puppet" do
    it "should join array properties to strings" do
      blade.stubs(:port_resources).returns({
        "ioa_interface" => {
          "Te 1/1" => {
            "vlan_tagged" => ["1", "2", "3"],
            "vlan_untagged" => ["4", "5", "6"],
          }
        }
      })

      expect(blade.to_puppet).to eq({
        "ioa_interface" => {
          "Te 1/1" => {
            "vlan_tagged" => "1,2,3",
            "vlan_untagged" => "4,5,6",
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
      blade.expects(:populate_interface_resources).with(:add).in_sequence(prepare)

      blade.stubs(:port_resources).returns({})

      expect(blade.prepare(:add)).to be(false)
    end

    it "should correctly indicate if a process! is needed" do
      blade.stubs(:reset!)
      blade.stubs(:populate_interface_resources)

      blade.stubs(:port_resources).returns({})
      expect(blade.prepare(:add)).to be(false)

      blade.stubs(:port_resources).returns({"ioa_interface" => {}})
      expect(blade.prepare(:add)).to be(true)
    end
  end
end

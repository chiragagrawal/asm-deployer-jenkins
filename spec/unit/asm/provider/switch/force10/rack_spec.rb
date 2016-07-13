require 'spec_helper'
require 'asm/provider/switch/force10/rack'

describe ASM::Provider::Switch::Force10::Rack do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:provider) { stub(:type => stub(:puppet_certname => "rspec"), :logger => logger) }
  let(:rack) { ASM::Provider::Switch::Force10::Rack.new(provider) }

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
      }.to raise_error("can only have one untagged network but found multiple untagged vlan requests for the same port on rspec")
    end
  end

  describe "#configure_interface_vlan" do
    it "should add the interface correctly" do
      rack.configure_interface_vlan("1", "1", true)
      rack.configure_interface_vlan("2", "2", false)
      rack.configure_interface_vlan("3", "3", true, true)

      expect(rack.interface_map).to include({:interface => "1", :portchannel=>"", :vlan => "1", :tagged => true, :mtu => "12000",  :action => :add})
      expect(rack.interface_map).to include({:interface => "2", :portchannel=>"", :vlan => "2", :tagged => false, :mtu => "12000", :action => :add})
      expect(rack.interface_map).to include({:interface => "3", :portchannel=>"", :vlan => "3", :tagged => true, :mtu => "12000", :action => :remove})
    end
  end

  describe "#populate_port_resources" do
    it "should create the correct interface resources" do
      rack.configure_interface_vlan("Te 1/1", "10", true)
      rack.configure_interface_vlan("Te 1/2", "10", true)
      rack.configure_interface_vlan("Te 1/1", "11", true)
      rack.configure_interface_vlan("Te 1/1", "18", false)
      rack.configure_interface_vlan("Te 1/3", "18", false, true)

      rack.populate_port_resources(:add)

      expect(rack.port_resources).to include("force10_interface")
      expect(rack.port_resources["force10_interface"]).to include("Te 1/1")
      expect(rack.port_resources["force10_interface"]).to include("Te 1/2")
    end
  end

  describe "#populate_vlan_resources" do
    context "when action is :add" do
      it "should create the correct vlan resources" do
        rack.configure_interface_vlan("Te 1/1", "10", true)
        rack.configure_interface_vlan("Te 1/2", "10", true)
        rack.configure_interface_vlan("Te 1/1", "11", true)
        rack.configure_interface_vlan("Te 1/1", "18", false)
        rack.configure_interface_vlan("Te 1/3", "18", false, true)
        rack.expects(:vlan_resource).with("10", {:interface => 'Te 1/2', :portchannel => '', :vlan => '10', :tagged => true, :mtu => "12000", :action => :add})
        rack.expects(:vlan_resource).with("11", {:interface => 'Te 1/1', :portchannel => '', :vlan => '11', :tagged => true, :mtu => "12000", :action => :add})
        rack.expects(:vlan_resource).with("18", {:interface => 'Te 1/1', :portchannel => '', :vlan => '18', :tagged => false, :mtu => "12000", :action => :add})

        rack.populate_vlan_resources(:add)
      end
    end

    # context "when action is :remove" do
    #   it "should not create any vlan resources" do
    #     rack.configure_interface_vlan("Te 1/3", "18", false, true)
    #
    #     rack.populate_vlan_resources(:remove)
    #   end
    # end
  end

  describe "#vlan_resource" do
    it "should create a new resource if none exist" do
      rack.configure_interface_vlan("Te 1/2", "10", true)
      rack.vlan_resource("10")

      expect(rack.port_resources["force10_vlan"]).to include("10")
      vlan = rack.port_resources["force10_vlan"]["10"]
      expect(vlan["vlan_name"]).to eq ("VLAN_10")
      expect(vlan["before"]).to eq(["Force10_interface[Te 1/2]"])
    end
  end

  describe "#to_puppet" do
    it "should join array properties to strings" do
      rack.stubs(:port_resources).returns({
        "force10_interface" => {
          "10" => {
            "tagged_vlan" => ["18", "20"],
            "untagged_vlan" => ["16", "12"],
          }
        }
      })

      provider.stubs(:model).returns("S4810")

      expect(rack.to_puppet).to eq({
        "force10_interface" => {
          "10" => {
            "tagged_vlan" => "18,20",
            "untagged_vlan" => "12,16",
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
      rack.expects(:populate_port_resources).with(:add).in_sequence(prepare)
      rack.expects(:populate_vlan_resources).with(:add).in_sequence(prepare)

      rack.stubs(:port_resources).returns({})

      expect(rack.prepare(:add)).to be(false)
    end

    it "should correctly indicate if a process! is needed" do
      rack.stubs(:reset!)
      rack.stubs(:populate_port_resources)
      rack.stubs(:populate_vlan_resources)

      rack.stubs(:port_resources).returns({})
      expect(rack.prepare(:add)).to be(false)

      rack.stubs(:port_resources).returns({"asm::force10" => {}})
      expect(rack.prepare(:add)).to be(true)
    end
  end
end

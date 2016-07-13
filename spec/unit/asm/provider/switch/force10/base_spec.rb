require 'spec_helper'
require 'asm/provider/switch/force10/base'

describe ASM::Provider::Switch::Force10::Base do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:provider) { stub(:type => stub(:puppet_certname => "rspec", :iom_mode => "programmable-mux"), :logger => logger) }
  let(:base) { ASM::Provider::Switch::Force10::Base.new(provider) }

  describe "#mxl_vlan_resource" do
    it "should not double manage a resource" do
      base.mxl_vlan_resource("10", "", "", [])
      expect {
        base.mxl_vlan_resource("10", "", "", [])
      }.to raise_error("Mxl_vlan[10] is already being managed on rspec")
    end

    it "should support creating a resource" do
      base.mxl_vlan_resource("10", "rspec name", "rspec description", ["1", "2"])
      expect(base.port_resources["mxl_vlan"]["10"]).to eq({
        "ensure" => "present",
        "shutdown" => "false",
        "vlan_name" => "rspec name",
        "desc" => "rspec description",
        "tagged_portchannel" => "1,2"
      })
    end

    it "should support ensure" do
      base.mxl_vlan_resource("10", "rspec name", "rspec description", ["1", "2"], true)
      expect(base.port_resources["mxl_vlan"]["10"]).to eq({
        "ensure" => "absent"
      })
    end
  end

  describe "#portchannel_resource" do
    it "should not double manage a resource" do
      base.portchannel_resource("10")
      expect {
        base.portchannel_resource("10")
      }.to raise_error("Mxl_portchannel[10] is already being managed on rspec")
    end

    it "should support creating the resource" do
      base.portchannel_resource(10)
      expect(base.port_resources["mxl_portchannel"]["10"]).to eq({
        "ensure" => "present",
        "switchport" => "true",
        "shutdown" => "false",
        "mtu" => "12000",
        "portmode" => "hybrid",
        "fip_snooping_fcf" => "false",
        "vltpeer" => "false",
        "ungroup" => "false"
      })
    end

    it "should support ensure" do
      base.portchannel_resource(10, true, true)
      expect(base.port_resources["mxl_portchannel"]["10"]).to eq({
        "ensure" => "absent",
        "switchport" => "true",
        "shutdown" => "false",
        "mtu" => "12000",
        "portmode" => "hybrid",
        "fip_snooping_fcf" => "true",
        "vltpeer" => "false",
        "ungroup" => "false",
      })
    end
  end

  describe "#mxl_interface_resource" do
    it "should not double manage a resource" do
      base.mxl_interface_resource("Te 0/1", "10")

      expect {
        base.mxl_interface_resource("Te 0/1", "10")
      }.to raise_error("Mxl_interface[Te 0/1] is already being managed on rspec")
    end

    it "should create the resource with a port channel" do
      base.mxl_interface_resource("Te 0/1", "10")

      expect(base.port_resources["mxl_interface"]["Te 0/1"]).to eq({
        "portchannel" => "10",
        "shutdown" => "false"
      })
    end

    it "should create the resource without a port channel" do
      base.mxl_interface_resource("Te 0/1")

      expect(base.port_resources["mxl_interface"]["Te 0/1"]).to eq({
        "shutdown" => "false"
      })
    end

    it "support the sequence" do
      base.sequence = "Notify[rspec]"
      base.mxl_interface_resource("Te 0/1")

      expect(base.port_resources["mxl_interface"]["Te 0/1"]).to eq({
        "shutdown" => "false",
        "require" => "Notify[rspec]"
      })

      expect(base.sequence).to eq("Mxl_interface[Te 0/1]")
    end

  end

  describe "#has_resource?" do
    it "should detect resources correctly" do
      base.port_resources["notify"] = {"rspec" => {}}

      expect(base.has_resource?("notify", "rspec")).to be(true)
      expect(base.has_resource?("mxl_interface", "rspec")).to be(false)
    end
  end

  describe "#configure_force10_settings" do
    it "should copy the settings verbatim to the port_resources" do
      base.configure_force10_settings("rspec" => true)
      expect(base.port_resources["force10_settings"]).to eq("rspec" => {"rspec" => true})
    end
  end

  describe "#ports_to_cli_ranges" do
    it "should correctly convert ranges" do
      provider.stubs(:model).returns("S4810")
      expect(base.ports_to_cli_ranges("0/1,0/2,0/3,0/5")).to eq("0/1,2,3,5")
      expect(base.ports_to_cli_ranges("0/1,0/2,1/1,1/2")).to eq("0/1,2,1/1,2")
    end

    it "should not convert ranges for S4048-ON" do
      provider.stubs(:model).returns("S4048-ON")
      expect(base.ports_to_cli_ranges("0/1,0/2,0/3,0/5")).to eq("0/1,0/2,0/3,0/5")
      expect(base.ports_to_cli_ranges("1/1,1/2,1/3,1/4")).to eq("1/1,1/2,1/3,1/4")
    end
  end

  describe "#port_count" do
    it "should correctly determine counts for MXL/Aggregators" do
      provider.expects(:model).returns("MXL-10/40GbE")
      expect(base.port_count).to eq(32)

      provider.expects(:model).returns("I/O-Aggregator")
      expect(base.port_count).to eq(32)
    end

    it "should default to 8 otherwise" do
      provider.expects(:model).returns("RSPEC")
      expect(base.port_count).to eq(8)
    end
  end

  describe "#initialize_ports" do
    it "should fail by default" do
      expect { base.initialize_ports! }.to raise_error("Initializing ports for rspec is not supported")
    end
  end

  describe "#reset!" do
    it "should clear the prepared resources" do
      base.port_resources["rspec"] = true
      base.sequence = "rspec"

      expect(base.port_resources).to_not be_empty
      expect(base.sequence).to eq("rspec")
      base.reset!
      expect(base.port_resources).to be_empty
      expect(base.sequence).to be(nil)
    end
  end

  describe "#port_number_from_name" do
    it "should get the correct number" do
      expect(base.port_number_from_name("Te 10")).to eq("10")
      expect(base.port_number_from_name("Gi 11")).to eq("11")
    end
  end
end

require 'spec_helper'

$LOAD_PATH << File.expand_path(File.join(File.dirname(__FILE__), "..", "..", "..", "..", "nagios"))

require 'check_snmp'

describe "When checking Compellent SNMP devices" do
  before do
    @options = {:host => "rspec",
                :vendor => "Dell"}

    @check = ASM::Nagios::CheckSnmp.new(@options)
  end

  it "should report green" do
    vendor = "Dell"
    model = "Compellent"
    state = "ok"
    @device = @check.create_device(vendor,model)
    @device.results_cache = SpecHelper.json_fixture("snmp/%s/%s_%s.json"%[vendor,model,state])
    status,message = @device.query_snmp(@options).should == [0,"OK"]
  end

  it "should report controller down" do
    vendor = "Dell"
    model = "Compellent"
    state = "controller_down"
    @device = @check.create_device(vendor,model)
    @device.results_cache = SpecHelper.json_fixture("snmp/%s/%s_%s.json"%[vendor,model,state])
    status,message = @device.query_snmp(@options).should == [2,"Controller:Down"]
  end

  it "should report degraded battery" do
    vendor = "Dell"
    model = "Compellent"
    state = "battery_warning"
    @device = @check.create_device(vendor,model)
    @device.results_cache = SpecHelper.json_fixture("snmp/%s/%s_%s.json"%[vendor,model,state])
    status,message = @device.query_snmp(@options).should == [1,"Battery:Degraded"]
  end

  it "should report critical fan" do
    vendor = "Dell"
    model = "Compellent"
    state = "critical_fan"
    @device = @check.create_device(vendor,model)
    @device.results_cache = SpecHelper.json_fixture("snmp/%s/%s_%s.json"%[vendor,model,state])
    status,message = @device.query_snmp(@options).should == [2,"Fan:Down"]
  end
end

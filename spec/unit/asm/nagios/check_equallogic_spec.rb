require 'spec_helper'

$LOAD_PATH << File.expand_path(File.join(File.dirname(__FILE__), "..", "..", "..", "..", "nagios"))

require 'check_snmp'

describe "When checking EqualLogic SNMP devices" do
  before do
    @options = {:host => "rspec",
                :vendor => "Dell"}

    @check = ASM::Nagios::CheckSnmp.new(@options)
  end

  it "should report green" do
    vendor = "Dell"
    model = "EqualLogic"
    state = "ok"
    @device = @check.create_device(vendor,model)
    @device.results_cache = SpecHelper.json_fixture("snmp/%s/%s_%s.json"%[vendor,model,state])
    status,message = @device.query_snmp(@options).should == [0,"OK"]
  end

  it "should report failed battery" do
    vendor = "Dell"
    model = "EqualLogic"
    state = "battery"
    @device = @check.create_device(vendor,model)
    @device.results_cache = SpecHelper.json_fixture("snmp/%s/%s_%s.json"%[vendor,model,state])
    status,message = @device.query_snmp(@options).should == [1,"Battery end of life warning"]
  end

  it "should report critical temperature" do
    vendor = "Dell"
    model = "EqualLogic"
    state = "critical_temp"
    @device = @check.create_device(vendor,model)
    @device.results_cache = SpecHelper.json_fixture("snmp/%s/%s_%s.json"%[vendor,model,state])
    status,message = @device.query_snmp(@options).should == [2,"High ambient temp"]
  end
end

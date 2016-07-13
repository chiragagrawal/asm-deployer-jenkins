require 'spec_helper'

$LOAD_PATH << File.expand_path(File.join(File.dirname(__FILE__), "..", "..", "..", "..", "nagios"))

require 'check_navisec'

describe "When checking NaviSec devices" do
  before do
    @options = {:host => "rspec",
                :vendor => "EMC"}

    @check = ASM::Nagios::CheckNaviSec.new(@options)
  end

  it "should report green" do
    vendor = "EMC"
    model = "VNX5300"
    state = "ok"
    @device = @check.create_device(vendor,model)
    @device.results_cache = SpecHelper.json_fixture("navisec/%s/%s_%s.json"%[vendor,model,state])
    status,message = @device.query_navisec(@options).should == [0,"OK"]
  end

  it "should report yellow" do
    vendor = "EMC"
    model = "VNX5300"
    state = "warning"
    @device = @check.create_device(vendor,model)
    @device.results_cache = SpecHelper.json_fixture("navisec/%s/%s_%s.json"%[vendor,model,state])
    status,message = @device.query_navisec(@options).should == [1,"SP A Absent"]
  end


end

require 'spec_helper'

$LOAD_PATH << File.expand_path(File.join(File.dirname(__FILE__), "..", "..", "..", "..", "nagios"))

require 'check-racadm'

describe "When checking racadm devices" do
  before(:each) do
    @options = {:host => "rspec",
                :port => 22,
                :user => "root",
                :password => "calvin",
                :module_svctag => nil,
                :module_slot => nil,
                :check_power => nil,
                :decrypt => false}

    @check = ASM::Nagios::CheckRacadm.new(@options)

    # Set activeerrors to empty.
    @check.racadm_getactiveerrors("")
  end

  it "should fail to parse with correct return values" do
    @check.racadm_getmodinfo("rspec").should == {"asm_error"=>"Could not parse output from racadm, unexpected line: rspec", "asm_nagios_code"=>3}
    @check.racadm_getmodinfo("").should == {"asm_error"=>"Could not parse output from racadm, no output were received", "asm_nagios_code"=>3}
  end

  it "should support an all green m1000e chassis" do
    stub_fixture = SpecHelper.load_fixture("racadm/m1000e_chassis_all_green")
    status = @check.racadm_getmodinfo(stub_fixture)
    status.size.should == 43
    @check.get_status_from_modinfo(status).should == [0, "OK"]
  end

  it "should support an all green fx2 chassis" do
    stub_fixture = SpecHelper.load_fixture("racadm/fx2_chassis_all_green")
    status = @check.racadm_getmodinfo(stub_fixture)
    status.size.should == 21
    @check.get_status_from_modinfo(status).should == [0, "OK"]
  end

  it "should detect a single module as critical when checking the whole chassis" do
    stub_fixture = SpecHelper.load_fixture("racadm/fx2_chassis_server-2_critical")
    status = @check.get_status_from_modinfo(@check.racadm_getmodinfo(stub_fixture), nil, nil)

    status.should == [1, "Server-2: Degraded"]
  end

  it "should detect a single module as critical when checking that module by module name" do
    stub_fixture = SpecHelper.load_fixture("racadm/fx2_chassis_server-2_critical")
    status = @check.get_status_from_modinfo(@check.racadm_getmodinfo(stub_fixture), nil, "Server-2")

    status.should == [1, "Server-2: Degraded"]
  end

  it "should detect a single module as critical when checking that module by svctag" do
    stub_fixture = SpecHelper.load_fixture("racadm/fx2_chassis_server-2_critical")
    status = @check.get_status_from_modinfo(@check.racadm_getmodinfo(stub_fixture), "ASMFC02", nil)

    status.should == [1, "Server-2: Degraded"]
  end

  it "should detect a single module as OK when checking that module by slot and another module is critical" do
    stub_fixture = SpecHelper.load_fixture("racadm/fx2_chassis_server-2_critical")
    status = @check.get_status_from_modinfo(@check.racadm_getmodinfo(stub_fixture), nil, "Switch-1")

    status.should == [0, "OK"]
  end

  it "should detect a single module as OK when checking that module by svctag and another module is critical" do
    stub_fixture = SpecHelper.load_fixture("racadm/fx2_chassis_server-2_critical")
    status = @check.get_status_from_modinfo(@check.racadm_getmodinfo(stub_fixture), "H4YRTS5", nil)

    status.should == [0, "OK"]
  end

  it "should not detect powered off switches as critical when not checking power" do
    stub_fixture = SpecHelper.load_fixture("racadm/fx2_chassis_switch_power_off")
    status = @check.get_status_from_modinfo(@check.racadm_getmodinfo(stub_fixture), nil, "Switch-2")

    status.should == [0, "OK"]
  end

  it "should detect a switch being off as critical when checking power" do
    @check.options[:check_power] = true

    stub_fixture = SpecHelper.load_fixture("racadm/fx2_chassis_switch_power_off")
    status = @check.get_status_from_modinfo(@check.racadm_getmodinfo(stub_fixture), nil, "Switch-2")

    status.should == [2, "Switch-2: Error"]
  end

  it "should parse corrupt power errors correctly" do
    stub_fixture = SpecHelper.load_fixture("racadm/m1000e_chassis_showing_power_error")
    modinfo = @check.racadm_getmodinfo(stub_fixture)
    modinfo.size.should == 43
    modinfo["PS-5"].should == {"presence"=>"Present", "pwrState"=>"Failed(No Input Power)", "svcTag"=>"", "health"=>1}
    modinfo["PS-6"].should == {"presence"=>"Present", "pwrState"=>"Failed(No Input Power)", "svcTag"=>"N/A", "health"=>1}
  end

  it "should correctly parse racadm output with blank svctags" do
    stub_fixture = SpecHelper.load_fixture("racadm/m1000e_chassis_svctags_blank")
    modinfo = @check.racadm_getmodinfo(stub_fixture)

    modinfo.size.should == 43
    modinfo["Fan-1"].should == {"presence"=>"Present", "pwrState"=>"ON", "svcTag"=>"", "health"=>0}
    modinfo["Switch-1"].should == {"presence"=>"Present", "pwrState"=>"ON", "svcTag"=>"NAVA100", "health"=>0}
  end

  it "should detect versions of racadm without getmodinfo" do
    stub_fixture = SpecHelper.load_fixture("racadm/m1000e_chassis_no_getmodinfo")
    modinfo = @check.racadm_getmodinfo(stub_fixture)
    modinfo["asm_error"].should == "Host rspec does not support get the getmodinfo command"
    modinfo["asm_nagios_code"].should == 3
  end

  it "should correctly parse activeerrors output" do
    stub_fixture = SpecHelper.load_fixture("racadm/m1000e_chassis_activeerrors")
    errors = @check.racadm_getactiveerrors(stub_fixture)

    # ae.size.should == 43
    errors["server-14"].should == "CPU 1 machine check error detected."
  end
end


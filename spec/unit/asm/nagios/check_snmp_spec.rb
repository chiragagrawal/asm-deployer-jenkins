require 'spec_helper'

$LOAD_PATH << File.expand_path(File.join(File.dirname(__FILE__), "..", "..", "..", "..", "nagios"))

require 'check_snmp'

describe "When checking SNMP devices" do
  before do
    @options = {:host => "rspec",
                :vendor => "Dell"}

    @check = ASM::Nagios::CheckSnmp.new(@options)
  end

  it "should report green" do
    vendor = "Dell"
    model = "S4810"
    state = "ok"
    @device = @check.create_device(vendor,model)
    @device.results_cache = SpecHelper.json_fixture("snmp/%s/%s_%s.json"%[vendor,model,state])
    status,message = @device.query_snmp(@options).should == [0,"OK"]
  end

  it "should report yellow for power off" do
    vendor = "Dell"
    model = "S4810"
    state = "warning"
    @device = @check.create_device(vendor,model)
    @device.results_cache = SpecHelper.json_fixture("snmp/%s/%s_%s.json"%[vendor,model,state])
    status,message = @device.query_snmp(@options).should == [1,"Power:Down"]
  end

  it "should report critical for fan down" do
    vendor = "Dell"
    model = "S4810"
    state = "critical"
    @device = @check.create_device(vendor,model)
    @device.results_cache = SpecHelper.json_fixture("snmp/%s/%s_%s.json"%[vendor,model,state])
    status,message = @device.query_snmp(@options).should == [2,"unitStatus:UnitDown,Fan:Down,Power:Down"]
  end

  it "should report yellow for power not present" do
    vendor = "Dell"
    model = "Dell Networking N3024"
    state = "warning"
    @device = @check.create_device(vendor,model)
    @device.results_cache = SpecHelper.json_fixture("snmp/%s/%s_%s.json"%[vendor,model,state])
    status,message = @device.query_snmp(@options).should == [1,"Power:notPresent"]
  end

  it "should report yellow for fans and power shutdown state" do
    vendor = "Dell"
    model = "Dell Networking N4064F"
    state = "warning"
    @device = @check.create_device(vendor,model)
    @device.results_cache = SpecHelper.json_fixture("snmp/%s/%s_%s.json"%[vendor,model,state])
    status,message = @device.query_snmp(@options).should == [1,"Fan:shutdown,Power:shutdown"]
  end

  it "should return true if community string correct we use this condition to notify user" do
    host ='172.17.11.13'
    vendor = "Dell"
    community = "public"
    model = "S4810"
    @device = @check.create_device(vendor, model)
    @device.expects(:get_device_certname).with(host).returns("dell_ftos-172.17.11.13")
    ASM::PrivateUtil.expects(:facts_find).with("dell_ftos-172.17.11.13").returns({'snmp_community_string' => "[\"public\"]"})
    @device.is_snmp_community_correct?(community, host).should be(true)
  end

  it 'should return certname' do
    host = '172.17.11.13'
    vendor = "Dell"
    community="public"
    model = "S4810"
    mock_db = mock()
    mock_db.expects(:find_node_by_management_ip).with(host).returns({"name" => "dell_ftos-172.17.11.13"})
    ASM::Client::Puppetdb.expects(:new).returns(mock_db)
    @device = @check.create_device(vendor, model)
    @device.get_device_certname(host).should eq('dell_ftos-172.17.11.13')
  end

end

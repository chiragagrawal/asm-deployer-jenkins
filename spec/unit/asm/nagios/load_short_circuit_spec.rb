require 'spec_helper'
require 'open3'

describe "When short circuiting execution" do
  it "should prevent execution when load is too high" do
    o, e, s = Open3.capture3("bash nagios/load_short_circuit.sh -f %s -c 'echo command ran'" % SpecHelper.fixture_path("nagios/load_3_0"))

    s.exitstatus.should == 0
    o.chomp.should == "Skipping the run due to load average 3.0 being greater than 2"
  end

  it "should allow execution when load is below the threshold" do
    o, e, s = Open3.capture3("bash nagios/load_short_circuit.sh -f %s -c 'echo command ran'" % SpecHelper.fixture_path("nagios/load_1_5"))

    s.exitstatus.should == 0
    o.chomp.should == "command ran"
  end

  it "should fail on non integer and float load averages for comparison" do
    ["a", "1.1.1"].each do |l|
      o, e, s = Open3.capture3("bash nagios/load_short_circuit.sh -l %s" % l)
      e.chomp.should == "The load average specified in -l should be a integer or float"
      s.exitstatus.should == 1
    end
  end

  it "should fail on non integer exit codes" do
    ["a", "1.1"].each do |l|
      o, e, s = Open3.capture3("bash nagios/load_short_circuit.sh -e %s" % l)
      e.chomp.should == "The exit code specified in -e should be a integer"
      s.exitstatus.should == 1
    end
  end

  it "should fail when the load average source is absent" do
    o, e, s = Open3.capture3("bash nagios/load_short_circuit.sh -f /nonexistant")
    e.chomp.should == "The load average file /nonexistant cannot be found"
    s.exitstatus.should == 1
  end

  it "should support a default off debug output" do
    unless RUBY_PLATFORM =~ /cygwin|mswin|mingw/ # /proc/loadavg will not exist here
      o, e, s = Open3.capture3("bash nagios/load_short_circuit.sh -v")
      e.should match(/System load sourced from \/proc\/loadavg is \d+\.\d+ and will be checked against a maximum load of 2/m)
    end

    o, e, s = Open3.capture3("bash nagios/load_short_circuit.sh")
    e.should_not match(/System load sourced from/m)
  end

  it "should support surpressing all non error output" do
    o, e, s = Open3.capture3("bash nagios/load_short_circuit.sh -f %s -c 'echo command ran' -s" % SpecHelper.fixture_path("nagios/load_3_0"))

    o.should_not match(/Skipping the run due to load average 3.0 being greater than 2/)
  end

  it "should support a custom skip message" do
    o, e, s = Open3.capture3("bash nagios/load_short_circuit.sh -f %s -c 'echo command ran' -m 'skipped by rspec'" % SpecHelper.fixture_path("nagios/load_3_0"))

    s.exitstatus.should == 0
    o.chomp.should == "skipped by rspec"
    o.should_not match(/command ran/m)
  end

  it "should support a custom exit code when skipping" do
    o, e, s = Open3.capture3("bash nagios/load_short_circuit.sh -f %s -c 'echo command ran' -e 100" % SpecHelper.fixture_path("nagios/load_3_0"))

    s.exitstatus.should == 100
    o.chomp.should == "Skipping the run due to load average 3.0 being greater than 2"
  end

  it "should support not running a command on success instead just exiting 0" do
    o, e, s = Open3.capture3("bash nagios/load_short_circuit.sh -f %s -v" % SpecHelper.fixture_path("nagios/load_1_5"))
    s.exitstatus.should == 0
    e.should match(/No command given so exiting 0 while load below 2/m)
  end

  it "should support showing help" do
    o, e, s = Open3.capture3("bash nagios/load_short_circuit.sh -h")
    s.exitstatus.should == 1
    o.should match(/Only runs COMMAND when the system load average is below LOAD/m)
  end
end

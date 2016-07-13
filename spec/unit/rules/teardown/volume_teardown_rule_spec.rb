require 'spec_helper'
require 'asm/type'
require 'asm/type/volume'
require 'asm/rule_engine'

describe "rules/teardown/volume_teardown_rule" do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:engine) { ASM::RuleEngine.new("/nonexisting", logger) }
  let(:state) { engine.new_state }
  let(:service) { SpecHelper.service_from_fixture("Teardown_EQL_VMware_Cluster.json") }
  let(:resource) { service.components_by_type("STORAGE").first.to_resource(stub(:id => "1234"), logger) }

  before(:each) do
    ASM.stubs(:logger).returns(logger)
    ASM.stubs(:cache).returns(stub(:setup => nil, :synchronize => nil))
    engine.rules.stubs(:locked?).returns(false)
    engine.rules.load_rule("rules/teardown/volume_teardown_rule.rb")
    state.add(:resource, resource)
    state.add(:service, service)
    state.add(:should_process, true)

    resource.stubs(:leave_cluster!)
    resource.stubs(:clean_access_rights!)
    resource.stubs(:process!)
  end

  after(:each) { raise state.results[0].error if state.had_failures? }

  it "should not run on earlier failures" do
    expect(engine.rules[0].run_on_fail?).to be(false)
  end

  it "should process for teardown components" do
    resource.expects(:teardown?).returns(true)
    resource.expects(:process!)
    state.process_rules
  end

  it "should not process for non teardown components" do
    resource.expects(:teardown?).returns(false)
    resource.expects(:process!).never
    state.process_rules
  end

  it "should allow other rules to stop process!" do
    state.add_or_set(:should_process, false)
    engine.process_rules(state)
    expect(state.acted_on_by).to be_empty
  end
end

require 'spec_helper'
require 'asm/type'
require 'asm/type/virtualmachine'
require 'asm/rule_engine'

describe "rules/teardown/virtualmachine_teardown_rule" do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:deployment) { stub(:decrypt? => true, :id => 1234) }
  let(:engine) { ASM::RuleEngine.new("/nonexisting", logger) }
  let(:state) { engine.new_state }
  let(:service) { SpecHelper.service_from_fixture("Teardown_EQL_Scvmm_Cluster.json") }
  let(:resource) { service.components_by_type("VIRTUALMACHINE").first.to_resource(deployment, logger) }

  before(:each) do
    ASM.stubs(:logger).returns(logger)
    engine.rules.stubs(:locked?).returns(false)
    engine.rules.load_rule("rules/teardown/virtualmachine_teardown_rule.rb")
    state.add(:resource, resource)
    state.add(:service, service)
    state.add(:should_process, true)
  end

  after(:each) { raise state.results[0].error if state.had_failures? }

  it "should not run on earlier failures" do
    expect(engine.rules[0].run_on_fail?).to be(false)
  end

  it "should not process virtual machines not being torn down" do
    resource.expects(:teardown?).returns(false)
    resource.expects(:process!).never
    engine.process_rules(state)
  end

  it "should process the virtual machine" do
    resource.expects(:process!).once
    engine.process_rules(state)
  end

  it "should allow other rules to stop process!" do
    state.add_or_set(:should_process, false)
    engine.process_rules(state)
    expect(state.acted_on_by).to be_empty
  end
end

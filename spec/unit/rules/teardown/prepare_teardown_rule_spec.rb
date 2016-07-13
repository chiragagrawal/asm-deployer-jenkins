require 'spec_helper'
require 'asm/type'
require 'asm/type/cluster'
require 'asm/rule_engine'

describe "rules/teardown/prepare_teardown_rule" do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:engine) { ASM::RuleEngine.new("/nonexisting", logger) }
  let(:state) { engine.new_state }
  let(:service) { SpecHelper.service_from_fixture("Teardown_EQL_VMware_Cluster.json") }
  let(:resource) { service.components_by_type("CLUSTER").first.to_resource(stub, logger) }

  before(:each) do
    ASM.stubs(:logger).returns(logger)
    engine.rules.stubs(:locked?).returns(false)
    engine.rules.load_rule("rules/teardown/prepare_teardown_rule.rb")

    state.add(:resource, resource)
    state.add(:service, service)
  end

  after(:each) { raise state.results[0].error if state.had_failures? }

  it "should have the right priority" do
    expect(engine.rules[0].priority).to be(40)
  end

  it "should process for teardown components" do
    resource.expects(:prepare_for_teardown!).returns(true)
    engine.process_rules(state)
  end

  it "should not process for non teardown components" do
    resource.expects(:teardown?).returns(false)
    resource.expects(:process!).never
    engine.process_rules(state)
  end

  it "should set :should_process to false when prepare_for_teardown! failed" do
    resource.expects(:prepare_for_teardown!).raises("rspec")
    engine.process_rules(state)
    expect(state[:should_process]).to be(false)
  end

  it "should set :should_process if prepare_for_teardown! returned false" do
    resource.expects(:prepare_for_teardown!).returns(false)
    engine.process_rules(state)
    expect(state[:should_process]).to be(false)
  end
end

require "spec_helper"
require "asm/type"
require "asm/rule_engine"

describe "rules/rules/component_common/pre_flight_rule" do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:engine) { ASM::RuleEngine.new("/nonexisting", logger) }
  let(:state) { engine.new_state }
  let(:service) { stub }
  let(:resource) { stub }
  let(:database) { stub }

  before(:each) do
    ASM.stubs(:logger).returns(logger)
    engine.rules.stubs(:locked?).returns(false)
    engine.rules.load_rule("rules/component_common/pre_flight_rule.rb")

    resource.stubs(:is_a?).returns(true)
    service.stubs(:is_a?).returns(true)
    state.add(:resource, resource)
    state.add(:service, service)
  end

  after(:each) { raise state.results[0].error if state.had_failures? }

  it "should set the component to in progress" do
    resource.stubs(:database).returns(database)
    database.expects(:execution_id).returns(1234)
    resource.expects(:db_in_progress!).once
    engine.process_rules(state)
  end

  it "should do nothing without a db" do
    resource.stubs(:database).returns(nil)
    database.expects(:execution_id).never
    engine.process_rules(state)
  end

  it "should do nothing without an execution" do
    resource.stubs(:database).returns(database)
    database.expects(:execution_id).returns(nil)
    resource.expects(:db_in_progress!).never
    engine.process_rules(state)
  end
end

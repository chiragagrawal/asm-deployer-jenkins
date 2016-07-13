require 'spec_helper'
require 'asm/type'
require 'asm/type/cluster'
require 'asm/rule_engine'

describe "rules/service/storage_lane_teardown_rule" do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:engine) { ASM::RuleEngine.new("/nonexisting", logger) }
  let(:state) { engine.new_state }
  let(:service) { SpecHelper.service_from_fixture("Teardown_CMPL_VMware_Cluster.json") }
  let(:processor) { ASM::Service::Processor.new(service.raw_service, "/rspec", logger) }

  before(:each) do
    ASM.stubs(:logger).returns(logger)
    engine.rules.stubs(:locked?).returns(false)
    engine.rules.load_rule("rules/service/storage_lane_teardown_rule.rb")

    state.add(:processor, processor)
    state.add(:service, service)
    state.add(:component_outcomes, [])
  end

  after(:each) { raise state.results[0].error if state.had_failures? }

  it "should process for STORAGE teardown components" do
    components = service.components_by_type("STORAGE")

    components.each do |component|
      result = {:component => component.puppet_certname, :component_s => component.to_s, :results => []}
      processor.expects(:process_state).with(component, instance_of(ASM::RuleEngine), instance_of(ASM::RuleEngine::State)).returns(result)
    end

    engine.process_rules(state)
  end

  it "should not process if it's not a teardown" do
    service.expects(:teardown?).returns(false)
    processor.expects(:process_lane).never
    engine.process_rules(state)
  end

  it "should not process when there are no storage components" do
    service.expects(:components_by_type).with("STORAGE").returns([])
    processor.expects(:process_lane).never
    engine.process_rules(state)
  end

  it "should raise the first error" do
    components = service.components_by_type("STORAGE")

    components.each_with_index do |component, i|
      results = [stub(:error => StandardError.new("rspec%s" % i))]
      result = {:component => component.puppet_certname, :component_s => component.to_s, :results => results}
      processor.expects(:process_state).with(component, instance_of(ASM::RuleEngine), instance_of(ASM::RuleEngine::State)).returns(result)
    end

    engine.process_rules(state)

    expect(state.results.size).to eq(1)
    expect(state.results[0].error.message).to eq("rspec0")

    # stop the after(:each)..
    state.expects(:had_failures?).returns(false)
  end
end

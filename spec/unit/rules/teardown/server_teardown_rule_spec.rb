require 'spec_helper'
require 'asm/type'
require 'asm/type/server'
require 'asm/rule_engine'

describe "rules/teardown/server_teardown_rule" do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:engine) { ASM::RuleEngine.new("/nonexisting", logger) }
  let(:state) { engine.new_state }
  let(:service) { SpecHelper.service_from_fixture("Teardown_EQL_VMware_Cluster.json") }
  let(:resource) { service.components_by_type("SERVER").first.to_resource(stub(:id => "1234"), logger) }

  before(:each) do
    ASM.stubs(:logger).returns(logger)
    engine.rules.stubs(:locked?).returns(false)
    engine.rules.load_rule("rules/teardown/server_teardown_rule.rb")
    state.add(:resource, resource)
    state.add(:should_process, true)
    state.add(:service, service)

    resource.stubs(:delete_server_cert!)
    resource.stubs(:delete_server_node_data!)
    resource.stubs(:process!)
    resource.stubs(:leave_cluster!)
    resource.stubs(:clean_related_volumes!)
    resource.stubs(:clean_virtual_identities!)
    resource.stubs(:power_off!)
    resource.stubs(:configure_networking!)
    resource.stubs(:delete_network_topology!)
  end

  after(:each) { raise state.results[0].error if state.had_failures? }

  it "should skip some steps for bfs servers" do
    resource.expects(:delete_server_cert!).never
    resource.expects(:leave_cluster!).never
    resource.expects(:process!).never
    resource.expects(:clean_related_volumes!).never
    resource.expects(:reset_management_ip!).never
    resource.expects(:boot_from_san?).returns(true)
    state.process_rules
  end

  it "should not run on earlier failures" do
    expect(engine.rules[0].run_on_fail?).to be(false)
  end

  it "should process for teardown components" do
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

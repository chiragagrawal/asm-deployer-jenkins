require 'spec_helper'
require 'asm/type'
require 'asm/type/server'
require 'asm/rule_engine'

describe "rules/migration/server_migration_rule" do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:engine) { ASM::RuleEngine.new("/nonexisting", logger) }
  let(:state) { engine.new_state }
  let(:deployment) { stub(:id => "1234", :debug? => false) }
  let(:processor) { stub(:deployment => deployment, :debug? => false) }
  let(:service) { SpecHelper.service_from_fixture("Migration_BFS_Server.json") }
  let!(:server_component) { service.components_by_type("SERVER").first }
  let(:new_server) { server_component.to_resource(deployment, logger) }
  let(:base_server) { server_component.resource_by_id("asm::baseserver") }

  # Create copy of server_component without using #deep_copy because it gets mocked
  let!(:old_server_component) { SpecHelper.service_from_fixture("Migration_BFS_Server.json")
                                    .components_by_type("SERVER")
                                    .first }
  let!(:old_server) { old_server_component.to_resource(deployment, logger) }

  before(:each) do
    ASM.stubs(:logger).returns(logger)
    ASM::Util.stubs(:get_preferred_ip).returns("192.168.1.1")
    engine.rules.stubs(:locked?).returns(false)
    engine.rules.load_rule("rules/migration/server_migration_rule.rb")
    state.add(:resource, new_server)
    state.add(:component, server_component)
    state.add(:service, service)
    state.add(:processor, processor)

    server_component.expects(:deep_copy).returns(old_server_component)
    old_server_component.expects(:to_resource).returns(old_server)
  end

  after(:each) { raise state.results[0].error if state.had_failures? }

  it "should decomission the right server" do
    logger.expects(:info).with("Migrating from server %s to %s, retiring %s" % [base_server.title, server_component.puppet_certname, base_server.title])

    new_server.expects(:boot_from_san?).returns(true)

    old_server.expects(:delete_server_cert!).never
    old_server.expects(:leave_cluster!).never
    old_server.expects(:process!).never
    old_server.expects(:clean_related_volumes!).never
    old_server.expects(:clean_virtual_identities!)

    # configure_network! should be called before delete_network_topology
    sequence = sequence('network_topology')
    old_server.expects(:configure_networking!).in_sequence(sequence)
    old_server.expects(:delete_network_topology!).in_sequence(sequence)

    old_server.expects(:power_off!)
    new_server.expects(:power_off!)
    state.process_rules
  end

  it "should do extra steps for non bfs servers" do
    new_server.expects(:boot_from_san?).returns(false)

    old_server.expects(:delete_server_cert!)
    old_server.expects(:leave_cluster!)
    old_server.expects(:process!)
    old_server.expects(:clean_related_volumes!)
    old_server.expects(:clean_virtual_identities!)

    # configure_network! should be called before delete_network_topology
    sequence = sequence('network_topology')
    old_server.expects(:configure_networking!).in_sequence(sequence)
    old_server.expects(:delete_network_topology!).in_sequence(sequence)

    old_server.expects(:power_off!)
    new_server.expects(:power_off!)

    state.process_rules

    expect(old_server.puppet_certname).to eq("bladeserver-6d4qqv1")
    expect(old_server.uuid).to eq("bladeserver-6d4qqv1")

    # Check hostname has been changed for old server to match asm::baseserver spec
    expect(server_component.resource_by_id("asm::server")["os_host_name"]).to eq ("gs1centos3")
    expect(old_server_component.resource_by_id("asm::server")["os_host_name"]).to eq ("gs1centos2")

    # Check old_server is ensure absent
    expect(old_server.ensure).to eq("absent")
  end
end

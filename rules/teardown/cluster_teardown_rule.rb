ASM::RuleEngine.new_rule(:cluster_teardown) do
  require_state :resource, ASM::Type::Cluster
  require_state :service, ASM::Service
  require_state :should_process, true

  condition(:service_teardown?) { state[:service].teardown? }
  condition(:component_teardown?) { state[:resource].teardown? }

  execute_when { service_teardown? && component_teardown? }

  set_priority 50
  set_concurrent

  execute do
    state[:resource].process!
  end
end

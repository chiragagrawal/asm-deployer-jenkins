ASM::RuleEngine.new_rule(:pre_flight) do
  require_state :resource, ASM::Type::Base
  require_state :service, ASM::Service

  condition(:has_db?) { !!state[:resource].database }
  condition(:has_execution?) { !!state[:resource].database.execution_id }

  execute_when { has_db? && has_execution? }

  set_priority 5
  set_concurrent

  execute do
    state[:resource].db_in_progress!
  end
end

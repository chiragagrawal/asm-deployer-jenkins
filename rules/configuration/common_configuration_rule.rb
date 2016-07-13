ASM::RuleEngine.new_rule(:common_configuration) do
  require_state :resource, ASM::Type::Configuration
  require_state :service, ASM::Service

  execute_when { true }

  set_priority 50
  set_concurrent

  execute do
    if state[:resource].provider_name == "force10"
      state[:resource].configure_networking! unless state[:resource].configure_force10_settings!
    else
      state[:resource].process!
    end
  end
end

ASM::RuleEngine.new_rule(:configuration_lane_provision) do
  require_state(:processor, ASM::Service::Processor)
  require_state(:service, ASM::Service)
  require_state(:component_outcomes, Array)

  set_priority(10)
  run_on_fail

  condition(:components?) { !state[:service].components_by_type("CONFIGURATION").empty? }

  execute_when { !state[:service].migration? && components? }

  execute do
    outcomes = state[:component_outcomes]
    components = state[:service].components_by_type("CONFIGURATION")

    outcomes.concat(state[:processor].process_lane(components, "configuration"))

    outcomes.each do |outcome|
      outcome[:results].each do |result|
        raise(result.error) if result.error
      end
    end
  end
end

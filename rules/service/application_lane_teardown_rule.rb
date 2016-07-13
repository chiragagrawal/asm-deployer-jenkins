ASM::RuleEngine.new_rule(:application_lane_teardown) do
  build_from_generator(&ASM::Service::RuleGen.configure_lane_teardown("SERVICE", 20, false))
end

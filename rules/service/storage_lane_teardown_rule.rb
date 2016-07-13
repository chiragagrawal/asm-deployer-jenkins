ASM::RuleEngine.new_rule(:storage_lane_teardown) do
  build_from_generator(&ASM::Service::RuleGen.configure_lane_teardown("STORAGE", 60, false))
end

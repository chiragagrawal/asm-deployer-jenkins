ASM::RuleEngine.new_rule(:test_lane_teardown) do
  build_from_generator(&ASM::Service::RuleGen.configure_lane_teardown("TEST", 20))
end

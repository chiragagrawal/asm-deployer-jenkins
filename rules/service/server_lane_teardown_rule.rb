ASM::RuleEngine.new_rule(:server_lane_teardown) do
  build_from_generator(&ASM::Service::RuleGen.configure_lane_teardown("SERVER", 50))
end

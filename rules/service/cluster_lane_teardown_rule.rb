ASM::RuleEngine.new_rule(:cluster_lane_teardown) do
  build_from_generator(&ASM::Service::RuleGen.configure_lane_teardown("CLUSTER", 40))
end

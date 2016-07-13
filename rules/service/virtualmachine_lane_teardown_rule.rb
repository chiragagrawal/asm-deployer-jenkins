ASM::RuleEngine.new_rule(:virtualmachine_lane_teardown) do
  build_from_generator(&ASM::Service::RuleGen.configure_lane_teardown("VIRTUALMACHINE", 30))
end

ASM::RuleEngine.new_rule(:server_lane_migration) do
  build_from_generator(&ASM::Service::RuleGen.configure_lane_migration("SERVER", 50))
end

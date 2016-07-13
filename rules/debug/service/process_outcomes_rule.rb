ASM::RuleEngine.new_rule(:process_outcomes) do
  require_state :component_outcomes, Array
  require_state :service, ASM::Service

  set_priority 999
  run_on_fail

  execute do
    puts
    puts "Deployment %s (%s) completed:" % [state[:service].deployment_name, state[:service].id]
    puts

    state[:component_outcomes].each do |outcome|
      puts "   Componenet: %s" % outcome[:component_s]
      puts

      outcome[:results].each do |result|
        puts "      %s: %s" % [!!result.error ? "  Error" : "Success", result.rule]
      end

      puts
    end
  end
end

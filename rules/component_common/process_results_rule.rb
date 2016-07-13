ASM::RuleEngine.new_rule(:process_results) do
  require_state :processor, ASM::Service::Processor
  require_state :resource, Object

  set_priority 999
  run_on_fail

  execute do
    if state.had_failures?
      state.results.each do |result|
        if result.error
          state[:processor].write_exception(state[:resource].name, result.error)
        end
      end

      state[:resource].db_error!
    else
      state[:resource].db_complete!
    end
  end
end

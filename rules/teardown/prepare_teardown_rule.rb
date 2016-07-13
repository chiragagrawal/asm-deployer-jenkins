ASM::RuleEngine.new_rule(:prepare_teardown) do
  require_state :resource, ASM::Type::Base
  require_state :service, ASM::Service

  condition(:service_teardown?) { state[:service].teardown? }
  condition(:component_teardown?) { state[:resource].teardown? }

  execute_when { service_teardown? && component_teardown? }

  set_priority 40

  execute do
    begin
      continue = !!state[:resource].prepare_for_teardown!
    rescue
      continue = false
      logger.warn("Preparing %s for teardown raised an exception: %s: %s" % [state[:resource].puppet_certname, $!.class, $!.to_s])
    end

    state.add_or_set(:should_process, continue)

    unless continue
      logger.info("Cancelling further teardown steps do to result of %s prepare_for_teardown!" % state[:resource].puppet_certname)
    end
  end
end

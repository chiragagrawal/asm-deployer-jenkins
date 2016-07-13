ASM::RuleEngine.new_rule(:update_inventory) do
  require_state :resource, ASM::Type::Base
  require_state :service, ASM::Service

  condition(:should_inventory?) { state[:resource].should_inventory? }

  execute_when { should_inventory? }

  set_priority 80
  run_on_fail
  set_concurrent

  execute do
    begin
      state[:resource].update_inventory
    rescue ASM::DeviceManagement::SyncException
      logger.warn("Updating of inventory for %s failed as it was already in progress" % state[:resource].puppet_certname)
    rescue
      logger.warn("Updating of inventory for %s failed, deployment will succeed: %s: %s" % [state[:resource].puppet_certname, $!.class, $!.to_s])
      logger.debug($!.backtrace.join("\n\t"))
    end
  end
end

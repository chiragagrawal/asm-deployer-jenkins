ASM::RuleEngine.new_rule(:volume_teardown) do
  require_state :resource, ASM::Type::Volume
  require_state :service, ASM::Service
  require_state :should_process, true

  condition(:service_teardown?) { state[:service].teardown? }
  condition(:component_teardown?) { state[:resource].teardown? }

  execute_when { service_teardown? && component_teardown? }

  set_priority 50
  set_concurrent

  execute do
    volume = state[:resource]

    volume.leave_cluster! rescue logger.warn(
      "Could not remove the volume %s from its associated clusters: %s: %s" % [volume.puppet_certname, $!.class, $!.to_s]
    )

    volume.clean_access_rights! rescue logger.warn(
      "Could not clean virtual identities for volume %s: %s: %s" % [volume.puppet_certname, $!.class, $!.to_s]
    )

    volume.process!
  end
end

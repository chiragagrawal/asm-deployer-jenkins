ASM::RuleEngine.new_rule(:server_teardown) do
  require_state :resource, ASM::Type::Server
  require_state :service, ASM::Service
  require_state :should_process, true

  condition(:service_teardown?) { state[:service].teardown? }
  condition(:component_teardown?) { state[:resource].teardown? }

  execute_when { service_teardown? && component_teardown? }

  set_priority 50
  set_concurrent

  execute do
    server = state[:resource]

    unless server.boot_from_san?
      server.delete_server_cert! rescue logger.debug(
        "Could not remove certificate for the server %s: %s: %s" % [server.puppet_certname, $!.class, $!.to_s]
      )

      server.delete_server_node_data! rescue logger.debug(
        "Could not remove node data for the server %s: %s: %s" % [server.puppet_certname, $!.class, $!.to_s]
      )

      server.leave_cluster! rescue logger.debug(
        "Could not leave cluster %s: %s: %s" % [server.puppet_certname, $!.class, $!.to_s]
      )

      server.reset_management_ip! rescue logger.warn(
        "Could not reset management ip on server %s: %s: %s" % [server.puppet_certname, $!.class, $!.to_s]
      )

      server.process! rescue logger.warn(
        "Could not remove the server %s: %s: %s" % [server.puppet_certname, $!.class, $!.to_s]
      )

      server.clean_related_volumes! rescue logger.warn(
        "Could not clean related volumes for server %s: %s: %s" % [server.puppet_certname, $!.class, $!.to_s]
      )
    end

    server.delete_server_network_overview_cache! rescue logger.warn(
      "Could not delete the network overview cache for server %s: %s: %s" % [server.puppet_certname, $!.class, $!.to_s]
    )

    server.clean_virtual_identities! rescue logger.warn(
      "Could not clean related virtual identities for server %s: %s: %s" % [server.puppet_certname, $!.class, $!.to_s]
    )

    server.configure_networking! rescue logger.warn(
      "Could not reset switch ports for server %s: %s: %s" % [server.puppet_certname, $!.class, $!.to_s]
    )

    server.delete_network_topology! rescue logger.debug(
      "Could not remove network topology data for the server %s: %s: %s" % [server.puppet_certname, $!.class, $!.to_s]
    )

    server.power_off! rescue logger.warn(
      "Could not power off the server %s: %s: %s" % [server.puppet_certname, $!.class, $!.to_s]
    )
  end
end

ASM::RuleEngine.new_rule(:server_migration) do
  require_state :resource, ASM::Type::Server
  require_state :component, ASM::Service::Component
  require_state :service, ASM::Service

  condition(:with_baseserver?) { state[:resource].service_component.has_resource_id?("asm::baseserver") }

  execute_when { with_baseserver? }

  execute do
    new_server = state[:resource]
    component = state[:component].deep_copy
    base_server = component.resource_by_id("asm::baseserver")
    asm_server = component.resource_by_id("asm::server")
    # asm::baseserver parameters override asm::server parameters for the old server
    asm_server.parameters.merge!(base_server.parameters.select { |k| asm_server.parameters.include?(k) })
    old_server = component.to_resource(state[:processor].deployment, @logger)

    old_server.puppet_certname = base_server.title
    old_server.uuid = base_server.title
    old_server.ensure = "absent"

    logger.info("Migrating from server %s to %s, retiring %s" % [old_server.puppet_certname, new_server.puppet_certname, old_server.puppet_certname])

    unless new_server.boot_from_san?
      old_server.delete_server_cert! rescue logger.debug(
        "Could not remove certificate for the server %s: %s: %s" % [old_server.puppet_certname, $!.class, $!.to_s]
      )

      old_server.delete_server_node_data! rescue logger.debug(
        "Could not remove node data for the server %s: %s: %s" % [old_server.puppet_certname, $!.class, $!.to_s]
      )

      old_server.leave_cluster! rescue logger.debug(
        "Could not leave cluster %s: %s: %s" % [old_server.puppet_certname, $!.class, $!.to_s]
      )

      old_server.process! rescue logger.warn(
        "Could not remove the server %s: %s: %s" % [old_server.puppet_certname, $!.class, $!.to_s]
      )

      old_server.clean_related_volumes! rescue logger.warn(
        "Could not clean related volumes for server %s: %s: %s" % [old_server.puppet_certname, $!.class, $!.to_s]
      )
    end

    old_server.clean_virtual_identities! rescue logger.warn(
      "Could not clean related virtual identities for server %s: %s: %s" % [old_server.puppet_certname, $!.class, $!.to_s]
    )

    old_server.configure_networking! rescue logger.warn(
      "Could not reset switch ports for server %s: %s: %s" % [old_server.puppet_certname, $!.class, $!.to_s]
    )

    old_server.delete_network_topology! rescue logger.debug(
      "Could not remove network topology data for the server %s: %s: %s" % [old_server.puppet_certname, $!.class, $!.to_s]
    )

    [new_server, old_server].each do |s|
      s.power_off! rescue logger.warn(
        "Could not power off server %s: %s: %s" % [s.puppet_certname, $!.class, $!.to_s]
      )
    end
  end
end

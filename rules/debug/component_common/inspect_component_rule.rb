ASM::RuleEngine.new_rule(:inspect_component) do
  require_state :resource, Object

  set_priority 1

  execute do
    component = state[:resource].service_component

    puts
    puts "About to process component: %s" % state[:resource]
    puts
    puts "           Name: %s" % component.name
    puts "           GUID: %s" % component.guid
    puts "       Teardown: %s" % component.teardown?
    puts "           Type: %s" % component.type
    puts "             ID: %s" % component.component_id
    puts "      Cert Name: %s" % component.puppet_certname
    puts "      Resources: %s" % component.resource_ids.inspect
    puts
    STDIN.getc if STDIN.tty? && STDOUT.tty?
  end
end

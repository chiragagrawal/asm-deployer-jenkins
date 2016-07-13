ASM::RuleEngine.new_rule(:inspect_service) do
  require_state :service, ASM::Service

  set_priority 1

  execute do
    puts
    puts "About to process service: %s" % state[:service]
    puts
    puts "    Deployment Name: %s" % state[:service].deployment_name
    puts "                 ID: %s" % state[:service].id
    puts "           Teardown: %s" % state[:service].teardown?
    puts "              Retry: %s" % state[:service].retry?
    puts "          Migration: %s" % state[:service].migration?
    puts
    puts "Components:"

    state[:service].components.each do |component|
      puts "    %s" % component
    end

    puts

    STDIN.getc if STDIN.tty? && STDOUT.tty?
  end
end

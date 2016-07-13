desc "Run rubocop style and lint checks"
task :rubocop do
  sh("bundle exec rubocop -f progress -f offenses rules lib/asm/nagios.rb lib/asm/type.rb lib/asm/type lib/asm/service.rb lib/asm/service lib/asm/rule_engine.rb lib/asm/rule_engine lib/asm/provider lib/asm/port_view.rb lib/asm/ipxe_builder.rb spec/unit/asm/ipxe_builder_spec.rb spec/unit/asm/razor_spec.rb spec/unit/asm/port_view_spec.rb lib/asm/processor/post_os.rb lib/asm/processor/linux_vm_post_os.rb lib/asm/cache.rb lib/asm/device_management.rb lib/asm/client/puppetdb.rb lib/asm/data/deployment.rb nagios/check_navisec.rb lib/asm/facts.rb")
end

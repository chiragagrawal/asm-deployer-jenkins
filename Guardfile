group :asm, :halt_on_fail => true do
  guard :shell do
    rspec_command = "rspec --color --format=doc --fail-fast %s"
    syntax_check_command = "ruby -c %s"

    watch(%r{^spec/unit/(.+)\.rb$}) do |m|
      if m && File.exist?(m[0])
        puts("%s: %s" % ["*" * 20, m[0]])
        system(rspec_command % m[0]) || throw(:task_has_failed)
      end
    end

    # Rule files
    watch(%r{^rules/(.+)\.rb$}) do |m|
      spec = "spec/unit/rules/#{m[1]}_spec.rb"

      puts("%s: %s" % ["*" * 20, m[0]])
      if File.exist?(spec)
        system(rspec_command % spec) || throw(:task_has_failed)
      else
        print("No tests found, checking syntax: ")
        system(syntax_check_command % m[0]) || throw(:task_has_failed)
      end
    end

    # Ruby files
    watch(%r{^lib/(.+)\.rb$}) do |m|
      spec = "spec/unit/#{m[1]}_spec.rb"

      puts("%s: %s" % ["*" * 20, m[0]])
      if File.exist?(spec)
        system(rspec_command % spec) || throw(:task_has_failed)
      else
        print("No tests found, checking syntax: ")
        system(syntax_check_command % m[0]) || throw(:task_has_failed)
      end
    end
  end

  guard :shell do
    rubocop_command = "rubocop --fail-fast -f progress -f offenses %s"

    watch(%r{^lib|rules/(.+)\.rb$}) do |m|
      next if ["0", "no", "false"].include?(ENV["RUBOCOP"])
      next if m[0].match(/service_deployment.rb/)

      system(rubocop_command % m[0]) || throw(:task_has_failed)
    end
  end
end

require 'rubygems'
require 'puppetlabs_spec_helper/rake_tasks'
require 'rake'
require 'rspec/core/rake_task'

Dir.glob('tasks/*.rake').each { |r| load r}

RSpec::Core::RakeTask.new(:spec)

# Run unit tests by default
task :default => ['spec:suite:unit', 'rubocop']

# To run unit tests:                 bundle exec rake spec:suite:unit
# To run database integration tests: bundle exec rake spec:suite:db

namespace :spec do
  desc "Run guard to automatically run spec and rubocop tests, skip rubocop with RUBOCOP=0"
  task :guard do
    system("guard")
  end

  namespace :suite do
    desc 'Run all specs in unit spec suite'
    RSpec::Core::RakeTask.new('unit') do |t|
      t.pattern = './spec/unit/**/*_spec.rb'
      if ENV["TRAVIS"] == "true"
        t.rspec_opts = '--profile'
      end
    end
  end

  namespace :suite do
    desc 'Run all specs in db spec suite'
    RSpec::Core::RakeTask.new('db') do |t|
      t.pattern = './spec/db/**/*_spec.rb'
    end
  end

  namespace :suite do
    desc 'Run all specs in db spec suite'
    RSpec::Core::RakeTask.new('all') do |t|
      t.pattern = './spec/**/*_spec.rb'
    end
  end
end

# WARNING: These db tasks do not work properly. Just use the db/schema.sql file
namespace :db do
  desc 'Run database migrations'
  task :migrate do |cmd, args|
    require 'asm'
    ASM.init unless ASM.initialized?
    require 'sequel/extensions/migration'
    Sequel::Migrator.apply(ASM.database, 'db/migrate')
  end

  desc 'Rollback the database'
  task :rollback do |cmd, args|
    require 'asm'
    ASM.init unless ASM.initialized?
    require 'sequel/extensions/migration'
    version = (row = ASM.database[:schema_info].first) ? row[:version] : nil
    Sequel::Migrator.apply(ASM.database, 'db/migrate', version - 1)
  end

  desc 'Nuke the database (drop all tables)'
  task :nuke do |cmd, args|
    require 'asm'
    ASM.init unless ASM.initialized?
    ASM.database.tables.each do |table|
      ASM.database.run("DROP TABLE #{table} CASCADE")
    end
  end

  desc 'Reset the database'
  task :reset => [:nuke, :migrate]
end

namespace :doc do
  desc "Serve YARD documentation on %s:%d" % [ENV.fetch("YARD_BIND", "127.0.0.1"), ENV.fetch("YARD_PORT", "9292")]
  task :serve do
    system("yard server --reload --bind %s --port %d" % [ENV.fetch("YARD_BIND", "127.0.0.1"), ENV.fetch("YARD_PORT", "9292")])
  end

  desc "Generate documentatin into the %s" % ENV.fetch("YARD_OUT", "doc")
  task :yard do
    system("yard doc --output-dir %s" % ENV.fetch("YARD_OUT", "doc"))
  end
end

dir = File.expand_path(File.dirname(__FILE__))
$LOAD_PATH.unshift File.join(dir, 'lib')

# Don't want puppet getting the command line arguments for rake or autotest
ARGV.clear

require 'puppet'
require 'facter'
require 'mocha/api'
gem 'rspec', '>=2.0.0'
require 'rspec/expectations'

require 'puppetlabs_spec_helper/module_spec_helper'
require 'asm'

module SpecHelper
  FIXTURE_PATH = File.expand_path(File.join(File.dirname(__FILE__), "fixtures"))

  def self.fixture_path(fixture)
    File.join(FIXTURE_PATH, fixture)
  end

  def self.load_fixture(fixture)
    File.read(fixture_path(fixture))
  end

  def self.json_fixture(fixture)
    JSON.parse(load_fixture(fixture), :max_nesting => 100)
  end

  def self.service_from_fixture(fixture, logger = nil)
    fixture = json_fixture(fixture)
    unless logger
      logger = Object.new # TODO: why can't I use logger = stub(...) here?
      logger.stubs(:debug => nil, :warn => nil, :info => nil)
    end
    deployment = Object.new
    deployment.stubs(:id => fixture["id"], :debug? => false, :process_generic => false, :logger => logger)

    ret = ASM::Service.new(fixture, :deployment => deployment)
    ret
  end

  def self.init_i18n
    I18n.load_path = Dir[File.expand_path(File.join(File.dirname(__FILE__), "..", "locales", "*.yml"))]
    I18n.locale = "en".intern
  end
end

module ASM
  # TODO: we should probably use config.yaml "environments" for this like razor does
  def self.test_config_file
    if RUBY_PLATFORM == 'java'
      File.join(File.dirname(__FILE__), 'jruby_config.yaml')
    else
      File.join(File.dirname(__FILE__), 'mri_config.yaml')
    end
  end

  def self.initialized_for_tests
    @initialized_for_tests
  end

  def self.init_for_tests
    # This is an ugly kludge, need to make the base_directory configurable and
    # just have the logger log to a temporary directory
    logger = Logger.new(nil)
    ASM.stubs(:logger).returns(logger)
    ASM.stubs(:database).returns({:database => "init-for-tests-database"})
    ASM::PrivateUtil.stubs(:appliance_ip_address).returns("10.0.0.1")
    ASM.init(YAML.load_file(self.test_config_file))
    @initialized_for_tests = true
  end
end

# Ensure that any test that fails to call ASM.init_for_tests does not pollute
# ASM.config by initializing it from the default top-level config.yaml file.
# If that happens it results in hard-to-debug failures in subsequent rspec tests.
ENV["ASM_CONFIG"] = ASM.test_config_file

RSpec.configure do |config|
  # FIXME REVISIT - We may want to delegate to Facter like we do in
  # Puppet::PuppetSpecInitializer.initialize_via_testhelper(config) because
  # this behavior is a duplication of the spec_helper in Facter.
  config.before :each do
    # Ensure that we don't accidentally cache facts and environment between
    # test cases.  This requires each example group to explicitly load the
    # facts being exercised with something like
    # Facter.collection.loader.load(:ipaddress)
    Facter::Util::Loader.any_instance.stubs(:load_all)
    Facter.clear
    Facter.clear_messages

    ASM::Cache.any_instance.stubs(:start_gc!)

    ASM::PrivateUtil.stubs(:facts_find).returns({})
  end

  config.expect_with(:rspec) do |c|
    c.syntax = [:should, :expect]
    c.warn_about_potential_false_positives = false
  end
end

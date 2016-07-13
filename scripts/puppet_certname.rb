require 'puppet'
require 'hashie'
require 'inifile'
require 'fileutils'
require 'rbconfig'

Puppet.initialize_settings unless Puppet.settings.global_defaults_initialized?
# delete the old cert directory

first_run = false
if !Config::CONFIG["arch"].include?('linux')
  # Windows platform
  sslfiledir = 'c:\\programdata\\PuppetLabs\\puppet\\etc\\ssl'
  verification_filename = 'c:\\programdata\\puppet_verification_run.txt'
  if !File.file?(verification_filename)
    puts "Running for the first time"
    FileUtils.rm_rf(sslfiledir)
    FileUtils.touch(verification_filename)
    first_run = true
  end

  interfaces = Facter.value('interfaces').split(',').sort
  macaddress = Facter.value("macaddress_#{interfaces[0]}")

else
  sslfiledir = '/var/lib/puppet/ssl'
  verification_filename = '/var/lib/puppet_verification_run.txt'
  if !File.file?(verification_filename)
    puts "Running for the first time"
    FileUtils.rm_rf(sslfiledir)
    FileUtils.touch(verification_filename)
    first_run = true
  end
  macaddress = Facter.value('macaddress')
end

config = IniFile.load(Puppet[:config])
config['agent'] ||= {}
config['main'] ||= {}

raise("Can not detect system macaddress.") unless macaddress
if config['main']['certname'].nil? || config['main']['certname'].empty?
  config['main']['certname'] = "vm%s" % macaddress.gsub(':','').downcase
end

if config['agent']['certname'].nil? || config['agent']['certname'].empty?
  config['agent']['certname'] = "vm%s" % macaddress.gsub(':','').downcase
end

config.save
abort

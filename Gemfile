source 'https://rubygems.org'

# WARNING: Gems added here probably need to be added to asm-deployer.gemspec

platforms :ruby, :mswin, :mingw do
  gem 'pg', '0.17.1'
end

platforms :jruby do
  # WARNING: Failing to specify the 9.2.1002.1 version of jdbc-postgres results
  # in failure to load the postgresql jar on torquebox, not sure why
  gem 'jdbc-postgres', '~> 9.2.1002.1'
  gem 'torquebox', '~> 3.1.2'
end

# Add gems necessary to run facter on Windows
platforms :mswin, :mingw do
  gem 'sys-admin'
  gem 'win32-process'
  gem 'win32-dir'
  gem 'win32-security'
  gem 'win32-service'
  gem 'win32-taskscheduler'
  gem 'windows-pr'
end


gem 'aescrypt', '1.0.0'
gem 'hashie', '3.3.1'
gem 'rest-client', '1.8.0' #or '1.7.2'?
gem 'sequel','4.16.0' #or 4.3.0?
gem 'sinatra', '1.4.5'
gem 'trollop', '2.0'
gem 'nokogiri', '1.5.10'
gem 'rbvmomi', '1.6.0'
gem 'i18n', '0.6.9'
gem 'dell-asm-util', :git => 'https://github.com/dell-asm/dell-asm-util.git', :branch => 'master'
gem 'concurrent-ruby', '~>1.0.0'

group :development, :test do
  gem 'rake'
  gem 'logger-colors', '~> 1.0.0', :require => false
  gem 'guard-shell'
  gem 'yard'
  gem 'kramdown'
  gem 'rubocop', '0.41.2'
  gem 'rspec', '~>3.4.0', :require => false
  gem 'mocha', :require => false
  gem 'puppet', :require => false
  gem 'puppetlabs_spec_helper', '0.4.1', :require => false
  gem 'ruby-prof', '~> 0.15.8', :platforms => [:ruby, :mswin, :mingw]
  gem 'pry-debugger', :platforms => [:ruby, :mswin, :mingw]
  gem 'listen', '~> 3.0.0' # Currently 3.0.6 is the latest for Ruby 1.9.3
  # Our ancient ruby / gems or bundler doesnt do well with new format dependencies in gems
  # so the author of this one made a special branch for people who have to use old rubies.
  # this gem - and specifically a new version of it - is needed by later rubocop.  Afraid
  # we'll get more of this kind of thing as time goes by and our ruby gets even more ancient
  # https://github.com/janlelis/unicode-display_width/issues/6
  gem 'unicode-display_width', git: 'https://github.com/janlelis/unicode-display_width', branch: 'old-rubies'
end

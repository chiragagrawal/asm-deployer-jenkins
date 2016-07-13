#!/bin/bash

VERSION=`puppet --version`

if [[ "$VERSION" =~ Enterprise ]]
then
  /opt/puppet/bin/gem install hashie
  /opt/puppet/bin/gem install inifile -v 2.0.2
  /opt/puppet/bin/ruby puppet_certname.rb
  /opt/puppet/bin/puppet agent -t
else
  gem install hashie
  gem install inifile -v 2.0.2
  ruby /usr/local/bin/puppet_certname.rb
  puppet agent -t
fi

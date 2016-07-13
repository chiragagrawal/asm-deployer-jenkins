module ASM
  class Provider
    class Cluster
      # Provider to manage HyperV clusters
      #
      # This is a provider capable of destroying HyperV clusters, creation should be possible with a few
      # tweaks to the {#configure_hook} to provide or derive missing information - see {ASM::ServiceDeployment#configure_hyperv_cluster}
      #
      # Not all server providers will support being used in HyperV, those who do need to expose a number
      # of propteries defined in SERVER_REQUIRED_PROPERTIES and they should be non nil.
      #
      # This provider uses {ASM::Type::Server#supports_hyperv?} to check if a server instance is configured
      # for HyperV and then extracts those values using {ASM::Type::Server#hyperv_config}.
      #
      # == Non standard teardown
      # While {#process!} will create the correct resource to remove a cluster the HyperV puppet types create
      # auto requires that do not support tearing down so we have to create our own thing here to remove them
      # one by one. So the {#prepare_for_teardown!} method is used to do the actual teardown by doing
      # several Puppet runs and ignoring failures. It's false return value indicates to the cluster teardown
      # rule that {#process!} should not be run.
      class Scvmm < Provider::Base
        puppet_type "asm::cluster::scvmm"

        property :ipaddress,                     :default => nil,                    :validation => :ipv4
        property :hostgroup,                     :default => nil,                    :validation => String
        property :scvmm_server,                  :default => nil,                    :validation => String
        property :ensure,                        :default => "present",              :validation => ["present", "absent"]
        property :hosts,                         :default => [],                     :validation => Array
        property :username,                      :default => nil,                    :validation => String
        property :password,                      :default => nil,                    :validation => String
        property :run_as_account_name,           :default => nil,                    :validation => String
        property :fqdn,                          :default => nil,                    :validation => String
        property :logical_network,               :default => [],                     :validation => Array
        property :logical_network_hostgroups,    :default => [],                     :validation => Array
        property :logical_network_subnet_vlans,  :default => [],                     :validation => Array
        property :vm_network,                    :default => "ConvergedNetSwitch",   :validation => String
        property :options,                       :default => {"timeout" => 600},     :validation => Hash
        property :name,                          :default => nil,                    :validation => String

        # ASM::Type::Server will use this and validate a server is correctly configured for HyperV
        # support, see {ASM::Provider::Server::Server#configured_for_hyperv?}
        SERVER_REQUIRED_PROPERTIES = ["domain_admin_user", "domain_admin_password", "domain_name", "fqdn"].freeze

        # Ensures the hostgroup is set and valid
        #
        # This is being called by {ASM::Provider::Base#configure!}
        #
        # @api private
        # @return [void]
        def configure_hook
          if self[:hostgroup].nil?
            logger.debug("hostgroup is empty on cluster %s, setting it using scvmm_cluster_information.rb")
            self[:hostgroup] = ASM::PrivateUtil.hyperv_cluster_hostgroup(type.puppet_certname, self[:name])
          end

          unless self[:hostgroup] =~ /All Hosts/
            self[:hostgroup] = "All Hosts\\%s" % self[:hostgroup]
          end
        end

        # Create transports records on teardown
        #
        # @api private
        # @return [Hash] of Puppet resources
        def additional_resources
          resources = super

          if self[:ensure] == "absent"
            if server = type.related_server
              credentials = server_run_as_account_credentials(server)
              resources.merge!(transport_config(server.primary_dnsserver, credentials, type.puppet_certname))
            end
          end

          resources
        end

        def virtualmachine_supported?(vm)
          vm.provider_path == "virtualmachine/scvmm"
        end

        # Teardown the server
        #
        # See comments at the top of the class for rational of destroying it here and skipping {#process!}
        #
        # @api private
        # @return [Boolean] false to indicate process! should be skipped
        def prepare_for_teardown!
          cluster_teardown_success = teardown_cluster_host
          teardown_cluster_servers
          teardown_cluster_storage
          teardown_logical_network

          if cluster_teardown_success
            teardown_cluster_dns
            teardown_cluster_ad
          else
            logger.warn("Cluster scvm_host_cluster resource failed so leaving dnsserver_resourcerecord for %s in place" % type.puppet_certname)
          end

          false
        end

        # (see ASM::Type::Cluster#evict_server!)
        def evict_server!(server)
          raise("The server %s is not a HyperV compatible server resource" % server.puppet_certname) unless server.supports_resource?(type)

          remove_server_from_host_cluster(server) rescue logger.warn("Failed to remove server %s from the host cluster: %s: %s" % [server.puppet_certname, $!.class, $!.to_s])
          remove_server_host(server) rescue logger.warn("Failed to remove server %s host: %s: %s" % [server.puppet_certname, $!.class, $!.to_s])
          remove_server_dns(server) rescue logger.warn("Failed to remove server %s dns: %s: %s" % [server.puppet_certname, $!.class, $!.to_s])
          remove_server_ad(server) rescue logger.warn("Failed to remove server %s active directory: %s: %s" % [server.puppet_certname, $!.class, $!.to_s])
        end

        # (see ASM::Type::Cluster#evict_volume!)
        def evict_volume!(volume)
          logger.warn("ASM does not support removing volumes from a running HyperV cluster.  Skipping eviction of volume %s" % volume.puppet_certname)
        end

        # Remove switch configuration when removing server from cluster
        #
        # @param server [ASM::Type::Server] the server to remove from the cluster
        # @return [Boolean]
        def evict_vds!(server)
          true
        end

        def evict_vsan!(server=nil)
          true
        end

        # Removes all the servers from the cluster
        #
        # Removal is done in a single Puppet run. No scvm_host_cluster resource are create.
        #
        # Failures are logged and squashed
        #
        # @api private
        # @return [Boolean] indicating sucess
        def teardown_cluster_servers
          unless self[:ensure] == "absent"
            raise("Refusing to remove all servers from cluster %s that is not being teardown" % type.puppet_certname)
          end

          begin
            resources = {"scvm_host" =>  {},
                         "transport" => {},
                         "dnsserver_resourcerecord" => {},
                         "computer_account" => {},
                         "scvm_host_group" => {}}

            type.related_servers.each do |server|
              logger.info("Removing server %s from cluster %s that is being torn down" % [server.puppet_certname, type.puppet_certname])

              host = remove_server_host(server, false)
              resources["scvm_host"].merge!(host["scvm_host"])
              resources["transport"].merge!(host["transport"])
              resources["scvm_host_group"].merge!(host["scvm_host_group"])

              dns = remove_server_dns(server, false)
              resources["dnsserver_resourcerecord"].merge!(dns["dnsserver_resourcerecord"]) if dns["dnsserver_resourcerecord"]

              ad = remove_server_ad(server, false)
              resources["computer_account"].merge!(ad["computer_account"]) if ad["computer_account"]
            end

            type.process_generic(type.puppet_certname, resources, puppet_run_type, true, nil, type.guid)

            true
          rescue
            logger.warn("Failed to remove all servers from cluster, continuing: %s: %s: %s" % [type.puppet_certname, $!.class, $!.to_s])
            false
          end
        end

        # Remove the cluster dns record
        #
        # Removal is based on the first related servers domainname, should this
        # not be found nothing will be done
        #
        # Failures are logged and squashed
        #
        # @api private
        # @return [Boolean] indicating sucess
        def teardown_cluster_dns
          resources = additional_resources
          dns = dnsserver_resourcerecord(type.related_server, type.puppet_certname)

          if dns.empty?
            logger.debug("Skipping removal of cluster dns as no records were found")
          else
            logger.info("Removing cluster %s dns using dnsserver_resourcerecord" % [type.puppet_certname])

            resources.merge!(dns)
            type.process_generic(type.puppet_certname, resources, puppet_run_type, true, nil, type.guid)
          end

          true
        rescue
          logger.warn("Failed to remove cluster dnsserver_resourcerecord, continuing: %s: %s: %s" % [type.puppet_certname, $!.class, $!.to_s])
          false
        end

        # Remove the cluster active directory record
        #
        # Removal is based on the first related servers domainname, should this
        # not be found nothing will be done
        #
        # Failures are logged and squashed
        #
        # @api private
        # @return [Boolean] indicating sucess
        def teardown_cluster_ad
          resources = additional_resources
          ad = cluster_computer_account

          if ad.empty?
            logger.debug("Skipping removal of cluster AD as no records were found")
          else
            logger.info("Removing cluster %s AD using computer_record" % [type.puppet_certname])

            resources.merge!(ad)
            type.process_generic(type.puppet_certname, resources, puppet_run_type, true, nil, type.guid)
          end

          true
        rescue
          logger.warn("Failed to remove cluster active directory, continuing: %s: %s: %s" % [type.puppet_certname, $!.class, $!.to_s])
          false
        end

        # Remove the ConvergedNetSwitch logical network definition
        #
        # Failures are logged and squashed
        #
        # @api private
        # @return [Boolean] indicating sucess
        def teardown_logical_network
          logger.info("Removing cluster %s logical network using sc_logical_network_definition" % [type.puppet_certname])

          resources = additional_resources
          resources.merge!(sc_logical_network_definition(type.puppet_certname))
          type.process_generic(type.puppet_certname, resources, puppet_run_type, true, nil, type.guid)

          true
        rescue
          logger.warn("Failed to remove sc_logical_network_definition, continuing: %s: %s: %s" % [type.puppet_certname, $!.class, $!.to_s])
          false
        end

        # Remove the cluster storage
        #
        # Failures are logged and squashed
        #
        # @api private
        # @return [Boolean] indicating sucess
        def teardown_cluster_storage
          logger.info("Removing cluster %s storage using scvm_cluster_storage" % [type.puppet_certname])

          resources = additional_resources
          resources.merge!(scvm_cluster_storage(type.puppet_certname))
          type.process_generic(type.puppet_certname, resources, puppet_run_type, true, nil, type.guid)
          true

        rescue
          logger.warn("Failed to remove scvm_cluster_storage, continuing: %s: %s: %s" % [type.puppet_certname, $!.class, $!.to_s])
          false
        end

        # Remove the cluster host
        #
        # Failures are logged and squashed
        #
        # @api private
        # @return [Boolean] indicating sucess
        def teardown_cluster_host
          logger.info("Removing cluster %s host using scvm_host_cluster" % [type.puppet_certname])

          resources = additional_resources
          resources.merge!(scvm_host_cluster(type.related_servers.select(&:teardown?), type.puppet_certname))
          type.process_generic(type.puppet_certname, resources, puppet_run_type, true, nil, type.guid)
          true

        rescue
          logger.warn("Failed to remove scvm_host_cluster, continuing: %s: %s: %s" % [type.puppet_certname, $!.class, $!.to_s])
          false
        end

        # Removes a server from the cluster
        #
        # This only create a scvm_host_cluster resource, other server removal steps
        # are not done.  Use {#evict_server!} for complete server removal
        #
        # @api private
        # @param server [ASM::Type::Server] the server to remove from the cluster
        # @raise [StandardError] on any failures
        # @return [void]
        def remove_server_from_host_cluster(server)
          credentials = server_run_as_account_credentials(server)

          resources = scvm_host_cluster(server, type.puppet_certname)
          resources.merge!(transport_config(server.primary_dnsserver, credentials, type.puppet_certname))

          type.process_generic(type.puppet_certname, resources, puppet_run_type, true, nil, type.guid)
        end

        # Removes a server
        #
        # This only create a scvm_host resource, other server removal steps
        # are not done.  Use {#evict_server!} for complete server removal
        #
        # @api private
        # @param server [ASM::Type::Server] the server to remove from the cluster
        # @param process [Boolean] avoid calling process_generic, return the hash to be processed instead
        # @raise [StandardError] on any failures
        # @return [Hash] the hash of resources when process is set to false
        # @return [void] when process is set to true
        def remove_server_host(server, process=true)
          credentials = server_run_as_account_credentials(server)

          resources = scvm_host(server, type.puppet_certname)
          resources.merge!(transport_config(server.primary_dnsserver, credentials, type.puppet_certname))

          if process
            type.process_generic(type.puppet_certname, resources, puppet_run_type, true, nil, type.guid)
          else
            resources
          end
        end

        # Removes a servers dns entry
        #
        # This only create a dnsserver_resourcerecord resource, other server removal steps
        # are not done.  Use {#evict_server!} for complete server removal
        #
        # @api private
        # @param server [ASM::Type::Server] the server to remove from the cluster
        # @param process [Boolean] avoid calling process_generic, return the hash to be processed instead
        # @raise [StandardError] on any failures
        # @return [Hash] the hash of resources when process is set to false
        # @return [void] when process is set to true
        def remove_server_dns(server, process=true)
          credentials = server_run_as_account_credentials(server)

          resources = dnsserver_resourcerecord(server)
          resources.merge!(transport_config(server.primary_dnsserver, credentials, type.puppet_certname))

          if process
            type.process_generic(type.puppet_certname, resources, puppet_run_type, true, nil, type.guid)
          else
            resources
          end
        end

        # Removes a servers active directory entry
        #
        # This only create a computer_account resource, other server removal steps
        # are not done.  Use {#evict_server!} for complete server removal
        #
        # @api private
        # @param server [ASM::Type::Server] the server to remove from the cluster
        # @param process [Boolean] avoid calling process_generic, return the hash to be processed instead
        # @raise [StandardError] on any failures
        # @return [Hash] the hash of resources when process is set to false
        # @return [void] when process is set to true
        def remove_server_ad(server, process=true)
          credentials = server_run_as_account_credentials(server)

          transport = transport_config(server.primary_dnsserver, credentials, type.puppet_certname)
          resources = computer_account(server).merge(transport)

          if process
            type.process_generic(type.puppet_certname, resources, puppet_run_type, true, nil, type.guid)
          else
            resources
          end
        end

        # Extract the domain username from a set of credentials
        #
        # @api private
        # @param credentials [Hash] credentials created using {#server_run_as_account_credentials}
        # @return [String] the domain username
        def domain_username(credentials)
          "%s\\%s" % [credentials["domain_name"], credentials["username"]]
        end

        # Extract the subnet vlans from a server PUBLIC_LAN, PRIVATE_LAN and PXE networks
        #
        # This is in the format the sc_logical_network_definition puppet resource expects
        #
        # @api private
        # @param server [ASM::Type::Server] the server to operate on
        # @return [Array<Hash>] Hashes describing the vlans
        def subnet_vlans(server)
          server.network_config.get_networks("PUBLIC_LAN", "PRIVATE_LAN", "PXE").collect do |network|
            {"vlan" => network["vlanId"], "subnet" => ""}
          end
        end

        # Extract the hostname and domainname from a server
        #
        # @api private
        # @param server [ASM::Type::Server]
        # @return [Array<String, String>] the hostname and domainname
        def server_domain_and_host(server)
          _, hostname, domainname = server_fqdn(server).match(/^(.+?)\.(.+)$/).to_a
          [hostname, domainname]
        end

        # Creates an FQDN for the server
        #
        # This provider expect a property called *fqdn* in the *asm::server* properties which
        # is unfortunately not an FQDN at all but just domain part.  This method constructs
        # a real FQDN based on the hostname and this fqdn property
        #
        # @api private
        # @param server [ASM::Type::Server]
        # @return [String] the fqdn
        def server_fqdn(server)
          fqdn = server.hyperv_config["fqdn"]
          "%s.%s" % [server.hostname, fqdn]
        end

        # Lookup the cluster IP address or reserve a new one if unset
        #
        # This uses the {ASM::ServiceDeployment#hyperv_cluster_ip?} and {ASM::ServiceDeployment#get_hyperv_cluster_ip}
        # methods to get or reserve a new HyperV cluster IP address when the cluster ipaddress property is not set
        #
        # When getting or reserving it updates the ipaddress property in this instance so subsequent calls will
        # not again reserve an IP
        #
        # When in debug mode the IP will be forced to 192.168.1.1 if it's not already set
        #
        # @api private
        # @param server [ASM::Type::Server] a server to base the reservation on
        # @return [String] an ip address
        def get_or_reserve_cluster_ip(server)
          if self[:ipaddress].nil? || self[:ipaddress].empty?
            if !debug?
              deployment = type.deployment

              self[:ipaddress] = deployment.hyperv_cluster_ip?(type.puppet_certname, self[:name]) || deployment.get_hyperv_cluster_ip(server.component_configuration)
            else
              self[:ipaddress] = "192.168.1.1"
            end
          else
            self[:ipaddress]
          end
        end

        # Extract credentials from a server resource
        #
        # @api private
        # @param server [ASM::Type::Server]
        # @return [Hash]
        def server_run_as_account_credentials(server)
          config = server.hyperv_config

          {"username"     => config["domain_admin_user"],
           "password"     => config["domain_admin_password"],
           "domain_name"  => config["domain_name"],
           "fqdn"         => config["fqdn"]}
        end

        # Creates a dnsserver_resourcerecord resource
        #
        # When hostname and domainname cannot be determined using {#server_domain_and_host}
        # an empty hash will be returned
        #
        # @api private
        # @param server [ASM::Type::Server] the related server to get hostname and domainname from
        # @param hostname [String] do not use the servers hostname, use this one instead
        # @param record_ensure ["absent", "present"] the ensure value for the record, defaults to the server ensure property
        # @return [Hash] the dnsserver_resourcerecord record
        def dnsserver_resourcerecord(server, hostname=nil, record_ensure=nil)
          if hostname
            _, domainname = server_domain_and_host(server)
          else
            hostname, domainname = server_domain_and_host(server)
          end

          record_ensure ||= server.ensure

          if hostname && domainname
            {"dnsserver_resourcerecord" =>
              {hostname =>
                {"ensure" => record_ensure,
                 "zonename" => domainname,
                 "transport" => "Transport[winrm]"
                }
              }
            }
          else
            {}
          end
        end

        # Creates a computer_account resource
        #
        # When hostname and domainname cannot be determined using {#server_domain_and_host}
        # an empty hash will be returned
        #
        # @api private
        # @param server [ASM::Type::Server] the related server to get hostname and domainname from
        # @param hostname [String] do not use the servers hostname, use this one instead
        # @param record_ensure ["absent", "present"] the ensure value for the record, defaults to the server ensure property
        # @return [Hash] the computer_account record
        def computer_account(server, hostname=nil, record_ensure=nil)
          if hostname
            _, domainname = server_domain_and_host(server)
          else
            hostname, domainname = server_domain_and_host(server)
          end

          record_ensure ||= server.ensure

          if hostname && domainname
            {"computer_account" =>
              {hostname =>
                {"ensure" => record_ensure,
                 "transport" => "Transport[winrm]"
                }
              }
            }
          else
            {}
          end
        end

        # Creates a computer_account resource to remove cluster AD resource
        #
        # @api private
        # @return [Hash] the computer_account record
        def cluster_computer_account(ensure_value="absent")
          {"computer_account" =>
            {name =>
              {"ensure" => ensure_value,
               "transport" => "Transport[winrm]"
              }
            }
          }
        end

        # Creates a sc_logical_network_definition Puppet resource
        #
        # @api private
        # @param transport_name [String] override the transport name, defaults to cluster puppet certname
        # @return [Hash]
        def sc_logical_network_definition(transport_name=nil)
          transport_name ||= type.puppet_certname

          {"sc_logical_network_definition" =>
            {"ConvergedNetSwitch" =>
              {"ensure" => self[:ensure],
               "logical_network" => "ConvergedNetSwitch",
               "host_groups" => [self[:hostgroup]],
               "subnet_vlans" => subnet_vlans(type.related_server),
               "inclusive" => false,
               "skip_deletion" => true,
               "transport" => "Transport[%s]" % transport_name
              }
            }
          }
        end

        # Creates a scvm_cluster_storage Puppet resource
        #
        # The credentials and host used is that of the first related server
        #
        # @api private
        # @param transport_name [String] override the transport name, defaults to cluster puppet certname
        # @return [Hash]
        def scvm_cluster_storage(transport_name=nil)
          server = type.related_server

          credentials = server_run_as_account_credentials(server)
          transport_name ||= type.puppet_certname

          {"scvm_cluster_storage" =>
            {self[:name] =>
              {"ensure" => self[:ensure],
               "host"   => server_fqdn(server),
               "path" => self[:hostgroup],
               "username" => domain_username(credentials),
               "password" => credentials["password"],
               "fqdn" => credentials["fqdn"],
               "transport" => "Transport[%s]" % transport_name,
               "provider" => "asm_decrypt"
              }
            }
          }
        end

        # Creates a scvm_host_cluster Puppet resource
        #
        # The credentials and host used is that of the first server
        #
        # When the cluster is being removed via ensure => absent the resulting resource will have
        # a *hosts* key that matches the list of servers being removed
        #
        # When the cluster is not being removed the resulting resource will have a *remove_hosts*
        # key that matches the list of servers being removed
        #
        # @note this resource is almost certainly wrong for creating clusters and should only
        #       be used to maintain server lists while removing servers or clusters
        # @api private
        # @param server [ASM::Type::Server, Array<ASM::Type::Server>] the server or servers to act on
        # @param transport_name [String] override the transport name, defaults to cluster puppet certname
        # @return [Hash]
        # @raise [StandardError] when no hosts are found to be torn down
        def scvm_host_cluster(server, transport_name=nil)
          servers = Array(server)

          credentials = server_run_as_account_credentials(servers.first)
          transport_name ||= type.puppet_certname

          remove_hosts = servers.select(&:teardown?).map {|s| server_fqdn(s)}

          raise("Cannot create scvm_host_cluster as it only supports hosts being torn down and none were found") if remove_hosts.empty?

          resource = {
            "ensure" => self[:ensure],
            "path" => self[:hostgroup],
            "username" => domain_username(credentials),
            "password" => credentials["password"],
            "fqdn" => credentials["fqdn"],
            "inclusive" => false,
            "transport" => "Transport[%s]" % transport_name,
            "provider" => "asm_decrypt"
          }

          if self[:ensure] == "absent"
            resource["hosts"] = remove_hosts
          else
            resource["remove_hosts"] = remove_hosts
          end

          if type.service_teardown?
            resource["cluster_ipaddress"] = ""
          else
            resource["cluster_ipaddress"] = get_or_reserve_cluster_ip(servers.first)
          end

          {"scvm_host_cluster" => {self[:name] => resource}}
        end

        # Create a scvm_host Puppet resource for a server
        #
        # The resulting resource will have a *before* relationship to a
        # *scvm_host_group* resource and will include the resource
        #
        # @api private
        # @param server [ASM::Type::Server] the server to create the record for
        # @param transport_name [String] override the transport name, defaults to cluster puppet certname
        # @return [Hash]
        def scvm_host(server, transport_name=nil)
          credentials = server_run_as_account_credentials(server)
          transport_name ||= type.puppet_certname

          {"scvm_host" =>
            {server_fqdn(server) =>
              {"ensure" => server.ensure,
               "path" => self[:hostgroup],
               "management_account" => credentials["username"],
               "transport" => "Transport[%s]" % transport_name,
               "provider" => "asm_decrypt",
               "username" => domain_username(credentials),
               "password" => credentials["password"],
               "before" => "Scvm_host_group[%s]" % self[:hostgroup]
              }
            }
          }.merge!(scvm_host_group(server, transport_name))
        end

        # Create a scvm_host_group Puppet resource for a server
        #
        # @api private
        # @param server [ASM::Type::Server] the server to create the record for
        # @param transport_name [String] override the transport name, defaults to cluster puppet certname
        # @return [Hash]
        def scvm_host_group(server, transport_name=nil)
          transport_name ||= type.puppet_certname

          {"scvm_host_group" =>
            {self[:hostgroup] =>
              {"ensure" => server.ensure,
               "transport" => "Transport[%s]" % transport_name
              }
            }
          }
        end

        # Creates transports for the cluster
        #
        # This includes a device_file transport and a winrm resource
        #
        # @api private
        # @param dnsserver [String] the dnsserver for the winrm resource
        # @param credentials [Hash] credentials created using {#server_run_as_account_credentials}
        # @param name [String] override the transport name, defaults to cluster puppet certname
        # @return [Hash]
        def transport_config(dnsserver, credentials, name=nil)
          name ||= type.puppet_certname

          {"transport" =>
            {name =>
              {"provider" => "device_file",
               "options" => {"timeout" => 600}
              },

             "winrm" =>
              {"server" => dnsserver,
               "username" => domain_username(credentials),
               "provider" => "asm_decrypt",
               "options"  => {"crypt_string" => credentials["password"]}
              }
            }
          }
        end
      end
    end
  end
end

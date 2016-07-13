require 'spec_helper'
require 'asm/type'

ASM::Type.load_providers!

describe ASM::Provider::Cluster::Scvmm do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:deployment) { stub(:id => "1234", :debug? => false, :log => nil) }
  let(:service) { SpecHelper.service_from_fixture("Teardown_EQL_Scvmm_Server.json") }
  let(:server_components) { service.components_by_type("SERVER") }
  let(:volume_components) { service.components_by_type("STORAGE") }
  let(:cluster_component) { service.components_by_type("CLUSTER").first }
  let(:vm_component) { service.components_by_type("VIRTUALMACHINE").first }

  let(:type) { cluster_component.to_resource(deployment, logger) }
  let(:provider) { type.provider }

  let(:server) { server_components.first.to_resource(deployment, logger) }

  before(:each) do
    ASM::NetworkConfiguration.any_instance.stubs(:add_nics!)
    deployment.stubs(:lookup_hostname).with(server.hostname, server.static_network_config).returns("rspec-testhost")
    deployment.stubs(:decrypt?).returns(true)

    type.stubs(:related_servers).returns([server])
    provider.stubs(:host_username).returns("root")
    provider[:ipaddress] = "192.168.1.1"
  end

  describe "#virtualmachine_supported?" do
    it "should support hyperv vms" do
      expect(provider.virtualmachine_supported?(vm_component.to_resource(deployment, logger))).to be(true)
    end

    it "should support no other providers" do
      expect(provider.virtualmachine_supported?(stub(:provider_path => "rspec/rspec"))).to be(false)
    end
  end
  describe "#teardown_cluster_servers" do
    it "should refuse to remove all servers from a cluster not being torn down" do
      provider.ensure = "present"
      expect { provider.teardown_cluster_servers }.to raise_error("Refusing to remove all servers from cluster scvmm-scvmm-172.28.4.173 that is not being teardown")
    end

    it "should merge dns and host resources for all hosts into one puppet run" do
      type.stubs(:related_servers).returns([
        service.components_by_type("SERVER")[0].to_resource(deployment, logger),
        service.components_by_type("SERVER")[0].to_resource(deployment, logger)
      ])

      provider.stubs(:server_domain_and_host).returns(["host0", "example.com"], ["host1", "example.com"])
      provider.stubs(:server_fqdn).returns("host0", "host1", "host0", "host1")

      type.expects(:process_generic).with("scvmm-scvmm-172.28.4.173",
                                          has_entries("scvm_host" => has_entries("host0" => is_a(Hash), "host1" => is_a(Hash)),
                                                      "transport" => is_a(Hash),
                                                      "scvm_host_group" => is_a(Hash),
                                                      "dnsserver_resourcerecord" => has_entries("host0" => is_a(Hash), "host1" => is_a(Hash))),
                                          "apply",
                                          true,
                                          nil,
                                          "scvmm-172.28.4.173")

      provider.teardown_cluster_servers
    end

    it "should squash failures" do
      type.expects(:related_servers).raises("rspec fail")
      logger.expects(:warn).with("Failed to remove all servers from cluster, continuing: scvmm-scvmm-172.28.4.173: RuntimeError: rspec fail")
      expect(provider.teardown_cluster_servers).to eq(false)
    end
  end

  describe "#get_or_reserve_cluster_ip" do
    it "should not reserve an ip when one has already been set" do
      provider.ipaddress = "192.168.1.2"
      deployment.expects(:hyperv_cluster_ip?).never
      deployment.expects(:get_hyperv_cluster_ip).never
      expect(provider.get_or_reserve_cluster_ip(server)).to eq("192.168.1.2")
    end

    it "should take the ip from hyperv_cluster_ip? if it provides one" do
      provider.ipaddress = nil
      deployment.expects(:hyperv_cluster_ip?).returns("192.168.1.2")
      deployment.expects(:get_hyperv_cluster_ip).never
      expect(provider.get_or_reserve_cluster_ip(server)).to eq("192.168.1.2")
    end

    it "should take the ip from get_hyperv_cluster_ip if needed" do
      provider.ipaddress = nil
      deployment.expects(:hyperv_cluster_ip?).returns(nil)
      deployment.expects(:get_hyperv_cluster_ip).returns("192.168.1.2")
      expect(provider.get_or_reserve_cluster_ip(server)).to eq("192.168.1.2")
    end
  end

  describe "#transport_config" do
    let(:expected) do
      {"transport" =>
        {"scvmm-scvmm-172.28.4.173" =>
          {"provider" => "device_file",
           "options" => {"timeout" => 600}
          },

         "winrm" =>
          {"server" => "8.8.8.8",
           "username" => "Aidev\\SushilR",
           "provider" => "asm_decrypt",
           "options"  => {"crypt_string" => "ff8080814dbf2d1d014dc2d4db530cf4"}
          }
        }
      }
    end

    it "should create the correct transport config" do
      expect(provider.transport_config("8.8.8.8", provider.server_run_as_account_credentials(server))).to eq(expected)
    end

    it "should allow custom transport name" do
      expected["transport"]["rspec"] = expected["transport"].delete("scvmm-scvmm-172.28.4.173")
      expect(provider.transport_config("8.8.8.8", provider.server_run_as_account_credentials(server), "rspec")).to eq(expected)
    end
  end

  describe "server_run_as_account_credentials" do
    it "should extract the correct credentials" do
      expected = {"username" => "SushilR",
                  "password" => "ff8080814dbf2d1d014dc2d4db530cf4",
                  "domain_name" => "Aidev",
                  "fqdn" => "Aidev.com"}

      expect(provider.server_run_as_account_credentials(server)).to eq(expected)
    end
  end

  describe "#scvm_host_group" do
    let(:expected) do
      {"scvm_host_group" =>
        {"All Hosts\\EqliSCSI" =>
          {"ensure" => "absent",
           "transport" => "Transport[scvmm-scvmm-172.28.4.173]"
          }
        }
      }
    end

    it "should create the correct host group" do
      expect(provider.scvm_host_group(server)).to eq(expected)
    end

    it "should allow transport to be overridden" do
      expected["scvm_host_group"]["All Hosts\\EqliSCSI"]["transport"] = "Transport[rspec]"
      expect(provider.scvm_host_group(server, "rspec")).to eq(expected)
    end
  end

  describe "#scvm_host" do
    let(:expected) do
      {"scvm_host" =>
        {"sushilhv1.Aidev.com" =>
          {"ensure" => "absent",
           "path"   => "All Hosts\\EqliSCSI",
           "management_account" => "SushilR",
           "transport" => "Transport[scvmm-scvmm-172.28.4.173]",
           "provider" => "asm_decrypt",
           "username" => "Aidev\\SushilR",
           "password" => "ff8080814dbf2d1d014dc2d4db530cf4",
           "before" => "Scvm_host_group[All Hosts\\EqliSCSI]"
          }
        }
      }.merge!(provider.scvm_host_group(server))
    end

    it "should default to cluster certname and create a valid config" do
      expect(provider.scvm_host(server)).to eq(expected)
    end

    it "should allow transport to be overridden" do
      expected["scvm_host"]["sushilhv1.Aidev.com"]["transport"] = "Transport[rspec]"
      expected["scvm_host_group"]["All Hosts\\EqliSCSI"]["transport"] = "Transport[rspec]"
      expect(provider.scvm_host(server, "rspec")).to eq(expected)
    end
  end

  describe "#scvm_host_cluster" do
    let(:expected) do
      {"scvm_host_cluster" =>
        {"EqliSCSI" =>
          {"ensure" => "absent",
           "cluster_ipaddress" => "",
           "path" => "All Hosts\\EqliSCSI",
           "username" => "Aidev\\SushilR",
           "password" => "ff8080814dbf2d1d014dc2d4db530cf4",
           "fqdn" => "Aidev.com",
           "inclusive" => false,
           "transport" => "Transport[scvmm-scvmm-172.28.4.173]",
           "hosts" => ["sushilhv1.Aidev.com"],
           "provider" => "asm_decrypt"
          }
        }
      }
    end

    it "should create the hosts key when also removing the cluster" do
      provider.ensure = "absent"
      expect(provider.scvm_host_cluster(server)).to eq(expected)
    end

    it "should create the remove_hosts key and fetch the cluster IP when not also removing the cluster" do
      provider.ensure = "present"
      expected["scvm_host_cluster"]["EqliSCSI"]["ensure"] = "present"
      expected["scvm_host_cluster"]["EqliSCSI"]["remove_hosts"] = expected["scvm_host_cluster"]["EqliSCSI"].delete("hosts")
      expect(provider.scvm_host_cluster(server)).to eq(expected)
    end

    it "should fail when no hosts are being torn down" do
      server.expects(:teardown?).returns(false)
      expect{ provider.scvm_host_cluster(server) }.to raise_error("Cannot create scvm_host_cluster as it only supports hosts being torn down and none were found")
    end

    it "should lookup the cluster IP when not being torn down" do
      type.stubs(:service_teardown?).returns(false)
      expected["scvm_host_cluster"]["EqliSCSI"]["cluster_ipaddress"] = "192.168.1.1"
      expect(provider.scvm_host_cluster(server)).to eq(expected)
    end

    it "should allow transport to be overridden" do
      expected["scvm_host_cluster"]["EqliSCSI"]["transport"] = "Transport[rspec]"
      expect(provider.scvm_host_cluster(server, "rspec")).to eq(expected)
    end
  end

  describe "#scvm_cluster_storage" do
    let(:expected) do
      {"scvm_cluster_storage" =>
        {"EqliSCSI" =>
          {"ensure" => "absent",
           "host"   => "sushilhv1.Aidev.com",
           "path" => "All Hosts\\EqliSCSI",
           "username" => "Aidev\\SushilR",
           "password" => "ff8080814dbf2d1d014dc2d4db530cf4",
           "fqdn" => "Aidev.com",
           "transport" => "Transport[scvmm-scvmm-172.28.4.173]",
           "provider" => "asm_decrypt"
          }
        }
      }
    end

    it "should default to cluster certname and create a valid config" do
      expect(provider.scvm_cluster_storage).to eq(expected)
    end

    it "should allow transport to be overridden" do
      expected["scvm_cluster_storage"]["EqliSCSI"]["transport"] = "Transport[rspec]"
      expect(provider.scvm_cluster_storage("rspec")).to eq(expected)
    end
  end

  describe "#sc_logical_network_definition" do
    let(:expected) do
      {"sc_logical_network_definition" =>
        {"ConvergedNetSwitch" =>
          {"ensure" => "absent",
           "logical_network" => "ConvergedNetSwitch",
           "host_groups" => ["All Hosts\\EqliSCSI"],
           "subnet_vlans" => [{"vlan"=>20, "subnet"=>""}, {"vlan"=>22, "subnet"=>""}],
           "inclusive" => false,
           "skip_deletion" => true,
           "transport" => "Transport[scvmm-scvmm-172.28.4.173]"
          }
        }
      }
    end

    it "should default to cluster certname and create a valid config" do
      expect(provider.sc_logical_network_definition).to eq(expected)
    end

    it "should allow transport to be overridden" do
      expected["sc_logical_network_definition"]["ConvergedNetSwitch"]["transport"] = "Transport[rspec]"
      expect(provider.sc_logical_network_definition("rspec")).to eq(expected)
    end
  end

  describe "#dnsserver_resourcerecord" do
    let(:expected) do
      {"dnsserver_resourcerecord"=>
        {"sushilhv1" =>
          {"ensure" => "absent",
           "zonename" => "Aidev.com",
           "transport" => "Transport[winrm]"
          }
        }
      }
    end

    it "should use the server hostname, domainname and ensure by default" do
      expect(provider.dnsserver_resourcerecord(server)).to eq(expected)
    end

    it "should allow hostname and ensure to be overridden" do
      expected["dnsserver_resourcerecord"]["rspec"] = expected["dnsserver_resourcerecord"].delete("sushilhv1")
      expected["dnsserver_resourcerecord"]["rspec"]["ensure"] = "present"

      expect(provider.dnsserver_resourcerecord(server, "rspec", "present")).to eq(expected)
    end

    it "should return an empty hash when hostname or domainname cannot be found" do
      provider.expects(:server_domain_and_host).returns(nil, "example.com")
      expect(provider.dnsserver_resourcerecord(server, "rspec", "present")).to eq({})

      provider.expects(:server_domain_and_host).returns("example", nil)
      expect(provider.dnsserver_resourcerecord(server, "rspec", "present")).to eq({})
    end
  end

  describe "#computer_account" do
    let(:expected) do
      {"computer_account"=>
           {"sushilhv1" =>
                {"ensure" => "absent",
                 "transport" => "Transport[winrm]"
                }
           }
      }
    end

    it "should use the server hostname, domainname and ensure by default" do
      expect(provider.computer_account(server)).to eq(expected)
    end

    it "should allow hostname and ensure to be overridden" do
      expected["computer_account"]["rspec"] = expected["computer_account"].delete("sushilhv1")
      expected["computer_account"]["rspec"]["ensure"] = "present"

      expect(provider.computer_account(server, "rspec", "present")).to eq(expected)
    end

    it "should return an empty hash when hostname or domainname cannot be found" do
      provider.expects(:server_domain_and_host).returns(nil, "example.com")
      expect(provider.computer_account(server, "rspec", "present")).to eq({})

      provider.expects(:server_domain_and_host).returns("example", nil)
      expect(provider.computer_account(server, "rspec", "present")).to eq({})
    end
  end

  describe "#teardown_cluster_ad" do
    let(:expected) do
      {"computer_account" =>
           {"EqliSCSI" =>
                {"ensure" => "absent",
                 "transport" => "Transport[winrm]"}
           }
      }
    end

    it "should return resource hash for cluster computer account cleanup" do
      expect(provider.cluster_computer_account).to eql(expected)
    end
  end


  describe "#server_fqdn" do
    it "should create the correct fqdn" do
      expect(provider.server_fqdn(server)).to eq("sushilhv1.Aidev.com")
    end
  end

  describe "#server_domain_and_host" do
    it "should extract the correct hostname and domainname" do
      expect(provider.server_domain_and_host(server)).to eq(["sushilhv1", "Aidev.com"])
    end
  end

  describe "#subnet_vlans" do
    it "should return the correct vlans" do
      expect(provider.subnet_vlans(server)).to eq([{"vlan"=>20, "subnet"=>""}, {"vlan"=>22, "subnet"=>""}])
    end
  end

  describe "#domain_username" do
    it "should convert credentials to a username" do
      expect(provider.domain_username("domain_name" => "example.com", "username" => "rspec")).to eq("example.com\\rspec")
    end
  end

  describe "#remove_server_from_host_cluster" do
    it "should remove the server" do
      type.expects(:process_generic).with("scvmm-scvmm-172.28.4.173", has_entries("scvm_host_cluster" => is_a(Hash), "transport" => is_a(Hash)), "apply", true, nil, "scvmm-172.28.4.173")

      provider.remove_server_from_host_cluster(server)
    end
  end
  describe "#remove_server_host" do
    it "should remove the server host" do
      type.expects(:process_generic).with("scvmm-scvmm-172.28.4.173", has_entries("transport" => is_a(Hash), "scvm_host" => is_a(Hash)), "apply", true, nil, "scvmm-172.28.4.173")

      provider.remove_server_host(server)
    end
  end


  describe "#remove_server_dns" do
    it "should remove the server dns" do
      type.expects(:process_generic).with("scvmm-scvmm-172.28.4.173", has_entries("transport" => is_a(Hash), "dnsserver_resourcerecord" => is_a(Hash)), "apply", true, nil, "scvmm-172.28.4.173")

      provider.remove_server_dns(server)
    end
  end

  describe "#remove_server_ad" do
    it "should remove the server ad" do
      type.expects(:process_generic).with("scvmm-scvmm-172.28.4.173", has_entries("transport" => is_a(Hash), "computer_account" => is_a(Hash)), "apply", true, nil, "scvmm-172.28.4.173")

      provider.remove_server_ad(server)
    end
  end

  describe "#teardown_cluster_host" do
    it "should remove the cluster host definition" do
      type.expects(:process_generic).with("scvmm-scvmm-172.28.4.173", has_key("scvm_host_cluster"), "apply", true, nil, "scvmm-172.28.4.173")
      expect(provider.teardown_cluster_host).to be(true)
    end

    it "should return false on failure" do
      provider.expects(:additional_resources).raises("rspec failure")
      deployment.expects(:process_generic).never
      expect(provider.teardown_cluster_host).to be(false)
    end
  end

  describe "#teardown_cluster_storage" do
    it "should remove the cluster storage definition" do
      type.expects(:process_generic).with("scvmm-scvmm-172.28.4.173", has_key("scvm_cluster_storage"), "apply", true, nil, "scvmm-172.28.4.173")
      expect(provider.teardown_cluster_storage).to be(true)
    end

    it "should return false on failure" do
      provider.expects(:additional_resources).raises("rspec failure")
      deployment.expects(:process_generic).never
      expect(provider.teardown_cluster_storage).to be(false)
    end
  end

  describe "#teardown_logical_network" do
    it "should remove the logical network" do
      type.expects(:process_generic).with("scvmm-scvmm-172.28.4.173", has_key("sc_logical_network_definition"), "apply", true, nil, "scvmm-172.28.4.173")
      expect(provider.teardown_logical_network).to be(true)
    end

    it "should return false on failures" do
      provider.expects(:additional_resources).raises("rspec failure")
      deployment.expects(:process_generic).never
      expect(provider.teardown_logical_network).to be(false)
    end
  end

  describe "#teardown_cluster_dns" do
    it "should remove dns records when they exist" do
      provider.expects(:additional_resources).returns({"additional" => true})
      provider.expects(:dnsserver_resourcerecord).with(server, "scvmm-scvmm-172.28.4.173").returns({"dnsserver_resourcerecord" => true})
      type.expects(:process_generic).with("scvmm-scvmm-172.28.4.173",
                                          {"additional" => true, "dnsserver_resourcerecord" => true },
                                          "apply", true, nil, "scvmm-172.28.4.173")
      expect(provider.teardown_cluster_dns).to be(true)
    end

    it "should not process when no dns record is returned" do
      provider.expects(:additional_resources).returns({"additional" => true})
      provider.expects(:dnsserver_resourcerecord).returns({})
      type.expects(:process_generic).never
      expect(provider.teardown_cluster_dns).to be(true)
    end

    it "should return false on failures" do
      provider.expects(:additional_resources).raises("rspec failure")
      expect(provider.teardown_cluster_dns).to be(false)
    end
  end

  describe "#prepare_for_teardown!" do
    before(:each) do
      provider.stubs(:teardown_cluster_host => nil, :teardown_cluster_storage => nil, :teardown_logical_network => nil, :teardown_cluster_dns => nil, :teardown_cluster_servers => nil)
    end

    it "should not remove cluster dns when removing the cluster fails" do
      provider.expects(:teardown_cluster_host).returns(false)
      provider.expects(:teardown_cluster_dns).never
      provider.prepare_for_teardown!
    end

    it "should return false" do
      expect(provider.prepare_for_teardown!).to eq(false)
    end

    it "should attempt to remove everything" do
      provider.expects(:teardown_cluster_host).returns(true)
      provider.expects(:teardown_cluster_storage).returns(true)
      provider.expects(:teardown_cluster_servers).returns(true)
      provider.expects(:teardown_logical_network).returns(true)
      provider.expects(:teardown_cluster_dns).returns(true)
      provider.expects(:teardown_cluster_ad).returns(true)
      expect(provider.prepare_for_teardown!).to eq(false)
    end
  end

  describe "#configure_hook" do
    let(:config_hash) { cluster_component.to_hash }

    before(:each) do
      config_hash["resources"][0]["parameters"].delete_at(0)
      cluster_component.stubs(:to_hash).returns(config_hash)
    end

    it "should detect the hostgroup if none is provided" do
      ASM::PrivateUtil.expects(:hyperv_cluster_hostgroup).with("scvmm-scvmm-172.28.4.173", "EqliSCSI").returns("All Hosts\\rspec group")
      type = cluster_component.to_resource(deployment, logger)
      expect(type.provider.hostgroup).to eq("All Hosts\\rspec group")
    end

    it "should prepend All Hosts when needed" do
      ASM::PrivateUtil.expects(:hyperv_cluster_hostgroup).with("scvmm-scvmm-172.28.4.173", "EqliSCSI").returns("rspec group")
      type = cluster_component.to_resource(deployment, logger)
      expect(type.provider.hostgroup).to eq("All Hosts\\rspec group")
    end
  end

  describe "#additional_resources" do
    it "should return no resources when not removing the cluster" do
      provider.ensure = "present"
      expect(provider.additional_resources).to eq({})
    end

    it "should return the transports when removing the cluster" do
      transport = provider.transport_config(server.primary_dnsserver, provider.server_run_as_account_credentials(server), type.puppet_certname)

      expect(provider.additional_resources).to include(transport)
    end
  end

  describe("#evict_server!") do
    it "should not evict non hyperv configured servers" do
      server.expects(:supports_resource?).with(type).returns(false)
      expect{ provider.evict_server!(server) }.to raise_error("The server bladeserver-gk4v5y1 is not a HyperV compatible server resource")
    end

    it "should remove the server and dns" do
      provider.expects(:remove_server_from_host_cluster).with(server)
      provider.expects(:remove_server_host).with(server)
      provider.expects(:remove_server_dns).with(server)
      provider.expects(:remove_server_ad).with(server)
      provider.evict_server!(server)
    end

    it "should silently fail on errors" do
      provider.expects(:remove_server_from_host_cluster).with(server).raises("rspec host cluster fail")
      provider.expects(:remove_server_host).with(server).raises("rspec host fail")
      provider.expects(:remove_server_dns).with(server).raises("rspec server dns fail")
      provider.expects(:remove_server_ad).with(server).raises("rspec server ad fail")

      logger.expects(:warn).with("Failed to remove server bladeserver-gk4v5y1 from the host cluster: RuntimeError: rspec host cluster fail")
      logger.expects(:warn).with("Failed to remove server bladeserver-gk4v5y1 host: RuntimeError: rspec host fail")
      logger.expects(:warn).with("Failed to remove server bladeserver-gk4v5y1 active directory: RuntimeError: rspec server ad fail")

      provider.evict_server!(server)
    end
  end
end

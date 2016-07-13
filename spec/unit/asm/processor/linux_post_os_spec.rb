require "spec_helper"
require "asm/processor/server"
require "asm/processor/linux_post_os"
require "asm/device_management"
require "asm/service"

describe ASM::Processor::LinuxPostOS do
  let(:puppetdb) { stub(:successful_report_after? => true) }
  let(:default_ip) {"1.1.1.1"}
  let(:appliance_ip) {"172.20.5.100"}
  before do
    ASM.init_for_tests
    ASM::Util.stubs(:default_routed_ip).returns("1.1.1.1")
    @service_deployment = SpecHelper.json_fixture("processor/linux_post_os/linux_post_os.json")
    @sd = mock("service_deployment")

    @tmp_dir = Dir.mktmpdir
    ASM.stubs(:base_dir).returns(@tmp_dir)
    ASM::PrivateUtil.stubs(:fetch_server_inventory).returns("refId" => "id", "model" => "R630", "serverType" => "rack")

    @deployment_db = mock("deploymentdb")
    @deployment_db.stub_everything
    @sd = ASM::ServiceDeployment.new("8000", @deployment_db)

    @sd.components(@service_deployment)
    @server_component = @sd.components_by_type('SERVER')[0]
    @linux_processor = ASM::Processor::LinuxPostOS.new(@sd, @server_component)
    @fqdd_to_mac = {"NIC.Integrated.1-1-1" => "00:0A:F7:38:94:F0",
                    "NIC.Integrated.1-2-1" => "00:0A:F7:38:94:F2",
                    "NIC.Integrated.1-3-1" => "00:0A:F7:38:94:F4",
                    "NIC.Integrated.1-4-1" => "00:0A:F7:38:94:F6",
                    "NIC.Slot.3-1-1" => "00:10:18:E7:ED:C0",
                    "NIC.Slot.3-2-1" => "00:10:18:E7:ED:C2"}
    nic_views = @fqdd_to_mac.keys.map do |fqdd|
      mac = @fqdd_to_mac[fqdd]
      {"FQDD" => fqdd, "PermanentMACAddress" => mac, "CurrentMACAddress" => mac, "LinkSpeed" => "5"}
    end

    ASM::WsMan.stubs(:get_nic_view).returns(nic_views)
    ASM::WsMan.stubs(:get_bios_enumeration).returns([])

    @network_config_ng_hash = {
        "resources" => {
            "network::bond::static" => {
                "bond0" => {
                    "ensure" => "up", "bonding_opts" => "miimon=100 mode=802.3ad xmit_hash_policy=layer2+3", "mtu" => 9000
                }, "bond1" => {
                    "ensure" => "up", "bonding_opts" => "miimon=100 mode=802.3ad xmit_hash_policy=layer2+3", "mtu" => 9000
                }
            }, "network::bond::vlan" => {
                "bond0" => {
                    "ensure" => "up", "ipaddress" => "172.20.11.100", "netmask" => "255.255.0.0", "gateway" => "172.20.0.1", "vlanId" => 20, "bonding_opts" => "miimon=100 mode=802.3ad xmit_hash_policy=layer2+3", "mtu" => 9000
                }, "bond1" => {
                    "ensure" => "up", "ipaddress" => "172.22.11.100", "netmask" => "255.255.0.0", "gateway" => "172.22.0.1", "vlanId" => 22, "bonding_opts" => "miimon=100 mode=802.3ad xmit_hash_policy=layer2+3", "mtu" => 9000
                }
            }, "network::bond::slave" => {
                "00:0A:F7:38:94:F0" => {
                    "macaddress" => "00:0A:F7:38:94:F0", "master" => "bond0"
                }, "00:0A:F7:38:94:F2" => {
                    "macaddress" => "00:0A:F7:38:94:F2", "master" => "bond0"
                }, "00:0A:F7:38:94:F4" => {
                    "macaddress" => "00:0A:F7:38:94:F4", "master" => "bond1"
                }, "00:0A:F7:38:94:F6" => {
                    "macaddress" => "00:0A:F7:38:94:F6", "master" => "bond1"
                }
            }, "host" => {
                "dellasm" => {
                    "ensure" => "present", "ip" => appliance_ip
                }
            }
        }
    }

    @network_config_dg_hash0 = {
        "classes" => {
            "network::global" => {
                "gateway" => "172.22.0.1", "gatewaydev" => "bond1.22"
            }
        },
        "resources" => {
            "network::bond::vlan" => {
                "bond0" => {
                    "ensure" => "up", "bonding_opts" => "miimon=100 mode=802.3ad xmit_hash_policy=layer2+3", "mtu" => 9000, "ipaddress" => "172.20.11.100", "netmask" => "255.255.0.0", "gateway" => "172.20.0.1", "vlanId" => 20
                },
                "bond1" => {
                    "ensure" => "up", "bonding_opts" => "miimon=100 mode=802.3ad xmit_hash_policy=layer2+3", "mtu" => 9000, "ipaddress" => "172.22.11.100", "netmask" => "255.255.0.0", "gateway" => "172.22.0.1", "vlanId" => 22
                }
            },
            "network::bond::static" => {
                "bond0" => {
                    "ensure" => "up", "bonding_opts" => "miimon=100 mode=802.3ad xmit_hash_policy=layer2+3", "mtu" => 9000
                }, "bond1" => {
                    "ensure" => "up", "bonding_opts" => "miimon=100 mode=802.3ad xmit_hash_policy=layer2+3", "mtu" => 9000
                }
            },
            "network::bond::slave" => {
                "00:0A:F7:38:94:F0" => {
                    "macaddress" => "00:0A:F7:38:94:F0", "master" => "bond0"
                },
                "00:0A:F7:38:94:F2" => {
                    "macaddress" => "00:0A:F7:38:94:F2", "master" => "bond0"
                },
                "00:0A:F7:38:94:F4" => {
                    "macaddress" => "00:0A:F7:38:94:F4", "master" => "bond1"
                },
                "00:0A:F7:38:94:F6" => {
                    "macaddress" => "00:0A:F7:38:94:F6", "master" => "bond1"
                }
            },
            "host" => {
                "dellasm" => {
                    "ensure" => "present", "ip" => appliance_ip
                }
            }
        }
    }

    @network_config_dg_hash1 = {
        "classes" => {
            "network::global" => {
                "gateway" => "172.20.0.1", "gatewaydev" => "bond0.20"
            }
        },
        "resources" => {
            "network::bond::vlan" => {
                "bond0" => {
                    "ensure" => "up", "bonding_opts" => "miimon=100 mode=802.3ad xmit_hash_policy=layer2+3", "mtu" => 9000, "ipaddress" => "172.20.11.100", "netmask" => "255.255.0.0", "gateway" => "172.20.0.1", "vlanId" => 20
                },
                "bond1" => {
                    "ensure" => "up", "bonding_opts" => "miimon=100 mode=802.3ad xmit_hash_policy=layer2+3", "mtu" => 9000, "ipaddress" => "172.22.11.100", "netmask" => "255.255.0.0", "gateway" => "172.22.0.1", "vlanId" => 22
                }
            },
            "network::bond::static" => {
                "bond0" => {
                    "ensure" => "up", "bonding_opts" => "miimon=100 mode=802.3ad xmit_hash_policy=layer2+3", "mtu" => 9000
                }, "bond1" => {
                    "ensure" => "up", "bonding_opts" => "miimon=100 mode=802.3ad xmit_hash_policy=layer2+3", "mtu" => 9000
                }
            },
            "network::bond::slave" => {
                "00:0A:F7:38:94:F0" => {
                    "macaddress" => "00:0A:F7:38:94:F0", "master" => "bond0"
                },
                "00:0A:F7:38:94:F2" => {
                    "macaddress" => "00:0A:F7:38:94:F2", "master" => "bond0"
                },
                "00:0A:F7:38:94:F4" => {
                    "macaddress" => "00:0A:F7:38:94:F4", "master" => "bond1"
                },
                "00:0A:F7:38:94:F6" => {
                    "macaddress" => "00:0A:F7:38:94:F6", "master" => "bond1"
                }
            },
            "host" => {
                "dellasm" => {
                    "ensure" => "present", "ip" => appliance_ip
                }
            }
        }
    }

    @network_config_on_nv_hash = {"resources" => {"network::if::static" => {"00:0A:F7:38:94:F0" => {"ensure" => "up", "ipaddress" => "172.20.11.100", "netmask" => "255.255.0.0", "gateway" => "172.20.0.1", "macaddress" => "00:0A:F7:38:94:F0", "domain" => "aidev.com"}}, "host" => {"dellasm" => {"ensure" => "present", "ip" => appliance_ip}}}}
    @network_config_ng_nv_hash = {
        "resources" => {
            "network::bond::static" => {
                "bond0" => {
                    "ensure" => "up", "bonding_opts" => "miimon=100 mode=802.3ad xmit_hash_policy=layer2+3", "mtu" => 9000, "ipaddress" => "172.20.11.100", "netmask" => "255.255.0.0", "gateway" => "172.20.0.1"
                },
                "bond1" => {
                    "ensure" => "up", "bonding_opts" => "miimon=100 mode=802.3ad xmit_hash_policy=layer2+3", "mtu" => 9000, "ipaddress" => "172.22.11.100", "netmask" => "255.255.0.0", "gateway" => "172.22.0.1"
                }
            },
            "network::bond::slave" => {
                "00:0A:F7:38:94:F0" => {
                    "macaddress" => "00:0A:F7:38:94:F0", "master" => "bond0"
                },
                "00:0A:F7:38:94:F2" => {
                    "macaddress" => "00:0A:F7:38:94:F2", "master" => "bond0"
                },
                "00:0A:F7:38:94:F4" => {
                    "macaddress" => "00:0A:F7:38:94:F4", "master" => "bond1"
                },
                "00:0A:F7:38:94:F6" => {
                    "macaddress" => "00:0A:F7:38:94:F6", "master" => "bond1"
                }
            },
            "host" => {
                "dellasm" => {
                    "ensure" => "present", "ip" => appliance_ip
                }
            }
        }
    }

    @network_config_ng_ob_nv_hash = {
        "resources" => {
            "network::if::static" => {
                "00:0A:F7:38:94:F0" => {
                    "ensure" => "up", "ipaddress" => "172.20.11.100", "netmask" => "255.255.0.0", "gateway" => "172.20.0.1", "macaddress" => "00:0A:F7:38:94:F0", "domain" => "aidev.com"
                }
            }, "network::bond::static" => {
                "bond0" => {
                    "ensure" => "up", "ipaddress" => "172.22.11.100", "netmask" => "255.255.0.0", "gateway" => "172.22.0.1", "bonding_opts" => "miimon=100 mode=802.3ad xmit_hash_policy=layer2+3", "mtu" => 9000
                }
            }, "network::bond::slave" => {
                "00:0A:F7:38:94:F4" => {
                    "macaddress" => "00:0A:F7:38:94:F4", "master" => "bond0"
                }, "00:0A:F7:38:94:F6" => {
                    "macaddress" => "00:0A:F7:38:94:F6", "master" => "bond0"
                }
            }, "host" => {
                "dellasm" => {
                    "ensure" => "present", "ip" => appliance_ip
                }
            }
        }
    }
    @network_config_on_hash = {"resources" => {"network::if::static" => {"00:0A:F7:38:94:F0" => {"ensure" => "up", "macaddress" => "00:0A:F7:38:94:F0", "domain" => "aidev.com"}}, "network::if::vlan" => {"00:0A:F7:38:94:F0" => {"ensure" => "up", "vlanId" => 20, "ipaddress" => "172.20.11.100", "netmask" => "255.255.0.0", "gateway" => "172.20.0.1", "domain" => "aidev.com"}}, "host" => {"dellasm" => {"ensure" => "present", "ip" => appliance_ip}}}}
    @network_config_ng_ob_hash = {
        "resources" => {
            "network::if::static" => {
                "00:0A:F7:38:94:F0" => {
                    "ensure" => "up", "macaddress" => "00:0A:F7:38:94:F0", "domain" => "aidev.com"
                }
            },
            "network::if::vlan" => {
                "00:0A:F7:38:94:F0" => {
                    "ensure" => "up", "vlanId" => 20, "ipaddress" => "172.20.11.100", "netmask" => "255.255.0.0", "gateway" => "172.20.0.1", "domain" => "aidev.com"
                }
            },
            "network::bond::vlan" => {
                "bond0" => {
                    "ensure" => "up", "bonding_opts" => "miimon=100 mode=802.3ad xmit_hash_policy=layer2+3", "mtu" => 9000, "ipaddress" => "172.22.11.100", "netmask" => "255.255.0.0", "gateway" => "172.22.0.1", "vlanId" => 22
                }
            },
            "network::bond::static" => {
                "bond0" => {
                    "ensure" => "up", "bonding_opts" => "miimon=100 mode=802.3ad xmit_hash_policy=layer2+3", "mtu" => 9000
                }
            },
            "network::bond::slave" => {
                "00:0A:F7:38:94:F4" => {
                    "macaddress" => "00:0A:F7:38:94:F4", "master" => "bond0"
                },
                "00:0A:F7:38:94:F6" => {
                    "macaddress" => "00:0A:F7:38:94:F6", "master" => "bond0"
                }
            },
            "host" => {
                "dellasm" => {
                    "ensure" => "present", "ip" => appliance_ip
                }
            }
        }
    }

    @network_config_ng_ob_hash_dhcp ={
        "resources" => {
            "network::if::static" => {
                "00:0A:F7:38:94:F0" => {
                    "ensure" => "up", "macaddress" => "00:0A:F7:38:94:F0"
                }
            },
            "network::if::vlan" => {
                "00:0A:F7:38:94:F0" => {
                    "ensure" => "up", "bootproto" => "dhcp", "vlanId" => 20
                }
            },
            "network::bond::static" => {
                "bond0" => {
                    "ensure" => "up", "bonding_opts" => "miimon=100 mode=802.3ad xmit_hash_policy=layer2+3", "mtu" => 9000
                }
            },
            "network::bond::vlan" => {
                "bond0" => {
                    "ensure" => "up", "bonding_opts" => "miimon=100 mode=802.3ad xmit_hash_policy=layer2+3", "mtu" => 9000, "bootproto" => "dhcp", "vlanId" => 22
                }
            },
            "network::bond::slave" => {
                "00:0A:F7:38:94:F4" => {
                    "macaddress" => "00:0A:F7:38:94:F4", "master" => "bond0"
                },
                "00:0A:F7:38:94:F6" => {
                    "macaddress" => "00:0A:F7:38:94:F6", "master" => "bond0"
                }
            },
            "host" => {
                "dellasm" => {
                    "ensure" => "present", "ip" => appliance_ip
                }
            }
        }
    }


    @network_config_vlan_untagged_dhcp = {"resources" => {"network::if::dynamic" => {"00:0A:F7:38:94:F0" => {"ensure" => "up", "macaddress" => "00:0A:F7:38:94:F0"}}, "host" => {"dellasm" => {"ensure" => "present", "ip" => appliance_ip}}}}

    @network_config_vlan_tagged_dhcp = {"resources" => {"network::if::static" => {"00:0A:F7:38:94:F0" => {"ensure" => "up", "macaddress" => "00:0A:F7:38:94:F0"}}, "network::if::vlan" => {"00:0A:F7:38:94:F0" => {"ensure" => "up", "bootproto" => "dhcp", "vlanId" => 20}}, "host" => {"dellasm" => {"ensure" => "present", "ip" => appliance_ip}}}}

    @teams_one_static_NIC = [
        {
            :networks => [
                {
                    :description => "",
                    :id => "ff80808150b4e04d0150b4f1394800a4",
                    :name => "Work Static",
                    :static => true,
                    :staticNetworkConfiguration => {
                        :dnsSuffix => "aidev.com",
                        :gateway => "172.20.0.1",
                        :ipAddress => "172.20.11.100",
                        :primaryDns => "172.20.0.8",
                        :secondaryDns => nil,
                        :subnet => "255.255.0.0"
                    },
                    :type => "PRIVATE_LAN",
                    :vlanId => 20
                }
            ],
            :mac_addresses => ["00:0A:F7:38:94:F0"]
        }
    ]

    @teams_two_static_NIC_two_bonds = [
        {
            :networks => [
                {
                    :description => "",
                    :id => "ff80808150b4e04d0150b4f1394800a4",
                    :name => "Work Static",
                    :static => true,
                    :staticNetworkConfiguration => {
                        :dnsSuffix => "aidev.com",
                        :gateway => "172.20.0.1",
                        :ipAddress => "172.20.11.100",
                        :primaryDns => "172.20.0.8",
                        :secondaryDns => nil,
                        :subnet => "255.255.0.0"
                    },
                    :type => "PRIVATE_LAN",
                    :vlanId => 20
                }
            ],
            :mac_addresses => ["00:0A:F7:38:94:F0", "00:0A:F7:38:94:F2"]
        },
        {
            :networks => [
                {
                    :description => "",
                    :id => "ff80808150b4e04d0150b4ef67800089",
                    :name => "Public Static",
                    :static => true,
                    :staticNetworkConfiguration => {
                        :dnsSuffix => "aidev.com",
                        :gateway => "172.22.0.1",
                        :ipAddress => "172.22.11.100",
                        :primaryDns => "172.20.0.8",
                        :secondaryDns => nil,
                        :subnet => "255.255.0.0"
                    },
                    :type => "PUBLIC_LAN",
                    :vlanId => 22
                }
            ],
            :mac_addresses => ["00:0A:F7:38:94:F4", "00:0A:F7:38:94:F6"]
        }
    ]

    @teams_two_static_NIC_one_bond = [
        {
            :networks => [
                {
                    :description => "",
                    :id => "ff80808150b4e04d0150b4f1394800a4",
                    :name => "Work Static",
                    :static => true,
                    :staticNetworkConfiguration => {
                        :dnsSuffix => "aidev.com",
                        :gateway => "172.20.0.1",
                        :ipAddress => "172.20.11.100",
                        :primaryDns => "172.20.0.8",
                        :secondaryDns => nil,
                        :subnet => "255.255.0.0"
                    },
                    :type => "PRIVATE_LAN",
                    :vlanId => 20
                }
            ],
            :mac_addresses => ["00:0A:F7:38:94:F0"]
        },
        {
            :networks => [
                {
                    :description => "",
                    :id => "ff80808150b4e04d0150b4ef67800089",
                    :name => "Public Static",
                    :static => true,
                    :staticNetworkConfiguration => {
                        :dnsSuffix => "aidev.com",
                        :gateway => "172.22.0.1",
                        :ipAddress => "172.22.11.100",
                        :primaryDns => "172.20.0.8",
                        :secondaryDns => nil,
                        :subnet => "255.255.0.0"
                    },
                    :type => "PUBLIC_LAN",
                    :vlanId => 22
                }
            ],
            :mac_addresses => ["00:0A:F7:38:94:F4", "00:0A:F7:38:94:F6"]
        }
    ]

    @teams_one_dhcp_NIC = [
        {
            :networks => [
                {
                    :description => "",
                    :id => "ff80808150b4e04d0150b4f1394800a4",
                    :name => "Work DHCP",
                    :static => false,
                    :type => "PRIVATE_LAN",
                    :vlanId => 20
                }
            ],
            :mac_addresses => ["00:0A:F7:38:94:F0"]
        }
    ]

    @teams_two_dhcp_NIC_one_bond = [
        {
            :networks => [
                {
                    :description => "",
                    :id => "ff80808150b4e04d0150b4f1394800a4",
                    :name => "Work DHCP",
                    :static => false,
                    :type => "PRIVATE_LAN",
                    :vlanId => 20
                }
            ],
            :mac_addresses => ["00:0A:F7:38:94:F0"]
        },
        {
            :networks => [
                {
                    :description => "",
                    :id => "ff80808150b4e04d0150b4ef67800089",
                    :name => "Public DHCP",
                    :static => false,
                    :type => "PUBLIC_LAN",
                    :vlanId => 22
                }
            ],
            :mac_addresses => ["00:0A:F7:38:94:F4", "00:0A:F7:38:94:F6"]
        }
    ]
  end

  after do
    ASM.reset
  end

  describe "should configure linux static network for the post installation process" do
    it "post_os_classes return empty hash" do
      expect(@linux_processor.post_os_classes).to eql({})
    end

    it "post_os_resources return empty hash" do
      expect(@linux_processor.post_os_resources).to eql({})
    end

    it "no static NIC specified" do
      @linux_processor.stubs(:teams).returns([])
      expect(@linux_processor.process_network_config(nil)).to eql({})
    end

    it "no static NIC specified but default gateway is set" do
      @linux_processor.stubs(:teams).returns([])
      expect(@linux_processor.process_network_config("ff80808150b4e04d0150b4ef67800089")).to eql({})
    end

    it "default gateway config hash without default gateway set" do
      @linux_processor.stubs(:default_gateway_network).returns(nil)
      expect(@linux_processor.default_gateway_config(@linux_processor.default_gateway_network)).to eql({})
    end

    it "default gateway config hash with a default gateway set" do
      @linux_processor.stubs(:default_gateway_network).returns
      expect(@linux_processor.default_gateway_config(@linux_processor.default_gateway_network)).to eql({})
    end

    it "process network config - no default gateway" do
      @linux_processor.stubs(:default_gateway_network).returns(nil)
      @linux_processor.stubs(:host_ip_config).returns(appliance_ip)
      expect(@linux_processor.process_network_config(nil)).to eql(@network_config_ng_hash)
    end

    it "process network config - default gateway is vlan 22" do
      @linux_processor.stubs(:default_gateway_network).returns("ff80808150b4e04d0150b4ef67800089")
      @linux_processor.stubs(:host_ip_config).returns(appliance_ip)
      expect(@linux_processor.post_os_config).to eql(@network_config_dg_hash0)
    end

    it "process network config - default gateway is vlan 20" do
      @linux_processor.stubs(:default_gateway_network).returns("ff80808150b4e04d0150b4f1394800a4")
      @linux_processor.stubs(:host_ip_config).returns(appliance_ip)
      expect(@linux_processor.post_os_config).to eql(@network_config_dg_hash1)
    end

    it "process network config with one static NIC" do
      @linux_processor.stubs(:teams).returns(@teams_one_static_NIC)
      @sd.stubs(:bm_tagged?).returns(false)
      @linux_processor.stubs(:host_ip_config).returns(appliance_ip)
      expect(@linux_processor.process_network_config(nil)).to eql(@network_config_on_nv_hash)
    end

    it "process network config with two static NICs where both are bonded" do
      @linux_processor.stubs(:teams).returns(@teams_two_static_NIC_two_bonds)
      @sd.stubs(:bm_tagged?).returns(false)
      @linux_processor.stubs(:host_ip_config).returns(appliance_ip)
      expect(@linux_processor.process_network_config(nil)).to eql(@network_config_ng_nv_hash)
    end

    it "process network config with two static NICs where one is bonded" do
      @linux_processor.stubs(:teams).returns(@teams_two_static_NIC_one_bond)
      @sd.stubs(:bm_tagged?).returns(false)
      @linux_processor.stubs(:host_ip_config).returns(appliance_ip)
      expect(@linux_processor.process_network_config(nil)).to eql(@network_config_ng_ob_nv_hash)
    end

    it "process network config with one static NIC - vlan tagged" do
      @linux_processor.stubs(:teams).returns(@teams_one_static_NIC)
      @sd.stubs(:bm_tagged?).returns(true)
      @linux_processor.stubs(:host_ip_config).returns(appliance_ip)
      expect(@linux_processor.process_network_config(nil)).to eql(@network_config_on_hash)
    end

    it "process network config with two static NICs where both are bonded - vlan tagged" do
      @linux_processor.stubs(:teams).returns(@teams_two_static_NIC_two_bonds)
      @sd.stubs(:bm_tagged?).returns(true)
      @linux_processor.stubs(:host_ip_config).returns(appliance_ip)
      expect(@linux_processor.process_network_config(nil)).to eql(@network_config_ng_hash)
    end

    it "process network config with two static NICs where one is bonded - vlan tagged" do
      @linux_processor.stubs(:teams).returns(@teams_two_static_NIC_one_bond)
      @sd.stubs(:bm_tagged?).returns(true)
      @linux_processor.stubs(:host_ip_config).returns(appliance_ip)
      expect(@linux_processor.process_network_config(nil)).to eql(@network_config_ng_ob_hash)
    end
  end

  describe "should configure linux dhcp network for the post installation process" do
    it "process network config with one dhcp NIC - vlan untagged" do
      @linux_processor.stubs(:teams).returns(@teams_one_dhcp_NIC)
      @sd.stubs(:bm_tagged?).returns(false)
      @linux_processor.stubs(:host_ip_config).returns(appliance_ip)
      expect(@linux_processor.process_network_config(nil)).to eql(@network_config_vlan_untagged_dhcp)
    end

    it "process network config with one dhcp NIC - vlan tagged" do
      @linux_processor.stubs(:teams).returns(@teams_one_dhcp_NIC)
      @sd.stubs(:bm_tagged?).returns(true)
      @linux_processor.stubs(:host_ip_config).returns(appliance_ip)
      expect(@linux_processor.process_network_config(nil)).to eql(@network_config_vlan_tagged_dhcp)
    end

    it "process network config with two dhcp NICs where one is bonded - vlan tagged" do
      @linux_processor.stubs(:teams).returns(@teams_two_dhcp_NIC_one_bond)
      @sd.stubs(:bm_tagged?).returns(true)
      @linux_processor.stubs(:host_ip_config).returns(appliance_ip)
      expect(@linux_processor.process_network_config(nil)).to eql(@network_config_ng_ob_hash_dhcp)
    end
  end

  describe "should configure linux network cleanup for the PXE" do
    it "process network config with one PXE NIC" do
      minimal_hash = [{"mac_address" => "00:0A:F7:38:94:F2", "networks" => ["ff80808152852a2f0152856c54500049"]}]
      minimal_hash[0].stubs(:networks).returns(minimal_hash[0]["networks"])
      @linux_processor.network_config.stubs(:get_partitions).with("PXE").returns(minimal_hash)
      expect(@linux_processor.network_config.get_partitions("PXE")).to eql(minimal_hash)
      expect(@linux_processor.pxe_nic_cleanup).to eql({"00:0A:F7:38:94:F2" => {"ensure" => "clean"}})
    end

    it "process network config with two PXE NICs" do
      minimal_hash = [{"mac_address" => "00:0A:F7:38:94:F2", "networks" => ["ff80808152852a2f0152856c54500049"]},
                      {"mac_address" => "00:0A:F7:38:94:F4", "networks" => ["ff80808152852a2f0152856c54500050"]}]
      minimal_hash[0].stubs(:networks).returns(minimal_hash[0]["networks"])
      minimal_hash[1].stubs(:networks).returns(minimal_hash[1]["networks"])
      @linux_processor.network_config.stubs(:get_partitions).with("PXE").returns(minimal_hash)
      expect(@linux_processor.network_config.get_partitions("PXE")).to eql(minimal_hash)
      expect(@linux_processor.pxe_nic_cleanup).to eql({"00:0A:F7:38:94:F2" => {"ensure" => "clean"}, "00:0A:F7:38:94:F4" => {"ensure" => "clean"}})
    end

    it "process network config with one PXE NIC that is on shared port/partition" do
      minimal_hash = [{"mac_address" => "00:0A:F7:38:94:F2", "networks" => ["ff80808152852a2f0152856c54500049", "ff80808152852a2f0152856c54500051"]}]
      minimal_hash[0].stubs(:networks).returns(minimal_hash[0]["networks"])
      @linux_processor.network_config.stubs(:get_partitions).with("PXE").returns(minimal_hash)
      expect(@linux_processor.network_config.get_partitions("PXE")).to eql(minimal_hash)
      expect(@linux_processor.pxe_nic_cleanup).to eql({})
    end
  end

  describe "should check OS and return appropriate network config options" do
    it "returns bonding opts" do
      expect(@linux_processor.bonding_opts).to eql("miimon=100 mode=802.3ad xmit_hash_policy=layer2+3")
    end
  end

  describe "should check OS family" do
    it "returns the OS value" do
      expect(@linux_processor.os).to eql("redhat")
    end

    it "determines if suse10 version is supported" do
      expect(@linux_processor.supported_suse?("suse10")).to eql(false)
    end

    it "determines if suse11 version is supported" do
      expect(@linux_processor.supported_suse?("suse11")).to eql(true)
    end

    it "determines if suse12 version is supported" do
      expect(@linux_processor.supported_suse?("suse12")).to eql(true)
    end
  end
end
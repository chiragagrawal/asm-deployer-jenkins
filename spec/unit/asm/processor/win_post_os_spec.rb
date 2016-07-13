require 'spec_helper'
require 'asm/processor/server'
require 'asm/processor/win_post_os'
require 'asm/device_management'
require 'asm/service'

describe ASM::Processor::WinPostOS do
  let(:puppetdb) { stub(:successful_report_after? => true) }

  before do
    ASM.init_for_tests
    @service_deployment = SpecHelper.json_fixture("processor/win_post_os/win_post_os.json")
    @sd = mock("service_deployment")

    @tmp_dir = Dir.mktmpdir
    ASM.stubs(:base_dir).returns(@tmp_dir)
    ASM::PrivateUtil.stubs(:fetch_server_inventory).returns({ 'refId' => 'id', 'model' => 'M620', 'serverType' => 'blade' })

    @deployment_db = mock('deploymentdb')
    @deployment_db.stub_everything
    @sd = ASM::ServiceDeployment.new('8000', @deployment_db)
    ASM::Cipher.stubs(:decrypt_string).returns('P@ssw0rd')

    @sd.components(@service_deployment)
    @server_component = @sd.components_by_type('SERVER')[0]
    @win_processor = ASM::Processor::WinPostOS.new(@sd, @server_component)
    @win_processor.stubs(:domain_password_token).returns('ASMTOKEN-223865659684068544219109134550755673546')
    @fqdd_to_mac = {'NIC.Integrated.1-1-1' => 'E0:DB:55:21:27:8C',
                    'NIC.Integrated.1-1-2' => 'E0:DB:55:21:27:90',
                    'NIC.Integrated.1-1-3' => 'E0:DB:55:21:27:94',
                    'NIC.Integrated.1-1-4' => 'E0:DB:55:21:27:98',
                    'NIC.Integrated.1-2-1' => 'E0:DB:55:21:27:8E',
                    'NIC.Integrated.1-2-2' => 'E0:DB:55:21:27:92',
                    'NIC.Integrated.1-2-3' => 'E0:DB:55:21:27:96',
                    'NIC.Integrated.1-2-4' => 'E0:DB:55:21:27:9A', }
    nic_views = @fqdd_to_mac.keys.map do |fqdd|
      mac = @fqdd_to_mac[fqdd]
      {"FQDD" => fqdd, "PermanentMACAddress" => mac, "CurrentMACAddress" => mac,
       "VendorName" => "Broadcom", "ProductName" => "57810"}
    end
    ASM::WsMan.stubs(:get_nic_view).returns(nic_views)
    ASM::WsMan.stubs(:get_bios_enumeration).returns([])

    @domain_hash = {"windows_postinstall::domain::domain_config"=>
                        {"domainfqdd"=>"Aidev.com",
                         "domainname"=>"Aidev",
                         "username"=>"SushilR",
                         "password"=>"ASMTOKEN-223865659684068544219109134550755673546"}}

    @nic_team_hash = {"windows_postinstall::nic::nic_team"=>
                          {"nic_team_info"=>
                               {"TeamInfo"=>
                                    [{"TeamName"=>"Workload-25-static",
                                      "TeamMembers"=>@fqdd_to_mac.values.join(',')}]}}}

    @domain_nic_team_hash = {"windows_postinstall::nic::nic_team"=>
                                 {"nic_team_info"=>
                                      {"TeamInfo"=>
                                           [{"TeamName"=>"Workload-25-static",
                                             "TeamMembers"=>@fqdd_to_mac.values.join(',')}]}},
                             "windows_postinstall::domain::domain_config"=>
                                 {"domainfqdd"=>"Aidev.com",
                                  "domainname"=>"Aidev",
                                  "username"=>"SushilR",
                                  "password"=>"ASMTOKEN-223865659684068544219109134550755673546",
                                  "require"=>["Class[Windows_postinstall::Nic::Nic_team]"]}}

    @nic_ip_config_hash = {"windows_postinstall::nic::nic_team"=>
                               {"nic_team_info"=>
                                    {"TeamInfo"=>
                                         [{"TeamName"=>"Workload-25-static",
                                           "TeamMembers"=>@fqdd_to_mac.values.join(',')}]}},
                           "windows_postinstall::nic::nic_ip_settings"=>
                               {"ipaddress_info"=>
                                    {"NICIPInfo"=>
                                         [{"adapter_name"=>"Workload-25-static",
                                           "ip_address"=>"172.25.10.60",
                                           "subnet"=>"255.255.0.0",
                                           "gateway"=>"172.25.0.1",
                                           "primaryDns"=>"172.28.0.8",
                                           "vlan_id"=>25}]},
                                "require"=>["Class[Windows_postinstall::Nic::Nic_team]"]},
                           "windows_postinstall::domain::domain_config"=>
                               {"domainfqdd"=>"Aidev.com",
                                "domainname"=>"Aidev",
                                "username"=>"SushilR",
                                "password"=>"ASMTOKEN-223865659684068544219109134550755673546",
                                "require"=>["Class[Windows_postinstall::Nic::Nic_team]",
                                            "Class[Windows_postinstall::Nic::Nic_ip_settings]"]}}

    @single_network_matcher_hash =  {"windows_postinstall::nic::nic_team"=>
                                         {"nic_team_info"=>
                                              {"TeamInfo"=>
                                                   [{"TeamName"=>"network1",
                                                     "TeamMembers"=>@fqdd_to_mac.values.join(',')}]}},
                                     "windows_postinstall::nic::nic_ip_settings"=>
                                         {"ipaddress_info"=>
                                              {"NICIPInfo"=>
                                                   [{"adapter_name"=>"network1",
                                                     "ip_address"=>"dhcp",
                                                     "subnet"=>"",
                                                     "gateway"=>"",
                                                     "primaryDns"=>"" }]},
                                          "require"=>["Class[Windows_postinstall::Nic::Nic_team]"]}}

    @double_network_match_hash = {"windows_postinstall::nic::nic_team"=>
                                      {"nic_team_info"=>
                                           {"TeamInfo"=>
                                                [
                                                    {"TeamName"=>"network1", "TeamMembers"=>@fqdd_to_mac.values[0..3].join(',')},
                                                    {"TeamName"=>"network2", "TeamMembers"=>@fqdd_to_mac.values[4..7].join(',')}]}},
                                  "windows_postinstall::nic::nic_ip_settings"=>
                                      {"ipaddress_info"=>
                                           {"NICIPInfo"=>
                                                [{"adapter_name"=>"network1",
                                                  "ip_address"=>"dhcp",
                                                  "subnet"=>"",
                                                  "gateway"=>"",
                                                  "primaryDns"=>"",
                                                  "vlan_id"=>"25"},
                                                 {"adapter_name"=>"network2",
                                                  "ip_address"=>"dhcp",
                                                  "subnet"=>"",
                                                  "gateway"=>"",
                                                  "primaryDns"=>"",
                                                  "vlan_id"=>"3"}]},
                                       "require"=>["Class[Windows_postinstall::Nic::Nic_team]"]}}

    @double_static_network_match_hash = {"windows_postinstall::nic::nic_team"=>
                                      {"nic_team_info"=>
                                           {"TeamInfo"=>
                                                [
                                                    {"TeamName"=>"network1", "TeamMembers"=>@fqdd_to_mac.values[0..3].join(',')},
                                                    {"TeamName"=>"network2", "TeamMembers"=>@fqdd_to_mac.values[4..7].join(',')}]}},
                                  "windows_postinstall::nic::nic_ip_settings"=>
                                      {"ipaddress_info"=>
                                           {"NICIPInfo"=>
                                                [{"adapter_name"=>"network1",
                                                  "ip_address"=>"1.1.1.1",
                                                  "subnet"=>"255.255.0.0",
                                                  "primaryDns"=>"2.2.2.2",
                                                  "vlan_id"=>"2"},
                                                 {"adapter_name"=>"network2",
                                                  "ip_address"=>"1.1.1.2",
                                                  "subnet"=>"255.255.0.0",
                                                  "primaryDns"=>"2.2.2.2",
                                                  "vlan_id"=>"3"}]},
                                       "require"=>["Class[Windows_postinstall::Nic::Nic_team]"]}}

    @double_static_network_match_gateway_hash = {"windows_postinstall::nic::nic_team"=>
                                             {"nic_team_info"=>
                                                  {"TeamInfo"=>
                                                       [
                                                           {"TeamName"=>"network1", "TeamMembers"=>@fqdd_to_mac.values[0..3].join(',')},
                                                           {"TeamName"=>"network2", "TeamMembers"=>@fqdd_to_mac.values[4..7].join(',')}]}},
                                         "windows_postinstall::nic::nic_ip_settings"=>
                                             {"ipaddress_info"=>
                                                  {"NICIPInfo"=>
                                                       [{"adapter_name"=>"network1",
                                                         "ip_address"=>"1.1.1.1",
                                                         "subnet"=>"255.255.0.0",
                                                         "primaryDns"=>"2.2.2.2",
                                                         "vlan_id"=>"2",
                                                         "gateway" => "1.1.1.1"},
                                                        {"adapter_name"=>"network2",
                                                         "ip_address"=>"1.1.1.2",
                                                         "subnet"=>"255.255.0.0",
                                                         "primaryDns"=>"2.2.2.2",
                                                         "vlan_id"=>"3"}]},
                                              "require"=>["Class[Windows_postinstall::Nic::Nic_team]"]}}

    @network_adapter_nic_hash = {"windows_postinstall::nic::adapter_nic_ip_settings"=>
                                     {"ipaddress_info"=>
                                          {"NICIPInfo"=>
                                               [{"adapter_name"=>"network1",
                                                 "ip_address"=>"1.1.1.1",
                                                 "subnet"=>"255.255.0.0",
                                                 "primaryDns"=>"2.2.2.2",
                                                 "vlan_id"=>"2",
                                                 "mac_address"=>"E0-DB-55-21-27-8C",
                                                 "gateway"=>"1.1.1.1"},
                                                {"adapter_name"=>"network2",
                                                 "ip_address"=>"1.1.1.2",
                                                 "subnet"=>"255.255.0.0",
                                                 "primaryDns"=>"2.2.2.2",
                                                 "vlan_id"=>"3",
                                                 "mac_address"=>"E0-DB-55-21-27-8E"}]}}}

    @network_adapter_nic_hash_2008 = {"windows_postinstall::nic::adapter_nic_ip_settings"=>
                                          {"ipaddress_info"=>
                                               {"NICIPInfo"=>"network1,1.1.1.1,255.255.0.0,1.1.1.1,2.2.2.2,E0-DB-55-21-27-8C,2;network2,1.1.1.2,255.255.0.0,,2.2.2.2,E0-DB-55-21-27-8E,3"}}}

  end

  after do
    ASM.reset
  end

  describe 'should configure windows post installation' do

    it 'should create domain config if domain name is provided' do
      @win_processor.stubs(:nic_team_config).returns({})
      @win_processor.stubs(:nic_ip_config).returns({})

      expect(@win_processor.post_os_classes).to eql(@domain_hash)
    end

    it 'should skip domain config if domain name is not provided' do
      @win_processor.stubs(:asm_server).returns({})
      @win_processor.stubs(:nic_team_config).returns({})
      @win_processor.stubs(:nic_ip_config).returns({})
      expect(@win_processor.post_os_classes).to eql({})
    end

    it 'should should create network config hash' do
      @win_processor.stubs(:domain_config).returns({})
      @win_processor.stubs(:nic_ip_config).returns({})
      @win_processor.stubs(:nic_ip_config).returns({})
      ASM::WsMan.stubs(:get_mac_addresses).returns(@fqdd_to_mac)
      expect(@win_processor.post_os_classes).to eql(@nic_team_hash)
    end

    it 'should should create network config with domain hash' do
      ASM::WsMan.stubs(:get_mac_addresses).returns(@fqdd_to_mac)
      @win_processor.stubs(:nic_ip_config).returns({})
      @win_processor.stubs(:nic_ip_config).returns({})
      expect(@win_processor.post_os_classes).to eql(@domain_nic_team_hash)
    end

    it 'should should create network IP config with team and domain hash' do
      ASM::WsMan.stubs(:get_mac_addresses).returns(@fqdd_to_mac)
      expect(@win_processor.post_os_classes).to eql(@nic_ip_config_hash)
    end

    it 'should return nic team info when single network is associated with multiple interface / partitions' do
      @win_processor.stubs(:asm_server).returns({'os_image_version' => 'windows2012r2datacenter'})
      network1 = Hashie::Mash.new(:name => 'network1', :vlanId => '2')
      workload_networks = {[network1] => @fqdd_to_mac.values}
      @win_processor.stubs(:workload_networks).returns(workload_networks)
      @sd.stubs(:workload_with_pxe?).returns(false)
      expect(@win_processor.post_os_classes).to eql(@single_network_matcher_hash)
    end

    it 'should return multiple nic team info when multiple networks are associated with interface / partitions' do
      @win_processor.stubs(:asm_server).returns({})
      network1 = Hashie::Mash.new(:name => 'network1', :vlanId => '25', :type => 'PUBLIC_LAN')
      network2 = Hashie::Mash.new(:name => 'network2', :vlanId => '3', :type => 'PUBLIC_LAN')
      @sd.stubs(:bm_tagged?).returns(true)
      workload_networks = {[network1] => @fqdd_to_mac.values[0..3],
                           [network2] => @fqdd_to_mac.values[4..7]}
      @win_processor.stubs(:workload_networks).returns(workload_networks)
      expect(@win_processor.post_os_classes).to eql(@double_network_match_hash)
    end

    it 'should return multiple nic team info when multiple networks (static) are associated with interface / partitions' do
      @win_processor.stubs(:asm_server).returns({})
      static_ip_config1 = Hashie::Mash.new(:ipAddress => '1.1.1.1',
                                         :subnet => '255.255.0.0',
                                         :gateway => '1.1.1.1',
                                         :primaryDns => '2.2.2.2',
      )
      static_ip_config2 = Hashie::Mash.new(:ipAddress => '1.1.1.2',
                                           :subnet => '255.255.0.0',
                                           :gateway => '1.1.1.1',
                                           :primaryDns => '2.2.2.2',
      )
      network1 = Hashie::Mash.new(:name => 'network1', :vlanId => '2', :static => true , :staticNetworkConfiguration => static_ip_config1)
      network2 = Hashie::Mash.new(:name => 'network2', :vlanId => '3', :static => true , :staticNetworkConfiguration => static_ip_config2)
      @sd.stubs(:bm_tagged?).returns(true)
      workload_networks = {[network1] => @fqdd_to_mac.values[0..3],
                           [network2] => @fqdd_to_mac.values[4..7]}
      @win_processor.stubs(:workload_networks).returns(workload_networks)
      expect(@win_processor.post_os_classes).to eql(@double_static_network_match_hash)
    end

    it 'should return multiple nic team info when multiple networks (static) are associated with interface / partitions with gateway selected' do
      @win_processor.stubs(:asm_server).returns({})
      static_ip_config1 = Hashie::Mash.new(:ipAddress => '1.1.1.1',
                                           :subnet => '255.255.0.0',
                                           :gateway => '1.1.1.1',
                                           :primaryDns => '2.2.2.2',
      )
      static_ip_config2 = Hashie::Mash.new(:ipAddress => '1.1.1.2',
                                           :subnet => '255.255.0.0',
                                           :gateway => '1.1.1.1',
                                           :primaryDns => '2.2.2.2',
      )
      network1 = Hashie::Mash.new(:id => 'id1', :name => 'network1', :vlanId => '2', :static => true , :staticNetworkConfiguration => static_ip_config1)
      network2 = Hashie::Mash.new(:id => 'id2', :name => 'network2', :vlanId => '3', :static => true , :staticNetworkConfiguration => static_ip_config2)
      workload_networks = {[network1] => @fqdd_to_mac.values[0..3],
                           [network2] => @fqdd_to_mac.values[4..7]}
      @win_processor.stubs(:workload_networks).returns(workload_networks)
      @win_processor.stubs(:default_gateway_network).returns('id1')
      @sd.stubs(:bm_tagged?).returns(true)
      expect(@win_processor.post_os_classes).to eql(@double_static_network_match_gateway_hash)
    end

    it 'should not return nic team info when single network is selected on a NIC (Physical / NPAR)' do
      @win_processor.stubs(:asm_server).returns({})
      static_ip_config1 = Hashie::Mash.new(:ipAddress => '1.1.1.1',
                                           :subnet => '255.255.0.0',
                                           :gateway => '1.1.1.1',
                                           :primaryDns => '2.2.2.2',
      )
      static_ip_config2 = Hashie::Mash.new(:ipAddress => '1.1.1.2',
                                           :subnet => '255.255.0.0',
                                           :gateway => '1.1.1.1',
                                           :primaryDns => '2.2.2.2',
      )
      network1 = Hashie::Mash.new(:id => 'id1', :name => 'network1', :vlanId => '2', :static => true , :staticNetworkConfiguration => static_ip_config1)
      network2 = Hashie::Mash.new(:id => 'id2', :name => 'network2', :vlanId => '3', :static => true , :staticNetworkConfiguration => static_ip_config2)
      workload_networks = {[network1] => [@fqdd_to_mac.values[0]],
                           [network2] => [@fqdd_to_mac.values[4]]}
      @win_processor.stubs(:workload_networks).returns(workload_networks)
      @win_processor.stubs(:default_gateway_network).returns('id1')
      @sd.stubs(:bm_tagged?).returns(true)
      expect(@win_processor.post_os_classes).to eql(@network_adapter_nic_hash)
    end

    it 'should not return nic team info when single network is selected on a NIC (Physical / NPAR) with Windows 2008' do
      @win_processor.stubs(:asm_server).returns({'os_image_version' => 'windows2008r2datacenter'})
      static_ip_config1 = Hashie::Mash.new(:ipAddress => '1.1.1.1',
                                           :subnet => '255.255.0.0',
                                           :gateway => '1.1.1.1',
                                           :primaryDns => '2.2.2.2',
      )
      static_ip_config2 = Hashie::Mash.new(:ipAddress => '1.1.1.2',
                                           :subnet => '255.255.0.0',
                                           :gateway => '1.1.1.1',
                                           :primaryDns => '2.2.2.2',
      )
      network1 = Hashie::Mash.new(:id => 'id1', :name => 'network1', :vlanId => '2', :static => true , :staticNetworkConfiguration => static_ip_config1)
      network2 = Hashie::Mash.new(:id => 'id2', :name => 'network2', :vlanId => '3', :static => true , :staticNetworkConfiguration => static_ip_config2)
      workload_networks = {[network1] => [@fqdd_to_mac.values[0]],
                           [network2] => [@fqdd_to_mac.values[4]]}
      @win_processor.stubs(:workload_networks).returns(workload_networks)
      @win_processor.stubs(:default_gateway_network).returns('id1')
      @sd.stubs(:bm_tagged?).returns(true)
      expect(@win_processor.post_os_classes).to eql(@network_adapter_nic_hash_2008)
    end
  end

end


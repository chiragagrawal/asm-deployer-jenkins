require 'spec_helper'
require 'asm/processor/server'
require 'asm/device_management'

describe ASM::Processor::Server do

  before do
    @net_config = mock('network_configuration')
    @net_config.stubs(:get_network).with('HYPERVISOR_MANAGEMENT').returns(
        Hashie::Mash.new({:name => 'HypMan', :vlanId => 28, :static => true,
                          :staticNetworkConfiguration => {
                              :gateway => '172.28.0.1', :netmask => '255.255.0.0',
                              :ipAddress => '172.28.15.162', :primaryDns => '172.20.0.8',
                          }
                         }))
    @net_config.stubs(:get_network).with('HYPERVISOR_MIGRATION').returns(
        Hashie::Mash.new({:name => 'LiveMigration', :vlanId => 23, :static => true,
                          :staticNetworkConfiguration => {
                              :gateway => '172.23.0.1', :netmask => '255.255.0.0',
                              :ipAddress => '172.23.15.101',
                          }
                         }))
    @net_config.stubs(:get_network).with('HYPERVISOR_CLUSTER_PRIVATE').returns(
        Hashie::Mash.new({:name => 'ClusterPriCP', :vlanId => 24, :static => true,
                          :staticNetworkConfiguration => {
                              :gateway => '172.24.0.1', :netmask => '255.255.0.0',
                              :ipAddress => '172.24.15.204',
                          }
                         }))
    @net_config.stubs(:get_networks).with('STORAGE_ISCSI_SAN').returns(
            [Hashie::Mash.new({:name => 'iSCSI', :vlanId => 16, :static => true,
                              :staticNetworkConfiguration => {
                                  :gateway => '172.16.0.1', :netmask => '255.255.0.0',
                                  :ipAddress => '172.16.15.162',
                              }}),
             Hashie::Mash.new({:name => 'iSCSI', :vlanId => 16, :static => true,
              :staticNetworkConfiguration => {
                  :gateway => '172.16.0.1', :netmask => '255.255.0.0',
                  :ipAddress => '172.16.15.163',
              }}),])
    @net_config.stubs(:get_all_partitions).returns(
        [{"id"=>"A000CB24-077D-4E18-9564-251E085B07E3",
          "name"=>"1",
          "networks"=>
              ["ff8080814e57ef2a014e61e19dac0074",
               "ff8080814e53b590014e53be5110006f"],
          "networkObjects"=>
              [{"id"=>"ff8080814e57ef2a014e61e19dac0074",
                "name"=>"iSCSI1",
                "description"=>"",
                "type"=>"STORAGE_ISCSI_SAN",
                "vlanId"=>16,
                "static"=>true,
                "staticNetworkConfiguration"=>
                    {"gateway"=>"172.16.0.1", "subnet"=>"255.255.0.0", "primaryDns"=>nil, "secondaryDns"=>nil, "dnsSuffix"=>nil, "ipAddress"=>"172.16.3.61"}},
               {"id"=>"ff8080814e53b590014e53be5110006f",
                "name"=>"PXE",
                "description"=>"",
                "type"=>"PXE",
                "vlanId"=>20,
                "static"=>false,
                "staticNetworkConfiguration"=>nil}],
          "minimum"=>0,
          "maximum"=>100,
          "lanMacAddress"=>"00:0E:AA:DC:00:9C",
          "iscsiMacAddress"=>"00:0E:AA:DC:00:9A",
          "iscsiIQN"=>"iqn.asm:software-asm-01-0000000000:000000002D",
          "wwnn"=>nil,
          "wwpn"=>nil,
          "port_no"=>1,
          "partition_no"=>1,
          "partition_index"=>0,
          "fqdd"=>"NIC.Slot.2-1-1",
          "mac_address"=>"00:0A:F7:06:94:50"},
         {"id"=>"CD0A85C0-B21E-474B-9A9A-EC0AA462C38C",
          "name"=>"1",
          "networks"=>
               ["ff8080814e57ef2a014e61f627e9009b",
               "ff8080814e53b590014e53be5110006f"],
          "networkObjects"=>
               [{"id"=>"ff8080814e57ef2a014e61f627e9009b",
                "name"=>"iSCSI2",
                "description"=>"",
                "type"=>"STORAGE_ISCSI_SAN",
                "vlanId"=>16,
                "static"=>true,
                "staticNetworkConfiguration"=>
                    {"gateway"=>"172.16.0.1", "subnet"=>"255.255.0.0", "primaryDns"=>nil, "secondaryDns"=>nil, "dnsSuffix"=>nil, "ipAddress"=>"172.16.12.61"}},
               {"id"=>"ff8080814e53b590014e53be5110006f",
                "name"=>"PXE",
                "description"=>"",
                "type"=>"PXE",
                "vlanId"=>20,
                "static"=>false,
                "staticNetworkConfiguration"=>nil}],
          "minimum"=>0,
          "maximum"=>100,
          "lanMacAddress"=>"00:0E:AA:DC:00:9F",
          "iscsiMacAddress"=>"00:0E:AA:DC:00:9E",
          "iscsiIQN"=>"iqn.asm:software-asm-01-0000000000:000000002E",
          "wwnn"=>nil,
          "wwpn"=>nil,
          "port_no"=>2,
          "partition_no"=>1,
          "partition_index"=>1,
          "fqdd"=>"NIC.Slot.2-2-1",
          "mac_address"=>"00:0A:F7:06:94:52"}])

    ASM::DeviceManagement.stubs(:parse_device_config).returns(Hashie::Mash.new(:host => '127.0.0.1'))
    ASM::NetworkConfiguration.stubs(:new).returns(@net_config)
    @data = {
      'asm::server' => {'title' => {
        'product_key'           => 'PK',
        'timezone'              => 'Central',
        'language'              => 'en-us',
        'keyboard'              =>  'en-us',
        'razor_image'           => 'hyperV2',
        'os_host_name'          => 'foo.bar.baz',
        'os_image_type'         => 'foo',
        'installer_options' => {
            'domain_name'           => 'aidev',
            'fqdn'                  => 'aidev.com',
            'domain_admin_user'     => 'admin',
            'domain_admin_password' => 'pass',
            'ntp_server'            => 'pool.ntp.org',
        }
      }},
      'asm::idrac' => {'title' => {}},
      'asm::esxiscsiconfig' => {'title' => {
        'network_configuration' => 'foo',
    }}
    }
  end


  describe 'when munging resource data for hyperV' do
    it 'should do some stuff' do
      ASM::Util.stubs(:get_preferred_ip).returns('192.168.1.100')
      ASM::NetworkConfiguration.stubs(:get_all_partitions).returns([])
      ASM::PrivateUtil.stubs(:create_serverdata).returns(true)
      ASM::PrivateUtil.stubs(:domain_password_token).returns('ASMTOKEN-26573915-b03a-52a5-a1c1-5c04a7a4ef19')
      data = subject.munge_hyperv_server('title', @data, '127.0.0.1', [], nil, false)
      server_data = data['asm::server']['title']
      idrac_data  = data['asm::idrac']['title']
      # make sure that all old values were munged out of server params
      server_data.size.should == 8

      server_data['razor_image'].should    == 'hyperV2'
      idrac_data['enable_npar'].should == false
      
      class_data   = server_data['puppet_classification_data']['hyperv::config']
      class_data.should == {
        'domain_name'             => 'aidev',
        'fqdn'                    => 'aidev.com',
        'domain_admin_user'       => 'admin',
        'domain_admin_password'   => 'ASMTOKEN-26573915-b03a-52a5-a1c1-5c04a7a4ef19',
        'ntp'                     => 'pool.ntp.org',
        'iscsi_target_ip_address' => '127.0.0.1',
        'iscsi_volumes'           => [],
        'ASM::Processor::Server_gateway' => '172.24.0.1',
        'ASM::Processor::Server_ip_address' => '172.24.15.204',
        'ASM::Processor::Server_netmask' => '',
        'ASM::Processor::Server_vlan_id' => 24,
        'hyperv_diskpart' => false,
        'iscsi_fabric' => 'Fabric A',
        'iscsi_ip_addresses' => ['172.16.15.162', '172.16.15.163'],
        'iscsi_netmask' => nil,
        'iscsi_vlan_id' => 16,
        'appliance_hypervior_management_ip' => '192.168.1.100',
        'nic_team_member_macs' => nil,
        "iscsi_macs"=>"",
        'iscsi_networks' => "00:0A:F7:06:94:50,255.255.0.0,172.16.3.61,16;00:0A:F7:06:94:52,255.255.0.0,172.16.12.61,16"
      }
    end

  end

end

require 'asm/service_deployment'
require 'asm/processor/win_post_os'
require 'json'
require 'spec_helper'
require 'yaml'
require 'asm/private_util'
require 'asm/ipxe_builder'

describe ASM::ServiceDeployment do
  let(:puppetdb) { stub(:successful_report_after? => true) }
  let(:endpoint) { {:host => "172.17.5.170", :user => "rspec-user", :password => "rspec-password"} }

  before do
    ASM.init_for_tests
    @tmp_dir = Dir.mktmpdir
    @deployment_db = mock('deploymentdb')
    @deployment_db.stub_everything
    @deployment_db.stubs(:get_component_status).returns({:status => "complete"})
    @sd = ASM::ServiceDeployment.new('8000', @deployment_db)
    @razor = mock('razor')
    @razor.stubs(:find_node).returns({})
    @razor.stubs(:block_until_task_complete).returns({:status=>:boot_install, :timestamp=>Time.new("1969-01-01 00:00:00 -0600")})
    @sd.stubs(:razor).returns(@razor)
    @sd.stubs(:puppetdb).returns(puppetdb)
    @sd.stubs(:create_broker_if_needed).returns('STUB-BROKER-NAME')
    @sd.stubs(:get_server_inventory).returns({})
    @sd.stubs(:update_inventory_through_controller)
    @sd.stubs(:reboot_all_servers).returns(nil)
    @sd.stubs(:process_switches_via_types)
    @sd.stubs(:process_service_with_rules)
    @sd.stubs(:enable_razor_boot)
    @sd.stubs(:enable_pxe)
    @sd.stubs(:disable_pxe)
    ASM.stubs(:base_dir).returns(@tmp_dir)
    network = {
      'id' => '1', 'name' => 'Test Network', 'vlanId' => '28',
      'staticNetworkConfiguration' => {
        'gateway' => '172.28.0.1', 'subnet' => '255.255.0.0'
      }
    }
    ASM::PrivateUtil.stubs(:fetch_managed_inventory).returns([])
    mock_command_result = Hashie::Mash.new({
      'stdout' => '', 'stderr' => '', 'exit_status' => 0, 'pid' => 0
    })
    ASM::PrivateUtil.stubs(:write_deployment_json) do |json_file|
      File.open(json_file, "w") {|f| f.puts JSON.pretty_generate(data, :max_nesting=>25)}
    end
    ASM::Util.stubs(:run_command_simple).returns(mock_command_result)
    ASM::Util.stubs(:run_command_success).returns(mock_command_result)
  end

  after do
    ASM.reset
  end

  describe 'when data is valid' do
    before do
      FileUtils.mkdir_p("#{@tmp_dir}/8000/resources")
      @r_dir = "#{@tmp_dir}/8000/resources"
      @r_file = "#{@r_dir}/server-cert.yaml"
      @o_file = "#{@tmp_dir}/8000/server-cert.out"
      @json_file = "#{@tmp_dir}/8000/deployment.json"
      @summary_file = "#{@r_dir}/state/server-cert/last_run_summary.yaml"
      @data = {'serviceTemplate' => {'components' => [
        {'id' => 'id', 'puppetCertName' => 'server-cert', 'resources' => []}
      ]}}
    end

    it 'should fail if the puppet run failed but exited with 0' do
      File.open( "#{@tmp_dir}/8000/server-cert.out", 'w') do |fh|
        fh.write('Results: For 0 resources. 0 from our run failed. 0 not from our run failed. 0 updated successfully.')
      end
      @sd.stubs(:iterate_file).with(@o_file).returns(@o_file)
      @sd.stubs(:iterate_file).with(@r_file).returns(@r_file)
      @sd.stubs(:iterate_file).with(@json_file).returns(@json_file)
      @sd.stubs(:brownfield_server?).returns(false)
      ASM::Util.expects(:run_command_streaming).with(
        "sudo puppet asm process_node --debug --trace --filename #{@r_file} --run_type apply --statedir #{@tmp_dir}/8000/resources --always-override server-cert", "#{@o_file}")
      @data['serviceTemplate']['components'][0]['type'] = 'TEST'
      @data['serviceTemplate']['components'][0]['resources'].push(
        {'id' => 'user', 'parameters' => [
          {'id' => 'title', 'value' => 'foo'},
          {'id' => 'foo', 'value' => 'bar'}
        ]}
      )

      ASM::DeviceManagement.expects(:puppet_run_success?).with("server-cert", 0, instance_of(Time), @o_file, @summary_file).returns([false, "rspec simulated fail"])

      expect { @sd.process(@data) }.to raise_error("puppet asm process_node for server-cert failed: rspec simulated fail")
    end

    describe 'when a server fails' do
      before do
        File.open( "#{@tmp_dir}/8000/server-cert.out", 'w') do |fh|
          fh.write('Results: For 0 resources. 0 from our run failed. 0 not from our run failed. 0 updated successfully.')
        end
        @sd.stubs(:iterate_file).with(@o_file).returns(@o_file)
        @sd.stubs(:iterate_file).with(@r_file).returns(@r_file)
        @sd.stubs(:iterate_file).with(@json_file).returns(@json_file)
        ASM::DeviceManagement.stubs(:puppet_run_success?).returns([false, "rspec simulated fail"])
        ASM::DeviceManagement.stubs(:parse_device_config).with("server-cert").returns(endpoint)
        ASM::Util.stubs(:run_command_streaming).with(
            "sudo puppet asm process_node --debug --trace --filename #{@r_file} --run_type apply --statedir #{@tmp_dir}/8000/resources --always-override server-cert", "#{@o_file}")
      end

      it "should migrate the server if retry on failure is enabled" do
        server_component =
            {
                "id" => "migrate_mock_id",
                "type" => "SERVER",
                "puppetCertName" => "server-cert",
                "relatedComponents" => {},
                "resources" => [
                    {"id" => "asm::server", "parameters" => [{"id" => "title", "value" => "server-cert"}]},
                    {"id" => "asm::idrac",
                     "parameters" =>
                         [
                             {"id" => "title", "value" => "server-cert"},
                             {"id" => "migrate_on_failure", "value" => "true", "type" => "BOOLEAN"}
                         ]
                    }
                ]
            }
        @data["serviceTemplate"]["components"][0] = server_component
        @sd.components(@data)
        #Just return the same server component when migrating to simulate successful migration
        @sd.expects(:migrate).with(server_component).returns([server_component, {}])
        ASM::DeviceManagement.stubs(:puppet_run_success?).returns([false, "rspec simulated fail"], [true, "rspec simulated success"])
        @sd.process(@data)
      end

      it "should not migrate the server if retry on failure is disabled" do
        server_component =
            {
                "type" => "SERVER",
                "puppetCertName" => "server-cert",
                "relatedComponents" => {},
                "resources" => [
                    {"id" => "asm::server", "parameters" => [{"id" => "title", "value" => "server-cert"}]},
                    {"id" => "asm::idrac",
                     "parameters" =>
                         [
                             {"id" => "title", "value" => "server-cert"},
                             {"id" => "migrate_on_failure", "value" => "false", "type" => "BOOLEAN"}
                         ]
                    }
                ]
            }
        @data["serviceTemplate"]["components"][0] = server_component
        @sd.components(@data)
        @sd.expects(:migrate).never
        expect{ @sd.process(@data) }.to raise_error("puppet asm process_node for server-cert failed: rspec simulated fail")
      end

      it 'should throw an error in the server swimlane if there are no clusters' do
        server_component =
            {
                'type' => 'SERVER',
                'puppetCertName' => 'server-cert',
                'id' => 'server',
                'relatedComponents' => {},
                'resources' => [
                    {'id' => 'asm::server', 'parameters' => [{'id' => 'title', 'value' => 'server-cert'}]},
                    {'id' => 'asm::idrac', 'parameters' =>[{'id' => 'title', 'value' => 'server-cert'}]}]
            }
        @data['serviceTemplate']['components'][0] = server_component
        @sd.expects(:process_cluster).never
        expect { @sd.process(@data) }.to raise_error("puppet asm process_node for server-cert failed: rspec simulated fail")
      end
    end


    it 'should be able to process data for a single resource' do
      File.open( "#{@tmp_dir}/8000/server-cert.out", 'w') do |fh|
        fh.write('Results: For 0 resources. 0 from our run failed. 0 not from our run failed. 0 updated successfully.')
      end
      @sd.stubs(:iterate_file).with(@o_file).returns(@o_file)
      @sd.stubs(:iterate_file).with(@r_file).returns(@r_file)
      @sd.stubs(:iterate_file).with(@json_file).returns(@json_file)
      @sd.stubs(:brownfield_server?).returns(false)
      ASM::DeviceManagement.stubs(:parse_device_config).with('server-cert').returns(endpoint)
      ASM::Util.expects(:run_command_streaming).with(
        "sudo puppet asm process_node --debug --trace --filename #{@r_file} --run_type apply --statedir #{@tmp_dir}/8000/resources --always-override server-cert", "#{@o_file}")
      @data['serviceTemplate']['components'][0]['type'] = 'TEST'
      @data['serviceTemplate']['components'][0]['resources'].push(
        {'id' => 'user', 'parameters' => [
          {'id' => 'title', 'value' => 'foo'},
          {'id' => 'foo', 'value' => 'bar'}
        ]}
      )

      ASM::DeviceManagement.expects(:puppet_run_success?).with("server-cert", 0, instance_of(Time), @o_file, @summary_file).returns([true, "x"])

      @sd.process(@data)
      YAML.load_file(@r_file)['user']['foo']['foo'].should == 'bar'
    end

    describe 'for server bare metal provisioning' do
      it 'should configure a server' do

        @sd.stubs(:iterate_file).with(@o_file).returns(@o_file)
        @sd.stubs(:iterate_file).with(@r_file).returns(@r_file)
        @sd.stubs(:iterate_file).with(@json_file).returns(@json_file)

        ASM::Util.expects(:run_command_streaming).at_most(2).with(
            "sudo -i puppet asm process_node --filename #{@r_file} --run_type apply --always-override server-cert", "#{@o_file}") do |cmd|
          File.open(@o_file, 'w') do |fh|
            fh.write('Results: For 0 resources. 0 from our run failed. 0 not from our run failed. 0 updated successfully.')
          end
        end


        @data['serviceTemplate']['components'][0]['type'] = 'SERVER'
        @data['serviceTemplate']['components'][0]['puppetCertName'] = 'server-cert'
        @data['serviceTemplate']['components'][0]['resources'].push(
            {'id' => 'asm::server', 'parameters' => [
                {'id' => 'title', 'value' => 'server-cert'},
                {'id' => 'admin_password', 'value' => 'foo'},
                {'id' => 'os_host_name', 'value' => 'foo'},
                {'id' => 'os_image_type', 'value' => 'foo'}
            ]}
        )
        @sd.stubs(:server_already_deployed).returns(false)
        ASM::DeviceManagement.stubs(:parse_device_config).with('server-cert').returns(endpoint)
        ASM::DeviceManagement.expects(:puppet_run_success?).at_most(2).with('server-cert', 0, instance_of(Time), @o_file, @summary_file).returns([true, "x"])
        @razor.expects(:delete_stale_policy!).with('server-cert', "policy-foo-8000")
        ASM::Util.stubs(:cert2serial).returns('server-cert')
        ASM::Util.stubs(:dell_cert?).returns(true)
        ASM::PrivateUtil.stubs(:fetch_server_inventory).returns({'serviceTag' => 'server-cert', 'model' => 'M630'})
        @sd.stubs(:get_post_installation_data).returns({})
        @sd.stubs(:get_post_installation_config).returns({})
        @sd.process(@data)
      end

      it 'should configure a windows server' do
        @sd.stubs(:iterate_file).with(@o_file).returns(@o_file)
        @sd.stubs(:iterate_file).with(@r_file).returns(@r_file)
        @sd.stubs(:iterate_file).with(@json_file).returns(@json_file)
        ASM::Util.expects(:run_command_streaming).at_most(2).with(
            "sudo -i puppet asm process_node --filename #{@r_file} --run_type apply --always-override server-cert", "#{@o_file}") do |cmd|
          File.open(@o_file, 'w') do |fh|
            fh.write('Results: For 0 resources. 0 from our run failed. 0 not from our run failed. 0 updated successfully.')
          end
        end

        @data['serviceTemplate']['components'][0]['type'] = 'SERVER'
        @data['serviceTemplate']['components'][0]['puppetCertName'] = 'server-cert'
        @data['serviceTemplate']['components'][0]['resources'].push(
            {'id' => 'asm::server', 'parameters' => [
                {'id' => 'title', 'value' => 'server-cert'},
                {'id' => 'admin_password', 'value' => 'foo'},
                {'id' => 'os_host_name', 'value' => 'foo'},
                {'id' => 'os_image_type', 'value' => 'windows2012'}
            ]}
        )
        @sd.stubs(:server_already_deployed).returns(false)
        ASM::DeviceManagement.stubs(:parse_device_config).with('server-cert').returns(endpoint)
        ASM::DeviceManagement.expects(:puppet_run_success?).at_most(2).with('server-cert', 0, instance_of(Time), @o_file, @summary_file).returns([true, "x"])
        @razor.expects(:delete_stale_policy!).with('server-cert', "policy-foo-8000")
        ASM::Util.stubs(:cert2serial).returns('server-cert')
        ASM::Util.stubs(:dell_cert?).returns(true)
        ASM::PrivateUtil.stubs(:fetch_server_inventory).returns({'serviceTag' => 'server-cert', 'model' => 'M630'})
        @sd.stubs(:get_post_installation_data).returns({})
        @sd.stubs(:get_post_installation_config).returns({})
        @sd.process(@data)
      end

      describe 'hyperV server' do
        it 'should process hyperv servers' do
          server_component =  {'id' => 'id', 'resources' => []}
          node = {'policy' => { 'name' => 'policy_test' } }
          @sd.stubs(:find_node).returns(node)
          policy = {
              'repo' => {'name' => 'esxi-5.1'},
              'installer' => {'name' => 'vmware_esxi'}
          }
          @sd.stubs(:get).returns(policy)
          server_component['id'] = 'id'
          server_component['puppetCertName'] = 'bladeserver-serialno'
          server_component['type'] = 'SERVER'
          parameters = [ {'id' => 'title', 'value' => 'bladeserver-serialno'},
                         {'id' => 'os_image_type', 'value' => 'hyperv'},
                         {'id' => 'os_image_version', 'value' => 'hyperv'},
                         {'id' => 'os_host_name', 'value' => 'foo'}
          ]
          resource1 = { 'id' => 'asm::server', 'parameters' => parameters }
          @sd.debug = true
          server_component['resources'].push(resource1)

          server_component['relatedComponents'] = { 'k1' => 'v1' }
          @sd.stubs(:server_already_deployed).returns(false)
          all_components = [
              {'id' => 'k1',
               'puppetCertName' => 'k1',
               'type' => 'STORAGE',
               'asmGUID' => 'equallogic-1.1.1.1',
               'componentID'=>'s1',
               'resources' => [{
                                   'id' => 'asm::volume::equallogic',
                                   'parameters' => [
                                       {'id' => 'title', 'value' => 'vol1'}
                                   ]
                               }]
              },
              {'id' => 'k1',
               'puppetCertName' => 'k1',
               'type' => 'STORAGE',
               'asmGUID' => 'equallogic-1.1.1.1',
               'componentID'=>'s1',
               'resources' => [{
                                   'id' => 'asm::volume::equallogic',
                                   'parameters' => [
                                       {'id' => 'title', 'value' => 'vol2'}
                                   ]
                               }]
              },
              server_component
          ]
          @sd.stubs(:components).returns(all_components)
          ASM::PrivateUtil.expects(:find_equallogic_iscsi_ip).with('equallogic-1.1.1.1').returns('127.0.1.1')
          ASM::Processor::Server.expects(:munge_hyperv_server).with(
              'bladeserver-serialno',
              {'asm::server' => {
                  'bladeserver-serialno' => {
                      'os_host_name' => 'foo',
                      'broker_type' => 'noop',
                      'os_image_version' => 'hyperv',
                      'serial_number' => 'SERIALNO',
                      'policy_name' => 'policy-foo-8000',
                      'razor_api_options' => {'url' => 'http://asm-razor-api:8080/api'},
                      'installer_options' => {
                          'os_type' => 'hyperv',
                          'agent_certname' => 'agent-foo'}}}},
              '127.0.1.1',
              ['vol1', 'vol2'],
              @sd.logger,
              true,
              'iscsi',
              'equallogic',
              'Fabric A',
              ['aa-bb-cc-dd-ee-ff', 'aa-bb-cc-dd-ee-f1']
          ).returns({})
          ASM::DeviceManagement.stubs(:parse_device_config).with(server_component['puppetCertName']).returns(endpoint)
          @razor.expects(:delete_stale_policy!).with("SERIALNO", "policy-foo-8000")
          @sd.stubs(:get_iscsi_fabric).returns('Fabric A')
          @sd.stubs(:hyperv_iscsi_macs).returns(['aa-bb-cc-dd-ee-ff','aa-bb-cc-dd-ee-f1'])
          @sd.process_server(server_component)
          @sd.debug = false
        end

        it 'should find correct equallogic iscsi ip address' do
          server_component =  {'id' => 'id', 'resources' => []}
          node = {'policy' => { 'name' => 'policy_test' } }
          @sd.stubs(:find_node).returns(node)
          policy = {
              'repo' => {'name' => 'esxi-5.1'},
              'installer' => {'name' => 'vmware_esxi'}
          }
          @sd.stubs(:get).returns(policy)
          server_component['id'] = 'id'
          server_component['puppetCertName'] = 'bladeserver-serialno'
          server_component['type'] = 'SERVER'
          parameters = [ {'id' => 'title', 'value' => 'bladeserver-serialno'},
                         {'id' => 'os_image_type', 'value' => 'hyperv'},
                         {'id' => 'os_image_version', 'value' => 'hyperv'},
                         {'id' => 'os_host_name', 'value' => 'foo'}
          ]
          resource1 = { 'id' => 'asm::server', 'parameters' => parameters }
          @sd.debug = true
          server_component['resources'].push(resource1)

          server_component['relatedComponents'] = { 'k1' => 'v1' }
          @sd.stubs(:server_already_deployed).returns(false)
          all_components = [
              {'id' => 'k1',
               'puppetCertName' => 'k1',
               'type' => 'STORAGE',
               'asmGUID' => 'equallogic-1.1.1.1',
               'componentID'=>'s1',
               'relatedComponents' => {'id' => 'bladeserver-serialno'},
               'resources' => [{
                                   'id' => 'asm::volume::equallogic',
                                   'parameters' => [
                                       {'id' => 'title', 'value' => 'vol1'}
                                   ]
                               }]
              },
              {'id' => 'k1',
               'puppetCertName' => 'k1',
               'type' => 'STORAGE',
               'asmGUID' => 'equallogic-1.1.1.1',
               'componentID'=>'s1',
               'relatedComponents' => {'id' => 'bladeserver-serialno'},
               'resources' => [{
                                   'id' => 'asm::volume::equallogic',
                                   'parameters' => [
                                       {'id' => 'title', 'value' => 'vol2'}
                                   ]
                               }]
              },
              server_component
          ]
          @sd.stubs(:components).returns(all_components)
          ASM::DeviceManagement.stubs(:parse_device_config).with(server_component['puppetCertName']).returns(endpoint)
          ASM::PrivateUtil.stubs(:find_equallogic_iscsi_ip).returns('1.1.1.1')
          target_ip = @sd.get_iscsi_target_ip(server_component)
          target_ip.should_not be_empty
          target_ip.should == '1.1.1.1'
          @sd.debug = false
        end
        it 'should find correct compellent iscsi ip address' do
          server_component =  {'id' => 'id', 'resources' => []}
          node = {'policy' => { 'name' => 'policy_test' } }
          @sd.stubs(:find_node).returns(node)
          policy = {
              'repo' => {'name' => 'esxi-5.1'},
              'installer' => {'name' => 'vmware_esxi'}
          }
          @sd.stubs(:get).returns(policy)
          server_component['id'] = 'id'
          server_component['puppetCertName'] = 'bladeserver-serialno'
          server_component['type'] = 'SERVER'
          parameters = [ {'id' => 'title', 'value' => 'bladeserver-serialno'},
                         {'id' => 'os_image_type', 'value' => 'hyperv'},
                         {'id' => 'os_image_version', 'value' => 'hyperv'},
                         {'id' => 'os_host_name', 'value' => 'foo'}
          ]
          resource1 = { 'id' => 'asm::server', 'parameters' => parameters }
          @sd.debug = true
          server_component['resources'].push(resource1)

          server_component['relatedComponents'] = { 'k1' => 'v1' }
          @sd.stubs(:server_already_deployed).returns(false)
          all_components = [
              {'id' => 'k1',
               'puppetCertName' => 'k1',
               'asmGUID' => 'compellent-1.1.1.1',
               'componentID'=>'s1',
               'type' => 'STORAGE',
               'resources' => [{
                                   'id' => 'asm::volume::compellent',
                                   'parameters' => [
                                       {'id' => 'title', 'value' => 'vol1'},
                                       {'id' => 'porttype', 'value' => 'iscsi'}
                                   ]
                               }]
              },
              {'id' => 'k1',
               'puppetCertName' => 'k1',
               'asmGUID' => 'compellent-1.1.1.1',
               'componentID'=>'s1',
               'type' => 'STORAGE',
               'resources' => [{
                                   'id' => 'asm::volume::compellent',
                                   'parameters' => [
                                       {'id' => 'title', 'value' => 'vol2'},
                                       {'id' => 'porttype', 'value' => 'iscsi'}
                                   ]
                               }]
              },
              server_component
          ]
          @sd.stubs(:components).returns(all_components)
          ASM::DeviceManagement.stubs(:parse_device_config).with(server_component['puppetCertName']).returns(endpoint)
          ASM::PrivateUtil.stubs(:facts_find).with('compellent-1.1.1.1').returns({"certname"=>"compellent-1.1.1.1",
                                                   "device_type"=>"script", "system_SerialNumber"=>"k1",
                                                   "system_Name"=>"SC8000-9-50", "system_ManagementIP"=>"172.17.9.55",
                                                   "system_Version"=>"6.6.4.6", "system_OperationMode"=>"Normal"})

          ASM::PrivateUtil.stubs(:find_em_facts_managing_sc).returns({ 'storage_center_iscsi_fact' =>
                                                                    { 'k1' => [
                                                                      { 'ipAddress' => '172.16.12.30', 'chapName' => 'iqn.2002-03.com.compellent:5000d31000555b56' } ,
                                                                      { 'ipAddress' => '172.16.3.30', 'chapName' => 'iqn.2002-03.com.compellent:5000d31000555b56' }
                                                                      ]
                                                                    }.to_json,
                                                                'storage_centers' =>  ['k1', '24260', '21851', '200366'].to_json
                                                              })
          #ASM::PrivateUtil.stubs(:find_compellent_iscsi_ip).returns('1.1.1.1')
          target_ip = @sd.get_iscsi_target_ip(server_component)
          target_ip.should_not be_empty
          target_ip.should == "172.16.12.30,172.16.3.30"
          @sd.debug = false
        end
        it 'should find return blank iscsi address for FC Compellent' do
          server_component =  {'id' => 'id', 'resources' => []}
          node = {'policy' => { 'name' => 'policy_test' } }
          @sd.stubs(:find_node).returns(node)
          policy = {
              'repo' => {'name' => 'esxi-5.1'},
              'installer' => {'name' => 'vmware_esxi'}
          }
          @sd.stubs(:get).returns(policy)
          server_component['id'] = 'id'
          server_component['puppetCertName'] = 'bladeserver-serialno'
          server_component['type'] = 'SERVER'
          parameters = [ {'id' => 'title', 'value' => 'bladeserver-serialno'},
                         {'id' => 'os_image_type', 'value' => 'hyperv'},
                         {'id' => 'os_image_version', 'value' => 'hyperv'},
                         {'id' => 'os_host_name', 'value' => 'foo'}
          ]
          resource1 = { 'id' => 'asm::server', 'parameters' => parameters }
          @sd.debug = true
          server_component['resources'].push(resource1)

          server_component['relatedComponents'] = { 'k1' => 'v1' }
          @sd.stubs(:server_already_deployed).returns(false)
          all_components = [
              {'id' => 'k1',
               'puppetCertName' => 'k1',
               'asmGUID' => 'compellent-1.1.1.1',
               'componentID'=>'s1',
               'type' => 'STORAGE',
               'resources' => [{
                                   'id' => 'asm::volume::compellent',
                                   'parameters' => [
                                       {'id' => 'title', 'value' => 'vol1'},
                                       {'id' => 'porttype', 'value' => 'FibreChannel'}
                                   ]
                               }]
              },
              {'id' => 'k1',
               'puppetCertName' => 'k1',
               'asmGUID' => 'compellent-1.1.1.1',
               'componentID'=>'s1',
               'type' => 'STORAGE',
               'resources' => [{
                                   'id' => 'asm::volume::compellent',
                                   'parameters' => [
                                       {'id' => 'title', 'value' => 'vol2'},
                                       {'id' => 'porttype', 'value' => 'FibreChannel'}
                                   ]
                               }]
              },
              server_component
          ]
          @sd.stubs(:components).returns(all_components)
          ASM::DeviceManagement.stubs(:parse_device_config).with(server_component['puppetCertName']).returns(endpoint)
          ASM::PrivateUtil.stubs(:facts_find).with('compellent-1.1.1.1').returns({"certname"=>"compellent-1.1.1.1",
                                                                           "device_type"=>"script", "system_SerialNumber"=>"k1",
                                                                           "system_Name"=>"SC8000-9-50", "system_ManagementIP"=>"172.17.9.55",
                                                                           "system_Version"=>"6.6.4.6", "system_OperationMode"=>"Normal"})

          ASM::PrivateUtil.stubs(:find_em_facts_managing_sc).returns({ 'storage_center_iscsi_fact' =>
                                                                    { 'k1' => [
                                                                        { 'ipAddress' => '172.16.12.30', 'chapName' => 'iqn.2002-03.com.compellent:5000d31000555b56' } ,
                                                                        { 'ipAddress' => '172.16.3.30', 'chapName' => 'iqn.2002-03.com.compellent:5000d31000555b56' }
                                                                    ]
                                                                    }.to_json,
                                                                'storage_centers' =>  ['k1', '24260', '21851', '200366'].to_json
                                                              })
          target_ip = @sd.get_iscsi_target_ip(server_component)
          target_ip.should be_empty
          @sd.debug = false
        end

      end

    end

    describe 'for boot from san server deployment' do
      it 'should configure a server' do

        @sd.stubs(:iterate_file).with(@o_file).returns(@o_file)
        @sd.stubs(:iterate_file).with(@r_file).returns(@r_file)
        @sd.stubs(:iterate_file).with(@json_file).returns(@json_file)

        ASM::Util.expects(:run_command_streaming).with(
            "sudo -i puppet asm process_node --filename #{@r_file} --run_type apply --always-override server-cert", "#{@o_file}") do |cmd|
          File.open(@o_file, 'w') do |fh|
            fh.write('Results: For 0 resources. 0 from our run failed. 0 not from our run failed. 0 updated successfully.')
          end
        end

        @data['serviceTemplate']['components'][0]['id'] = 'server'
        @data['serviceTemplate']['components'][0]['type'] = 'SERVER'
        @data['serviceTemplate']['components'][0]['resources'].push(
            {'id' => 'asm::server', 'parameters' => [
                {'id' => 'title', 'value' => 'foo'},
                {'id' => 'admin_password', 'value' => 'foo'},
                {'id' => 'os_host_name', 'value' => 'foo'},
                {'id' => 'os_image_type', 'value' => 'foo'}
            ]},
            {'id' => 'asm::idrac', 'parameters' => [
                {'id' => 'target_boot_device', 'value' => 'iSCSI'},
                {'id' => 'title', 'value' => 'foo'},
                {'id' => 'attempted_servers', 'value' => 'foo'},
            ]},
            {'id' => 'asm::bios', 'parameters' => [
                {'id' => 'title', 'value' => 'foo'},
            ]}
        )
        @data['serviceTemplate']['components'][0]['relatedComponents'] = {'k1' => 'vol1'}
        @data['serviceTemplate']['components'].concat(
          [
            {'id' => 'k1',
             'puppetCertName' => 'k1',
             'asmGUID' => 'equallogic-1.1.1.1',
             'componentID'=>'s1',
             'type' => 'STORAGE',
             'relatedComponents' => {'server' => 'server'},
             'resources' =>
                 [{
                   'id' => 'asm::volume::equallogic',
                   'parameters' => [{'id' => 'title', 'value' => 'vol1'}]
                 }]
            }
          ]
        )
        @sd.components(@data)
        @sd.stubs(:process_storage)

        ASM::PrivateUtil.stubs(:fetch_server_inventory).returns({'serviceTag' => 'server-cert', 'model' => 'M630'})
        ASM::DeviceManagement.stubs(:parse_device_config).with('k1').returns({})
        ASM::DeviceManagement.stubs(:run_puppet_device!).returns({})
        ASM::PrivateUtil.stubs(:find_equallogic_iscsi_volume).returns('volname')
        ASM::PrivateUtil.stubs(:find_equallogic_iscsi_ip).returns('127.0.0.1')

        ASM::Util.stubs(:dell_cert?).returns(true)
        @sd.stubs(:process_tor_switches).returns(true)
        @sd.stubs(:process_san_switches).returns(true)
        @sd.stubs(:server_already_deployed).returns(false)
        ASM::DeviceManagement.stubs(:parse_device_config).with('server-cert').returns(endpoint)
        ASM::DeviceManagement.expects(:puppet_run_success?).with("server-cert", 0, instance_of(Time), @o_file, @summary_file).returns([true, "x"])
        @sd.process(@data)
      end
    end
  end

  describe 'when data is invalid' do

    it 'should warn when no serviceTemplate is defined' do
      @mock_log = mock('foo')
      @sd.expects(:logger).at_least_once.returns(@mock_log)
      @mock_log.stubs(:debug)
      @mock_log.expects(:info).with('Status: Started')
      @mock_log.expects(:info).with('Starting deployment ')
      @mock_log.expects(:warn).with('Service deployment data has no serviceTemplate defined')
      @mock_log.expects(:info).with('Status: Completed')
      @sd.stubs(:brownfield_server?).returns(false)
      @sd.process({})
    end

    it 'should warn when there are no components' do
      @mock_log = mock('foo')
      @sd.expects(:logger).at_least_once.returns(@mock_log)
      @mock_log.stubs(:debug)
      @mock_log.expects(:info).with('Status: Started')
      @mock_log.expects(:info).with('Starting deployment ')
      @mock_log.expects(:warn).with('service deployment data has no components')
      @mock_log.expects(:info).with('Status: Completed')
      @sd.stubs(:brownfield_server?).returns(false)
      @sd.process({'serviceTemplate' => {}})
    end

    it 'should fail when resources do not have types' do
      @sd.stubs(:brownfield_server?).returns(false)
      expect do
        @sd.process({'serviceTemplate' => {'components' => [
          {'id' => 'id', 'puppetCertName' => 'server-cert', 'type' => 'TEST', 'resources' => [
            {}
          ]}
        ]}})
      end.to raise_error('resource found with no type')
    end

    it 'should fail when resources do not have paremeters' do
      @sd.stubs(:brownfield_server?).returns(false)
      expect do
        @sd.process({'serviceTemplate' => {'components' => [
          {'type' => 'TEST', 'id' => 'id2','puppetCertName' => 'cert2', 'resources' => [
            {'id' => 'user'}
          ]}
        ]}})
      end.to raise_error('resource of type user has no parameters')
    end

    it 'should fail when component has no certname' do
      @sd.stubs(:brownfield_server?).returns(false)
      expect do
        @sd.process({'serviceTemplate' => {'components' => [
          {'type' => 'TEST', 'resources' => [
            {'id' => 'user'}
          ]}
        ]}})
      end.to raise_error('Component has no certname')
    end

    it 'should fail when a resource has no title' do
      @sd.stubs(:brownfield_server?).returns(false)
      expect do
        @sd.process({'serviceTemplate' => {'components' => [
          {'type' => 'TEST', 'id' => 'foo', 'puppetCertName' => 'cert4', 'resources' => [
            {'id' => 'user', 'parameters' => []}
          ]}
        ]}})
      end.to raise_error('Component has resource user with no title')
    end

  end

  describe 'dealing with duplicate certs in the same deployment' do
    before do
      @counter_files = [File.join(@tmp_dir, 'existing_file.yaml')]
    end
    after do
      @counter_files.each do |f|
        File.delete(f) if File.exists?(f)
      end
    end
    def write_counter_files
      @counter_files.each do |f|
        File.open(f, 'w') do |fh|
          fh.write('stuff')
        end
      end
    end
    it 'should be able to create file counters labeled 2 when files exist' do
      write_counter_files
      @sd.iterate_file(@counter_files.first).should == File.join(@tmp_dir, 'existing_file___2.yaml')
    end
    it 'should increment existing counter files' do
      @counter_files.push(File.join(@tmp_dir, 'existing_file___4.yaml'))
      write_counter_files
      @sd.iterate_file(@counter_files.first).should == File.join(@tmp_dir, 'existing_file___5.yaml')
    end
    it 'should return passed in file when no file exists' do
      @sd.iterate_file(@counter_files.first).should == File.join(@tmp_dir, 'existing_file.yaml')
    end
  end

  describe 'when checking agent status' do
    before do
      RestClient.stubs(:get)
        .with(URI.escape("http://localhost:7080/v3/nodes?query=[\"and\", [\"=\", [\"node\", \"active\"], true], [\"=\", \"name\", \"host\"]]]"),
        {:content_type => :json, :accept => :json})
          .returns('[{"name":"host"}]')

      RestClient.stubs(:get)
        .with(URI.escape("http://localhost:7080/v3/reports?query=[\"=\", \"certname\", \"host\"]&order-by=[{\"field\": \"receive-time\", \"order\": \"desc\"}]&limit=1"),
        {:content_type => :json, :accept => :json})
          .returns('[{"receive-time":"1970-01-01 01:00:00 +0000", "hash":"fooreport"}]')
    end

    it 'should be able to detect when a node has checked in' do
      sd = ASM::ServiceDeployment.new('123', @deployment_db)
      time = Time.at(0)
      cert_name = "host"
      sd.stubs(:puppetdb).returns(puppetdb)
      sd.await_agent_run_completion(cert_name, time, 1).should be(true)
    end

    it 'should raise PuppetEventException if node has not checked in' do
      sd = ASM::ServiceDeployment.new('123', @deployment_db)
      puppetdb.stubs(:successful_report_after?).returns(false)
      sd.stubs(:puppetdb).returns(puppetdb)
      expect{sd.await_agent_run_completion('host', Time.at(0), 1)}.to raise_exception(ASM::ServiceDeployment::PuppetEventException)
    end
  end

  describe 'when checking find related components' do
    before do
      data = SpecHelper.json_fixture("find_related_components.json")
      @sd.components(data)
      @components = data['serviceTemplate']['components']
    end
    it 'should return related component based on componentID' do
      expected = [{"id" => "ID1",
                   "componentID" => "COMPID1",
                   "type" => "CLUSTER",
                   "relatedComponents" => {"ID1" => "Virtual Machine 1"},
                   "resources" => {
                       "id" => "asm::cluster",
                       "parameters" => [{"id" => "datacenter"}]}
                  }]
      @sd.find_related_components('CLUSTER', @components[0]).should == expected
    end
    it 'should fail to related component based on ID' do
       @sd.find_related_components('VIRTUALMACHINE', @components[1]).should == []
    end
  end

  describe 'when checking for external connected volumes' do
    before do
      data = SpecHelper.json_fixture("Deployment_ESX_VDS_Input.json")
      @sd.components(data)
      @components = data['serviceTemplate']['components']
    end
    it 'should find an external volume connected with most servers' do
      @sd.find_external_volume_with_most_servers.should == "adan-vol2"
    end
  end

  describe 'verifying service deployer internal configuration' do
    it 'configures directory' do
      @sd.stubs(:create_dir)
      @sd.send(:deployment_dir).should == File.join(@tmp_dir, @sd.id)
      @sd.send(:resources_dir).should == File.join(@tmp_dir, @sd.id, 'resources')
    end
  end

  describe 'should find correct storage HBAs' do
    before do
      @mock_log = mock('logger')
      @mock_log.stub_everything
      @sd.stubs(:logger).returns(@mock_log)
      @endpoint = Hashie::Mash.new(endpoint)
      @hba_macs = {
          'vmhba33' => '00:10:18:C3:D9:7C',
          'vmhba34' => '00:10:18:C3:D9:7D',
          'vmhba35' => '00:10:18:C3:D9:7E',
          'vmhba36' => '00:10:18:C3:D9:7F',
      }
      @hbas = @hba_macs.keys.collect do |hba|
        {'Adapter' => hba, 'Description' => 'Broadcom iSCSI Adapter'}
      end
      ASM::Util.stubs(:esxcli).with(%w(iscsi adapter list), @endpoint, @mock_log).returns(@hbas)
      @hba_macs.each do |hba, mac|
        cmd = %w(iscsi adapter get --adapter).push(hba)
        serial = mac.gsub(/:/, '').downcase
        response = <<EOT
#{hba}
   Name: iqn.1998-01.com.vmware:host1051def.:674130862:35
   Alias: bnx2i-001018c3d97c
   Vendor: VMware
   Model: Broadcom iSCSI Adapter
   Description: Broadcom iSCSI Adapter
   Serial Number: #{serial}
   Hardware Version:
   Asic Version:
   Firmware Version:
   Option Rom Version:
   Driver Name: bnx2i-vmnic22
   Driver Version:
   TCP Protocol Supported: false
   Bidirectional Transfers Supported: false
   Maximum Cdb Length: 64
   Can Be NIC: true
   Is NIC: true
   Is Initiator: true
   Is Target: false
   Using TCP Offload Engine: true
   Using ISCSI Offload Engine: true

EOT
        ASM::Util.stubs(:esxcli).with(cmd, @endpoint, @mock_log, true).returns(response)
      end
    end

    it 'should fail if no hbas found' do
      expect do
        ASM::Util.stubs(:esxcli).with(%w(iscsi adapter list), @endpoint, @mock_log).returns([])
        @sd.parse_hbas(@endpoint, nil)
      end.to raise_error
    end

    it 'should return first two hbas when no iscsi macs specified' do
      ASM::Util.stubs(:esxcli).with(%w(iscsi adapter list), @endpoint, @mock_log).returns(@hbas)
      hbas = @sd.parse_hbas(@endpoint, nil)
      hbas.should == %w(vmhba33 vmhba34)
    end

    it 'should match hbas to iscsi macs' do
      ASM::Util.stubs(:esxcli).with(%w(iscsi adapter list), @endpoint, @mock_log).returns(@hbas)
      expected_hbas = %w(vmhba35 vmhba36)
      iscsi_macs = expected_hbas.collect { |hba| @hba_macs[hba] }
      hbas = @sd.parse_hbas(@endpoint, iscsi_macs)
      hbas.should == expected_hbas
    end

  end

  describe 'should find network partition information' do

    it 'should return storage network' do
      network_config = mock('network_configuration')
      iscsi_networks = [Hashie::Mash.new({:type => 'STORAGE_ISCSI_SAN'})]
      network_config.stubs(:teams).returns([:networks => iscsi_networks])
      info = @sd.gather_vswitch_info(network_config)
      info.first[:storage][:networks].should == iscsi_networks
    end

  end

  describe 'deployed servers ids' do

    before do
      data = SpecHelper.json_fixture("deployed_server.json")
      @sd.components(data)
      @server_components = @sd.components_by_type('SERVER')
      @components = data['serviceTemplate']['components']
    end

    it 'should return server ids' do
      @sd.server_component_ids.should == ["ID1", "ID2"]
    end

    it 'should return deployed servers when all servers are deployed' do
      @sd.stubs(:server_already_deployed).returns(true)
      @sd.deployed_server_ids.should == ["ID1", "ID2"]
      @sd.server_ids_not_deployed == []
    end

    it 'should return deployed servers as blank when all servers are not deployed' do
      @sd.stubs(:server_already_deployed).returns(false)
      @sd.deployed_server_ids.should == []
      @sd.server_ids_not_deployed == ["ID1", "ID2"]
    end

    it 'should return only deployed servers' do
      @sd.stubs(:server_already_deployed).with(@server_components[0],nil).returns(true)
      @sd.stubs(:server_already_deployed).with(@server_components[1],nil).returns(false)
      @sd.deployed_server_ids.should == ["ID1"]
      @sd.server_ids_not_deployed == ["ID2"]
    end

  end

  describe 'resolving hostnames' do

    before do
      @static = {'primaryDns' => '192.168.0.1',
                 'dnsSuffix' => 'foo.com',
                 'ipAddress' => '192.168.0.100'}
    end

    it 'should return the fqdn when hostname matches the IP' do
      hostname = 'host100'
      fqdn = "#{hostname}.#{@static['dnsSuffix']}"
      resolver = mock('resolver')
      resolved_ip = Resolv::IPv4.create(@static['ipAddress'])
      resolver.expects(:getaddress).with(hostname).returns(resolved_ip)
      spec = {:nameserver => [@static['primaryDns']], :search => Array(@static['dnsSuffix']), :ndots => 1}
      Resolv::DNS.expects(:open).with(spec).yields(resolver).returns(resolved_ip)
      @sd.lookup_hostname(hostname, @static).should == fqdn
    end

    it 'should return the fqdn when hostname matches the IP (both dns servers)' do
      @static['secondaryDns'] = '192.168.0.2'
      hostname = 'host100'
      fqdn = "#{hostname}.#{@static['dnsSuffix']}"
      resolver = mock('resolver')
      resolved_ip = Resolv::IPv4.create(@static['ipAddress'])
      resolver.expects(:getaddress).with(hostname).returns(resolved_ip)
      spec = {:nameserver => [@static['primaryDns'], @static['secondaryDns']],
              :search => Array(@static['dnsSuffix']), :ndots => 1}
      Resolv::DNS.expects(:open).with(spec).yields(resolver).returns(resolved_ip)
      @sd.lookup_hostname(hostname, @static).should == fqdn
    end

    it 'should return the fqdn when hostname matches the IP (secondary dns only)' do
      @static['primaryDns'] = nil
      @static['secondaryDns'] = '192.168.0.2'
      hostname = 'host100'
      fqdn = "#{hostname}.#{@static['dnsSuffix']}"
      resolver = mock('resolver')
      resolved_ip = Resolv::IPv4.create(@static['ipAddress'])
      resolver.expects(:getaddress).with(hostname).returns(resolved_ip)
      spec = {:nameserver => [@static['secondaryDns']],
              :search => Array(@static['dnsSuffix']), :ndots => 1}
      Resolv::DNS.expects(:open).with(spec).yields(resolver).returns(resolved_ip)
      @sd.lookup_hostname(hostname, @static).should == fqdn
    end

    it 'should return the hostname when it matches the IP without domain' do
      @static['dnsSuffix'] = nil
      hostname = 'host100'
      resolver = mock('resolver')
      resolved_ip = Resolv::IPv4.create(@static['ipAddress'])
      resolver.expects(:getaddress).with(hostname).returns(resolved_ip)
      spec = {:nameserver => [@static['primaryDns']], :search => Array(@static['dnsSuffix']), :ndots => 1}
      Resolv::DNS.expects(:open).with(spec).yields(resolver).returns(resolved_ip)
      @sd.lookup_hostname(hostname, @static).should == hostname
    end

    it 'should return the IP when host does not resolve' do
      hostname = 'host100'
      fqdn = "#{hostname}.#{@static['dnsSuffix']}"
      resolver = mock('resolver')
      resolver.expects(:getaddress).with(hostname).raises(Resolv::ResolvError.new)
      spec = {:nameserver => [@static['primaryDns']], :search => Array(@static['dnsSuffix']), :ndots => 1}
      Resolv::DNS.expects(:open).with(spec).yields(resolver)
      @sd.lookup_hostname(hostname, @static).should == @static['ipAddress']
    end

    it 'should return the IP when host resolves to a different IP' do
      hostname = 'host100'
      fqdn = "#{hostname}.#{@static['dnsSuffix']}"
      resolver = mock('resolver')
      resolved_ip = Resolv::IPv4.create('192.168.0.200')
      resolver.expects(:getaddress).with(hostname).returns(resolved_ip)
      spec = {:nameserver => [@static['primaryDns']], :search => Array(@static['dnsSuffix']), :ndots => 1}
      Resolv::DNS.expects(:open).with(spec).yields(resolver).returns(resolved_ip)
      @sd.lookup_hostname(hostname, @static).should == @static['ipAddress']
    end

    it "should not append the suffix when a fqdn is given" do
      hostname = "host100.my.com"
      fqdn = "host100.my.com"
      resolver = mock('resolver')
      resolved_ip = Resolv::IPv4.create('192.168.0.200')
      resolver.expects(:getaddress).with(fqdn).returns(resolved_ip)
      spec = {:nameserver => [@static['primaryDns']], :search => Array(@static['dnsSuffix']), :ndots => 1}
      Resolv::DNS.expects(:open).with(spec).yields(resolver).returns(resolved_ip)
      @sd.lookup_hostname(hostname, @static).should == @static['ipAddress']
    end
  end

  describe 'esxi version information' do

    it 'should return esxi version' do
      @endpoint = Hashie::Mash.new(endpoint)
      esx_version_out = SpecHelper.load_fixture("esxcli/system_version_get.txt")
      ASM::Util.stubs(:esxcli).returns(esx_version_out)
      @sd.esx_version(@endpoint).should == '5.1.0'
    end
  end

  describe 'iscsi hyperv deployment' do

    before do
      data = SpecHelper.json_fixture("Deployment_HyperV_iSCSI.json")
      @sd.components(data)
      @server_components = @sd.components_by_type('SERVER')
      @components = data['serviceTemplate']['components']
    end

    it 'should return card having iscsi networks' do
      @sd.hyperv_iscsi_fabric(@server_components[0]).should == [0]
    end

    it 'should return fabric id corresponding to the card' do
      @sd.get_iscsi_fabric(@server_components[0]).should == 'Fabric A'
    end

  end

  describe 'iscsi hyperv deployment with diverged fabric' do

    before do
      data = SpecHelper.json_fixture("Deployment_HyperV_iSCSI_DualFabric.json")
      @sd.components(data)
      @server_components = @sd.components_by_type('SERVER')
      @components = data['serviceTemplate']['components']
    end

    it 'should return card having iscsi networks' do
      @sd.hyperv_iscsi_fabric(@server_components[0]).should == [1]
    end

    it 'should return fabric id corresponding to the card' do
      @sd.get_iscsi_fabric(@server_components[0]).should == 'Fabric B'
    end
  end

  describe "#vds_name" do

    before do
      data = SpecHelper.json_fixture("Deployment_ESX_VDS_Input.json")
      @sd.components(data)
      @server_components = @sd.components_by_type('SERVER')
      @components = data['serviceTemplate']['components']
      @cert_name = "vcenter-vcenter-as800r.aidev.com"
      @existing_vds = { @cert_name =>
          {"vds_name::ff80808152d28d300152d29033790000:ff80808152d28d300152d29057150135" => "mnagementvds",
           "vds_pg::ff80808152d28d300152d29033790000:ff80808152d28d300152d29057150135::ff80808152d28d300152d29033790000::1" => "mgmtpxeVDS",
           "vds_pg::ff80808152d28d300152d29033790000:ff80808152d28d300152d29057150135::ff80808152d28d300152d29057150135::1" => "pxe",
           "vds_name::ff80808152d28d300152d290450a0069" => "vmotionVDS",
           "vds_pg::ff80808152d28d300152d290450a0069::ff80808152d28d300152d290450a0069::1" => "vmotion",
           "vds_name::ff80808152d28d300152d2904f9c00cf" => "iscsiVDS",
           "vds_pg::ff80808152d28d300152d2904f9c00cf::ff80808152d28d300152d2904f9c00cf::1" => "iscsi0",
           "vds_pg::ff80808152d28d300152d2904f9c00cf::ff80808152d28d300152d2904f9c00cf::2" => "iscsi1",
           "vds_name::ff80808152d28d300152d2905a410136" => "workloadVDS",
           "vds_pg::ff80808152d28d300152d2905a410136::ff80808152d28d300152d2905a410136::1" => "workload0"
          }
        }
    end

    it "should return vds name for matching network id" do
      mgmt_network = Hashie::Mash.new("id" => "ff80808152d28d300152d29033790000")
      @sd.vds_name([mgmt_network], @existing_vds, @cert_name).should == "mnagementvds"
    end
  end

  describe "#vds_portgroup" do

    before do
      data = SpecHelper.json_fixture("Deployment_ESX_VDS_Input.json")
      @sd.components(data)
      @server_components = @sd.components_by_type('SERVER')
      @components = data['serviceTemplate']['components']
      @cert_name = "vcenter-env08-vcenter"
      @existing_vds =
        { @cert_name =>
          {"vds_name::ff80808152d28d300152d29033790000:ff80808152d28d300152d29057150135" => "mnagementvds",
           "vds_pg::ff80808152d28d300152d29033790000:ff80808152d28d300152d29057150135::ff80808152d28d300152d29033790000::1" => "mgmt",
           "vds_pg::ff80808152d28d300152d29033790000:ff80808152d28d300152d29057150135::ff80808152d28d300152d29057150135::1" => "pxe",
           "vds_name::ff80808152d28d300152d290450a0069" => "vmotionVDS",
           "vds_pg::ff80808152d28d300152d290450a0069::ff80808152d28d300152d290450a0069::1" => "vmotion",
           "vds_name::ff80808152d28d300152d2904f9c00cf" => "iscsiVDS",
           "vds_pg::ff80808152d28d300152d2904f9c00cf::ff80808152d28d300152d2904f9c00cf::1" => "iscsi0",
           "vds_pg::ff80808152d28d300152d2904f9c00cf::ff80808152d28d300152d2904f9c00cf::2" => "iscsi1",
           "vds_name::ff80808152d28d300152d2905a410136::ff80808152d28d300152d2905a410137" => "workloadVDS",
           "vds_pg::ff80808152d28d300152d2905a410136:ff80808152d28d300152d2905a410137::ff80808152d28d300152d2905a410136::1" => "workload1",
           "vds_pg::ff80808152d28d300152d2905a410136:ff80808152d28d300152d2905a410137::ff80808152d28d300152d2905a410137::2" => "workload2"
          }
        }
    end

    it "should return workload vds port group name when existing workload network is defined" do
      portgroup_type = :workload
      network1 = Hashie::Mash.new(:name => 'Workload-22', :vlanId => 22, :type => 'PUBLIC_LAN', :id => "ff80808152d28d300152d2905a410136")
      @sd.vds_portgroup_names(@cert_name, @existing_vds, [network1]).should == ["workload1"]
    end

    it "should return workload vds port group name when multiple existing workload network is defined" do
      portgroup_type = :workload

      network1 = Hashie::Mash.new(:name => 'Workload-22', :vlanId => 22, :type => 'PUBLIC_LAN', :id => "ff80808152d28d300152d2905a410136")
      network2 = Hashie::Mash.new(:name => 'Workload-24', :vlanId => 24, :type => 'PUBLIC_LAN', :id => "ff80808152d28d300152d2905a410137")
      @sd.vds_portgroup_names(@cert_name, @existing_vds, [network1,network2]).should == ["workload1", "workload2"]
    end

    it "should return management vds port group name when existing management vds is defined" do
      portgroup_type = :management

      network1 = Hashie::Mash.new(:name => 'hv_management', :vlanId => 28, :type => 'HYPERVISOR_MANAGEMENT', :id => "ff80808152d28d300152d29033790000")
      @sd.vds_portgroup_names(@cert_name, @existing_vds,[network1]).should == ["mgmt"]
    end

    it "should return migration vds port group name when existing migration vds is defined" do
      portgroup_type = :migration

      network1 = Hashie::Mash.new(:name => 'vmotion', :vlanId => 23, :type => 'HYPERVISOR_MIGRATION', :id => "ff80808152d28d300152d290450a0069")
      @sd.vds_portgroup_names(@cert_name, @existing_vds,[network1]).should == ["vmotion"]
    end

    it "should return multiple iscsi vds port group names when existing migration vds are defined" do
      portgroup_type = :storage

      network1 = Hashie::Mash.new(:name => 'iscsi_network', :vlanId => 16, :type => 'STORAGE_ISCSI_SAN', :id => "ff80808152d28d300152d2904f9c00cf")
      @sd.vds_portgroup_names(@cert_name,@existing_vds,[network1]).should == ["iscsi0", "iscsi1"]
    end
  end

  describe "#enable_razor_boot" do
    let(:wsman) { mock("rspec-endpoint") }
    let(:serial_number) { "RSPEC-SERIAL" }
    let(:mac_address) {"00:8c:fa:f1:cc:b7"}
    let(:network_config) { mock("rspec-network-config") }
    let(:razor) {@razor}

    before(:each) do
      @sd.unstub(:enable_razor_boot)
    end

    it "should fail if no PXE partitions available" do
      network_config.expects(:get_partitions).with("PXE").returns([])
      err = "No OS Installation networks available"
      expect { @sd.enable_razor_boot(serial_number, network_config) }.to raise_error(err)
    end

    it "should check in the node" do
      razor.expects(:find_node).with(serial_number).returns("name" => "node3")
      network_config.expects(:get_partitions).with("PXE").returns([stub(:mac_address => mac_address)])
      razor.expects(:checkin_node).with("node3", [mac_address], {:serialnumber => serial_number})
      @sd.enable_razor_boot(serial_number, network_config)
    end

    it "should reuse existing facts if present" do
      facts = {:foo => "foo"}
      razor.expects(:find_node).with(serial_number).returns("name" => "node3", "facts" => facts)
      network_config.expects(:get_partitions).with("PXE").returns([stub(:mac_address => mac_address)])
      razor.expects(:checkin_node).with("node3", [mac_address], facts)
      @sd.enable_razor_boot(serial_number, network_config)
    end

    it "should register the node if doesn't exist" do
      razor.expects(:find_node).with(serial_number).returns(nil)
      razor.expects(:register_node)
           .with(:mac_addresses => [mac_address], :serial => serial_number, :installed => false)
           .returns("name" => "node7")
      razor.expects(:get).with("nodes", "node7").returns("name" => "node7")
      network_config.expects(:get_partitions).with("PXE").returns([stub(:mac_address => mac_address)])
      razor.expects(:checkin_node).with("node7", [mac_address], {:serialnumber => serial_number})
      @sd.enable_razor_boot(serial_number, network_config)
    end

    it "should fail if it can't find the node it registered" do
      razor.expects(:find_node).with(serial_number).returns(nil)
      response = {"name"=>"node7"}
      razor.expects(:register_node)
          .with(:mac_addresses => [mac_address], :serial => serial_number, :installed => false)
          .returns(response)
      razor.expects(:get).with("nodes", "node7").returns(nil)
      network_config.expects(:get_partitions).with("PXE").returns([stub(:mac_address => mac_address)])
      err = "Failed to register node for %s. Register_node response was: %s" % [serial_number, response]
      expect {@sd.enable_razor_boot(serial_number, network_config)}.to raise_error(err)
    end
  end

  describe "#enable_pxe" do
    let(:wsman) { stub(:host => "rspec-ip", :nic_views => [0, 1, 2, 3]) }
    let(:network_config) { mock("rspec-network-config") }

    before(:each) do
      @sd.unstub(:enable_pxe)
    end

    it "should fail if no PXE partitions are found" do
      network_config.expects(:get_partitions).with("PXE").returns([])
      expect { @sd.enable_pxe(network_config, wsman) }.to raise_error("No PXE partition found for O/S installation")
    end

    it "should boot ipxe ISO if server only has Intel NICs" do
      partition = stub(:fqdd => "rspec-nic-fqdd")
      network_config.expects(:get_partitions).with("PXE").returns([partition])
      network_config.expects(:get_network).with("PXE").returns(stub(:static => true))

      wsman.expects(:client).returns(stub(:endpoint => endpoint))
      ASM::NetworkConfiguration::NicInfo.expects(:fetch).returns([stub(:disabled? => false, :ports => [stub(:vendor => :intel)])])

      ASM::IpxeBuilder.expects(:build).with(network_config, 4, "/var/lib/razor/repo-store/asm/generated/ipxe-rspec-ip.iso")
      wsman.expects(:boot_rfs_iso_image).with(:uri => "smb://guest:guest@localhost/razor/asm/generated/ipxe-rspec-ip.iso",
                                              :reboot_job_type => :power_cycle)
      @sd.enable_pxe(network_config, wsman)
    end

    it "should boot ipxe ISO if server only has enabled Intel NICs" do
      partition = stub(:fqdd => "rspec-nic-fqdd")
      network_config.expects(:get_partitions).with("PXE").returns([partition])
      network_config.expects(:get_network).with("PXE").returns(stub(:static => true))

      wsman.expects(:client).returns(stub(:endpoint => endpoint))
      cards = [stub(:disabled? => true, :ports => [stub(:vendor => :qlogic  )]),
               stub(:disabled? => false, :ports => [stub(:vendor => :intel)])]
      ASM::NetworkConfiguration::NicInfo.expects(:fetch).returns(cards)

      ASM::IpxeBuilder.expects(:build).with(network_config, 4, "/var/lib/razor/repo-store/asm/generated/ipxe-rspec-ip.iso")
      wsman.expects(:boot_rfs_iso_image).with(:uri => "smb://guest:guest@localhost/razor/asm/generated/ipxe-rspec-ip.iso",
                                              :reboot_job_type => :power_cycle)
      @sd.enable_pxe(network_config, wsman)
    end

    it "should fail if static OS installation requested on server without Intel NICs" do
      partition = stub(:fqdd => "rspec-nic-fqdd")
      network_config.expects(:get_partitions).with("PXE").returns([partition])
      network_config.expects(:get_network).with("PXE").returns(stub(:static => true))

      wsman.expects(:client).returns(stub(:endpoint => endpoint))
      ASM::NetworkConfiguration::NicInfo.expects(:fetch).returns([stub(:disabled? => false, :ports => [stub(:vendor => :qlogic)])])

      expect { @sd.enable_pxe(network_config, wsman) }.to raise_error("Static OS installation is only supported on servers with all Intel NICs")
    end

    it "should boot from NIC otherwise" do
      partition = stub(:fqdd => "rspec-nic-fqdd")
      network_config.expects(:get_partitions).with("PXE").returns([partition])
      network_config.expects(:get_network).with("PXE").returns(stub(:static => false))

      wsman.expects(:client).returns(stub(:endpoint => endpoint))
      ASM::NetworkConfiguration::NicInfo.expects(:fetch).returns([stub(:disabled? => false, :ports => [stub(:vendor => :qlogic)])])

      wsman.expects(:set_boot_order).with("rspec-nic-fqdd", :reboot_job_type => :power_cycle)
      @sd.enable_pxe(network_config, wsman)
    end

    it "should retry set boot order command if deployment fails due to time out" do
       partition = stub(:fqdd => "rspec-nic-fqdd")
       network_config.expects(:get_partitions).with("PXE").returns([partition])
       network_config.expects(:get_network).with("PXE").returns(stub(:static => false))

       wsman.expects(:client).returns(stub(:endpoint => endpoint))
       ASM::NetworkConfiguration::NicInfo.expects(:fetch).returns([stub(:disabled? => false, :ports => [stub(:vendor => :qlogic)])])

       wsman.expects(:set_boot_order).with("rspec-nic-fqdd", :reboot_job_type => :power_cycle)
           .twice
           .raises("Deployment failed")
           .returns(:status => "success")

       @sd.stubs(:sleep)
       @sd.enable_pxe(network_config, wsman)
    end

    it "should fail if set boot order command fails twice" do
      partition = stub(:fqdd => "rspec-nic-fqdd")
      network_config.expects(:get_partitions).with("PXE").returns([partition])
      network_config.expects(:get_network).with("PXE").returns(stub(:static => false))

      wsman.expects(:client).returns(stub(:endpoint => endpoint))
      ASM::NetworkConfiguration::NicInfo.expects(:fetch).returns([stub(:disabled? => false, :ports => [stub(:vendor => :qlogic)])])

      wsman.expects(:set_boot_order).with("rspec-nic-fqdd", :reboot_job_type => :power_cycle) .twice
             .raises("Deployment failed")
      @sd.stubs(:sleep)
      expect { @sd.enable_pxe(network_config, wsman) }.to raise_error
    end
  end

  describe "#disable_pxe" do
    let (:wsman) { stub("rspec-endpoint", :client => stub(:host => "rspec-host")) }

    before(:each) do
      @sd.unstub(:disable_pxe)
    end

    it "should set hdd in the boot order" do
      wsman.expects(:set_boot_order).with(:hdd, :reboot_job_type => :graceful_with_forced_shutdown)
      wsman.expects(:rfs_iso_image_connection_info).returns(:return_value => "1")
      @sd.disable_pxe(wsman)
    end

    it "should disconnect the RFS ISO if connected" do
      wsman.expects(:set_boot_order).with(:hdd, :reboot_job_type => :graceful_with_forced_shutdown)
      wsman.expects(:rfs_iso_image_connection_info).returns(:return_value => "0")
      wsman.expects(:disconnect_rfs_iso_image)
      @sd.disable_pxe(wsman)
    end

    it "should retry set boot order command" do
      wsman.expects(:set_boot_order).with(:hdd, :reboot_job_type => :graceful_with_forced_shutdown)
          .twice
          .raises("Deployment failed")
          .returns(:status => "success")
      wsman.expects(:rfs_iso_image_connection_info).returns(:return_value => "1")
      @sd.stubs(:sleep)
      @sd.disable_pxe(wsman)
    end

    it "should fail if set boot order command fails twice" do
      wsman.expects(:set_boot_order).with(:hdd, :reboot_job_type => :graceful_with_forced_shutdown)
          .twice
          .raises("Deployment failed")
      @sd.stubs(:sleep)
      expect { @sd.disable_pxe(wsman) }.to raise_error
    end
  end

  describe "#esxi_merge_iscsi_teams" do
    let(:network_config) { mock("rspec-network-config") }
    let(:mgmt_network) { Hashie::Mash.new({:id => "mgmt_network", "name"=>"HypervisorManagement", "type"=>"HYPERVISOR_MANAGEMENT"})}
    let(:vmotion_network) { Hashie::Mash.new({:id => "vmotion_network", "name"=>"LiveMigration", "type"=>"HYPERVISOR_MIGRATION"})}
    let(:workload_network) { Hashie::Mash.new({:id => "workload_network", "name"=>"Workload", "type"=>"PUBLIC_LAN"})}
    let(:iscsi1) {Hashie::Mash.new({:id => "iscsi1", "name"=>"iscsi1", "type"=>"STORAGE_ISCSI_SAN"})}
    let(:iscsi2) {Hashie::Mash.new({:id => "iscsi2", "name"=>"iscsi2", "type"=>"STORAGE_ISCSI_SAN"})}

    let(:nic_team)  {
      [{:networks => [mgmt_network], :mac_addresses => ['mac1']},
                          {:networks => [vmotion_network], :mac_addresses => ['mac2']}]
    }
    let(:nic_team_1)  {
      [{:networks => [mgmt_network], :mac_addresses => ['mac1']},
       {:networks => [vmotion_network], :mac_addresses => ['mac2']},
       {:networks => [iscsi1, iscsi2], :mac_addresses => ['mac3', 'mac4']}]
    }

    let(:nic_team_2)  {
      [{:networks => [mgmt_network], :mac_addresses => ['mac1']},
       {:networks => [vmotion_network], :mac_addresses => ['mac2']},
       {:networks => [iscsi1], :mac_addresses => ['mac3']},
       {:networks => [iscsi2], :mac_addresses => ['mac4']}]
    }
    it "should return nic team if there is not iscsi network" do
      team = @sd.esxi_merge_iscsi_teams(nic_team)
      team.should be(nic_team)
    end

    it "should return nic team if there is single nic team for iscsi network" do
      team = @sd.esxi_merge_iscsi_teams(nic_team_1)
      team.should be(nic_team_1)
    end

    it "should return updated nic team if there is multiple nic team for iscsi network" do
      team = @sd.esxi_merge_iscsi_teams(nic_team_2)
      team.size.should be(3)
    end
  end

  describe "#esxi_merge_team_mac" do
    let(:network_config) { mock("rspec-network-config") }
    let(:mgmt_network) { Hashie::Mash.new({:id => "mgmt_network", "name"=>"HypervisorManagement", "type"=>"HYPERVISOR_MANAGEMENT"})}
    let(:vmotion_network) { Hashie::Mash.new({:id => "vmotion_network", "name"=>"LiveMigration", "type"=>"HYPERVISOR_MIGRATION"})}
    let(:workload_network) { Hashie::Mash.new({:id => "workload_network", "name"=>"Workload", "type"=>"PUBLIC_LAN"})}
    let(:iscsi1) {Hashie::Mash.new({:id => "iscsi1", "name"=>"iscsi1", "type"=>"STORAGE_ISCSI_SAN"})}
    let(:iscsi2) {Hashie::Mash.new({:id => "iscsi2", "name"=>"iscsi2", "type"=>"STORAGE_ISCSI_SAN"})}

    let(:nic_team)  {
      [{:networks => [mgmt_network, vmotion_network, workload_network], :mac_addresses => ['mac1', 'mac2']},
       {:networks => [iscsi1], :mac_addresses => ['mac1']},
       {:networks => [iscsi2], :mac_addresses => ['mac2']}]
    }

    let(:nic_team_1)  {
      [{:networks => [mgmt_network, vmotion_network, workload_network], :mac_addresses => ['mac1', 'mac2']},
       {:networks => [iscsi1], :mac_addresses => ['mac3']},
       {:networks => [iscsi2], :mac_addresses => ['mac4']}]
    }

    let(:nic_team_2)  {
      [{:networks => [mgmt_network, vmotion_network, workload_network], :mac_addresses => ['mac1', 'mac2']},
       {:networks => [iscsi1], :mac_addresses => ['mac3', 'mac4']},
       ]
    }

    let(:nic_team_3)  {
      [{:networks => [mgmt_network], :mac_addresses => ['mac1', 'mac2']},
       {:networks => [vmotion_network], :mac_addresses => ['mac3', 'mac4']},
       {:networks => [workload_network], :mac_addresses => ['mac5', 'mac6']},
       {:networks => [iscsi1], :mac_addresses => ['mac7', 'mac8']},
      ]
    }

    let(:nic_team_4)  {
      [{:networks => [mgmt_network], :mac_addresses => ['mac1', 'mac2']},
       {:networks => [vmotion_network], :mac_addresses => ['mac3', 'mac4']},
       {:networks => [workload_network], :mac_addresses => ['mac5', 'mac6']},
       {:networks => [iscsi1], :mac_addresses => ['mac7']},
       {:networks => [iscsi2], :mac_addresses => ['mac8']}]
    }

    it "should return updated nic team if iscsi network have common mac address as management nic team" do
      team = @sd.esxi_merge_team_mac(nic_team)
      team.size.should be(1)
    end

    it "should return un-modified nic team if iscsi network have different mac address as management nic team" do
      team = @sd.esxi_merge_team_mac(nic_team_1)
      team.size.should be(3)
    end

    it "should return un-modified nic team if iscsi network have different mac address as management nic team" do
      team = @sd.esxi_merge_team_mac(nic_team_2)
      team.size.should be(2)
    end

    it "should return un-modified nic team if iscsi network have different mac address as management nic team" do
      team = @sd.esxi_merge_team_mac(nic_team_3)
      team.size.should be(4)
    end

    it "should return un-modified nic team if iscsi network have different mac address as management nic team" do
      team = @sd.esxi_merge_team_mac(nic_team_4)
      team.size.should be(5)
    end
  end

  describe "#gather_vswitch_info" do
    let(:mgmt_network) { Hashie::Mash.new({:id => "mgmt_network", "name"=>"HypervisorManagement", "type"=>"HYPERVISOR_MANAGEMENT"})}
    let(:vmotion_network) { Hashie::Mash.new({:id => "vmotion_network", "name"=>"LiveMigration", "type"=>"HYPERVISOR_MIGRATION"})}
    let(:workload_network) { Hashie::Mash.new({:id => "workload_network", "name"=>"Workload", "type"=>"PUBLIC_LAN"})}
    let(:iscsi1) {Hashie::Mash.new({:id => "iscsi1", "name"=>"iscsi1", "type"=>"STORAGE_ISCSI_SAN"})}
    let(:iscsi2) {Hashie::Mash.new({:id => "iscsi2", "name"=>"iscsi2", "type"=>"STORAGE_ISCSI_SAN"})}

    it "should put portgroups from a single nic team in proper order" do
      net_config = mock("rspec-network-config")
      nic_team = [{:networks => [workload_network, iscsi1, iscsi2, vmotion_network, mgmt_network]}]
      net_config.stubs(:teams).returns(nic_team)
      vswitches = @sd.gather_vswitch_info(net_config)
      vswitches.size.should be(1)
      vswitches.first.keys.should eql([:management, :migration, :workload, :storage])
    end

    it "should put portgroups in separate nic teams in proper order" do
      net_config = mock("rspec-network-config")
      nic_team = [{:networks => [iscsi1, iscsi2]},
                  {:networks => [workload_network]},
                  {:networks => [mgmt_network]},
                  {:networks => [vmotion_network]}]
      net_config.stubs(:teams).returns(nic_team)
      vswitches = @sd.gather_vswitch_info(net_config)
      vswitches.size.should be(4)
      vswitches.collect { |vswitch| vswitch.keys }.should eql([[:management], [:migration], [:workload], [:storage]])
    end
  end

  describe "#finalize_deployment" do
    let(:deployment_db) { mock("db")}
    let(:deployment) { ASM::ServiceDeployment.new("finalize_deployment_test", deployment_db)}

    before(:each) do
      deployment.stubs(:service_hash).returns({"deploymentName" => "mock_deployment"})
      deployment.stubs(:components).returns(
          [{"id" => "component1", "teardown" => false},
           {"id" => "component2", "teardown" => false},
           {"id" => "component3", "teardown" => true}])

      deployment_db.stubs(:remove_component)
    end

    it "should set deployment status to complete if no components failed" do
      deployment_db.stubs(:get_component_status).returns({:status => "complete"})
      deployment_db.expects(:log).with(:info, "Deployment mock_deployment completed")
      deployment_db.expects(:set_status).with(:complete)
      deployment.finalize_deployment
    end

    it "should set deployment status to error if any components failed" do
      deployment_db.stubs(:get_component_status).returns({:status => "complete"}, {:status => "error"})
      deployment_db.expects(:log).with(:error, "mock_deployment deployment failed")
      deployment_db.expects(:set_status).with(:error)
      deployment.finalize_deployment
    end

    it "should remove a torn down component and not use it for status" do
      deployment_db.stubs(:get_component_status).returns({:status => "complete"}, {:status => "complete"}, {:status => "error"})
      deployment_db.expects(:log).with(:info, "Deployment mock_deployment completed")
      deployment_db.expects(:set_status).with(:complete)
      deployment_db.expects(:remove_component).with("component3")
      deployment.finalize_deployment
    end
  end

  describe "#process_storage_vnx" do

    before do
      FileUtils.mkdir_p("#{@tmp_dir}/8000/resources")
      o_file = "#{@tmp_dir}/8000/vnx-apm00132402069.out"
      r_file = "#{@tmp_dir}/8000/resources/vnx-apm00132402069.yaml"

      File.open( "#{@tmp_dir}/8000/vnx-apm00132402069.out", 'w') do |fh|
        fh.write('Results: For 0 resources. 0 from our run failed. 0 not from our run failed. 0 updated successfully.')
      end
      @sd.stubs(:iterate_file).with(o_file).returns(o_file)
      @sd.stubs(:iterate_file).with(r_file).returns(r_file)
      @sd.stubs(:iterate_file).with(@json_file).returns(@json_file)
      ASM::DeviceManagement.stubs(:run_puppet_device!).returns({})
      ASM::DeviceManagement.stubs(:puppet_run_success?).returns([true, "rspec simulated success"])
      ASM::Util.stubs(:run_command_streaming).with(
          "sudo puppet asm process_node --debug --trace --filename #{r_file} --run_type apply --statedir #{@tmp_dir}/8000/resources --always-override vnx-apm00132402069", "#{o_file}")
    end
    let(:all_components) {[
        {'id' => 'k1',
         'puppetCertName' => 'vnx-apm00132402069',
         'asmGUID' => 'vnx-1.1.1.1',
         'componentID'=>'s1',
         'type' => 'STORAGE',
         'resources' => [{
                             'id' => 'asm::volume::vnx',
                             'parameters' => [
                                 {'id' => 'title', 'value' => 'vol1'},
                                 {'id' => 'pool', 'value' => 'Pool 0'},
                                 {'id' => 'size', 'value' => '100GB'},
                                 {'id' => 'type', 'value' => 'nonthin'},
                                 {'id' => 'folder', 'value' => ''},
                                 {'id' => 'ensure', 'value' => 'present'}
                             ]
                         }]
        },
        {'id' => 'k2',
         'puppetCertName' => 'vnx-apm00132402069',
         'asmGUID' => 'vnx-1.1.1.1',
         'componentID'=>'s1',
         'type' => 'STORAGE',
         'resources' => [{
                             'id' => 'asm::volume::vnx',
                             'parameters' => [
                                 {'id' => 'title', 'value' => 'vol2'},
                                 {'id' => 'pool', 'value' => 'Pool 0'},
                                 {'id' => 'size', 'value' => '200GB'},
                                 {'id' => 'type', 'value' => 'nonthin'},
                                 {'id' => 'folder', 'value' => ''},
                                 {'id' => 'ensure', 'value' => 'present'}
                             ]
                         }]
        },
    ]}
    let(:server_components) {
      [
        {
          "id" => "server1",
          "type" => "SERVER",
          "puppetCertName" => "server-cert-1",
          "relatedComponents" => {},
          "resources" => [
              {"id" => "asm::server", "parameters" => [
                  {"id" => "title", "value" => "server-cert-1"},
                  {"id" => "os_host_name", "value" => "server1"}]},
              {"id" => "asm::idrac",
               "parameters" =>
                 [
                   {"id" => "title", "value" => "server-cert-1"},
                   {"id" => "migrate_on_failure", "value" => "true", "type" => "BOOLEAN"}
                 ]
              }
          ]
        },
        {
          "id" => "server-1",
          "type" => "SERVER",
          "puppetCertName" => "server-cert-2",
          "relatedComponents" => {},
          "resources" => [
              {"id" => "asm::server", "parameters" => [
                  {"id" => "title", "value" => "server-cert-2"},
                  {"id" => "os_host_name", "value" => "server2"}]},
              {"id" => "asm::idrac",
               "parameters" =>
                 [
                   {"id" => "title", "value" => "server-cert-2"},
                   {"id" => "migrate_on_failure", "value" => "true", "type" => "BOOLEAN"}
                 ]
              },
          ]
        }
      ]
    }

    let(:volume_hash) {{"asm::volume::vnx"=>
                            {"vol1"=>
                                 {"pool"=>"Pool 0",
                                  "size"=>"100GB",
                                  "type"=>"nonthin",
                                  "folder"=>"",
                                  "ensure"=>"present"},
                             "vol2"=>
                                 {"pool"=>"Pool 0",
                                  "size"=>"200GB",
                                  "type"=>"nonthin",
                                  "folder"=>"",
                                  "ensure"=>"present"}}}}

    let(:host_access_hash) {[{"asm::volume::vnx"=>
                                  {"vol1"=>
                                       {"pool"=>"Pool 0",
                                        "size"=>"100GB",
                                        "type"=>"nonthin",
                                        "folder"=>"",
                                        "ensure"=>"present",
                                        "host_name"=>"server1",
                                        "sgname"=>"ASM-8000",
                                        "luns"=>[{"hlu"=>0, "alu"=>"1"},
                                                 {"hlu"=>1, "alu"=>"2"}]}}},
                             {"asm::volume::vnx"=>
                                  {"vol1"=>
                                       {"pool"=>"Pool 0",
                                        "size"=>"100GB",
                                        "type"=>"nonthin",
                                        "folder"=>"",
                                        "ensure"=>"present",
                                        "host_name"=>"server2",
                                        "sgname"=>"ASM-8000",
                                        "luns"=>[{"hlu"=>0, "alu"=>"1"},
                                                 {"hlu"=>1, "alu"=>"2"}]}}}]}

    it "#vnx_volume_create size exists in input" do
      @sd.stubs(:components).returns(all_components)
      @sd.stubs(:vnx_components).returns(all_components)
      @sd.stubs(:find_related_components).returns([])

      @sd.vnx_create_volume(all_components[0])
      @sd.expects(:process_generic).with(all_components[0]['puppetCertName'], volume_hash, 'apply', true, nil, all_components[0]['asmGUID']).at_most(2)
    end

    it "#vnx_volume_create size do not exists in input" do
      comp_withoutsize = all_components.dup
      comp_withoutsize.each {|x| x['resources'].each { |y| y['parameters'].delete_if {|z| z['id'] == 'size'} } }
      @sd.stubs(:components).returns(comp_withoutsize)
      @sd.stubs(:vnx_components).returns(comp_withoutsize)
      @sd.stubs(:find_related_components).returns([])
      ASM::PrivateUtil.stubs(:update_vnx_resource_hash).returns(volume_hash)

      @sd.expects(:process_generic).with(all_components[0]['puppetCertName'], volume_hash, 'apply', true, nil, all_components[0]['asmGUID']).at_most(2)
    end

    it "#vnx_host_access_configuration when luns are not added to the storage group" do
      @sd.stubs(:find_related_components).returns(server_components)
      @sd.stubs(:vnx_components).returns(all_components)
      ASM::PrivateUtil.stubs(:is_host_connected_to_vnx).returns(true)
      ASM::PrivateUtil.stubs(:get_vnx_lun_id).with('vnx-1.1.1.1', 'vol1', @sd.logger).returns('1')
      ASM::PrivateUtil.stubs(:get_vnx_lun_id).with('vnx-1.1.1.1', 'vol2', @sd.logger).returns('2')
      @sd.stubs(:host_lun_info).returns(nil)

      @sd.vnx_host_access_configuration(all_components[0])
      @sd.expects(:process_generic).with(all_components[0]['puppetCertName'], host_access_hash, 'apply', true, nil, all_components[0]['asmGUID']).at_most(4)
    end

  end
end

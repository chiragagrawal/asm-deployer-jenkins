require 'spec_helper'
require 'asm/update_deployment'
require 'asm/deployment_teardown'
require 'asm'
require 'tmpdir'

describe ASM::UpdateDeployment do

  before do
    ASM.init_for_tests
    @test_dir = Dir.mktmpdir('update_deployment_spec')
    FileUtils.cp_r(File.expand_path('../../../fixtures/deployments', __FILE__), @test_dir)
    ASM.stubs(:base_dir).returns("#{@test_dir}/deployments")
    ASM::PrivateUtil.stubs(:reserve_network_ips).returns(['172.23.119.2'])
    ASM::PrivateUtil.stubs(:fetch_managed_inventory).returns([])
    mock_command_result = Hashie::Mash.new({
      'stdout' => '', 'stderr' => '', 'exit_status' => 0, 'pid' => 0
    })
    ASM::Util.stubs(:run_command_simple).returns(mock_command_result)
    ASM::Util.stubs(:run_command_success).returns(mock_command_result)
    ASM::Util.stubs(:run_command)
    populate_blade_switch_hash = {
      "dell_iom-172.17.15.234"=>
        {"connection_url"=>nil,
         "device_type"=>"dell_powerconnect"
        },
      "dell_iom-172.17.15.237"=>
        {"connection_url"=>nil,
         "device_type"=>"dell_powerconnect"}
    }
    ASM::ServiceDeployment.any_instance.stubs(:populate_blade_switch_hash).returns(populate_blade_switch_hash)
    ASM::PrivateUtil.stubs(:fetch_server_inventory).returns({"serverType"=>"BLADE","serviceTag"=>"1FQSGT1","model"=>"PowerEdge M620"})
    ASM::ServiceDeployment.any_instance.stubs(:process_tor_switches).returns(nil)
    ASM::ServiceDeployment.any_instance.stubs(:process_san_switches).returns(nil)
    ASM::ServiceDeployment.any_instance.stubs(:process_components).returns(nil)
    ASM::ServiceDeployment.any_instance.stubs(:reboot_all_servers).returns(nil)
    ASM::ServiceDeployment.any_instance.stubs(:is_fcoe_enabled).returns(false)

    mock = mock('deployment_data')
    mock.stub_everything
    ASM::Data::Deployment.stubs(:new).returns(mock)
  end

  after do
    ASM.reset
    FileUtils.rm_rf(@test_dir)
  end

  it 'should be able to update a deployment' do
    deployment_id = 'ff808081452c813b01453c4b14e80751'
    dir = File.join(ASM::base_dir, deployment_id)
    deployment_file = dir + "/deployment.json"
    deployment = JSON.parse(File.read(deployment_file))
    deployment['debug'] = 'true'
    ASM.stubs(:database).returns(mock("database"))
    ASM.retry_deployment('ff808081452c813b01453c4b14e80751', deployment)

    # deployment is async w.r.t. ASM.retry_deployment; wait a bit for it to kick off...
    20.times do |i|
      sleep 0.5
      break if File.exist?(deployment_file)
    end

    deployment = JSON.parse(File.read(deployment_file))
    deployment['jobStatus'].should eq('SUCCESSFUL')
  end

  it 'should be able to find previous deployments' do
    deployment_id = 'ff808081452c813b01453c4b14e80751'
    dir = File.join(ASM::base_dir, deployment_id)
    Dir.mkdir("#{dir}/1")
    FileUtils.cp("#{dir}/deployment.json", "#{dir}/1/deployment.json")
    ASM::DeploymentTeardown.get_previous_deployment_certs('ff808081452c813b01453c4b14e80751').should eq(['agent-devlinuxhost1'])
  end

end

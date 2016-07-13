require 'spec_helper'
require 'asm/deployment_teardown'
require 'asm'

describe ASM::DeploymentTeardown do

  before do
    ASM.init_for_tests
    @id = '123'
    @names = ["agent-winbaremetal", "agent-gs1vmwin1", "agent-gs1vmwin2", "agent-gs1vmlin1", "agent-gs1vmlin2"]

    data = SpecHelper.json_fixture("deployment_teardown_test.json")
    ASM::DeploymentTeardown.stubs(:deployment_data).with(@id).returns(data)

    @data = SpecHelper.json_fixture("deployment_teardown_test.json")
  end

  after do
    ASM.reset
  end

  it 'should be able to find certs' do
    certs = ASM::DeploymentTeardown.get_deployment_certs(@data)
    certs.should == ["agent-winbaremetal", "agent-gs1vmwin1", "agent-gs1vmwin2", "agent-gs1vmlin1", "agent-gs1vmlin2"]
  end

  it 'should be able to deactivate nodes' do
    ASM::Util.expects(:run_command_success).
      with('sudo puppet node deactivate agent-winbaremetal agent-gs1vmwin1 agent-gs1vmwin2 agent-gs1vmlin1 agent-gs1vmlin2').
      returns({'exit_status' => 0})

    ASM::DeploymentTeardown.clean_puppetdb_nodes(@names)
  end

  #Puppet deactivate will always send a request to puppetdb to deactivate node, so no real error can be tested

  it 'should be able to return a list of puppet nodes/certs deactivated/cleared' do
    name_string = "agent-winbaremetal agent-gs1vmwin1 agent-gs1vmwin2 agent-gs1vmlin1 agent-gs1vmlin2"

    ASM::DeploymentTeardown.expects(:get_deployment_certs).with(@data).returns(@names)

    ASM::PrivateUtil.expects(:get_puppet_certs).returns(@names)
    @names.each do |name|
      ASM::DeviceManagement.expects(:remove_device).with(name, @names)
    end

    ASM::DeploymentTeardown.clean_deployment(@id)
  end

end

require 'asm/private_util'
require 'spec_helper'
require 'tempfile'
require 'json'
require 'asm'

describe ASM::Util do

  # TODO: test invalid device config files

  # TODO: test idrac resource configuration

  describe 'when data is valid' do
    it 'should produce component configuration data' do
      deployment = SpecHelper.json_fixture("dellworld_template.json")['serviceTemplate']

      # Check a server component
      component = deployment['components'][1]
      title = component['id']

      config = {}
      resources = ASM::Util.asm_json_array(component['resources'])
      resources.each do |resource|
        config = ASM::PrivateUtil.append_resource_configuration!(resource, config, :title => title)
      end

      config.keys.size.should == 2
      config['asm::idrac'].size.should == 1
      title = config['asm::idrac'].keys[0]
      config['asm::idrac'][title]['target_boot_device'].should == 'SD'
      config['asm::server'].size.should == 1
      title = config['asm::server'].keys[0]
      config['asm::server'][title]['razor_image'].should == 'esxi-5.1'


      # Check a cluster component
      component = deployment['components'][3]
      resources = ASM::Util.asm_json_array(component['resources'])
      title = component['id']
      resources.each do |resource|
        config = ASM::PrivateUtil.append_resource_configuration!(resource, {}, :title => title)
      end

      config.keys.size.should == 1
      title = config['asm::cluster'].keys[0]
      config['asm::cluster'][title]['cluster'].should == 'dwcluster'
    end
  end

  describe 'when hosts already deployed' do
    it 'should return hosts if they are already deployed' do
      ASM.stubs(:block_hostlist).returns([])
      ASM::PrivateUtil.stubs(:get_puppet_certs).returns(['server1','server2'])
      ASM::PrivateUtil.check_host_list_against_previous_deployments(['server1','server2', 'server3']).should == ['server1','server2']
      ASM::PrivateUtil.unstub(:get_puppet_certs)
    end
  end

  it 'should return just host names from puppet cert list all' do
    ASM.init_for_tests
    result =  Hashie::Mash.new({"stdout"=>"+ \"dell_ftos-172.17.15.234\" (SHA256) 1C:DB:87:DA:4B:BF:92:A6:0F:71:F1:EE:BC:0B:31:75:0D:BF:58:14:CE:3B:A2:34:E7:72:BF:7E:AB:BD:07:9A\n+ \"dell_ftos-172.17.15.237\" (SHA256) A5:C1:95:ED:48:AF:65:F6:A3:D7:85:B8:6B:E7:C0:20:29:02:97:6D:CB:F3:A3:67:92:CC:E7:68:E7:96:EC:94\n+ \"dellasm\"                 (SHA256) 16:C0:9F:0B:04:22:58:74:BC:3F:DB:F8:DC:8B:D7:E5:2C:2E:1D:52:BA:69:BF:AF:93:95:FE:71:D9:5F:E5:1F (alt names: \"DNS:dellasm\", \"DNS:dellasm.aus.amer.dell.com\", \"DNS:puppet\")\n+ \"equallogic-172.17.15.10\" (SHA256) 21:2A:62:83:51:93:FB:A7:6F:97:30:C0:3C:97:7F:81:6E:65:36:C8:51:AA:6A:93:2E:BA:6A:AC:D2:C5:0D:E1\n", "stderr"=>"", "pid"=>3170, "exit_status"=>0})
    ASM::Util.stubs(:run_command_success).returns(result)
    ASM::PrivateUtil.get_puppet_certs.should == ["dell_ftos-172.17.15.234", "dell_ftos-172.17.15.237", "dellasm", "equallogic-172.17.15.10"]
    ASM.reset
  end

end

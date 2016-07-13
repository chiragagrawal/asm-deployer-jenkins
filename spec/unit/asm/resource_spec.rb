require 'spec_helper'
require 'rbvmomi'
require 'asm/resource'

describe ASM::Resource::VM do

  it 'reject bad VMs' do
    data = [
      {'asm::vm::vmware' =>  {'id' => {}}}
    ]
    data.each do |i|
      expect{ASM::Resource::VM.create(i)}.to raise_error
    end
  end

  context 'VMware VMs' do
    before :each do
      conf = Hashie::Mash.new(
        :host => 'localhost',
        :user => 'admin',
        :password => 'password'
      )
      ASM::DeviceManagement.stubs(:parse_device_config).returns(conf)
      @server = Hashie::Mash.new
      @cluster = Hashie::Mash.new({'cluster' => 'dc_cluster'})
    end

    it 'creates VMs' do
      data = [
        {'asm::vm' =>  {'id' => {}}},
        {'asm::vm::vcenter' => {'id' => {}}}
      ]
      data.each do |i|
        vms = ASM::Resource::VM.create(i)
        expect(vms.first.is_a? ASM::Resource::VM::VMware).to be true
      end
    end

    it 'transforms windows vm to puppet' do
      config = Hashie::Mash.new
      config.debug_service_deployments = true
      ASM.stubs(:config).returns(config)
      data = {
        'asm::vm' => {
          'win2k8' => {
            'os_image_type' => 'windows',
            'hostname' => 'vm-win2k8r2',
            'network_interfaces' => {},
          }
        }
      }
      vm = ASM::Resource::VM.create(data).first
      @server.os_image_type = 'windows'
      deployment_id = "1"
      vm.process!('vm-win2k8r2', @server, @cluster, deployment_id, nil)
      vm_hash = vm.to_puppet
      vm_hash['asm::vm::vcenter']['vm-win2k8r2'].delete('requested_network_interfaces')
      result = {
        "asm::vm::vcenter"=> {
          "vm-win2k8r2"=> {
            "os_image_type"=>"windows",
            "network_interfaces"=> [{"portgroup"=>"VM Network", "nic_type"=>"vmxnet3"}],
            "os_type"=>"windows",
            "os_guest_id"=>"windows8Server64Guest",
            "scsi_controller_type"=>"LSI Logic SAS",
            "cluster"=>"dc_cluster",
            "datacenter"=>nil,
            "vcenter_id"=>"vm-win2k8r2",
            "vcenter_options"=>{"insecure"=>true},
            "ensure"=>"present",
          }
        }
      }
      expect(vm_hash).to eq(result)
    end

    it 'transforms linux vm to puppet' do
      config = Hashie::Mash.new
      config.debug_service_deployments = true
      ASM.stubs(:config).returns(config)
      data = {
        'asm::vm' => {
          'linux' => {
            'os_image_type' => 'linux',
            'hostname' => 'vm-rhel6',
            'network_interfaces' => {},
          }
        }
      }
      vm = ASM::Resource::VM.create(data).first
      @server.os_image_type = 'linux'
      deployment_id = "1"
      vm.process!('vm-rhel6', @server, @cluster, deployment_id, nil)
      vm_hash = vm.to_puppet
      vm_hash['asm::vm::vcenter']['vm-rhel6'].delete('requested_network_interfaces')
      result = {
        "asm::vm::vcenter"=> {
          "vm-rhel6"=> {
            "os_image_type"=>"linux",
            "network_interfaces"=> [{"portgroup"=>"VM Network", "nic_type"=>"vmxnet3"}],
            "os_type"=>"linux",
            "os_guest_id"=>"rhel6_64Guest",
            "scsi_controller_type"=>"VMware Paravirtual",
            "cluster"=>"dc_cluster",
            "datacenter"=>nil,
            "vcenter_id"=>"vm-rhel6",
            "vcenter_options"=>{"insecure"=>true},
            "ensure"=>"present",
          }
        }
      }
      expect(vm_hash).to eq(result)
    end
  end

  context 'HyperV VMs' do
    it 'creates hyperv vm' do
      data = [
        {'asm::vm::scvmm' => {'id' =>{}}}
      ]
      data.each do |i|
        vms = ASM::Resource::VM.create(i)
        expect(vms.first.is_a? ASM::Resource::VM::Scvmm).to be true
      end
    end
  end
end

describe ASM::Resource::Server do
  context 'Windows Server' do
    it 'creates windows vm' do
      data = {
        'asm::server' => {
          'title' => {
            'product_key' => 'aaaa-bbbb-cccc-dddd-eeee',
            'os_host_name' => 'win2k8',
            'os_image_type' => 'windows',
            'os_image_version' => 'win2012r2standard',
          }
        }
      }
      server = ASM::Resource::Server.create(data).first
      ASM::Util.stubs(:hostname_to_certname).returns('certname')
      server.process!('H8YDL9', 1)

      result = {
        "title" => {
          "os_host_name" => 'win2k8',
          "os_image_version"=>"win2012r2standard",
          "broker_type"=>"noop",
          "serial_number"=>"H8YDL9",
          "policy_name"=>"policy-win2k8-1",
          'razor_api_options' => {'url' => 'http://asm-razor-api:8080/api'},
          "installer_options"=>{
              "product_key"=>"aaaa-bbbb-cccc-dddd-eeee",
              "os_type"=>"windows",
              'agent_certname' => 'certname'},
        }
      }

      expect(server.to_puppet).to eq(result)
    end
  end
end

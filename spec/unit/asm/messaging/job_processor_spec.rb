require 'spec_helper'
require 'asm/messaging/job_processor'

describe ASM::Messaging::JobProcessor do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:job_dir) { Dir.mktmpdir('job_processor_spec') }
  let(:job_id) { "42" }
  let(:processor) { ASM::Messaging::JobProcessor.new }

  before do
    ASM.stubs(:logger).returns(logger)
    processor.stubs(:create_execution_environment).returns(job_dir)
  end

  after do
    FileUtils.rm_rf(job_dir)
  end

  describe "#on_message" do
    it "should call the specified action" do
      msg = {:action => 'test', :cert_name => 'foo'}
      response = processor.on_message(msg)
      expect(response[:success]).to eq(true)
    end

    it "should fail for unknown actions" do
      msg = {:action => 'foo', :cert_name => 'foo'}
      response = processor.on_message(msg)
      expect(response[:success]).to eq(false)
      expect(response[:msg]).to match(/Unrecognized action foo/)
    end
  end

  describe "#on_puppet_apply" do
    let(:body) { {:action => "puppet_apply", :cert_name => "cert",
                  :resources => {"asm::resource" => {"cert" => {"p1" => "v1"}}},
                  :job_dir => job_dir, :job_id => job_id} }

    it "should run puppet apply" do
      ASM::Util.expects(:run_command_streaming)
      ASM::DeviceManagement.expects(:puppet_run_success?).returns([true, "success"])
      output_file = processor.out_file(body)
      File.open(output_file, "w") { |f| f.puts "Puppet apply output" }
      response = processor.on_puppet_apply(body)
      expect(response[:success]).to eq(true)
      expect(response[:log]).to eq("Puppet apply output\n")
    end

    it "should return failure message on error" do
      ASM::Util.expects(:run_command_streaming).raises("Failed to execute command")
      response = processor.on_puppet_apply(body)
      expect(response[:success]).to eq(false)
      expect(response[:msg]).to eq("Failed to execute command")
    end

  end

  describe "#on_inventory" do
    it "should gather facts" do
      device = Hashie::Mash.new({:cert_name => "cert"})
      facts = {:fact => "fact"}
      body = {:action => "inventory", :cert_name => device.cert_name, :job_dir => job_dir, :job_id => job_id}
      processor.stubs(:create_logger).returns(logger)
      ASM::DeviceManagement.stubs(:parse_device_config).with(device.cert_name).returns(device)
      log_file = processor.out_file(body)
      File.open(log_file, "w") { |f| f.puts "Test output" }
      ASM::DeviceManagement.stubs(:gather_facts)
          .with(device, {:logger => logger,
                         :output_file => processor.cache_file(body),
                         :log_file => log_file})
          .returns(facts)
      response = processor.on_inventory(body)
      expect(response[:success]).to eq(true)
      expect(response[:facts]).to eq(facts)
      expect(response[:log]).to eq("Test output\n")
    end

    it "should return failure message on error" do
      body = {:action => "inventory", :cert_name => "cert", :job_dir => job_dir, :job_id => job_id}
      ASM::DeviceManagement.stubs(:parse_device_config).with("cert").raises("Parse device config failed")
      response = processor.on_inventory(body)
      expect(response[:success]).to eq(false)
      expect(response[:msg]).to eq("Parse device config failed")
      expect(response[:log]).to eq(nil)
    end
  end

end

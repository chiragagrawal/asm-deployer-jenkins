require 'spec_helper'
require 'asm/device_management'
require 'asm'
require 'tempfile'

describe ASM::DeviceManagement do

  before do
    ASM.init_for_tests
    @test_dir = Dir.mktmpdir('device_mgmt_test')
    @conf_dir = FileUtils.mkdir("#{@test_dir}/devices").first
    @node_data_dir = FileUtils.mkdir("#{@test_dir}/node_data").first
    @ssl_dir = FileUtils.mkdir("#{@test_dir}/ssl").first
    @cert_name = "foo-127.0.0.1"
    @tmpfile = Tempfile.new('AsmUtil_spec')

    ASM::DeviceManagement.send(:remove_const, :DEVICE_CONF_DIR)
    ASM::DeviceManagement.const_set(:DEVICE_CONF_DIR, @conf_dir)
    ASM::DeviceManagement.send(:remove_const, :NODE_DATA_DIR)
    ASM::DeviceManagement.const_set(:NODE_DATA_DIR, @node_data_dir)
    ASM::Util.send(:remove_const, :DEVICE_SSL_DIR)
    ASM::Util.const_set(:DEVICE_SSL_DIR, @ssl_dir)

    mock_log = mock('device_management')
    mock_log.stub_everything
    ASM::DeviceManagement.stubs(:logger).returns(stub({:debug => nil, :warn => nil, :info => nil}))
  end

  after do
    ASM.reset
    FileUtils.remove_entry_secure @test_dir
    @tmpfile.unlink
  end

  it 'should be able to parse single device config file' do
    certname = 'equallogic-172.17.15.10'
    text = <<END
[#{certname}]
  type equallogic
  url https://eqluser:eqlpw@172.17.15.10

END
    @tmpfile.write(text)
    @tmpfile.close

    conf = ASM::DeviceManagement.parse_device_config_file(@tmpfile)
    conf.keys.size.should eq 1
    conf[certname].provider.should eq 'equallogic'
  end

  it 'should be able to parse uri query string' do
    certname = 'equallogic-172.17.15.10'
    text = <<END
[#{certname}]
  type equallogic
  url https://eqluser:eqlpw@172.17.15.10?foo=bar

END
    @tmpfile.write(text)
    @tmpfile.close

    conf = ASM::DeviceManagement.parse_device_config_file(@tmpfile)
    ASM::DeviceManagement.stubs(:parse_device_config_file).returns(conf)
    File.stubs(:exist?).returns(true)

    conf = ASM::DeviceManagement.parse_device_config(certname)
    conf.keys.size.should eq 12
    conf.cert_name.should eq certname
    conf.host.should eq '172.17.15.10'
    conf.arguments.should == {'foo' => 'bar'}
  end

  it 'should handle missing uri query string' do
    certname = 'equallogic-172.17.15.10'
    text = <<END
[#{certname}]
  type equallogic
  url https://eqluser:eqlpw@172.17.15.10

END
    @tmpfile.write(text)
    @tmpfile.close

    conf = ASM::DeviceManagement.parse_device_config_file(@tmpfile)
    ASM::DeviceManagement.stubs(:parse_device_config_file).returns(conf)
    File.stubs(:exist?).returns(true)

    conf = ASM::DeviceManagement.parse_device_config(certname)
    conf.keys.size.should eq 12
    conf.cert_name.should eq certname
    conf.host.should eq '172.17.15.10'
    conf.arguments.should == {}
  end

  it 'should be able to delete a node data file' do
    conf_file = FileUtils.touch("#{@node_data_dir}/#{@cert_name}.yaml").first
    ASM::DeviceManagement.remove_node_data(@cert_name)
    File.exist?(conf_file).should == false
  end

  it 'should not fail if node data file does not exist' do
    ASM::DeviceManagement.remove_node_data(@cert_name)
  end

  it 'should be able to delete a conf file' do
    conf_file = FileUtils.touch("#{@conf_dir}/#{@cert_name}.conf").first
    ASM::DeviceManagement.remove_device_conf(@cert_name)
    File.exist?(conf_file).should == false
  end

  it 'should be able to delete a device puppet ssl folder' do
    dir_name = @ssl_dir + "/#{@cert_name}"
    dir = FileUtils.mkdir_p(dir_name)
    #Sanity check to ensure proper directory was created
    #ASM::Util.run_command_simple("sudo /opt/Dell/scripts/rm-device-ssl.sh #{device_name}")
    ASM::Util.stubs(:run_command_simple).with("sudo /opt/Dell/scripts/rm-device-ssl.sh #{@cert_name}") do
      FileUtils.rm_rf(dir)
    end.returns(true)
    File.exist?(dir_name).should == true
    ASM::DeviceManagement.remove_device_ssl_dir(@cert_name)
    File.exist?(dir_name).should == false
  end

  it 'should be able to clean up devices if puppet cert is active' do
    node_data_file = FileUtils.touch(ASM::DeviceManagement::NODE_DATA_DIR + "/#{@cert_name}.yaml").first
    conf_file = FileUtils.touch(ASM::DeviceManagement::DEVICE_CONF_DIR + "/#{@cert_name}.conf").first

    # NOTE: not actually creating this directory, just verifying rm-device-ssl.sh is run
    ssl_dir = ASM::Util::DEVICE_SSL_DIR + "/#{@cert_name}"

    ASM::PrivateUtil.stubs(:get_puppet_certs).returns([@cert_name])

    ASM::Util.stubs(:run_command_simple).
        with("sudo /opt/Dell/scripts/rm-device-ssl.sh #{@cert_name}").
        returns(Hashie::Mash.new({:exit_status => 0 }))
    ASM::Util.expects(:run_command_simple).
        with("sudo puppet cert clean #{@cert_name}").
        returns(Hashie::Mash.new({:exit_status => 0 }))
    ASM::Util.expects(:run_command_simple).
        with("sudo puppet node deactivate --terminus=puppetdb #{@cert_name}").
        returns(Hashie::Mash.new({:exit_status => 0 }))

    ASM::DeviceManagement.remove_device(@cert_name)
    File.exist?(node_data_file).should == false
    File.exist?(conf_file).should == false
    File.exist?(ssl_dir).should == false
  end

  it "should report unknown devices as such" do
    ASM::DeviceManagement.get_device_state("unknown_device").should == :unknown
  end

  it "should check state validity" do
    expect {
      ASM::DeviceManagement.set_device_state("rspec", :rspecstate)
    }.to raise_error("Unsupported state rspecstate for node rspec")
  end

  it "should be able to set and retrieve the device state" do
    ASM::DeviceManagement.set_device_state("rspec", :failed)
    ASM::DeviceManagement.get_device_state("rspec").should == :failed
  end

  describe 'when writing a config file' do
    before do
      @device = {"cert_name" => "rspec", "host" => "1.2.3.4",
                 "user" => "rip", "pass" => "secret",
                 "provider" => "rspec", "scheme" => "ssh"}
    end

    it "should correctly create URLs" do
      ASM::DeviceManagement.url_for_device(@device).should == "ssh://rip:secret@1.2.3.4"
      ASM::DeviceManagement.url_for_device(@device.merge({"user" => nil, "pass" => nil})).should == "ssh://1.2.3.4"
      ASM::DeviceManagement.url_for_device(@device.merge({"port" => 443})).should == "ssh://rip:secret@1.2.3.4:443"
      ASM::DeviceManagement.url_for_device(@device.merge({"path" => "rspec/rspec"})).should == "ssh://rip:secret@1.2.3.4/rspec/rspec"
      ASM::DeviceManagement.url_for_device(@device.merge({"arguments" => {"a" => "b", "c" => "d"}})).should == "ssh://rip:secret@1.2.3.4?a=b&c=d"
      ASM::DeviceManagement.url_for_device(@device.merge({"port" => 443, "path" => "rspec/rspec", "arguments" => {"a" => "b", "c" => "d"}})).should == "ssh://rip:secret@1.2.3.4:443/rspec/rspec?a=b&c=d"
    end

    it 'should ensure all the paramaters are present' do
      expect {
        ASM::DeviceManagement.write_device_config({})
      }.to raise_error("Devices need cert_name, host, provider, scheme parameters")
    end

    it 'should support custom device files' do
      ASM::DeviceManagement.expects(:device_config_name).never

      out = ASM::DeviceManagement.write_device_config(@device, true, @tmpfile.path)

      out.should == @tmpfile.read
    end

    it 'should not overwrite files by default' do
      expect {
        ASM::DeviceManagement.write_device_config(@device, false, "/tmp")
      }.to raise_error(/Device file \/tmp already exist/)
    end


    it 'should write and return the file contents' do
      ASM::DeviceManagement.expects(:device_config_name).returns(@tmpfile.path)

      out = ASM::DeviceManagement.write_device_config(@device, true)

      out.should == @tmpfile.read
    end

    it "should have a overwrite short cut method" do
      ASM::DeviceManagement.expects(:write_device_config).with(@device, true, "/tmp")
      ASM::DeviceManagement.write_device_config!(@device, "/tmp")
    end
  end


  describe "when doing device discovery" do
    before do
      ASM::Util.stubs(:run_command_simple)
    end

    it "should determine the correct state dir" do
      ASM::DeviceManagement.device_state_dir("rspec").should == "/var/opt/lib/pe-puppet/devices/rspec/state"
    end

    it "should determine the correct summary file" do
      ASM::DeviceManagement.device_summary_file("rspec").should == "/var/opt/lib/pe-puppet/devices/rspec/state/last_run_summary.yaml"
    end

    it "should give a really old mtime for the nonexisting summary files" do
      ASM::DeviceManagement.expects(:device_summary_file).returns("/nonexisting")
      ASM::DeviceManagement.last_run_summary_mtime("rspec").should == Time.at(0)
    end

    it "should return the correct mtime for the summary files" do
      now = Time.now
      File.expects(:mtime).with("/tmp").returns(now)
      ASM::DeviceManagement.stubs(:device_summary_file).returns("/tmp")

      ASM::DeviceManagement.last_run_summary_mtime("rspec").should == now
    end

    describe "when testing a logfile for pluginsync errors" do
      it "should return false if the logfile does not exist" do
        ASM::DeviceManagement.log_has_pluginsync_errors?("/nonexisting").should == false
      end

      it "should return false if there are no pluginsync errors" do
        log = SpecHelper.fixture_path("pluginsync-passed-device-run")
        ASM::DeviceManagement.log_has_pluginsync_errors?(log).should == false
      end

      it "should return true when there are pluginsync errors" do
        log = SpecHelper.fixture_path("pluginsync-failed-device-run")
        ASM::DeviceManagement.log_has_pluginsync_errors?(log).should == true
      end

      it "should handle encoding errors gracefully" do
        log = SpecHelper.fixture_path("pluginsync-failed-device-run-wrong-encoding")
        ASM::DeviceManagement.log_has_pluginsync_errors?(log).should == true
      end
    end

    describe "when determining the device run failed" do
      before do
        @result = Hashie::Mash.new
        @result.exit_status = 0
      end

      it "should fail when the exit code was !0" do
        @result.exit_status = 1

        ASM::DeviceManagement.puppet_run_success?("rspec", @result, Time.now).should == [false, "puppet exit code was 1"]
      end

      it "should support numeric result codes" do
        ASM::DeviceManagement.puppet_run_success?("rspec", 1, Time.now).should == [false, "puppet exit code was 1"]
      end

      it "should fail when the last_run_summary was not updated" do
        ASM::DeviceManagement.expects(:last_run_summary_mtime).with("rspec", nil).returns(Time.at(0))
        ASM::DeviceManagement.puppet_run_success?("rspec", @result, Time.now).should == [false, "/var/opt/lib/pe-puppet/devices/rspec/state/last_run_summary.yaml has not been updated in this run"]
      end

      it "should fail when the last_run_summary is not valid yaml" do
        ASM::DeviceManagement.expects(:last_run_summary_mtime).with("rspec", nil).returns(Time.at(4102466400))
        ASM::DeviceManagement.expects(:last_run_summary).with("rspec", nil).raises "simulated error"
        ASM::DeviceManagement.puppet_run_success?("rspec", @result, Time.now).should == [false, "Could not parse /var/opt/lib/pe-puppet/devices/rspec/state/last_run_summary.yaml as YAML: #<RuntimeError: simulated error>"]
      end

      it "should fail on non hash data" do
        ASM::DeviceManagement.expects(:last_run_summary_mtime).with("rspec", nil).returns(Time.at(4102466400))
        ASM::DeviceManagement.expects(:last_run_summary).with("rspec", nil).returns("")
        ASM::DeviceManagement.puppet_run_success?("rspec", @result, Time.now).should == [false, "/var/opt/lib/pe-puppet/devices/rspec/state/last_run_summary.yaml was not a hash"]
      end

      it "should fail on empty data" do
        ASM::DeviceManagement.expects(:last_run_summary_mtime).with("rspec", nil).returns(Time.at(4102466400))
        ASM::DeviceManagement.expects(:last_run_summary).with("rspec", nil).returns({})
        ASM::DeviceManagement.puppet_run_success?("rspec", @result, Time.now).should == [false, "/var/opt/lib/pe-puppet/devices/rspec/state/last_run_summary.yaml is empty"]
      end

      it "should fail when the config version is not valid" do
        ASM::DeviceManagement.expects(:last_run_summary_mtime).with("rspec", nil).returns(Time.at(4102466400))
        ASM::DeviceManagement.expects(:last_run_summary).with("rspec", nil).returns({"version" => {"config" => nil}})
        ASM::DeviceManagement.puppet_run_success?("rspec", @result, Time.now).should == [false, "/var/opt/lib/pe-puppet/devices/rspec/state/last_run_summary.yaml has an invalid config version"]
      end

      it "should fail when there are no resources section" do
        ASM::DeviceManagement.expects(:last_run_summary_mtime).with("rspec", nil).returns(Time.at(4102466400))
        ASM::DeviceManagement.expects(:last_run_summary).with("rspec", nil).returns({"version" => {"config" => 1}})
        ASM::DeviceManagement.puppet_run_success?("rspec", @result, Time.now).should == [false, "/var/opt/lib/pe-puppet/devices/rspec/state/last_run_summary.yaml has no resources section"]
      end

      it "should fail when there are pluginsync errors in the log" do
        ASM::DeviceManagement.expects(:last_run_summary_mtime).with("rspec", nil).returns(Time.at(4102466400))
        ASM::DeviceManagement.expects(:last_run_summary).with("rspec", nil).returns({"version" => {"config" => 1}, "resources" => {}})
        ASM::DeviceManagement.expects(:log_has_pluginsync_errors?).with("/some/file").returns(true)
        ASM::DeviceManagement.puppet_run_success?("rspec", @result, Time.now, "/some/file").should == [false, "pluginsync failed based on logfile /some/file"]
      end

      it "should passs on good files and exit codes" do
        ASM::DeviceManagement.expects(:last_run_summary_mtime).with("rspec", nil).returns(Time.at(4102466400))
        ASM::DeviceManagement.expects(:last_run_summary).with("rspec", nil).returns({"version" => {"config" => 1}, "resources" => {}})
        ASM::DeviceManagement.puppet_run_success?("rspec", @result, Time.now).should == [true, "last_run_summary.yaml and exit code checks pass"]
      end

      it "should support checking time for summary files" do
        ASM::DeviceManagement.expects(:last_run_summary_mtime).with("rspec", "/some/file").returns(Time.at(0))
        ASM::DeviceManagement.puppet_run_success?("rspec", @result, Time.now, nil, "/some/file").should == [false, "/some/file has not been updated in this run"]
      end

      it "should support loading data from custom summary data files" do
        ASM::DeviceManagement.expects(:last_run_summary_mtime).with("rspec", "/some/file").returns(Time.at(4102466400))
        ASM::DeviceManagement.expects(:last_run_summary).with("rspec", "/some/file").returns({"version" => {"config" => 1}, "resources" => {}})
        ASM::DeviceManagement.puppet_run_success?("rspec", @result, Time.now, nil, "/some/file").should == [true, "last_run_summary.yaml and exit code checks pass"]
      end

      it "should fail gracefully for any exceptions" do
        ASM::DeviceManagement.expects(:last_run_summary_mtime).with("rspec", nil).raises("simulated error")

        success, reason = ASM::DeviceManagement.puppet_run_success?("rspec", @result, Time.now)

        success.should == false
        reason.should match(/Failed to determine puppet run success: simulated error at /)
      end
    end

    describe "when multiple discovery requests for the same device are made" do
      it "should raise an exception when fail_for_in_progress=true" do
        logger = mock
        logger.expects(:info).with("Discovery for device rspec is already in progress - state is requested")

        ASM::DeviceManagement.set_device_state("rspec", :requested)

        expect {
          ASM::DeviceManagement.run_puppet_device!("rspec", logger, true)
        }.to raise_error("Discovery for device rspec is already in progress - state is requested")

        ASM::DeviceManagement.get_device_state("rspec").should == :requested
      end

      it "should wait for an in progress discovery to finish before starting a new one when fail_for_in_progress=false" do
        logger = mock
        ASM::DeviceManagement.set_device_state("rspec", :requested)

        ASM::PrivateUtil.expects(:wait_until_available)
        ASM::DeviceManagement.run_puppet_device!("rspec", logger, false)
      end
    end


    it "should handle any exception as a failure" do
      logger = mock
      logger.expects(:info).with("Puppet device run for node rspec caught exception: rspec error")

      ASM::DeviceManagement.set_device_state("rspec", :success)
      ASM::PrivateUtil.expects(:wait_until_available).raises("rspec error")
      expect do
        ASM::DeviceManagement.run_puppet_device!("rspec", logger)
      end.to raise_error("rspec error")
      ASM::DeviceManagement.get_device_state("rspec").should == :failed
    end

    it "should interpret puppet command failures correctly" do
      result = Hashie::Mash.new
      result.exit_status = 1
      logger = mock
      ASM::DeviceManagement.stubs(:parse_device_config).with("rspec").returns({"rspec" => true})

      logger.expects(:info).with("Puppet device run for node rspec started, logging to /tmp/log")
      logger.expects(:info).with("Puppet device run for node rspec failed: puppet exit code was 1")

      ASM::Util.expects(:run_command_simple).returns(result)
      ASM::DeviceManagement.expects(:device_log_file).returns("/tmp/log")

      ASM::DeviceManagement.set_device_state("rspec", :success)
      ASM::DeviceManagement.run_puppet_device!("rspec", logger)
      ASM::DeviceManagement.get_device_state("rspec").should == :failed
    end

    it "should interpret puppet command success correctly" do
      result = Hashie::Mash.new
      result.exit_status = 0
      logger = mock
      ASM::DeviceManagement.stubs(:parse_device_config).with("rspec").returns({"rspec" => true})

      ASM::Util.expects(:run_command_simple).returns(result)
      ASM::DeviceManagement.expects(:device_log_file).returns("/tmp/log")
      ASM::DeviceManagement.expects(:puppet_run_success?).returns([true, ""])

      logger.expects(:info).with("Puppet device run for node rspec started, logging to /tmp/log")
      logger.expects(:info).with("Puppet device run for node rspec succeeded")

      ASM::DeviceManagement.set_device_state("rspec", :failed)
      ASM::DeviceManagement.run_puppet_device!("rspec", logger)
      ASM::DeviceManagement.get_device_state("rspec").should == :success
    end
  end

  describe "when loading config files" do
    before do
      File.stubs(:exist?).with(ASM::DeviceManagement.device_config_name("rspec")).returns(true)
      ASM::DeviceManagement.stubs(:parse_device_config).with("rspec").returns({"rspec" => true})
      puppetdb = mock("puppetdb")
      puppetdb.stubs(:facts).with("rspec").returns({:rspec => :facts})
      ASM::Client::Puppetdb.stubs(:new).returns(puppetdb)
      ASM::DeviceManagement.stubs(:get_device_state).returns(:rspec)
    end

    it "should detect unknown devices" do
      File.stubs(:exist?).with(ASM::DeviceManagement.device_config_name("rspec")).returns(false)
      expect { ASM::DeviceManagement.get_device("rspec") }.to raise_error("Device rspec is unknown")
    end

    it "should support loading a device configuration and default to not supplying facts" do
      ASM::PrivateUtil.expects(:facts_find).never
      ASM::DeviceManagement.get_device("rspec", false).should == {"rspec" => true, "facts" => {}, "discovery_status" => :rspec}
    end

    it "should support loading facts for a device configuration" do
      ASM::DeviceManagement.get_device("rspec").should == {"rspec" => true, "facts" => {:rspec => :facts}, "discovery_status" => :rspec}
    end

    it "should set the discovery status to unknown when facts arent requested and no status is known" do
      ASM::DeviceManagement.expects(:get_device_state).returns(:unknown)
      ASM::DeviceManagement.get_device("rspec", false).should == {"rspec" => true, "facts" => {}, "discovery_status" => :unknown}
    end

    it "should set the discovery status to success when there are facts and no status is known" do
      ASM::DeviceManagement.expects(:get_device_state).returns(:unknown)
      ASM::DeviceManagement.get_device("rspec").should == {"rspec" => true, "facts" => {:rspec => :facts}, "discovery_status" => :success}
    end

  end
end

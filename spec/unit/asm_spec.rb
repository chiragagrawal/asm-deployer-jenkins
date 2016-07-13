require 'spec_helper'
require 'asm'

describe ASM do

  it 'should return hard coded base dir' do
    config_file = File.join(File.dirname(__FILE__), '..', 'config.yaml')
    FileUtils.expects(:mkdir_p).with('/opt/Dell/ASM/deployments').once
    ASM.init_for_tests
    ASM.base_dir.should == '/opt/Dell/ASM/deployments'
    # this is being called once to verify that mkdir_p is only
    # called once
    ASM.base_dir.should == '/opt/Dell/ASM/deployments'
    ASM.send(:reset)
  end

  describe 'the global counter' do
    before do
      config_file = File.join(File.dirname(__FILE__), '..', 'config.yaml')
      ASM.init_for_tests
    end

    after do
      ASM.send(:reset)
    end

    it 'should support an ever increasing counter' do
      10.times {|i| ASM.counter.should == i + 1 }
    end

    it 'should support incrementing a named counter' do
      ASM.counter_incr(:rspec).should == 1
      ASM.counter_incr(:rspec2).should == 1
    end

    it 'should support decrementing a named counter' do
      ASM.counter_incr(:rspec).should == 1
      ASM.counter_incr(:rspec2).should == 1
      ASM.counter_decr(:rspec).should == 0
    end

    it 'should support retrieving a named counter' do
      ASM.counter_incr(:rspec).should == 1
      ASM.counter_incr(:rspec2).should == 1
      ASM.counter_decr(:rspec).should == 0
      ASM.get_counter(:rspec).should == 0
      ASM.get_counter(:rspec2).should == 1
    end

    it 'should support conditional increments' do
      5.times { ASM.counter_incr(:rspec) }

      ASM.increment_counter_if_less_than(5, :rspec).should == false
      ASM.increment_counter_if_less_than(6, :rspec).should == 6
      ASM.get_counter(:rspec).should == 6
    end

    it 'should support waiting on a counter' do
      ASM.counter_incr(:rspec)

      t = Thread.new { sleep 0.1; ASM.counter_decr(:rspec) }

      x = mock
      x.expects(:y).once

      ASM.wait_on_counter_threshold(1, 3, :rspec) { x.y }
    end

    it 'should support waiting on a counter but timeout if its too long' do
      ASM.counter_incr(:rspec)

      t = Thread.new { sleep 0.5; ASM.counter_decr(:rspec) }

      x = mock
      x.expects(:y).never

      expect {
        ASM.wait_on_counter_threshold(1, 0.1, :rspec) { x.y }
      }.to raise_exception /Timed out waiting on global counter/
    end
  end

  describe 'tests requiring initialization' do
    before do
      ASM.init_for_tests
    end

    after do
      # Use send to bypass private scope
      ASM.send(:reset)
    end

    describe 'when managing deployment processing' do

      before do
        mock = mock('deployment')
        mock.stub_everything
        ASM::ServiceDeployment.expects(:new).twice.returns(mock)
        @tmp_dir = Dir.mktmpdir
        @basic_data_1 = {'id' => 'foo'}
        @basic_data_2 = {'id' => 'bar'}
      end

      it 'should only manage deployment processing state one at a time' do
        # verifies that only one thread can enter the deployment
        # tracking methods at a time
        now = Time.now
        ASM.expects(:track_service_deployments_locked).with() do |id|
          sleep 0.1;
          true
        end.twice.returns(true)
        ASM.expects(:complete_deployment).twice
        mock_deployment_db = mock('deployment_db')
        mock_deployment_db.stub_everything
        [@basic_data_1, @basic_data_2].collect do |data|
          Thread.new do
            ASM.process_deployment(data, mock_deployment_db) {}
          end
        end.each do |thd|
          thd.join
        end
        end_time = Time.now

        # ASM::ServiceDeployment.process is now done asynchronously from
        # ASM.process_deployment, so sleep a bit to allow them to complete
        sleep 0.2

        ((end_time - now) > 0.2).should be(true)
      end

    end

    it 'should track service deployments' do
      ASM.track_service_deployments('one').should be(true)
      ASM.track_service_deployments('one').should be(false)
      ASM.track_service_deployments('two').should be(true)
      ASM.complete_deployment('one')
      ASM.complete_deployment('two')
      ASM.track_service_deployments('one').should be(true)
    end

    it 'should fail if we call ASM.init twice' do
      expect do
        ASM.init_for_tests
      end.to raise_error('Can not initialize ASM class twice')
    end

    describe 'when hostlist is initialized/updated with hosts' do

      it 'should return [] list' do
        ASM.block_hostlist(['server1', 'server2']).should == []
      end

      it 'should return list of duplicate hosts' do
        ASM.block_hostlist(['host1', 'host2'])
        ASM.block_hostlist(['host1', 'host2']).should == ['host1', 'host2']
      end

      it 'should return [] if hosts are blocked, unblocked and blocked again' do
        ASM.block_hostlist(['host1', 'host2', 'host3'])
        ASM.unblock_hostlist(['host1', 'host2'])
        ASM.block_hostlist(['host1', 'host2']).should == []
      end

      it 'should return list of hosts if hosts are if they already exist in block list' do
        ASM.block_hostlist(['host1', 'host2', 'host3'])
        ASM.unblock_hostlist(['host1', 'host2'])
        ASM.block_hostlist(['host3']).should == ['host3']
      end

    end

  end
end

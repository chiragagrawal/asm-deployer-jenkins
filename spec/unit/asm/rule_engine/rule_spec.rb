require 'spec_helper'
require 'asm/rule_engine'

describe ASM::RuleEngine::Rule do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:engine) { ASM::RuleEngine.new("/nonexisting", logger) }
  let(:state) { ASM::RuleEngine::State.new(engine, logger) }
  let(:rule) { ASM::RuleEngine::Rule.new(logger) }

  before :each do
    rule.logger = logger
    rule.name = "rspec"
    rule.set_state(state)
  end

  describe "#set_concurrent" do
    it "should set the rule to be concurrent" do
      expect(rule.concurrent?).to be(false)
      rule.set_concurrent
      expect(rule.concurrent?).to be(true)
    end
  end

  describe "#build_from_generator" do
    it "should correctly construct a rule" do
      generator = ->(rule) { set_priority 10 }
      rule.build_from_generator(&generator)
      expect(rule.priority).to eq(10)
    end
  end
  describe "#reset" do
    it "should reset state" do
      expect(rule.state).to be_an_instance_of(ASM::RuleEngine::State)
      rule.reset!
      expect(rule.state).to eq(nil)
    end
  end

  describe "#run_on_fail?" do
    it "should correctly report settings and default to false" do
      expect(rule.run_on_fail?).to eq(false)
      rule.run_on_fail
      expect(rule.run_on_fail?).to eq(true)
    end
  end

  describe "#set_priority" do
    it "should only accept integers < 1000" do
      expect { rule.set_priority("rspec") }.to raise_error("Priority should be an integer less than 1000")
    end

    it "should correctly update the priority" do
      expect(rule.priority).to eq(50)
      rule.set_priority(100)
      expect(rule.priority).to eq(100)
    end
  end

  describe "#condition" do
    it "should always expect a block" do
      expect { rule.condition(:x) }.to raise_error("A block is required for a condition")
    end

    it "should correctly store the block" do
      blk = -> { true }
      rule.condition(:x, &blk)
      expect(rule.conditions[:x]).to eq(blk)
    end
  end

  describe "#execute_when" do
    it "should require a block" do
      expect{ rule.execute_when }.to raise_error("A block is required for the execute_when logic")
    end
  end

  describe "#execute" do
    it "should require a block" do
      expect{ rule.execute }.to raise_error("A block is required for the execution logic")
    end
  end

  describe "#should_run?" do
    it "should check the state and evaluate logic" do
      rule.expects(:check_state).returns(true)
      ASM::RuleEngine::RuleEvaluator.any_instance.expects(:evaluate!).returns(true)
      expect(rule.should_run?).to eq(true)
    end

    it "should only evaluate the logic if the state passes" do
      rule.expects(:check_state).returns(false)
      ASM::RuleEngine::RuleEvaluator.any_instance.expects(:evaluate!).never
      expect(rule.should_run?).to eq(false)
    end
  end

  describe "#run" do
    it "should only run if there is state" do
      rule.reset!
      expect { rule.run }.to raise_error("Cannot run without a state set")
    end

    it "should not run on failure by default" do
      run = mock
      run.expects(:running).never
      logger.expects(:debug).with(regexp_matches(/Rule processing for rule rspec skipped on failed state/))

      rule.execute { run.running }
      state.had_failures!
      rule.run
    end

    it "should run on failure when configured to do so" do
      run = mock
      run.expects(:running).once

      rule.execute { run.running }
      rule.run_on_fail
      state.had_failures!
      rule.run
    end
  end

  describe "#process_state" do
    before(:each) do
      result = ASM::RuleEngine::Result.new(rule)
      result.stub_start_time_for_tests(Time.now - 2 )
      ASM::RuleEngine::Result.expects(:new).returns(result)

      rule.expects(:reset!).once
      state.expects(:record_actor).with(rule)
    end

    it "should run and record actors with the given state" do
      rule.expects(:set_state).with(state)
      rule.expects(:should_run?).returns(true)
      rule.expects(:run).returns("rspec")
      logger.expects(:info).with(regexp_matches(/^Running rule /))

      result = rule.process_state(state)
      expect(result.elapsed_time).to be > 0
      expect(state.had_failures?).to eq(false)
      expect(result.out).to eq("rspec")
    end

    it "should process failed runs correctly" do
      rule.expects(:run).raises("rspec simulated failure")
      logger.expects(:info).with(regexp_matches(/^Running rule /))
      logger.expects(:warn).with(regexp_matches(/^Rule .+ failed to run: rspec simulated failure/))

      result = rule.process_state(state)
      expect(result.elapsed_time).to be > 1
      expect(state.had_failures?).to eq(true)
      expect(result.error.to_s).to eq("rspec simulated failure")
    end
  end

  describe "#check_state" do
    it "should fail if no state is set on the rule" do
      r = ASM::RuleEngine::Rule.new(logger)
      expect { r.check_state }.to raise_error("Cannot check state when no state is set or supplied")
    end

    it "should detect missing state items" do
      logger.expects(:debug).with(regexp_matches(/does not contain item x/))

      rule.require_state(:x, String)
      expect(rule.check_state).to eq(false)
    end

    it "should use the item validator to do checks" do
      state[:x] = "rspec"
      rule.require_state(:x, String)

      ASM::ItemValidator.expects(:validate!).with("rspec", String).returns([true, nil])
      expect(rule.check_state).to eq(true)
    end

    it "should log the fail message" do
      state[:x] = "rspec"
      rule.require_state(:x, Fixnum)

      ASM::ItemValidator.expects(:validate!).with("rspec", Fixnum).returns([false, "rspec"])
      logger.expects(:debug).with(regexp_matches(/state has x but it failed validation: rspec/))
      expect(rule.check_state).to eq(false)
    end
  end
end

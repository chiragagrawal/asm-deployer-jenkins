require 'spec_helper'
require 'asm/rule_engine'

describe ASM::RuleEngine::Rules do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:rules) { ASM::RuleEngine::Rules.new(["/nonexisting1", "/nonexisting2"], logger) }
  let(:state) { ASM::RuleEngine::State.new(nil, logger) }

  before(:each) do
    rules.stubs(:locked?).returns(false)
  end

  describe "#rules" do
    it "should return a frozen copy of the rules" do
      expect(rules.rules).to be_frozen
      expect(rules.rules).to_not be(rules.rules)
    end
  end

  describe "#add_rule" do
    it "should not allow rules to be added while locked" do
      rules.expects(:locked?).returns(true)
      expect { rules.add_rule(:rspec) }.to raise_error("Cannot add any rules once initialized")
    end
  end

  describe "#load_rule" do
    it "should not allow rules to be loaded while locked" do
      rules.expects(:locked?).returns(true)
      expect { rules.load_rule("/nonexisting") }.to raise_error("Cannot add any rules once initialized")
    end

    it "should fail on non existing files" do
      expect { rules.load_rule("/nonexisting") }.to raise_error("Cannot read file /nonexisting to load a rule from")
    end

    it "should load and evaluate the rule yielding a functional rule" do
      ASM.init_for_tests

      rule_txt = "ASM::RuleEngine::new_rule('rspec') { execute { state[:rspec].run }}"

      File.expects(:readable?).with("/nonexisting").returns(true)
      File.expects(:read).with("/nonexisting").returns(rule_txt)

      runner = mock
      runner.expects(:run).once
      state[:rspec] = runner

      rules.load_rule("/nonexisting")
      rule = rules.rules.first
      rule.set_state(state)
      rule.run

      expect(rule.file).to eq("/nonexisting")
      expect(rule.name).to eq("rspec")
      expect(rule.logger).to eq(logger)

       ASM.reset
    end
  end

  describe "#find_rules" do
    it "should return an empty array for non directories" do
      logger.expects(:debug).with("The argument /nonexisting is not a directory while looking for rules")
      expect(rules.find_rules("/nonexisting")).to eq([])
    end

    it "should find all rules in a directory" do
      File.expects(:directory?).with("/nonexisting").returns(true).once
      Dir.expects(:entries).with("/nonexisting").returns([".", "..", "rule1_rule.rb", "rule2_rule.rb"])
      expect(rules.find_rules("/nonexisting")).to eq(["rule1_rule.rb", "rule2_rule.rb"])
    end
  end

  describe "#load_rules!" do
    it "should not allow rules to be added while locked" do
      rules.expects(:locked?).returns(true)
      expect { rules.load_rules! }.to raise_error("Cannot add any rules once initialized")
    end

    it "should load rules for each directory" do
      rules.expects(:find_rules).with("/nonexisting1").returns([]).once
      rules.expects(:find_rules).with("/nonexisting2").returns([]).once
      rules.load_rules!
    end

    it "should load all rules in the rules directory" do
      rules.expects(:find_rules).with("/nonexisting1").returns([]).once
      rules.expects(:find_rules).with("/nonexisting2").returns(["rule1_rule.rb"]).once
      rules.expects(:load_rule).with("/nonexisting2/rule1_rule.rb").once
      rules.load_rules!
    end
  end
end

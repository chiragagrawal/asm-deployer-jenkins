require 'spec_helper'
require 'asm/rule_engine'

describe ASM::RuleEngine do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:rules) { stub(:load_rules!) }

  describe "#new_rule" do
    it "should not allow rules without blocks" do
      expect {
        ASM::RuleEngine.new_rule("x")
      }.to raise_error("Rules can only be created from a block")
    end

    it "should set the name" do
      rule = ASM::RuleEngine.new_rule("x", :logger => logger) { }

      expect(rule.name).to eq("x")
    end

    it "should parse options" do
      rule = ASM::RuleEngine.new_rule("x",
        :logger => logger,
        :run_on_fail => true,
        :concurrent => true,
        :priority => 10
      ) {}

      expect(rule.run_on_fail?).to be(true)
      expect(rule.concurrent?).to be(true)
      expect(rule.priority).to be(10)

      rule = ASM::RuleEngine.new_rule("x",
        :logger => logger,
        :run_on_fail => false
      ) {}

      expect(rule.run_on_fail?).to be(false)
      expect(rule.priority).to be(50)
    end

    it "should not override the rule body with options" do
      rule = ASM::RuleEngine.new_rule("x",
        :logger => logger,
        :priority => 10,
        :run_on_fail => false
      ) {run_on_fail; set_priority 100}

      expect(rule.run_on_fail?).to be(true)
      expect(rule.priority).to be(100)
    end
  end

  describe "#initialize" do
    it "should support OS specific path splits" do
      paths = ["/nonexisting1", "/nonexisting2"]
      os_path = paths.join(File::PATH_SEPARATOR)

      engine = ASM::RuleEngine.new(os_path, logger)
      expect(engine.path).to eq(paths)
    end
  end

  describe "#new_state" do
    it "should support creating states" do
      engine = ASM::RuleEngine.new("/nonexisting", logger)
      expect(engine.new_state).to be_an_instance_of(ASM::RuleEngine::State)
    end
  end

  describe "#size" do
    it "should support reporting the number of loaded rules" do
      rules.expects(:size).returns(1).once
      ASM::RuleEngine.any_instance.stubs(:rules).returns(rules)
      ASM::RuleEngine.new("/nonexisting", logger).size
    end
  end

  describe "#rules_by_priority" do
    it "should support iterating rules by priority" do
      rule = mock
      rules.expects(:by_priority).multiple_yields([rule])

      ASM::RuleEngine.any_instance.stubs(:rules).returns(rules)
      ASM::RuleEngine.new("/nonexisting", logger).rules_by_priority{|r| expect(r).to eq(rule)}
    end
  end

  describe "#process_rules" do
    it "should process rules by priority" do
      engine = ASM::RuleEngine.new("/nonexisting", logger)
      state = engine.new_state

      engine.rules.stubs(:locked?).returns(false)

      2.times do |i|
        rule = mock(:priority => i, :concurrent? => true)
        rule.expects(:process_state).with(state).returns("result %d" % i)
        engine.rules.add_rule(rule)
      end

      s = sequence(:mutability)
      state.expects(:mutable=).with(false).in_sequence(s)
      state.expects(:mutable=).with(true).in_sequence(s)
      state.expects(:mutable=).with(false).in_sequence(s)
      state.expects(:mutable=).with(true).in_sequence(s)

      expect(engine.process_rules(state)).to eq(["result 0", "result 1"])
      expect(state.results).to eq(["result 0", "result 1"])
    end
  end
end

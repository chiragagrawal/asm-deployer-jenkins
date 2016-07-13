require 'spec_helper'
require 'asm/rule_engine'

describe ASM::RuleEngine::RuleEvaluator do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:state) { ASM::RuleEngine::State.new(nil, logger) }
  let(:rule) { ASM::RuleEngine::Rule.new(logger) }
  let(:evaluator) { ASM::RuleEngine::RuleEvaluator.new(rule, state) }

  before :each do
    rule.logger = logger
    rule.set_state(state)
  end

  describe "#method_missing" do
    it "should evaluate conditions and return their result" do
      condition = mock
      condition.expects(:run).once.returns(true)
      logger.expects(:debug).with(regexp_matches(/Condition x evaluated to true in .+/))

      rule.condition(:x) { condition.run }
      expect(evaluator.x).to eq(true)
    end

    it "should fail for non existing conditions" do
      expect { evaluator.x }.to raise_error(NameError, "undefined local variable or method `x'")
    end
  end

  describe "#evaluate!" do
    it "should evaluate the rule conditional logic" do
      condition1 = mock
      condition1.expects(:run).once.returns(true)

      condition2 = mock
      condition2.expects(:run).once.returns(true)

      rule.condition(:one) { condition1.run }
      rule.condition(:two) { condition2.run }

      rule.execute_when { one && two }

      expect(evaluator.evaluate!).to eq(true)
    end
  end
end

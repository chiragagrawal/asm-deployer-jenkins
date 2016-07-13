require 'spec_helper'
require 'asm/rule_engine'

describe ASM::RuleEngine::Result do
  let(:rule) { stub(:name => "rspec") }
  let(:result) { ASM::RuleEngine::Result.new(rule) }

  it "should allow recording of rule run times" do
    result.end_time = Time.now + 61
    expect(result.elapsed_time).to be > 60
    expect(result.elapsed_time).to be < 62
  end

  it "should set the result name from the rule and store the rule" do
    expect(result.name) == "rspec"
    expect(result.rule) == rule
  end
end

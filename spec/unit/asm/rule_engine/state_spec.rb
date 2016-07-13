require 'spec_helper'
require 'asm/rule_engine'

describe ASM::RuleEngine::State do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:engine) { ASM::RuleEngine.new("/nonexisting", logger) }
  let(:state) { ASM::RuleEngine::State.new(engine, logger) }

  describe "#store_result" do
    it "should store the result" do
      state.store_result("rspec")

      expect(state.results).to eq(["rspec"])
    end
  end

  describe "#results" do
    it "should return a frozen dup" do
      state.store_result("rspec")

      expect(state.results).to eq(["rspec"])
      expect(state.results).to_not be(state.instance_variable_get("@results"))
      expect(state.results).to be_frozen
    end
  end

  describe "#acted_on_by" do
    it "should return a frozen dup" do
      state.record_actor("rspec")

      expect(state.acted_on_by).to eq(["rspec"])
      expect(state.acted_on_by).to_not be(state.instance_variable_get("@acted_on_by"))
      expect(state.acted_on_by).to be_frozen
    end
  end

  describe "#had_failures!" do
    it "should default to no failures" do
      expect(state.had_failures?).to eq(false)
    end

    it "should track failures correctly" do
      state.had_failures!
      expect(state.had_failures?).to eq(true)
    end
  end

  describe "#record_actor" do
    it "should correctly track actors" do
      expect(state.acted_on_by).to eq([])
      state.record_actor("rspec")
      expect(state.acted_on_by).to eq(["rspec"])
    end
  end

  describe "#each_result" do
    it "should iterate results" do
      state.expects(:results).returns(["rspec"])
      state.each_result{|r| expect(r).to eq("rspec")}
    end
  end

  describe "#add_or_set" do
    it "should be able to make a new item and change it" do
      state.add_or_set(:x, :y)
      expect(state[:x]).to eq(:y)
      state.add_or_set(:x, :z)
      expect(state[:x]).to eq(:z)
    end

    it "should fail when the state is not mutable" do
      state.mutable = false
      expect { state.add_or_set(:x, :y) }.to raise_error("State is not mustable")
    end
  end

  describe "#add, #get and #delete" do
    it "should add the item correctly" do
      state.add(:x, :y)
      expect(state.get(:x)).to eq(:y)

      state[:y] = :z
      expect(state[:y]).to eq(:z)

      state.delete(:y)
      expect(state.has?(:y)).to eq(false)
    end

    it "should protect against adding the same item twice" do
      state.add(:x, :y)
      expect { state.add(:x, :y) }.to raise_error("Already have an item called x")
    end

    it "should fail when the state is not mutable" do
      state.mutable = false
      expect { state.add(:x, :y) }.to raise_error("State is not mustable")
      expect { state.delete(:x) }.to raise_error("State is not mustable")
    end
  end

  describe "#has?" do
    it "should correctly check if an item exist" do
      expect( state.has?(:x) ).to eq(false)
      state[:x] = :y
      expect( state.has?(:x) ).to eq(true)
    end
  end
end

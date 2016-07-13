require 'spec_helper'
require 'asm/cache'

describe ASM::Cache do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:locks_mutex) { Mutex.new }
  let(:cache_locks) { Hash.new }
  let(:cache_store) { Hash.new }
  let(:cache) { ASM::Cache.new(locks_mutex, cache_locks, cache_store, logger) }

  before(:each) do
    cache.stubs(:gc!)
  end

  describe "#gc!" do
    it "should gc all caches" do
      cache.setup(:rspec1)
      cache.setup(:rspec2)
      cache.expects(:gc_cache!).with(:rspec1)
      cache.expects(:gc_cache!).with(:rspec2)
      cache.unstub(:gc!)
      cache.gc!
    end
  end

  describe "#gc_cache!" do
    it "should remove all old entries from a cache" do
      cache.setup(:rspec, 1)
      cache.write(:rspec, :a, :v)
      cache.write(:rspec, :b, :v)

      expect(cache_store[:rspec]).to include(:a)
      expect(cache_store[:rspec]).to include(:b)

      cache.expects(:unsafe_ttl).with(:rspec, :a).returns(0)
      cache.expects(:unsafe_ttl).with(:rspec, :b).returns(1)

      cache.gc_cache!(:rspec)

      expect(cache_store[:rspec]).to_not include(:a)
      expect(cache_store[:rspec]).to include(:b)
    end
  end

  describe "#read_or_set" do
    it "should return a unexpired cache item" do
      cache.setup(:rspec)
      cache.write(:rspec, "x", "y")
      cache.expects(:write).never

      fetcher = stub
      fetcher.expects(:fetch).never

      expect(cache.read_or_set(:rspec, "x") { fetcher.fetch }).to eq("y")
    end

    it "should set and return the value" do
      cache.setup(:rspec, 1)
      cache.write(:rspec, "x", "y")

      cache.expects(:unsafe_ttl).with(:rspec, "x").twice.returns(0, 1)

      expect(cache.read_or_set(:rspec, "x", :new_value)).to eq(:new_value)
      expect(cache.read(:rspec, "x")).to eq(:new_value)
    end

    it "should set and return the block result" do
      cache.setup(:rspec, 10)
      cache.write(:rspec, "x", "y")

      cache.expects(:unsafe_ttl).with(:rspec, "x").twice.returns(0, 1)

      fetcher = mock(:fetch => :block_result)

      expect(cache.read_or_set(:rspec, "x") { fetcher.fetch }).to eq(:block_result)
      expect(cache.read(:rspec, "x")).to eq(:block_result)
    end
  end

  describe "#method_missing" do
    it "should allow dot based synchrnize" do
      cache.setup(:rspec)

      cache_locks[:rspec].expects(:synchronize).yields

      cache.rspec { nil }
    end
  end

  describe "#synchronize" do
    it "should use the correct mutex" do
      cache.setup("rspec")

      cache_locks["rspec"].expects(:synchronize).yields

      ran = 0
      cache.synchronize("rspec") do
        ran = 1
      end

      expect(ran).to be(1)
    end
  end

  describe "#ttl" do
    it "should return a positive value for an unexpired item" do
      cache.setup("rspec", 300)
      cache.write("rspec", :key, :val)
      expect(cache.ttl("rspec", :key)).to be >= 0
    end

    it "should return <0 for an expired item" do
      cache.setup("rspec", 300)
      cache.write("rspec", :key, :val)

      time = Time.now + 600
      Time.expects(:now).returns(time)

      expect(cache.ttl("rspec", :key)).to be <= 0
    end
  end

  describe "#read" do
    it "should read a written entry correctly" do
      cache.setup("rspec")
      cache.write("rspec", :key, :val)
      expect(cache.read("rspec", :key)).to be(:val)
    end

    it "should raise on expired reads" do
      cache.setup("rspec", 10)
      cache.write("rspec", :key, :val)

      cache.expects(:unsafe_ttl).with("rspec", :key).returns(0)

      expect { cache.read("rspec", :key) }.to raise_error(/has expired/)
    end

    it "should return clones of the data" do
      cache.setup("rspec")
      cache.write("rspec", "data", stored = "rspec")
      expect(cache.read("rspec", "data")).to eq("rspec")
      expect(cache.read("rspec", "data")).to_not be(stored)
    end
  end

  describe "#setup" do
    it "should use a mutex to set up the ache" do
      locks_mutex.expects(:synchronize).yields.twice
      cache.setup("rspec1")
      cache.setup("rspec2", ASM::Cache::DAY)

      expect(cache_locks["rspec1"]).to be_a(Mutex)
      expect(cache_locks["rspec2"]).to be_a(Mutex)
      expect(cache_locks["rspec1"]).to_not be(cache_locks["rspec2"])

      expect(cache_store["rspec1"]).to eq({:__cache_max_age => 3600.0})
      expect(cache_store["rspec2"]).to eq({:__cache_max_age => 86400.0})
    end
  end

  describe "#has_cache?" do
    it "should correctly report presense of a cache" do
      cache.setup("rspec")
      expect(cache.has_cache?("rspec")).to be(true)
      expect(cache.has_cache?("fail")).to be(false)
    end
  end

  describe "#write" do
    it "should detect unknown caches" do
      expect { cache.write("rspec", :key, :val) }.to raise_error("No cache called 'rspec'")
    end

    it "should write to the cache" do
      time = Time.now
      Time.stubs(:now).returns(time)

      cache.setup("rspec")
      expect(cache.write("rspec", :key, :val)).to eq(:val)

      expect(cache_store["rspec"][:key][:value]).to eq(:val)
      expect(cache_store["rspec"][:key][:item_create_time]).to be(time)
    end
  end
end

require 'spec_helper'
require 'asm/provider/base'

describe ASM::Provider::Base do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:provider) { ASM::Provider::Base.new }
  let(:deployment) { stub }
  let(:type) { stub(:logger => logger) }

  before :all do
    ASM::Provider::Base.property(:rspec, :default => nil, :validation => String)
    ASM::Provider::Base.property(:hello, :default => "world", :validation => String)
    ASM::Provider::Base.property(:additional, :default => "world", :validation => String, :tag => :additional)
  end

  before :each do
    ASM::Provider::Base.puppet_type "test"

    provider.uuid = "rspec"
    type.stubs(:deployment).returns(deployment)
    type.stubs(:puppet_certname).returns("rspec_cert")
    type.stubs(:guid).returns("rspec_guid")
    type.stubs(:component_configuration).returns({})
    type.stubs(:facts_find).returns({})
    provider.type = type
  end

  it "should include phash" do
    expect(provider.class.ancestors.include?(ASM::Provider::Phash)).to eq(true)
  end

  describe "#parse_json_fact" do
    it "should parse JSON strings" do
      provider.facts = {"rspec" => JSON.dump("rspec" => true)}
      provider.parse_json_fact("rspec")
      expect(provider.facts["rspec"]). to eq("rspec" => true)
    end

    it "should parse JSON strings with arrays in them when the default is a array" do
      provider.facts = {"rspec" => JSON.dump([1,2])}
      provider.parse_json_fact("rspec", [])
      expect(provider.facts["rspec"]). to eq([1,2])
    end

    it "should create array of the data when data does not start with [ and the default is a array" do
      provider.facts = {"rspec" => "1"}
      provider.parse_json_fact("rspec", [])
      expect(provider.facts["rspec"]). to eq(["1"])
    end
  end

  describe "#facts" do
    it "should retrieve_facts and return {} when not set" do
      provider.instance_variable_set("@__facts", nil)
      provider.expects(:retrieve_facts!).returns({})
      expect(provider.facts).to eq({})
    end
  end

  describe "#facts=" do
    it "should only accept hashes" do
      expect {
        provider.facts = nil
      }.to raise_error("Facts has to be a hash, cannot store facts for rspec_cert")
    end

    it "should normalize facts" do
      provider.expects(:normalize_facts!).once
      provider.facts = {}
    end

    it "should return the normalized facts" do
      provider.stubs(:json_facts).returns(["rspec"])
      result = provider.facts = {"rspec" => '{"rspec":1}'}
      expect(result["rspec"]).to eq("rspec" => 1)
      expect(provider.facts["rspec"]).to eq("rspec" => 1)
    end
  end

  describe "#normalize_facts!" do
    it "should define a list of JSON facts" do
      expect(provider.json_facts).to be_a(Array)
      expect(provider.json_facts).to be_empty
    end

    it "should parse JSON hash like facts" do
      provider.stubs(:json_facts).returns(["rspec1", "rspec2"])
      provider.json_facts.each do |fact|
        json = ({"rspec" => fact}).to_json
        provider.facts = {fact => json}
        expect(provider.facts[fact]).to eq({"rspec" => fact})
      end
    end

    it "should parse JSON array like facts" do
      provider.stubs(:json_facts).returns([["rspec1", {}], ["rspec2", 1]])
      provider.json_facts.each do |fact|
        provider.facts = {fact[0] => ["rspec"].to_json}
        expect(provider.facts[fact[0]]).to eq(["rspec"])
      end
    end

    it "should assign to empty hash if not set" do
      provider.stubs(:json_facts).returns([["rspec1", []], "rspec2"])
      provider.facts = {}
      expect(provider.facts["rspec1"]).to eq([])
      expect(provider.facts["rspec2"]).to eq({})
    end
  end

  describe "#supports_resource?" do
    it "should proxy to type" do
      type.expects(:supports_resource?)
      provider.supports_resource?(stub)
    end
  end

  describe "#puppet_run_type" do
    it "should return the class level puppet_run_type" do
      ASM::Provider::Base.expects(:puppet_run_type).returns("apply")
      expect(provider.puppet_run_type).to eq("apply")
    end
  end

  describe "#process!" do
    it "should support appending to a hash" do
      resources = provider.process!(:append_to_resources => {"rspec" => true})
      expect(resources).to eq({"rspec"=>true, "test"=>{"rspec"=>{"hello"=>"world"}}})
    end

    it "should call process_generic with the apply run type by default" do
      type.expects(:process_generic).with("rspec_cert", provider.to_puppet, 'apply', true, nil, 'rspec_guid', false)
      provider.process!
    end

    it "should call process_generic with the specified run type" do
      ASM::Provider::Base.puppet_run_type "device"
      type.expects(:process_generic).with("rspec_cert", provider.to_puppet, "device", true, nil, 'rspec_guid', false)
      provider.process!
    end

    it "should support requesting an inventory update" do
      ASM::Provider::Base.puppet_run_type "device"
      type.expects(:process_generic).with("rspec_cert", provider.to_puppet, "device", true, nil, 'rspec_guid', true)
      provider.process!(:update_inventory => true)
    end
  end

  describe "#configure!" do
    it "should support configuring the provider" do
      provider.configure!({"uuid" => {"rspec" => "hello world"}})
      expect(provider.rspec).to eq("hello world")
      expect(provider.uuid).to eq("uuid")
    end

    it "should not attempt to call non existing configure_hook" do
      provider.stubs(:respond_to?).returns(false)
      provider.expects(:respond_to?).with(:configure_hook).returns(false)
      provider.expects(:configure_hook).never
      provider.configure!({"uuid" => {"rspec" => "hello world"}})
    end

    it "should call the configure_hook when it exists" do
      provider.stubs(:respond_to?).returns(false)
      provider.expects(:respond_to?).with(:configure_hook).returns(true)
      provider.expects(:configure_hook)
      provider.configure!({"uuid" => {"rspec" => "hello world"}})
    end
  end

  describe "#to_puppet" do
    it "should fail when a puppet_type was not provided" do
      ASM::Provider::Base.stubs(:puppet_type).returns([])

      expect {
        provider.to_puppet
      }.to raise_error("The puppet type has not been set")
    end

    it "should correctly convert the provider into a puppet hash" do
      provider.configure!({"uuid" => {"rspec" => "hello world"}})
      puppet_hash = {"test"=>{"uuid"=>{"rspec"=>"hello world", "hello" => "world"}}}

      expect(provider.to_puppet).to eq(puppet_hash)
    end

    it "should merge the created resource with the configuration and override the configuration" do
      type.expects(:component_configuration).returns({"test" => "to go", "test1" => "to stay"})
      provider.configure!({"uuid" => {"rspec" => "hello world"}})

      expected = {
                    "test" => {"uuid" => {"hello" => "world", "rspec" => "hello world"}},
                    "test1" => "to stay"
                 }

      expect(provider.to_puppet).to eq(expected)
    end

    it "should allow providers to supply additional resources" do
      provider.configure!({"uuid" => {"rspec" => "hello world"}})
      provider.expects(:additional_resources).returns({"additional" => 1})

      expected = {
                    "test" => {"uuid" => {"hello" => "world", "rspec" => "hello world"}},
                    "additional" => 1
                 }

      expect(provider.to_puppet).to eq(expected)
    end

    it "should not include the provider resources when there are no :puppet tagged properties" do
      provider.expects(:properties).with(:puppet).returns([])
      provider.expects(:to_hash).never
      expect(provider.to_puppet).to eq({})
    end
  end
end

require 'spec_helper'
require 'asm/provider/phash'
require 'asm/provider/base'

describe ASM::Provider::Phash do
  # phash is a module, it's really hard to test modules, using Base here
  # that's quite small and includes phash
  let(:base) { ASM::Provider::Base.new }
  let(:klass) { base.class }

  before(:each) {
    klass.phash_reset!
    klass.property(:x, :default => "hello", :validation => String)
    ASM::Provider::Base.puppet_type "rspec"
    base.type = stub(:puppet_certname => "rspec")
  }

  describe ASM::Provider::Phash::ClassMethods do
    describe "#property" do
      it "should check for valid arguments" do
        expect {
          klass.property(:y, :def => nil, :validate => true)
        }.to raise_error("Invalid keys for property y: def, validate")
      end

      it "should protect against double property definitions" do
        expect {
          klass.property(:x, :default => nil, :validation => String)
        }.to raise_error("Already have a property x")
      end

      it "should store properties with stringified keys" do
        expect(klass.phash_config).to include("x")
      end

      it "should create sane defaults" do
        klass.property(:y)
        config = klass.phash_config["y"]
        expect(config).to eq({:default => nil, :validation => nil, :tag => [:puppet]})
      end
    end

    describe "#phash_default_value" do
      it "should fail for unknown properties" do
        expect {
          klass.phash_default_value(:rspec)
        }.to raise_error("Unknown property rspec")
      end

      it "should call procs that are set as default" do
        default = mock
        default.expects(:calltest).once.returns("rspec")

        klass.property(:rspec, :default => ->() { default.calltest })
        expect(klass.phash_default_value(:rspec)).to eq("rspec")
      end

      it "should return configured default" do
        klass.property(:rspec, :default => "rspec string")
        expect(klass.phash_default_value(:rspec)).to eq("rspec string")
      end
    end
  end


  describe "#each" do
    it "should use get_proeprty_value and call hooks" do
      base.expects(:has_hook_method?).with(:x_prefetch_hook).returns(true)
      base.expects(:x_prefetch_hook)

      base.each {|k, v| }
    end
  end

  describe "#get_property_value" do
    it "should call a hook" do
      base.expects(:has_hook_method?).with(:x_prefetch_hook).returns(true).twice
      base.expects(:x_prefetch_hook).twice
      expect(base.x).to eq("hello")
      expect(base.x).to eq("hello")
    end

    it "should support not calling the hook" do
      base.expects(:has_hook_method?).with(:x_prefetch_hook).returns(false).twice
      base.expects(:x_prefetch_hook).never
      expect(base.x).to eq("hello")
      expect(base.x).to eq("hello")
    end
  end

  describe "#default_property_value" do
    it "should get the default from the class methods" do
      klass.expects(:phash_default_value).with(:rspec).once.returns("rspec")
      expect(base.default_property_value(:rspec)).to eq("rspec")
    end

    it "should clone the properties when possible" do
      default = "rspec"
      klass.expects(:phash_default_value).with(:rspec).once.returns(default)
      expect(base.default_property_value(:rspec)).to_not be(default)
    end

    it "should not fail on unclonable values" do
      default = true
      klass.stubs(:phash_default_value).with(:rspec).once.returns(default)
      expect(base.default_property_value(:rspec)).to be(default)
    end
  end

  describe "#phash_config" do
    it "should fetch the config from the class methods" do
      klass.expects(:phash_config).once
      base.phash_config
    end
  end

  describe "#phash_values" do
    it "should initialize with defaults if unknown and return intialized data in future" do
      base.expects(:default_property_value).with("x").once.returns("rspec")
      base.phash_values
      base.phash_values
    end
  end

  describe "#include?" do
    it "should correctly determine if a property is known" do
      expect(base.include?(:x)).to eq(true)
      expect(base.include?(:y)).to eq(false)
    end
  end

  describe "#update_property" do
    it "should support munging data via helper methods" do
      klass.send(:define_method, :test_update_munger, ->(old, new) { {:munged => new} })
      klass.property(:test, :default => nil, :validation => Hash)

      base.stubs(:validate_property)
      base.expects(:validate_property).with("test", {:munged => "rspec"})

      base.test = "rspec"
      expect(base.test).to eq({:munged => "rspec"})

      klass.send(:remove_method, :test_update_munger)
    end

    it "should support calling a hook post update" do
      klass.send(:define_method, :test_update_hook, ->(old) { self.side_effect = "side effect: %s: %s" % [old, self.test] })
      klass.property(:test, :default => nil, :validation => String)
      klass.property(:side_effect, :default => nil, :validation => String)

      base.test = "hello"
      base.test = "world"
      expect(base.side_effect).to eq("side effect: hello: world")

      klass.send(:remove_method, :test_update_hook)
    end

    it "should fail to update unknown properties" do
      expect {
        base.update_property(:nonexisting, 1)
      }.to raise_error("Unknown property nonexisting")
    end

    it "should validate and store values" do
      base.stubs(:validate_property)
      base.expects(:validate_property).with("x", "rspec").once

      base.update_property("x", "rspec")
      expect( base[:x] ).to eq("rspec")
    end
  end

  describe "#validate_property" do
    it "should fail to validate unknown properties" do
      expect { base.validate_property(:fail, nil) }.to raise_error("Unknown property fail")
    end

    it "should pass if validation is nil" do
      ASM::ItemValidator.expects(:validate).never

      klass.property(:y)
      expect(base.validate_property(:y, nil)).to eq(true)
    end

    it "should pass if supplied data is default" do
      ASM::ItemValidator.expects(:validate).never

      klass.property(:y, :default => nil, :validation => String)
      expect(base.validate_property(:y, nil)).to eq(true)
    end

    it "should short circuit on nil values" do
      ASM::ItemValidator.expects(:validate).never

      expect {
        base.validate_property(:x, nil)
      }.to raise_error("x should be String but got nil")
    end

    it "should pass validation to the ItemValidator" do
      ASM::ItemValidator.expects(:validate!).with("hello world", String).returns([true, nil])
      expect(base.validate_property(:x, "hello world")).to eq(true)
    end

    it "should raise the validator error messages correctly" do
      ASM::ItemValidator.expects(:validate!).with("hello world", String).returns([false, "rspec test"])
      expect {
        base.validate_property(:x, "hello world")
      }.to raise_error("x failed to validate: rspec test")
    end
  end

  describe "#[]" do
    it "should fetch while disabling hooks" do
      base.expects(:get_property_value).with(:foo, false).returns("rspec")
      expect(base[:foo]).to eq("rspec")
    end

    it "should fail on unknown properties" do
      expect { base[:foo] }.to raise_error("No such property: foo")
    end

    it "should fetch the correct value" do
      expect(base[:x]).to eq("hello")
    end
  end

  describe "#[]=" do
    it "should set the value via update_property" do
      base.expects(:update_property).with(:rspec, "test")
      base[:rspec] = "test"
    end
  end

  describe "#merge!" do
    it "should not try to merge non hashes" do
      expect { base.merge!("x") }.to raise_error("Can't merge String into Hash")
    end

    it "should merge the given values into the class" do
      klass.property(:y, :default => nil, :validation => String)
      base.merge!({"x" => "1", "y" => "2"})
      expect(base["x"]).to eq("1")
      expect(base["y"]).to eq("2")
    end
  end

  describe "#merge" do
    it "should all prefetch hooks when merging" do
      base.expects(:has_hook_method?).with(:x_prefetch_hook).returns(true)
      base.expects(:x_prefetch_hook)
      expect(base.merge("foo" => :bar)).to eq("x"=>"hello", "foo"=>:bar)
    end

    it "should not try to merge non hashes" do
      expect { base.merge("x") }.to raise_error("Can't merge String into Hash")
    end
  end

  describe "#method_missing" do
    it "should fetch properties with a hook when used as a method" do
      base[:x] = "rspec"
      base.expects(:get_property_value).with('x', true).returns("rspec")
      base.x
    end

    it "should support fetching properties as a method" do
      base[:x] = "rspec"
      expect(base.x).to eq("rspec")
    end

    it "should support setting properties as a method" do
      base.x("rspec")
      expect(base.x).to eq("rspec")
    end

    it "should support setting properties as a variable" do
      base.x = "rspec"
      expect(base.x).to eq("rspec")
    end

    it "should fail for non existing properties" do
      expect{ base.y(10) }.to raise_error(NameError, "undefined local variable or method `y'")
      expect{ base.y = 10 }.to raise_error(NameError, "undefined local variable or method `y='")
      expect{ base.y }.to raise_error(NameError, "undefined local variable or method `y'")
    end
  end

  describe "#to_hash" do
    it "should use get_property_value to call hooks when building the hash" do
      base.expects(:has_hook_method?).with(:x_prefetch_hook).returns(true)
      base.expects(:x_prefetch_hook)
      base.to_hash
    end

    it "should return all properties by default" do
      klass.property(:rspec, :default => nil, :tag => [:rspec])
      expect(base.to_hash).to eq({"rspec"=>nil, "x"=>"hello"})
    end

    it "should allow skipping of nil values" do
      klass.property(:rspec, :default => nil)
      expect(base.to_hash(true)).to eq({"x"=>"hello"})
    end

    it "should allow building hashes of certain tags only" do
      klass.property(:rspec, :tag => [:rspec, :test])
      klass.property(:u, :tag => [:test, :rspec, :puppet])
      klass.property(:v, :tag => [])
      klass.property(:w, :tag => [:test, :rspec])
      klass.property(:y, :tag => [:puppet, :test])
      klass.property(:z, :tag => :rspec)

      expect(base.to_hash(false, [:rspec, :test])).to eq({"rspec" => nil, "u" => nil, "w" => nil})
    end
  end

  describe "#properties" do
    it "should provide a sorted list of all properties by default" do
      klass.property(:z)
      klass.property(:y)
      expect(base.properties).to eq(["x", "y", "z"])
    end

    it "should support selecting properties by tags" do
      klass.property(:rspec, :tag => [:rspec, :test])
      klass.property(:u, :tag => [:test, :rspec, :puppet])
      klass.property(:v, :tag => [])
      klass.property(:w, :tag => [:test, :rspec])
      klass.property(:y, :tag => [:puppet, :test])
      klass.property(:z, :tag => :rspec)

      expect(base.properties([:rspec, :test])).to eq(["rspec", "u", "w"])
      expect(base.properties([:puppet])).to eq(["u", "x", "y"])
      expect(base.properties([:test, :puppet])).to eq(["u", "y"])
    end
  end
end

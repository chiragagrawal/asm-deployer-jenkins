require 'spec_helper'
require 'asm/item_validator'

describe ASM::ItemValidator do
  describe "#validate!" do
    it "should support symbol validations" do
      v = ASM::ItemValidator.new(true, :boolean)
      v.expects(:symbol_validator).once.returns("rspec")
      expect(v.validate!).to eq("rspec")
    end

    it "should support array validations" do
      v = ASM::ItemValidator.new("one", ["one", "two"])
      expect(v.validate!).to eq([true, nil])

      v = ASM::ItemValidator.new("three", ["one", "two"])
      expect(v.validate!).to eq([false, "should be one of: one, two"])
    end

    it "should support regex validations" do
      expect(ASM::ItemValidator.new("rspec", /^rspec$/).validate!).to eq([true, nil])
      expect(ASM::ItemValidator.new("rspec", /^foo$/).validate!).to eq([false, "should match regular expression /^foo$/"])
    end

    it "should support proc validations" do
      expect(ASM::ItemValidator.new("rspec", ->(v) { v == "rspec"}).validate!).to eq([true, nil])
      expect(ASM::ItemValidator.new("foo", ->(v) { v == "rspec"}).validate!).to eq([false, "should validate against given lambda"])
    end

    it "should support class validations" do
      expect(ASM::ItemValidator.new("rspec", String).validate!).to eq([true, nil])
      expect(ASM::ItemValidator.new(1, String).validate!).to eq([false, "should be a String but is a Fixnum"])
    end

    it "should support equality validations" do
      expect(ASM::ItemValidator.new("rspec", "rspec").validate!).to eq([true, nil])
      expect(ASM::ItemValidator.new("rspec", "foo").validate!).to eq([false, 'should match "foo"'])
    end
  end

  describe "#symbol_validator" do
    it "should be able to test booleans" do
      expect(ASM::ItemValidator.new(true, :boolean).symbol_validator).to eq([true, nil])
      expect(ASM::ItemValidator.new(false, :boolean).symbol_validator).to eq([true, nil])
      expect(ASM::ItemValidator.new("1", :boolean).symbol_validator).to eq([false, "should be boolean"])
    end

    it "should delegate ip tests" do
      v = ASM::ItemValidator.new("2a01:7e00::f03c:91ff:fe50:b67f", :ipv6)
      v.expects(:ip_validator).with(6).once
      v.symbol_validator

      v = ASM::ItemValidator.new("80.85.84.108", :ipv4)
      v.expects(:ip_validator).with(4).once
      v.symbol_validator
    end
  end

  describe "#ip_validator" do
    it "should pass on ipv6" do
      v = ASM::ItemValidator.new("2a01:7e00::f03c:91ff:fe50:b67f", "x")
      expect(v.ip_validator(6)).to eq([true, nil])
      expect(v.ip_validator(4)).to eq([false, "should be a valid IPv4 address"])
    end

    it "should pass on ipv4" do
      v = ASM::ItemValidator.new("80.85.84.108", "x")
      expect(v.ip_validator(4)).to eq([true, nil])
      expect(v.ip_validator(6)).to eq([false, "should be a valid IPv6 address"])
    end

    it "should pass on any ip address" do
      v = ASM::ItemValidator.new("80.85.84.108", "x")
      expect(v.ip_validator(:any)).to eq([true, nil])

      v = ASM::ItemValidator.new("2a01:7e00::f03c:91ff:fe50:b67f", "x")
      expect(v.ip_validator(:any)).to eq([true, nil])
    end

    it "should fail on unsupported version schemes" do
      v = ASM::ItemValidator.new("hello world", "x")
      expect(v.ip_validator(:test)).to eq([false, "Unsupported IP address version 'test' given"])
    end

    it "should fail on non ips" do
      v = ASM::ItemValidator.new("hello world", "x")
      expect(v.ip_validator(4)).to eq([false, "should be a valid IPv4 address"])
      expect(v.ip_validator(6)).to eq([false, "should be a valid IPv6 address"])
      expect(v.ip_validator(:any)).to eq([false, "should be a valid IPv4 or IPv6 address"])
    end
  end
end

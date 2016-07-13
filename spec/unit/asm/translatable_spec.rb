require 'spec_helper'
require 'asm/translatable'

describe ASM::Translatable do
  before(:each) do
    @dummy_class = Class.new
    @dummy_class.extend(ASM::Translatable)
  end

  it 'should lookup the correct msgid and default message' do
    I18n.expects(:t).with(:RSPEC123, :default => "default message")
    @dummy_class.t(:RSPEC123, "default message")
  end

  it 'should pass supplied parameters' do
    I18n.expects(:t).with(:RSPEC123, :default => "default message", :rspec => "test")
    @dummy_class.t(:RSPEC123, "default message", :rspec => "test")
  end
end

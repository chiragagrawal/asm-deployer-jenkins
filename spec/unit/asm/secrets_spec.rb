require 'spec_helper'
require 'asm/secrets'
require 'hashie'

describe ASM::Secrets do
  describe "#create" do

    it 'should require a secrets_source' do
      expect do
        ASM::Secrets.create(Hashie::Mash.new({}))
      end.to raise_error
    end

    it 'should require valid secrets_source' do
      expect do
        ASM::Secrets.create(Hashie::Mash.new({:secrets_source => 'unknown'}))
      end.to raise_error
    end

    it 'should require asm_api_user for local secrets' do
      expect do
        ASM::Secrets.create(Hashie::Mash.new({:secrets_source => :local,
                                              :asm_api_domain => 'domain'}))
      end.to raise_error
    end

    it 'should require asm_api_domain for local secrets' do
      expect do
        ASM::Secrets.create(Hashie::Mash.new({:secrets_source => :local,
                                              :asm_api_user => 'user'}))
      end.to raise_error
    end

    it 'should create local secrets' do
      secret = ASM::Secrets.create(Hashie::Mash.new({:secrets_source => :local,
                                                     :asm_api_user => 'user',
                                                     :asm_api_domain => 'domain'}))
      secret.class.should == ASM::Secrets::LocalSecrets
    end

    it 'should require url.asm_secrets for rest secrets' do
      expect do
        ASM::Secrets.create(Hashie::Mash.new({:secrets_source => 'rest'}))
      end.to raise_error
    end

    it 'should create rest secrets' do
      conf = Hashie::Mash.new
      conf.secrets_source = :rest
      conf.url!.asm_secrets = 'http://dellasm:8081/asm/secret'
      secret = ASM::Secrets.create(conf)
      secret.class.should == ASM::Secrets::RestSecrets
    end
  end
end

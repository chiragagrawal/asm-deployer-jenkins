require 'spec_helper'
require 'asm/config'

describe ASM::Config do
  describe "#new" do
    it "should capture values" do
      config = ASM::Config.new({:large_process_concurrency => 2})
      expect(config.large_process_concurrency).to eq(2)
    end

    it "should eval large_process_concurrency" do
      config = ASM::Config.new({:large_process_concurrency => "2 * 2"})
      expect(config.large_process_concurrency).to eq(4)
    end
  end

  describe "#http_client_options" do
    it "should return a hash" do
      config = ASM::Config.new({:http_client_options => {:verify_ssl => OpenSSL::SSL::VERIFY_PEER}})
      expect(config.http_client_options).to eq({"verify_ssl" => OpenSSL::SSL::VERIFY_PEER})
    end
  end

  describe "#rest_client_options" do
    it "should return http_client_options as hash with symbol keys" do
      config = ASM::Config.new({:http_client_options => {:verify_ssl => OpenSSL::SSL::VERIFY_PEER}})
      expect(config.rest_client_options).to eq({:verify_ssl => OpenSSL::SSL::VERIFY_PEER})
    end

    it "should instantiate ssl_client_key" do
      File.stubs(:exists?).with("keyfile.pem").returns(true)
      File.stubs(:read).with("keyfile.pem").returns("key-bytes")
      OpenSSL::PKey::RSA.stubs(:new).with("key-bytes").returns("instantiated-key")
      config = ASM::Config.new({:http_client_options => {:ssl_client_key => "keyfile.pem"}})
      expect(config.rest_client_options).to eq({:ssl_client_key => "instantiated-key"})
    end

    it "should instantiate ssl_client_cert" do
      File.stubs(:exists?).with("cert.pem").returns(true)
      File.stubs(:read).with("cert.pem").returns("key-bytes")
      OpenSSL::PKey::RSA.stubs(:new).with("key-bytes").returns("instantiated-cert")
      config = ASM::Config.new({:http_client_options => {:ssl_client_key => "cert.pem"}})
      expect(config.rest_client_options).to eq({:ssl_client_key => "instantiated-cert"})
    end
  end

end

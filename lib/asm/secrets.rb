module ASM
  module Secrets
    def self.create(config)
      if config.secrets_source == :local
        raise 'Missing required asm_api_user configuration' unless config.asm_api_user
        raise 'Missing required asm_api_domain configuration' unless config.asm_api_domain
        LocalSecrets.new(config.asm_api_user, config.asm_api_domain)
      elsif config.secrets_source == :rest
        raise 'Missing required url.asm_secrets configuration' unless config.url.asm_secrets
        RestSecrets.new(config.url.asm_secrets, config.rest_client_options)
      else
        raise("Invalid secrets source: #{config.secrets_source}")
      end
    end

    class LocalSecrets
      def initialize(asm_api_user, asm_api_domain)
        @asm_api_user = asm_api_user
        @asm_api_domain = asm_api_domain
      end

      def api_auth
        filepath = ASM::Util::DATABASE_CONF
        raise(ArgumentError, "Invalid filepath: #{filepath}") unless File.exists? filepath
        config = YAML.load_file(filepath)
        raise Error, "Invalid config: #{config}" unless config.is_a? ::Hash
        conf = OpenStruct.new(config)

        if RUBY_PLATFORM == 'java'
          require 'jdbc/postgres'
          Jdbc::Postgres.load_driver
          url = "jdbc:postgresql://#{conf.host}/user_manager?user=#{conf.username}&password=#{conf.password}"
        else
          require 'pg'
          url = "postgres://#{conf.username}:#{conf.password}@#{conf.host}:#{conf.port}/user_manager"
        end
        query = <<EOF
SELECT apikey, api_secret FROM users AS u JOIN user_key AS k ON u.user_seq_id = k.user_seq_id_fk
  WHERE u.username = ? AND u.domain_name = ?
EOF
        Sequel.connect(url, :pool_timeout => 10, :max_connections => 8) do |db|
          row = db[query, @asm_api_user, @asm_api_domain].first
          if row
            row[:api_secret] = ASM::Cipher.decrypt_string(row[:api_secret])
          end
          row
        end
      end

      def device_config(cert_name)
        require 'asm/device_management'
        ASM::DeviceManagement.parse_device_config_local(cert_name)
      end

      def decrypt_string(id)
        require 'asm/cipher'
        ASM::CipherLocal.decrypt_string(id)
      end

      def decrypt_credential(id)
        require 'asm/cipher'
        ASM::CipherLocal.decrypt_credential(id)
      end

      def decrypt_token(id, request)
        require 'asm/cipher'
        token_key = request.params['token_key']
        data = ASM::PrivateUtil.get_serverdata(id)
        if data
          token_data = JSON.parse(data)
          # Check the timestamp information in the token data.
          # Proceed if current time is just 120 minutes past timestamp in the token data
          if ( Time.now.to_i - token_data['timestamp'].to_i ) > 14400 || token_key != token_data['token']
            ASM::PrivateUtil.delete_serverdata(id)
            raise(ASM::NotFoundException, "Token data is invalid or has expired for %s", [id])
          end
          ASM::CipherLocal.decrypt_string(token_data['data'].scan(/ASMCRED-(\S+)/).flatten.first)
        else
          raise(ASM::NotFoundException, "Token data is not available for %s", [id])
        end
      end
    end

    class RestSecrets
      def initialize(url, options = nil)
        require 'restclient'
        @conn = RestClient::Resource.new(url, options)
      end

      def api_auth
        JSON.parse(@conn['api/auth'].get)
      end

      def device_config(cert_name)
        begin
          response = @conn["device/#{cert_name}"].get
          Hashie::Mash.new(JSON.parse(response))
        rescue RestClient::ResourceNotFound
          # Return nil to match current behavior of DeviceManagement.parse_device_config
          nil
        end
      end

      def decrypt_string(id)
        begin
          @conn["string/#{id}"].get
        rescue RestClient::ResourceNotFound
          raise ASM::NotFoundException
        end
      end

      def decrypt_credential(id)
        begin
          response = @conn["credential/#{id}"].get
          Hashie::Mash.new(JSON.parse(response))
        rescue RestClient::ResourceNotFound
          raise ASM::NotFoundException
        end
      end

    end
  end

end

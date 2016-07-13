module ASM
  class Provider
    class Configuration
      class Serverupdate < Provider::Base
        puppet_type "asm::server_update"

        property :install_type,           :default => "uri",          :validation => String
        property :force_restart,          :default => false,          :validation => :boolean
        property :path,                   :default => nil,            :validation => String
        property :asm_hostname,           :default => nil,            :validation => String
        property :esx_hostname,           :default => nil,            :validation => String
        property :esx_password,           :default => nil,            :validation => String
        property :server_firmware,        :default => nil,            :validation => String
        property :server_software,        :default => nil,            :validation => String
        property :instance_id,            :default => nil,            :validation => String
        property :vcenter_cert,           :default => nil,            :validation => String
        property :vcenter_ha_config,      :default => nil,            :validation => String

        def server_firmware_munger(o_value, n_value)
          return n_value if n_value.is_a?(String) || n_value.nil?
          JSON.dump(n_value)
        end

        def server_software_munger(o_value, n_value)
          return n_value if n_value.is_a?(String) || n_value.nil?
          JSON.dump(n_value)
        end

        def vcenter_ha_config_munger(o_value, n_value)
          return n_value if n_value.is_a?(String)
          JSON.dump(n_value)
        end

        def configure_hook
          unless asm_hostname
            self.asm_hostname = ASM::Util.get_preferred_ip(type.device_config.host)
          end
        end
      end
    end
  end
end

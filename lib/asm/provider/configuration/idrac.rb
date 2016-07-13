module ASM
  class Provider
    class Configuration
      class Idrac < Provider::Base
        puppet_type "asm::idrac::config"

        property :chassis_name,           :default => "",             :validation => String
        property :register_dns,           :default => false,          :validation => :boolean
        property :dns_name,               :default => nil,            :validation => String
        property :datacenter,             :default => nil,            :validation => String
        property :aisle,                  :default => nil,            :validation => String
        property :rack,                   :default => nil,            :validation => String
        property :rackslot,               :default => nil,            :validation => String
        property :users,                  :default => nil,            :validation => String
        property :alert_destinations,     :default => nil,            :validation => String
        property :email_destinations,     :default => nil,            :validation => String
        property :smtp_server,            :default => nil,            :validation => String
        property :ntp_enabled,            :default => false,          :validation => :boolean
        property :ntp_preferred,          :default => nil,            :validation => String
        property :ntp_secondary,          :default => nil,            :validation => String
        property :time_zone,              :default => nil,            :validation => String
        property :power_cap,              :default => nil,            :validation => String
        property :power_cap_type,         :default => nil,            :validation => String
        property :ipmi_over_lan,          :default => false,          :validation => :boolean
        property :provider,               :default => "asm_decrypt",  :validation => String

        def users_munger(o_value, n_value)
          return n_value if n_value.is_a?(String)
          JSON.dump(n_value)
        end

        def alert_destinations_munger(o_value, n_value)
          return n_value if n_value.is_a?(String)
          JSON.dump(n_value)
        end

        def email_destinations_munger(o_value, n_value)
          return n_value if n_value.is_a?(String)
          JSON.dump(n_value)
        end
      end
    end
  end
end

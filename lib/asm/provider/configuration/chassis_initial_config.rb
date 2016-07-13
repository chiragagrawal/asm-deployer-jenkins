module ASM
  class Provider
    class Configuration
      class Chassisinitialconfig < Provider::Base
        puppet_type "asm::chassis::initial_config"

        property :idrac_network_type,     :default => nil,             :validation => String
        property :cmc_network_type,       :default => nil,             :validation => String
        property :iom_network_type,       :default => nil,             :validation => String
        property :idrac_networks,         :default => [],              :validation => Array
        property :idrac_slots,            :default => "",              :validation => String
        property :cmc_network,            :default => [],              :validation => Array
        property :iom_networks,           :default => [],              :validation => Array
        property :iom_slots,              :default => "",              :validation => String
        property :idrac_cred_id,          :default => nil,             :validation => String
        property :cmc_cred_id,            :default => nil,             :validation => String
        property :iom_cred_id,            :default => nil,             :validation => String
      end
    end
  end
end

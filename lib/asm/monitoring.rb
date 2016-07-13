require 'json'
require 'asm'
require 'pp'

module ASM
  class Monitoring
    def conf
      @config ||= database_config(ASM::Util::DATABASE_CONF)
    end

    def inventory_db
      @inventory_db ||= connect_db("asm_manager")
    end

    def credentials_db
      @credentials_db ||= connect_db("encryptionmgr")
    end

    def chassis_db
      @chassis_db ||= connect_db("chassis_ra")
    end

    def connect_db(db_name)
      if RUBY_PLATFORM == 'java'
        require 'jdbc/postgres'
        Jdbc::Postgres.load_driver
        Sequel.connect("jdbc:postgresql://#{conf.host}/#{db_name}?user=#{conf.username}&password=#{conf.password}")
      else
        require 'pg'
        Sequel.connect("postgres://#{conf.username}:#{conf.password}@#{conf.host}:#{conf.port}/#{db_name}")
      end
    end

    def update_service_status(state)
      inventory_db.from(:device_inventory).where('ref_id = ?', state["host"]).update(:health => state["state"], :health_message => state["service"])
    end

    def get_resources
      inventory_db.from(:device_inventory).where(:device_type => ['BladeServer', 'ChassisM1000e', 'RackServer', 'TowerServer', 'dellswitch', 'Server', 'ChassisFX', 'FXServer','equallogic','compellent','emcvnx',]).order(:ref_id)
    end

    # Determines if a Dell Server will emit metrics from it's iDRAC
    #
    # Only 13G and newer machines support metrics from their iDRAC, dell
    # machines are named like "PowerEdge M630" here the '3' indicates it's
    # a 13G machine. Based on the assumption that 14G machines will be '4'
    # this checks for >= 3
    #
    # @param model [String] a model like PowerEdge M630
    # @return [Boolean]
    def model_has_metrics?(model)
      if model =~ /\d(\d)\d/
        return true if Integer($1) >= 3
      end

      false
    end

    # Get a list of machines with iDRAC cards that support metrics
    #
    # Today that means iDRAC8 machines but could be others in future
    #
    # @return [Array<Hash>] all data from the device_inventory table
    def idrac_eight_inventory
      inventory_db.from(:device_inventory).where(:discover_device_type => ['IDRAC8']).order(:ref_id).to_a.select do |candidate|
        model_has_metrics?(candidate[:model])
      end
    end

    def get_chassis(svc_tag)
      chassis_db["SELECT chassis.*, iom.slot FROM chassis, iom  WHERE chassis.id = iom.chassis_ref_id AND iom.service_tag='#{svc_tag}'"]
    end

  end
end

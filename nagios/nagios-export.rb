#!/opt/puppet/bin/ruby

require 'asm'
require 'asm/cipher'
require 'erb'
require 'json'
require 'rest_client'
require 'asm/private_util'

def conf
  @config ||= database_config(ASM::Util::DATABASE_CONF)
end

def nagios_query(action,data=nil)
  base_url = ASM.config.url.nagios || 'http://localhost:8081/asm/nagios/'
  response = ASM::PrivateUtil.query(base_url, action, 'put', data)
  JSON.parse(response, :symbolize_names => true)
end

def inventory_db
  nagios_query('get_inventory')
end

def chassis_db(svc_tag)
  data = {
      :svc_tag => svc_tag
  }
  nagios_query('get_chassis', data)
end

def path_to_template(template)
  File.read(File.expand_path(File.join(File.dirname(__FILE__), "templates", template)))
end

def render_host(server, chassis)
  ERB.new(path_to_template("host.erb")).result(binding)
end

def render_services(server, chassis)
  erb = path_to_template("check_%s_hardware_health.erb" % server[:device_type])
  ERB.new(erb).result(binding)
end

def render_related_os_services(server, chassis)
  erb = path_to_template("check_%s_os_health.erb" % server[:os_image_type])
  ERB.new(erb).result(binding)
end

def chassis_for_switch(svctag, resources)
  chassis = chassis_db(svctag)
  result = nil

  if chassis.count == 1
    if chassis_tag = chassis.first[:service_tag]
      matched_chassis = resources.select{|r| r[:service_tag] == chassis_tag}

      if matched_chassis.count == 1
        result = matched_chassis.first.to_hash
        result[:chassis_slot] = chassis.first[:slot]
      end
    end
  end

  result
end

resources = inventory_db

config_file = [File.read(File.expand_path(File.join(File.dirname(__FILE__), "templates", "commands.cfg")))]

resources.each do |server|
  server[:credentials] = ASM::Cipher::decrypt_credential(server[:cred_id])
  server[:ip_address] = server[:ip_address].to_s
end

resources.each do |server|
  chassis = {}

  if server[:device_type] == "dellswitch"
   # Get the chassis or nil if tor switch
   chassis = chassis_for_switch(server[:service_tag], resources)
  end

  config_file << render_host(server, chassis)
  config_file << render_services(server, chassis)

  # disk checks via the OS is only done on C62-Series machines, device type "Server"
  if (server[:model].match(/^PowerEdge C62\d+/) && server[:os_ip_address] && !server[:os_ip_address].empty?)
    config_file << render_related_os_services(server, chassis)
  end
end

new_config = config_file.join("\n")
old_config = File.read("/etc/nagios/conf.d/asm.cfg") rescue ""

unless new_config == old_config
  File.open("/etc/nagios/conf.d/asm.cfg", "w") do |f|
    f.puts new_config
  end

  system("/sbin/service nagios reload 2>&1 >/dev/null")
end

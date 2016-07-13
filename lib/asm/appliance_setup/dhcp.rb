require 'asm'
require 'asm/service_deployment'
require 'asm/private_util'

module ASM
  module ApplianceSetup
    module DHCP
      class PuppetEventException < StandardError; end

      def self.logger
        @logger ||= ASM.logger
      end
      def self.set_dhcp (options)
        enabled = ASM::Util.to_boolean(options['enabled'])
        config = {}
        if(enabled)
          config = {
            'subnet' => options['subnet'],
            'netmask' => options['netmask'],
            'min_range' => options['startingIpAddress'],
            'max_range' => options['endingIpAddress'],
            'default_lease' => options['defaultLeaseTime'],
            'max_lease' => options['maxLeaseTime']
          }
          #Optional parameters
          config['default_gateway'] = options['gateway'] unless options['gateway'].nil? || options['gateway'] == ''
          config['dns'] = options['dns'] unless options['dns'].nil? || options['dns'] == ''
          config['domain'] = options['domain'] unless options['domain'].nil? || options['domain'] == ''
        end
        config['service_ensure'] = enabled ? 'running' : 'stopped'
        begin
          result = run_puppet(config)
          logger.info("Successfully ran puppet to configure DHCP. Result: #{result}")
          {'message' => result, 'status' => 200}
        rescue => e
          logger.error("Could not set DHCP correctly.  Exception: #{e.message}")
          {'message' => e.message, 'status'=> 500}
        end
      end

      def self.create_yaml(config, certname='dellasm')
        yaml_content = 
        {
          certname=> {
            'classes'=> {
              'asm::dhcp'=> config 
        }}}
        ASM::PrivateUtil.write_node_data(certname, yaml_content)
      end

      def self.run_puppet(config, certname='dellasm', noop=false)
        create_yaml(config, certname)
        #Puppet apply does not work without some "trash" code in the -e flag, so the notice($certname) is code that won't do anything, but the configuration in the yaml file will still be run.
        cmd = "sudo puppet apply -e 'notice($certname)' --certname #{certname} --detailed-exitcodes"
        results = ASM::Util.run_command(cmd)
        #Puppet returns error code 2 if catalog was successful with detailed-exitcodes
        unless [0,2].include?(results['exit_status'])
          raise(PuppetEventException, results['stderr'])
        end
        return "success"
      end
    end
  end
end

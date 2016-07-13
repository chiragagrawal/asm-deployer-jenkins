module ASM
  class Provider
    class Application
      class Puppet < Provider::Base
        puppet_type "asm::application"

        def prepare_for_teardown!
          # Application can only be related to one entity so the following is safe
          related_host = type.related_server || type.related_vm

          ASM::PrivateUtil.remove_from_node_data(related_host.agent_certname, type.component_configuration, logger)
        end

        def should_inventory?
          false
        end
      end
    end
  end
end

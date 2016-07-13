require "asm/util"
require "rbvmomi"

module ASM
  class Provider
    class Virtualmachine
      class Vmware < Provider::Base
        puppet_type "asm::vm::vcenter", "asm::vm"

        VALID_SCSI_TYPES = ["BusLogic Parallel", "LSI Logic SAS", "LSI Logic Parallel", "VMware Paravirtual"].freeze

        property :ensure,                       :default => "present",                :validation => ["present", "absent"]
        property :cpu_count,                    :default => nil,                      :validation => /^\d+$/
        property :memory_in_mb,                 :default => nil,                      :validation => /^\d+$/
        property :disksize_in_gb,               :default => nil,                      :validation => /^\d+$/
        property :cluster,                      :default => nil,                      :validation => String
        property :os_type,                      :default => nil,                      :validation => String
        property :os_guest_id,                  :default => nil,                      :validation => String
        property :datacenter,                   :default => nil,                      :validation => String
        property :vcenter_id,                   :default => nil,                      :validation => String
        property :vcenter_options,              :default => {"insecure" => true},     :validation => Hash
        property :clone_type,                   :default => nil,                      :validation => String
        property :source,                       :default => nil,                      :validation => String
        property :source_datacenter,            :default => nil,                      :validation => String
        property :datastore,                    :default => nil,                      :validation => String
        property :skip_local_datastore,         :default => false,                    :validation => :boolean
        property :network_interfaces,           :default => nil,                      :validation => Array
        property :scsi_controller_type,         :default => "VMware Paravirtual",     :validation => VALID_SCSI_TYPES
        property :default_gateway,              :default => nil,                      :validation => String

        property :requested_network_interfaces, :default => [],                       :validation => Array,  :tag => :extra
        property :hostname,                     :default => nil,                      :validation => String, :tag => :extra

        attr_accessor :server

        # Merge in the configured asm::server
        #
        # By default additional resources will be included in to_puppet but
        # in this provider we have to also reconfigure the asm::server for
        # example we change its uuid.
        #
        # So this overrides the asm::server from additional resources with our
        # mogrified one
        #
        # @return [Hash] asm::server puppet resource or empty Hash when no server found
        def additional_resources
          if @server
            @server.to_puppet
          else
            {}
          end
        end

        def configure_hook
          configure_guest_type! if configure_server!
          configure_network!
          configure_certname!
        end

        def prepare_for_teardown!
          if @server
            begin
              @server.delete_server_cert!
              @server.delete_server_node_data!
            rescue
              logger.warn("Could not delete certificate for server %s: %s: %s" % [@server.puppet_certname, $!.class, $!.to_s])
            end
          else
            # handle the cloned VM case:
            delete_vm_cert!
          end

          true
        end

        # Cleans the puppet cert for the cloned VM
        #
        # @api private
        # @return [void]
        def delete_vm_cert!
          logger.debug("Fetching mac address for clone VM #{hostname} from #{vcenter_id} to find the certname")
          certname = "vm#{macaddress.downcase}"
          logger.info("Deleting certificate for clone VM #{hostname}; certname = #{certname}")
          ASM::DeviceManagement.clean_cert(certname) unless debug?
        end

        def cluster_supported?(cluster)
          cluster.provider_path == "cluster/vmware"
        end

        def configure_certname!
          type.puppet_certname = "vm-%s" % hostname.downcase if hostname
        end

        def hostname
          if @server
            self[:hostname] || @server.hostname
          else
            self[:hostname]
          end
        end

        # Returns the agent certname
        #
        # @return [String]
        def agent_certname
          if clone?
            "vm%s" % macaddress.delete(":").downcase
          else
            ASM::Util.hostname_to_certname(hostname)
          end
        end

        # Returns true if cloned vm
        #
        # @return [Bool]
        def clone?
          !!clone_type
        end

        # Creates a ASM::Type::Server and configure both resources
        #
        # @return [Boolean] whether or not a server resource could be created
        def configure_server!
          if @server ||= create_server_resource
            self[:hostname] ||= @server.hostname
            @server.provider.uuid = hostname
            self.uuid = hostname

            @server.serial_number = "" if type.teardown?
            true
          else
            # clones do not have @server
            self.uuid = hostname
            false
          end
        end

        # @api private
        # @return [ASM::Type::Server, nil] nil on failure
        def create_server_resource
          server = type.service_component.resource_by_id("asm::server")
          server_component = server.to_component(nil, "SERVER")
          server_component.to_resource(type.deployment, logger)
        rescue
          logger.warn("Could not create the associated Server resource for Virtual Machine %s: %s: %s" % [type.puppet_certname, $!.class, $!.to_s])
          nil
        end

        # Configures the network interfaces for the resources
        #
        # This should implement all the work from ASM::Resource::VM::VMware#process! but as teardown
        # sets network_interfaces to nil anyway we can luckily skip that for now
        #
        # @api private
        # @return [void]
        def configure_network!
          if self[:ensure] == "absent" || type.teardown?
            self[:network_interfaces] = nil
          else
            logger.warn("Cannot configure networking for Virtual Machine %s as it only supports teardown" % type.puppet_certname)
          end
        end

        def lazy_configure_related_cluster
          return if @__cluster_configured

          configure_related_cluster!

          @__cluster_configured = true
        end

        def cluster_prefetch_hook
          lazy_configure_related_cluster
        end

        def datacenter_prefetch_hook
          lazy_configure_related_cluster
        end

        def vcenter_id_prefetch_hook
          lazy_configure_related_cluster
        end

        def vcenter_options_prefetch_hook
          lazy_configure_related_cluster
        end

        # Configure the related cluster into the VM properties if not supplied
        #
        # @api private
        # @return [void]
        def configure_related_cluster!
          if cluster = type.related_cluster
            if cluster.supports_resource?(type)
              # usually providers should not go spelunking into other providers but as
              # both of these are VMware and effectively part of the same package this is
              # ok, they are both in each others private domain
              self[:cluster] ||= cluster.provider.cluster
              self[:datacenter] ||= cluster.provider.datacenter
              self[:vcenter_id] ||= cluster.puppet_certname

              if self[:vcenter_options].empty?
                self[:vcenter_options] = {"insecure" => true}
              end
            else
              logger.warn("Virtual machine %s is not supported by cluster %s" % [type, cluster])
            end
          else
            logger.warn("Cannot find a related cluster for Virtual Machine %s" % type.puppet_certname)
          end
        end

        # @api private
        # @return [void]
        def configure_guest_type!
          if @server
            image_type = @server.os_image_type
          else
            image_type = "unknown"
          end

          case image_type
          when /windows/
            self[:os_type] = "windows"
            self[:os_guest_id] = "windows8Server64Guest"
            self[:scsi_controller_type] = "LSI Logic SAS"
          else
            self[:os_type] = "linux"
            self[:os_guest_id] = "rhel6_64Guest"
            self[:scsi_controller_type] = "VMware Paravirtual"
          end
        end

        # Returns the device configuration as a hash
        #
        # @return [Hash] the device configuration data
        def cluster_conf
          @conf ||= ASM::DeviceManagement.parse_device_config(vcenter_id)
        end

        # Returns the macaddress of the VM without colons
        #
        # @return [String]
        def macaddress
          return "06000000000f" if debug?
          value = ASM::Util.block_and_retry_until_ready(300, NoMethodError, 10) do
            vm.guest.net.first.macAddress
          end
          value.delete(":")
        end

        # Returns the VM object, which is the representation of the actual VM in the vCenter, by the name of the VM
        #
        # @return [Object]
        def vm
          @vm ||= findvm(dc.vmFolder, (hostname || @hostname))
        end

        # Helper method to find the VM from the given folder object in the VIM library
        #
        # @return [Object]
        def findvm(folder, name)
          folder.children.each do |subfolder|
            break if @vm_obj
            case subfolder
            when RbVmomi::VIM::Folder
              findvm(subfolder, name)
            when RbVmomi::VIM::VirtualMachine
              @vm_obj = subfolder if subfolder.name == name
            when RbVmomi::VIM::VirtualApp
              @vm_obj = subfolder.vm.find {|vm| vm.name == name }
            else
              raise(ArgumentError, "Unknown child type: #{subfolder.class}")
            end
          end
          @vm_obj
        end

        # Returns the datacenter object from the VIM library
        #
        # @return [Object]
        def dc
          @dc ||= vim.serviceInstance.find_datacenter(datacenter)
        end

        # Returns the VIM object that is connected to the target vCenter of the given vCenter device configurations
        #
        # @return [Object]
        def vim
          @vim ||= begin
            raise("Resource has not been processed.") unless cluster_conf

            options = {
              :host => cluster_conf.host,
              :user => cluster_conf.user,
              :password => cluster_conf.password,
              :insecure => true
            }
            RbVmomi::VIM.connect(options)
          end
        end
      end
    end
  end
end

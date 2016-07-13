require "asm"
require "asm/util"
require "fileutils"
require "tempfile"
require "erb"

module ASM
  # Utility module for building custom iPXE ISO images
  module IpxeBuilder
    IPXE_DIR = ASM.config.ipxe_src_dir
    LOCK = Mutex.new

    def self.ipxe_dir
      IPXE_DIR
    end

    def self.ipxe_src_dir
      File.join(ipxe_dir, "src")
    end

    def self.path_to_template(template)
      File.read(File.expand_path(File.join(File.dirname(__FILE__), "..", "..", "templates", template)))
    end

    def self.render_bootstrap(network_config, n_nics)
      ERB.new(path_to_template("bootstrap.ipxe.erb"), nil, "-").result(binding)
    end

    # Generates a bootstrap.ipxe file for specified network configuration
    #
    # @param network_config [ASM::NetworkConfiguration] the configuration. Must have had {ASM::NetworkConfiguration#add_nics!} called on it.
    # @param n_nics [FixNum] the total number of network devices on the target server
    # @param path [String] the file path to save the resulting bootstrap script to
    def self.generate_bootstrap(network_config, n_nics, path)
      File.write(path, render_bootstrap(network_config, n_nics))
    end

    # Retrieves static network configuration
    #
    # Information is only provided for static OS installs otherwise nil is returned
    #
    # @example returned data
    #
    #     {
    #       "macAddress" => "EC:F4:BB:BF:29:7C",
    #       "ipAddress" => "172.25.3.151",
    #       "netmask" => "255.255.0.0",
    #       "gateway" => "172.25.0.1"
    #     }
    #
    # @note the network configuration must have had {ASM::NetworkConfiguration#add_nics!} ran
    # @param network_config [NetworkConfiguration]
    # @return [Hash,nil] nil when not a static OS install
    # @raise [StandardError] when network config is incomplete or incorrect
    def self.get_static_network_info(network_config)
      # Collect network configuration info
      partition = network_config.get_partitions("PXE").first
      if partition
        mac_address = partition.mac_address
        # Must have MAC address for netsh command in SET_STATIC_IP.CMD script
        raise("MAC address missing in network config. The network config must have had add_nics! run.") unless mac_address

        network = partition.networkObjects.find { |p| p["type"] == "PXE" }
        static = network.static && network.staticNetworkConfiguration
        if static
          # If this is a static OS install, we must have an IP address
          # and subnet for the netsh command in the SET_STATIC_IP.CMD
          # script which will be included in the generated ISO.
          raise("IP address missing in network config") unless static.ipAddress
          raise("subnet missing in network config") unless static.subnet

          # Create hash with ip and dns info
          {
            "macAddress" => mac_address,
            "ipAddress" => static.ipAddress,
            "netmask" => static.subnet,
            "gateway" => static.gateway
          }
        end
      end
    end

    # Build a custom iPXE ISO image targeted to the specified network configuration
    #
    # The custom ISO image will contain a bootstrap.ipxe file tailored to the
    # provided network configuration object. On boot with the ISO, ethernet devices
    # corresponding to the PXE partitions in the network configuration will be configured with
    # either static or DHCP networking as specified by the PXE network. Each ethernet
    # device will be tried sequentially, so if iPXE chain-loading fails on one
    # device the boot will be retried with subsequent devices.
    #
    # In the case of static networking, the SET_STATIC_IP.CMD script is included
    # in the image for use by our customized WinPE environment. This script sets
    # up static networking for WInPE. It is customized by sed in the geniso script
    # to include the networking info from the network config passed in.
    #
    # @param network_config [ASM::NetworkConfiguration] the configuration. Must have had {ASM::NetworkConfiguration#add_nics!} called on it.
    # @param n_nics [FixNum] the total number of network devices on the target server
    # @param dest_filename [String] the file path to save the resulting ISO
    # @raise [StandardError] if a failure occurs while building the ISO
    def self.build(network_config, n_nics, dest_filename)
      bootstrap_file = nil
      LOCK.synchronize do
        bootstrap_file = Tempfile.new("bootstrap.ipxe")
        generate_bootstrap(network_config, n_nics, bootstrap_file.path)

        # Clean any previous iso image for the target IP in our mount area
        FileUtils.rm_f(dest_filename)

        # Remove any existing ipxe.iso to force rebuild of image
        # with new SET_STATIC_IP.CMD script with data from current
        # deployment
        FileUtils.rm_f(File.join(ipxe_src_dir, "bin", "ipxe.iso"))

        # Create hash with ip and dns info
        ip_info = get_static_network_info(network_config)

        if !ip_info.nil?
          ret = ASM::Util.run_command("env", "IP_ADDRESS=%s" % ip_info["ipAddress"],
                                      "MAC_ADDRESS=%s" % ip_info["macAddress"],
                                      "NETMASK=%s" % ip_info["netmask"],
                                      "GATEWAY=%s" % ip_info["gateway"],
                                      "make", "-C", ipxe_src_dir,
                                      "bin/ipxe.iso", "EMBED=%s" % bootstrap_file.path)
        else
          ret = ASM::Util.run_command("make", "-C", ipxe_src_dir,
                                      "bin/ipxe.iso", "EMBED=%s" % bootstrap_file.path)
        end
        raise("iPXE ISO build failed: %s" % ret.to_s) unless ret.exit_status == 0
        FileUtils.mv(File.join(ipxe_src_dir, "bin", "ipxe.iso"), dest_filename)
      end
      nil
    ensure
      bootstrap_file.unlink if bootstrap_file
    end
  end
end

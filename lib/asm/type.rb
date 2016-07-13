require "asm/type/base"
require "asm/provider/base"
require "asm/type/virtualmachine"
require "asm/type/cluster"
require "asm/type/server"
require "asm/type/volume"
require "asm/type/controller"
require "asm/type/switch"
require "asm/type/configuration"
require "asm/type/application"

module ASM
  class Type
    def self.providers
      if @providers.nil?
        @providers = []
        load_providers!
      end

      @providers
    end

    def self.register_provider(puppet_type, klass)
      unless klass.to_s.end_with?("Base")
        providers << {:type => puppet_type, :class => klass}
      end
    end

    # load all not yet loaded providers in libdir/asm/provider/*/* so they will
    # register their puppet_types into Type#register_provider
    def self.load_providers!
      providers_dir = File.expand_path(File.join(File.dirname(__FILE__), "provider"))

      Dir.glob("%s/*/*.rb" % providers_dir).each do |provider|
        require(provider)
      end
    end

    def self.component_type(component)
      # we have asm::volume but component["type"] STORAGE :(
      if component.type == "STORAGE"
        type = "volume"
      elsif component.type == "SERVICE"
        type = "application"
      else
        type = component.type.downcase
      end
      require "asm/type/%s" % type.downcase
      const_get(type.capitalize)
    end

    def self.to_resource(component, type=nil, deployment=nil, logger=ASM.logger)
      type = component_type(component) unless type

      instance = type.create(component, logger)
      instance.deployment = deployment
      if RUBY_PLATFORM == "java"
        require "jruby/synchronized"
        instance.extend(JRuby::Synchronized)
      end
      instance
    end

    def self.to_resources(components, type=nil, deployment=nil, logger=ASM.logger)
      components.map do |component|
        to_resource(component, type, deployment, logger)
      end
    end
  end
end

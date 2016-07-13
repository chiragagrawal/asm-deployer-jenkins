module ASM
  # A class to provide standardised validation in rules and providers
  #
  # @example puppet properties in a provider validated using ItemValidator
  #
  #   property  :ensure,         :default => 'present',   :validate => ['present','absent']
  #   property  :hosts,          :default => [],          :validate => Array
  #   property  :nfsipaddress,   :default => nil,         :validation => :ipaddress
  #
  # @example rule state validated using ItemValidator
  #
  #   require_state :resource, ASM::Type::Cluster
  #   require_state :target, :ipaddress
  #
  # In both these examples the ItemValidator is used to do the validation, in both the
  # last paramater is the validation
  #
  # @example programatically validate something
  #
  #    ItemValidator.validate!("192.168.1.1", :ipv4)
  #    => [true, nil]
  #
  #    ItemValidator.validate!("bob", :ipv4)
  #    => [false, "should be a valid IPv4 address"]
  #
  # At present the validator supports the following validations:
  #
  #  * :ipv4 - must be a IPv4 address
  #  * :ipv6 - must be a IPv6 address
  #  * :ipaddress - must be either a IPv4 or IPv6 address
  #  * :boolean - either true or false
  #  * /something/ - the value must match the regex
  #  * ["one", "two"] - the value must exactly match one of the array members
  #  * {|v| v <= 10} - the proc must return true/false, +v+ is the value being validated
  #  * String - the value must be of the class String or one inheriting from String
  #  * "x" - the value must be "x"
  #
  # @note code is based on https://github.com/ripienaar/gwtf/blob/master/lib/objhash.rb
  class ItemValidator
    attr_accessor :value, :validation

    # Validates value using validation
    #
    # @return [Array<Boolean, String>] the boolean indicates validation pass/fail and a string with an error, nil on success
    def self.validate!(value, validation)
      ItemValidator.new(value, validation).validate!
    end

    def initialize(value=nil, validation=nil)
      @value = value
      @validation = validation
    end

    def v4_address?(address)
      IPAddr.new(address).ipv4?
    rescue
      false
    end

    def v6_address?(address)
      IPAddr.new(address).ipv6?
    rescue
      false
    end

    def ip_validator(version)
      require 'ipaddr'

      case version
        when 4
          return([false, "should be a valid IPv4 address"]) unless v4_address?(value)
        when 6
          return([false, "should be a valid IPv6 address"]) unless v6_address?(value)
        when :any
          return([false, "should be a valid IPv4 or IPv6 address"]) unless v4_address?(value) || v6_address?(value)
        else
          return([false, "Unsupported IP address version '%s' given" % version])
      end

      [true, nil]
    end

    def symbol_validator
      validated = false
      fail_message = nil

      case validation
        when :boolean
          if [TrueClass, FalseClass].include?(value.class)
            validated = true
          else
            fail_message = "should be boolean"
          end
        when :ipv6
          validated, fail_message = ip_validator(6)
        when :ipv4
          validated, fail_message = ip_validator(4)
        when :ipaddress
          validated, fail_message = ip_validator(:any)
        else
          fail_message = "unknown symbol validation: %s" % [validation]
      end

      [validated, fail_message]
    end

    # Performs the validation
    #
    # @note using {ItemValidator.validate!} is probably easier
    # @return [Array<Boolean, String>] the boolean indicates validation pass/fail and a string with an error, nil on success
    def validate!
      if validation.is_a?(Symbol)
        return symbol_validator

      elsif validation.is_a?(Array)
        unless validation.include?(value)
          return([false, "should be one of: %s" % validation.join(", ")])
        end

      elsif validation.is_a?(Regexp)
        unless value.match(validation)
          return([false, "should match regular expression %s" % validation.inspect])
        end

      elsif validation.is_a?(Proc)
        unless validation.call(value)
          return([false, "should validate against given lambda"])
        end

      elsif validation.is_a?(Class)
        unless value.is_a?(validation)
          return([false, "should be a %s but is a %s" % [validation, value.class]])
        end

      else
        unless value == validation
          return([false, "should match %s" % validation.inspect])
        end
      end

      [true, nil]
    end
  end
end

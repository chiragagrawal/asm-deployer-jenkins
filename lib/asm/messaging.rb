if RUBY_PLATFORM == 'java'
  require 'torquebox-messaging'
else
  # Shim for loading Processor classes in MRI ruby where torquebox-messaging
  # is not supported.
  module TorqueBox
    module Messaging
      class MessageProcessor; end
    end
  end
end

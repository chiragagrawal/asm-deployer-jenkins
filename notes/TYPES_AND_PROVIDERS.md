# ASM Types and Provider System

A new way of writing code specific to hardware is being integrated into ASM - first into the teardown part of the code.

The goals of the system is to separate hardware specific code and program flow code so that additional hardware types can be added in isolation and potentially by 3rd parties in the future.

This necessitates a big shift in how we write code and requires greater discipline wrt code quality and review.

The code uses a few terms, some are borrowed from Puppet:

  * **Type** - A Ruby class that represents the public API to the hardware but has no hardware specific logic, example *ASM::Type::Volume*, inherits behaviours from *ASM::Type::Base*.
  * **Providers** - A Ruby class that contains hardware specific logic.  These classes go hand in hand with Puppet modules like the *dell-equallogic* module and so contains a list of all properties the class supports.
  * **Service** - A work in progress abstraction of the JSON template the ASM core and frontend produces.  The *ASM::Service* class represents a single template and contains many *ASM::Service::Component* instances corresponding to *template["serviceTemplate"]["components"]*
  * **Component** - A single item that needs to be managed, a Volume or a Virtual Machine or a Cluster.
  * **Component Resource** - Components can be made up of many resources, these are instances of *ASM::Service::Component::Resource*
  * **Resource** - An instance of a type that represents a single Component that provides access to the provider.
  * **YARD** - A Ruby API documentation system, we will use this to document the new code - see http://yardoc.org/

## Types and Providers Usage Overview

Here as a quick overview we have a service template that has a number of components in it.  To show what is in the template we can use the new *ASM::Service*:

```ruby
raw_service = JSON.parse(File.read("service.json"), :max_nesting => 100)
service = ASM::Service.new(raw_service)

service.each_component do |component|
  puts "%20s: %s - %s" % [component.type, component.name, component.puppet_certname]
end
```

will produce:

```
      VIRTUALMACHINE: vCenter Virtual Machine - FE8E1A17-259B-427A-ADA6-A2581F19B012
      VIRTUALMACHINE: vCenter Virtual Machine 2 - 8EA87B82-72F2-431E-8A79-8390B17E7F6A
             CLUSTER: VMWare Cluster - vcenter-env02-vcenter.aidev.com
              SERVER: Server - bladeserver-jgd5hw1
             STORAGE: EqualLogic - equallogic-eql-env02
```

We'll take the first STORAGE component and force create it - actual creation is stubbed, it would print a puppet command.

We specifically set *ensure*, *passwd* and *encrypt* here overriding the template, in general use the template will populate everything - doing it here just to show how to reach the properties and force creation.

```ruby
require 'logger'
require 'asm/type'
require 'pp'

# usually an instance of ASM::ServiceDeployment
class StubDeployer
  def process_generic(*args)
    File.open("/tmp/test/resources", "w") {|f| f.puts args[1].to_yaml}

    puts "puppet asm process_node --debug --trace --filename %s --run_type %s --statedir /tmp/test %s" % ["/tmp/test/resources", args[2], args[0]]
  end
end


# would default to ASM.logger
logger = Logger.new(STDOUT)

service = ASM::Service.new(raw_service)
component = service.components_by_type("STORAGE").first

# resource would be a ASM::Type::Volume based on the contents of the template
resource = component.to_resource(StubDeployer.new, logger)

# resource.provider is ASM::Provider::Volume::Equallogic and exposes
# all the puppet module properties.  They are initiated by default to
# the values in the Service
resource.provider.ensure = "present"
resource.provider.passwd = "secret"
resource.provider.decrypt = false

# all providers respond to process! and does the basic puppet run via
# ServiceDeployment#process_generic
resource.process!
```

The code creates a fake *ASM::ServiceDeployment* to keep things short, otherwise this is typical ASM code and will
create a Equallogic volume.

This shows the preferred way to go about creating a resource from a component, other ways could be:

```ruby
service = ASM::Service.new(raw_service)
component = service.components_by_type("STORAGE").first

resource = ASM::Type.to_resource(component, nil, StubDeployer.new)
```

Or to create a collection of resources:

```ruby
service = ASM::Service.new(raw_service)
resources = ASM::Type.to_resources(service.components, StubDeployer.new)
```

## Writing a Type

For the most part types are very small, they all inherit from *ASM::Type::Base* which brings a bunch of standard behaviours like *#related_server*, *#related_servers*, *#related_cluster* and all that's needed to create instances of the type.

Types have no hardware specific code and unlike types in Puppet they do not expose all the properties the hardware has.  As we are not greenfield we cannot now model all our properties so to access properties you'd use the provider later on.

Types can add more methods as long as they are not hardware specific, here's the Volume type that adds an additional helper method and overrides the *#related_cluster* from the Base class with something that's more appropriate.

The override and additional helper is optional so the default Type is just an empty class that inherits from *Base* and do not need tests.

Inline documentation complies with YARD:

```ruby
# lib/asm/type/volume.rb
require 'asm/type'

module ASM
  class Type
    # A type that represents a volume to ASM
    class Volume < Base
      # Remove the storage volume from any clusters using it.
      #
      # Typically this will be used before calling {#process!} when tearing down
      # clusters to avoid a situation where a volume is deleted but clusters are
      # still referencing it.
      #
      # @return [void]
      # @raise [StandardError] when the volume is not associated with the related cluster
      # @method remove_storage_from_cluster!
      def remove_storage_from_cluster!
        delegate(provider, remove_storage_from_cluster!)
      end

      # Finds any related Clusters where a Volume is used
      #
      # Can return nil if no related resources are found
      #
      # @return [ASM::Type::Cluster]
      def related_cluster
        if server = related_server
          if cluster = server.related_cluster
            return cluster
          end
        end

        nil
      end
    end
  end
end
```

The use of *delegate* should be noted here, the *remove_storage_from_cluster!* method exist on the provider.  It's the hardware specific logic. But the type needs a proxy method to call it as the type is the public interface. Here the use of ```delegate()``` is achieving the same as ```provider.remove_storage_from_cluster!``` would but with additional debug logging that would show who is calling what.  It's just a convenience method to avoid repetitive calls to debug logging.

Tests for this type are quite simple and uses the new rspec syntaxes:

```ruby
# spec/unit/asm/type/volume_spec.rb
require 'spec_helper'
require 'asm/type/volume'

describe ASM::Type::Volume do
  let(:logger) { stub(:debug, :warn, :info) }
  let(:cluster) { stub }
  let(:server) { stub(:related_cluster => cluster) }
  let(:volume) { ASM::Type::Volume.new({}, "rspec", {}, logger) }

  describe "#related_cluster" do
    it "should return the related cluster" do
      volume.expects(:related_server).returns(server)
      expect(volume.related_cluster).to eq(cluster)
    end

    it "should return nil when no related server can be found" do
      volume.expects(:related_server).returns(nil)
      expect(volume.related_cluster).to eq(nil)
    end

    it "should return nil when no related cluster can be found" do
      volume.expects(:related_server).returns(server)
      server.expects(:related_cluster).returns(nil)
      expect(volume.related_cluster).to eq(nil)
    end
  end
end
```

## Writing a Provider

Providers go along with a Puppet module, this example uses the *asm::volume::equallogic* defined type to create *ASM::Provider::Volume::Equallogic*.

The Provider must know about all the properties the *asm::volume::equallogic* type can take, their defaults, valid inputs etc. and it needs to declare it's related to the Puppet Type.  To do this some DSL like methods are used:


```ruby
module ASM
  class Provider
    class Volume
      # Provider that is capable of handling basic creation and destruction of Equallogic
      # volumes based on the +asm::volume::equallogic+ puppet class
      class Equallogic < Provider::Base
        puppet_type "asm::volume::equallogic"
        pupppet_run_type "device"

        property  :size,              :default => nil,        :validation => /\d+GB/
        property  :ensure,            :default => "present",  :validation => ["present", "absent"]
        .
        .
      end
    end
  end
end
```

Providers **must** have the *puppet_type* defined, this associates any components found in the template with the declared defined type with this provider.  Only 1 provider per puppet resource type.

Providers **may** have the *puppet_run_type* defined, this can be *apply* or *device*.  It will default to *apply* if not set in the provider.

Providers **must** have *property* lines for every property in the Puppet defined type.  These lines do the following:

  * Creates a getter and setter for each property
  * Sets defaults if the component did not supply a value
  * Sets up validation, any attempt to set a property will be validated.  Validation is done using *ASM::ItemValidator*. Some special validations values like *:boolean*, *:ipv4* and *:ipv6* can be used - see the ItemValidator.

If the module and the Provider do not agree on these things will go bad, settings will get lost or templates will be rejected or other undefined outcomes.  Only declared properties will be fetched from the template and fed into the class.

A provider like the one above is all that's needed in the most basic case and the sample code found at the top of this document will work.  Every provider has a *#process!* method via the Base class and this supports calling *#process_generic* with a Puppet representation of the provider.  So given the *asm::volume::equallogic* Puppet type these lines are all you need to create and destroy an Equallogic Volume using ASM.

Unfortunately it does not stay this simple.  Consider the case where we want to tear down a volume: If the volume was in use by any clusters and we just did *ensure => absent* in Puppet then those clusters will all enter an error state as the volume just vanished while they are still using the volume.

So the Equallogic provider has an additional method called *#remove_storage_from_cluster!* that takes care of this and unfortunately we just need to know that we have to call this method before *#process!* is called.  In future we might have a way to express this need in the provider but we'll have to keep that as a future enhancement.

So to provide this additional method the *ASM::Type::Volume* expose the public part of the method and the provider must implement the hardware specific method.  Every volume provider will have to implement this method, soon as it's on the type it becomes required public API.  See *lib/asm/provider/volume/equallogic.rb* for details of this is implemented.


Providers need tests, a full example are there for the Equallogic one, here's some basics that shows how to load a service JSON from disk and set up a basic set of tests and a stub deployment instance:

```ruby
require 'spec_helper'
require 'asm/type'

ASM::Type.load_providers!

describe ASM::Provider::Volume::Equallogic do
  let(:service_data) do
    fixture = File.expand_path(File.join(File.dirname(__FILE__), '..', '..', '..', '..', 'fixtures', 'service_deployment_teardown_test.json'))
    JSON.parse(File.read(fixture), :max_nesting => 100)
  end

  let(:service) { ASM::Service.new(service_data) }
  let(:logger) { stub(:debug, :warn, :info) }
  let(:deployment) { stub }
  let(:volume_component) { service.components_by_type("STORAGE")[0] }
  let(:server_components) { service.components_by_type("SERVER") }
  let(:cluster_components) { service.components_by_type("CLUSTER") }

  let(:type) { volume_component.to_resource(deployment, logger) }
  let(:provider) { type.provider }

  before :each do
    deployment.stubs(:find_related_components).with("SERVER", any_parameters).returns(server_components)
    deployment.stubs(:find_related_components).with("CLUSTER", any_parameters).returns(cluster_components)
  end

  describe "#initialize" do
    it "should specify the device run type" do
      expect(provider.puppet_type).to eq("asm::volume::equallogic")
    end
  end
end
```

## Tips and Tricks

### Always including custom extra resources in to_puppet

Sometimes you need to programmatically create custom resources and merge them with those created by ```to_puppet```

Think for example when a cluster provider need to always return transports.  The to_puppet method can call a method called ```additional_resources``` which *must* return a Hash.

These resources will be merged with any that ```to_puppet``` generates

### Doing custom configuration on a provider

Imagine you have a case where on teardown you need to set specific properties that the
service component might not have or just in general tweak some setting.  You can do this
with the ```configure_hook``` in a provider.

When a provider is created it's ```configure!``` method is called with a hash of the raw
component.  After this is done it will optionally call a method called ```configure_hook```
on your provider.

Here I have a Server provider that should always have a ```serial_number``` but does not
always, I want to derive it from the certificate when not set.

```ruby
def configure_hook
  self[:serial_number] ||= type.cert2serial
end
```

require 'spec_helper'
require 'asm/service'

describe ASM::Service do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:raw_service) { SpecHelper.json_fixture("Teardown_EQL_VMware_Cluster.json") }
  let(:service) { SpecHelper.service_from_fixture("Teardown_EQL_VMware_Cluster.json", logger) }

  describe "#generate_component" do
    it "should generate and add a component" do
      service.generate_component("rspec") do |component|
        component.type = "CLUSTER"
        component.id = "rspec-id"
        component.component_id = "rspec-generated-component-1"
        component.add_resource("asm::cluster", "Cluster Settings", [
          {:id => "datacenter", :value => "M830Datacenter"},
          {:id => "title", :value => "vcenter-env10-vcenter.aidev.com"}
        ])

        component.add_related_component(service.component_by_id("B0151383-9478-459F-A420-CAED5DE5B063"))
      end

      component = service.component_by_id("rspec-id")

      resource = component.to_resource(nil, logger)

      expect(resource).to be_instance_of(ASM::Type::Cluster)
      expect(resource.puppet_certname).to eq("rspec")
      expect(resource.provider.datacenter).to eq("M830Datacenter")
      expect(resource.uuid).to eq("vcenter-env10-vcenter.aidev.com")
      expect(resource.related_server.puppet_certname).to eq("bladeserver-15kvd42")
    end
  end

  describe "#create_processor" do
    it "should create a processor with default rules by default" do
      processor = service.create_processor

      expect(processor).to be_a(ASM::Service::Processor)
      expect(processor.rule_repositories).to eq(["/etc/asm-deployer/rules"])
    end

    it "should support custom rulesets" do
      processor = service.create_processor("rspec")
      expect(processor.rule_repositories).to eq(["rspec"])
    end
  end

  describe "#component_by_id" do
    it "should select components by id" do
      a, b, c = stub(:id => "a"), stub(:id => "b"), stub(:id => "c")

      service.expects(:components).returns([a, b, c])
      expect(service.component_by_id("a")).to  be(a)
    end
  end

  describe "#template" do
    it "should support returning the template" do
      expect(service.template).to eq(raw_service["serviceTemplate"])
    end
  end

  describe "#components" do
    it "should create and iterate components" do
      service.components.each do |component|
        expect(component).to be_an_instance_of(ASM::Service::Component)
        expect(component.service).to be(service)
      end

      expect(service.components.size).to eq(4)
    end
  end

  describe "#components_by_type" do
    it "should select components by type" do
      a, b, c = mock(:type => "a"), mock(:type => "b"), mock(:type => "a")

      service.expects(:components).returns([a, b, c])
      expect(service.components_by_type("a")).to  eq([a, c])
    end
  end
end


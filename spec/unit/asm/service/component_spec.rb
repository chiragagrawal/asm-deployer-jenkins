require 'spec_helper'
require 'asm/service'

describe ASM::Service::Component do
  let(:raw_service) { SpecHelper.json_fixture("Teardown_EQL_VMware_Cluster.json") }

  let(:raw_component) { raw_service["serviceTemplate"]["components"][1] }
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:deployment) { stub(:logger => logger)}
  let(:service) { ASM::Service.new(raw_service, :deployment => deployment) }
  let(:component) { service.components[1] }

  describe "#reource_ids" do
    it "should list all the resource ids" do
      expect(component.resource_ids).to eq(["asm::idrac", "asm::bios", "asm::server", "asm::esxiscsiconfig"])
    end
  end

  describe "#related_components" do
    it "should find all related components" do
      related = component.related_components

      expect(related.size).to be(3)
      expect(related[0].id).to eq("6012D791-4EBF-4684-A6BC-B44CF0D56F20")
      expect(related[1].id).to eq("15D940CE-427F-41BC-BA06-66C84AC80C65")
      expect(related[2].id).to eq("24BFB5FC-6CF3-4982-A4AB-F7AF7EFBF0B9")
    end

    it "should support limiting them by type" do
      component = service.components[1]
      related = service.related_components(component, "STORAGE")

      expect(related.size).to be(2)
      expect(related[0].id).to eq("6012D791-4EBF-4684-A6BC-B44CF0D56F20")
      expect(related[1].id).to eq("24BFB5FC-6CF3-4982-A4AB-F7AF7EFBF0B9")
    end
  end

  describe "#associated_components" do
    it "should find all associated components" do
      assoc_component_hash = {"entry"=>[
        {"key"=>"353B3066-C47B-45BF-8904-11F293A8163D", "value"=>{
          "entry"=>[{"key"=>"install_order", "value"=>"1"}, {"key"=>"name", "value"=>"linux_postinstall"}]}}]}

      component = service.components[1]
      component.instance_variable_set("@component",{"associatedComponents" => assoc_component_hash})

      mocked_component = mock("associated_component", :type => "SERVICE")
      service.stubs(:component_by_id).returns(mocked_component)
      associated = component.associated_components("SERVICE")

      expect(associated).to eq([{"install_order"=>"1", "name"=>"linux_postinstall", "component"=> mocked_component}])
    end
  end

  describe "#resources" do
    it "should create instances of Component::Resource" do
      component.resources.each do |resource|
        expect(resource).to be_a(ASM::Service::Component::Resource)
        expect(resource.service). to be(service)
      end
    end

    it "should create the right amount of resources" do
      expect(component.resources.size).to eq(raw_component["resources"].size)
    end
  end

  describe "#resources_by_id" do
    it "should return the correct selection of resources" do
      expect(component.resource_by_id("asm::idrac")).to eq(component.resources[0])
      expect(component.resource_by_id("asm::bios")).to eq(component.resources[1])
      expect(component.resource_by_id("asm::server")).to eq(component.resources[2])
      expect(component.resource_by_id("asm::esxiscsiconfig")).to eq(component.resources[3])
      expect(component.resource_by_id("nonexisting")).to be(nil)
    end
  end

  describe "#puppet_certname" do
    it "should supply the puppet_certname" do
      expect(component.puppet_certname).to eq(raw_component["puppetCertName"])
    end
  end

  describe "#id" do
    it "should supply the component id" do
      expect(component.id).to eq(raw_component["id"])
    end
  end

  describe "#component_id" do
    it "should supply the component id" do
      expect(component.component_id).to eq(raw_component["componentId"])
    end
  end

  describe "#type" do
    it "should supply the type" do
      expect(component.type).to eq(raw_component["type"])
    end
  end

  describe "#name" do
    it "should supply the name" do
      expect(component.name).to eq(raw_component["name"])
    end
  end

  describe "#guid" do
    it "should supply the guid" do
      expect(component.guid).to eq(raw_component["asmGUID"])
    end
  end

  describe "#teardown" do
    it "should supply the teardown" do
      expect(component.teardown).to eq(raw_component["teardown"])
    end
  end

  describe "#teardown?" do
    it "should be able to determine teardown status" do
      expect(component.teardown?).to eq(true)
    end
  end

  describe "#brownfield?" do
    it "should be able to determine brownfield status" do
      expect(component.brownfield?).to eq(false)
    end
  end


  describe "#to_resource" do
    it "should support creating a ASM::Type instance" do
      component
      ASM::Type.expects(:to_resource).with(component, nil, nil, logger)
      component.to_resource(nil, logger)
    end
  end

  describe "#configuration" do
    it "should be able to create a configuration" do
      config = ASM::PrivateUtil.build_component_configuration(raw_service["serviceTemplate"]["components"][1], :decrypt => true)

      expect(component.configuration).to eq(config)
    end

    it "should default have a default value of an empty hash" do
      expect(component.configuration.default).to eq({})
    end
  end

  describe "#to_hash" do
    it "should be able to return a clone of the original hash" do
      expect(component.to_hash).to eq(raw_component)
      expect(component.to_hash.object_id).to_not eq(raw_component.object_id)
    end
  end
end


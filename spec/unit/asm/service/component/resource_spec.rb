require 'spec_helper'
require 'asm/service'

describe ASM::Service::Component::Resource do
  let(:raw_service) { SpecHelper.json_fixture("Teardown_EQL_VMware_Cluster.json") }

  let(:raw_component) { raw_service["serviceTemplate"]["components"][1] }
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:deployment) { stub(:logger => logger)}
  let(:service) { ASM::Service.new(raw_service, :deployment => deployment) }
  let(:component) { service.components[1] }
  let(:resource) { component.resources[0] }

  describe "#parameters" do
    it "should return the correct parameters" do
      expect(resource.parameters).to eq(resource.configuration[resource.id][resource.title])
    end
  end

  describe "#id" do
    it "should return the resource id" do
      expect(resource.id).to eq(raw_component["resources"][0]["id"])
    end
  end

  describe "#title" do
    it "should return the right title" do
      title = raw_component["resources"][0]["parameters"].select do |param|
        param["id"] == "title"
      end[0]["value"]

      expect(resource.title).to eq(title)
    end
  end

  describe "#[]" do
    it "should fetch the correct value for a property" do
      expect(resource["target_boot_device"]).to eq("SD")
      expect(resource["migrate_on_failure"]).to eq(true)
      expect(resource["ensure"]).to eq("absent")
      expect(resource["rspec"]).to eq(nil)
    end
  end

  describe "#[]=" do
    it "should set the value for a property" do
      resource["target_boot_device"] = "HD"
      expect(resource["target_boot_device"]).to eq("HD")
      resource["migrate_on_failure"] = false
      expect(resource["migrate_on_failure"]).to eq(false)
      resource["ensure"] = "present"
      expect(resource["ensure"]).to eq("present")
    end

    it "should not set properties that do not exist" do
      expect { resource["rspec"] = "foo" }.to raise_error(ASM::NotFoundException)
    end

    it "should not set NETWORKCONFIGURATION properties" do
      expect do
        component.resource_by_id("asm::esxiscsiconfig")["network_configuration"] = "foo"
      end.to raise_error(StandardError, "Parameters of type NETWORKCONFIGURATION may not be changed")
    end
  end

  describe "#to_hash" do
    it "should create a clone of the resource" do
      expect(resource.to_hash).to eq(raw_component["resources"][0])
      expect(resource.to_hash.object_id).to_not eq(raw_component["resources"][0].object_id)
    end

    it "should include changed simple properties" do
      orig_boot = raw_component["resources"][0]["parameters"].find { |e| e["id"] == "target_boot_device"}
      resource["target_boot_device"] = "%s_RSPEC" % orig_boot["value"]
      orig_boot["value"] = "%s_RSPEC" % orig_boot["value"]
      expect(resource.to_hash).to eq(raw_component["resources"][0])
    end
  end

  describe "#configuration" do
    it "should create a simplified hash" do
      expect(resource.configuration).to eq({"asm::idrac"=>{"bladeserver-15kvd42"=>{"target_boot_device"=>"SD", "migrate_on_failure"=>true, "ensure"=>"absent"}}})
    end
  end
end

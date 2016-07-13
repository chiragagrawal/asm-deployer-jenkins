require 'spec_helper'
require 'asm/service'

describe ASM::Service::Component::Generator do
  let(:raw_service) { SpecHelper.json_fixture("Teardown_EQL_VMware_Cluster.json") }

  let(:raw_component) { raw_service["serviceTemplate"]["components"][1] }
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:deployment) { stub(:logger => logger)}
  let(:service) { ASM::Service.new(raw_service, :deployment => deployment) }
  let(:generated) { ASM::Service::Component::Generator.new("rspec") }

  describe "#has_parameter?" do
    it "should correctly detect parameters" do
      generated.add_resource("asm::cluster", "Cluster Settings", [
        {:id => "datacenter", :value => "M830Datacenter"},
        {:id => "title", :value => "my_cluster.aidev.com"}
      ])

      expect(generated.has_parameter?("datacenter")).to be(true)
      expect(generated.has_parameter?("title")).to be(true)
      expect(generated.has_parameter?("rspec")).to be(false)
    end
  end

  describe "#to_component_hash" do
    it "should create a valid component hash" do
      expected = {
        "id"=>"rspec-id",
        "componentID"=>"rspec-generated-component-1",
        "puppetCertName"=>"rspec",
        "name"=>"Generated Cluster Component",
        "type"=>"CLUSTER",
        "teardown"=>false,
        "asmGUID"=>nil,
        "relatedComponents"=>{},
        "manageFirmware"=>false,
        "resources"=>[
          {
            "id"=>"asm::cluster",
            "displayName"=>"Cluster Settings",
            "parameters"=>[
              {"id"=>"datacenter",
               "value"=>"M830Datacenter",
               "type"=>"STRING"
              },
              {
                "id"=>"title",
                "value"=>"my_cluster.aidev.com",
                "type"=>"STRING"
              }
            ]
          }
        ]
      }

      generated.type = "CLUSTER"
      generated.id = "rspec-id"
      generated.component_id = "rspec-generated-component-1"

      generated.add_resource("asm::cluster", "Cluster Settings", [
        {:id => "datacenter", :value => "M830Datacenter"},
        {:id => "title", :value => "my_cluster.aidev.com"}
      ])

      expect(generated.to_component_hash).to eq(expected)
    end
  end

  describe "#type=" do
    it "should validate and set the type" do
      generated.type = "cluster"
      expect(generated.type).to eq("CLUSTER")

      expect {
        generated.type = "FAIL"
      }.to raise_error("Invalid type FAIL")
    end
  end

  describe "#valid_type?" do
    it "should accept valid types" do
      valid_types = ASM::Type.providers.map{|p| p[:type]}

      valid_types.each do |type|
        expect(generated.valid_type?(type.downcase)).to be(true)
        expect(generated.valid_type?(type.upcase)).to be(true)
      end
    end

    it "should not accept invalid types" do
      expect(generated.valid_type?("fail")).to be(false)
    end
  end

  describe "#add_resource" do
    it "should correctly add a resource" do
      resource = [{
        :id => "datacenter",
        :value => "M830Datacenter"
      }]

      generated.add_resource("asm::cluster", "Cluster Settings", resource)

      expected = {
        "id" => "asm::cluster",
        "displayName" => "Cluster Settings",
        "parameters" => [
          {
            "id" => "datacenter",
            "value" => "M830Datacenter",
            "type" => "STRING"
          }
        ]
      }

      expect(generated.resources.first).to eq(expected)
    end
  end

  describe "#add_related_component" do
    it "should support adding a component object" do
      related = service.components.first
      generated.add_related_component(related)

      expect(generated.related_components[related.id]).to eq(related.type)
    end

    it "should support adding a id and type" do
      generated.add_related_component("15D940CE-427F-41BC-BA06-66C84AC80C65", "CLUSTER")
      expect(generated.related_components["15D940CE-427F-41BC-BA06-66C84AC80C65"]).to eq("CLUSTER")
    end

    it "should require a type when adding a id string" do
      expect {
        generated.add_related_component("15D940CE-427F-41BC-BA06-66C84AC80C65")
      }.to raise_error("Need a type for the related component 15D940CE-427F-41BC-BA06-66C84AC80C65")
    end

    it "should detect invalid types" do
      expect {
        generated.add_related_component("15D940CE-427F-41BC-BA06-66C84AC80C65", "FAIL")
      }.to raise_error("Type FAIL is not a valid component type")
    end
  end
end

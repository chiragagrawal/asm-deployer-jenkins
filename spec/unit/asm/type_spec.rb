require 'spec_helper'
require 'asm/type'

describe ASM::Type do
  describe "#component_type" do
    it "should detect the correct component types" do
      ASM::Type.expects(:require).with("asm/type/virtualmachine").returns(true)
      ASM::Type.expects(:const_get).with("Virtualmachine")
      ASM::Type.component_type(stub(:type => "VIRTUALMACHINE"))
    end

    it "should map STORAGE to VOLUME" do
      ASM::Type.expects(:require).with("asm/type/volume").returns(true)
      ASM::Type.expects(:const_get).with("Volume")
      ASM::Type.component_type(stub(:type => "STORAGE"))
    end
  end

  describe "#to_resource" do
    let(:type) { mock }
    let(:type_instance) { mock }
    let(:component) { stub(:type => "VIRTUALMACHINE") }
    let(:deployment) { mock }
    let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }

    it "should support receiving a type" do
      ASM::Type.expects(:component_type).never
      type.expects(:create).with(component, logger).returns(type_instance)
      type_instance.expects(:deployment=).with(deployment)
      expect(ASM::Type::to_resource(component, type, deployment, logger)).to eq(type_instance)
    end

    it "should support detectig the type" do
      ASM::Type.expects(:component_type).returns(type)
      type.expects(:create).with(component, logger).returns(type_instance)
      type_instance.expects(:deployment=).with(deployment)
      expect(ASM::Type::to_resource(component, nil, deployment, logger)).to eq(type_instance)
    end
  end

  describe "#to_resources" do
    let(:components) { [ stub(:type => "VIRTUALMACHINE"), stub(:type => "SERVER")] }

    it "should support an array or components" do
      ASM::Type.expects(:to_resource).with(components[0], nil, nil, nil).once.returns(1)
      ASM::Type.expects(:to_resource).with(components[1], nil, nil, nil).once.returns(2)

      expect(ASM::Type::to_resources(components, nil, nil, nil)).to eq([1, 2])
    end
  end
end

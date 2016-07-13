require 'spec_helper'
require 'asm/service'

describe ASM::Service::Processor do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:raw_service) { SpecHelper.json_fixture("Teardown_EQL_VMware_Cluster.json") }

  let(:processor) { ASM::Service::Processor.new(raw_service, "/rspec/rules", logger) }
  let(:deployment) { stub(:debug? => false, :logger => logger) }
  let(:service) { ASM::Service.new(raw_service, :deployment => deployment, :decrypt => true) }

  let(:state) { stub(:results => [], :add => nil) }
  let(:engine) { stub(:new_state => state, :process_rules => nil) }
  let(:component) { service.components[0] }


  before(:each) do
    processor.deployment = deployment
  end

  describe "#repositories" do
    it "should use the given repos if supplied" do
      expect(processor.repositories("/one#{File::PATH_SEPARATOR}/two")).to eq(["/one", "/two"])
    end

    it "should use the configuration default otherwise" do
      ASM.config.expects(:rule_repositories).returns("/three#{File::PATH_SEPARATOR}/four")
      expect(processor.repositories(nil)).to eq(["/three", "/four"])
    end

    it "should fallback to a hardcoded value if not configured" do
      ASM.config.expects(:rule_repositories).returns(nil)
      expect(processor.repositories(nil)).to eq(["/etc/asm-deployer/rules"])
    end
  end

  describe "#debug?" do
    it "should get the deployment debug state if set" do
      deployment.expects(:debug?).returns(true)
      expect(processor.debug?).to be(true)
    end

    it "should use false otherwise" do
      processor.expects(:deployment).returns(nil)
      deployment.expects(:debug?).never
      expect(processor.debug?).to be(false)
    end
  end

  describe "#write_exception" do
    it "should write to file when not in debug mode" do
      processor.expects(:debug?).returns(false)
      deployment.expects(:write_exception).with("rspec", Exception.new)
      processor.write_exception("rspec", Exception.new)
    end

    it "should write log lines when in debug mode" do
      exception = Exception.new("rspec")
      exception.set_backtrace(["rspec"])

      processor.expects(:debug?).returns(true)
      logger.expects(:error).with("Exception during processing of rspec: Exception: rspec")
      logger.expects(:error).with(exception.backtrace.pretty_inspect)

      processor.write_exception("rspec", exception)
    end
  end

  describe "#process_state" do
    it "should process the rules and create a outcome" do
      state.expects(:results).returns(results = [stub, stub])

      outcome = processor.process_state(component, engine, state)
      expect(outcome).to include(:component => "vcenter-env10-vcenter.aidev.com")
      expect(outcome).to include(:results => results)
      expect(outcome).to have_key(:component_s)
    end
  end

  describe "#process_state_threaded" do
    it "should create threads" do
      expect(processor.process_state_threaded(component, engine, state)).to be_a(Thread)
    end
  end

  describe "#process_state_unthreaded" do
    it "should not create any threads" do
      expect(processor.process_state_unthreaded(component, engine, state)).to be_a(Hash)
    end
  end

  describe "#process_lane" do
    it "should process every component with the right ruleset" do
      components = service.components_by_type("STORAGE")

      expected = []

      components.each do |component|
        expected << outcome = {:component => component.puppet_certname, :component_s => component.to_s, :results => []}
        processor.expects(:process_state).with(component, instance_of(ASM::RuleEngine), instance_of(ASM::RuleEngine::State)).returns(outcome)
      end

      results = processor.process_lane(components, "rspec")

      expect(results).to eq(expected)
    end
  end

  describe "#process_component" do
    before(:each) do
      processor.stubs(:create_engine).returns(engine)
    end

    it "should create and configure an engine" do
      processor.expects(:create_engine).with(["rspec", "component_common"]).returns(engine)

      state.expects(:add).with(:processor, processor)
      state.expects(:add).with(:service, service)
      state.expects(:add).with(:component, component)
      state.expects(:add).with(:resource, instance_of(ASM::Type::Cluster))
      engine.expects(:process_rules).with(state)

      result = processor.process_component(component, "rspec", false)

      expected = {
        :outcome => {
          :component => "vcenter-env10-vcenter.aidev.com",
          :component_s => component.to_s,
          :results => []
        }
      }

      expect(result).to eq(expected)
    end

    it "should support non threaded mode by default" do
      processor.expects(:process_state_threaded).with(component, engine, state)
      processor.expects(:process_state_unthreaded).never
      processor.process_component(component, "rspec")
    end

    it "should support threaded mode" do
      processor.expects(:process_state_unthreaded).with(component, engine, state)
      processor.expects(:process_state_threaded).never
      processor.process_component(component, "rspec", false)
    end
  end

  describe "#rule_paths" do
    it "should calculate the right paths" do
      expect(processor.rule_paths("rspec")).to eq("/rspec/rules/rspec")
    end
  end

  describe "#create_engine" do
    it "should create a rule engine with the right set loaded" do
      engine = processor.create_engine("rspec")
      expect(engine.path).to eq(["/rspec/rules/rspec"])
    end
  end

  describe "#process_service" do
    it "should create and configure an engine for the service ruleset" do
      state = stub(:results => [])
      engine = stub(:new_state => state)
      processor.expects(:create_engine).with("service").returns(engine)

      service = mock("rspec-service")
      ASM::Service.expects(:new)
          .with(raw_service, :deployment => deployment, :decrypt => true)
          .returns(service)

      state.expects(:add).with(:processor, processor)
      state.expects(:add).with(:service, service)
      state.expects(:add).with(:component_outcomes, [])
      engine.expects(:process_rules).with(state)

      processor.process_service
    end

    it "should raise the first error encountered" do
      state = stub(:add => nil)
      engine = stub(:new_state => state, :process_rules => nil)
      processor.stubs(:create_engine).returns(engine)

      results = [ stub(:error => nil), stub(:error => "rspec1"), stub(:error => "rspec2") ]
      state.expects(:results).returns(results)

      expect { processor.process_service }.to raise_error("rspec1")
    end
  end
end


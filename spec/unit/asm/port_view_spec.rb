require "spec_helper"
require "asm"

describe ASM::PortView do
  let(:network_overview_data) {Hashie::Mash.new(SpecHelper.json_fixture("network_overview.json"))}
  let(:network_overview_with_extra_data) {Hashie::Mash.new(SpecHelper.json_fixture("network_overview_with_extra_data.json"))}

  describe "#updated_port_view_json" do
    it "should not alter correct network overview" do
      expect(ASM::PortView.updated_port_view_json(network_overview_data)).to eq(network_overview_data)
    end

    it "should generate correct network overview for specified keys" do
      expect(ASM::PortView.updated_port_view_json(network_overview_with_extra_data)).to eq(network_overview_data)
    end
  end
end

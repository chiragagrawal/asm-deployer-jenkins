require 'spec_helper'
require 'asm/monitoring'

describe ASM::Monitoring do
  describe "#model_has_metrics?" do
    it "should correctly report models" do
      monitoring = ASM::Monitoring.new

      ["M420", "PowerEdge M520", "PowerEdge M820", "PowerEdge R720XD", "PowerEdge C6220 II"].each do |m|
        expect(monitoring.model_has_metrics?(m)).to be(false)
      end

      ["PowerEdge FC430", "PowerEdge FC630", "PowerEdge FC830", "PowerEdge M830", "PowerEdge M630", "PowerEdge R430", "PowerEdge R530", "PowerEdge R630", "PowerEdge R730", "PowerEdge R730 XD", "PowerEdge R930"].each do |m|
        expect(monitoring.model_has_metrics?(m)).to be(true)
      end
    end
  end
end

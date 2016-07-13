require 'spec_helper'
require 'asm/device_metrics'

describe ASM::DeviceMetrics do
  before do
    @m = ASM::DeviceMetrics.new("rspec")
    @fixture_file = SpecHelper.fixture_path("device_metadata.json")
    @m.stubs(:device_metadata_filename).returns(@fixture_file)

    @stub_data = [
                  {"target" => "One",
                   "datapoints" => [[1, 1000], [2, 1001], [3, 1002], [nil, 1003], [5, 1004], [nil, 1005]]},
                  {"target" => "One_LowerThresholdCritical",
                   "datapoints" => [[1, 1000], [1, 1001], [1, 1002], [nil, 1003], [2, 1004], [nil, 1005]]},
                  {"target" => "One_LowerThresholdNonCritical",
                   "datapoints" => [[2, 1000], [2, 1001], [2, 1002], [nil, 1003], [3, 1004], [nil, 1005]]}
                 ]

    @cleaned_stub_data = [
                  {"target" => "One",
                   "datapoints" => [[1, 1000], [2, 1001], [3, 1002], [nil, 1003], [5, 1004]]},
                  {"target" => "One_LowerThresholdCritical",
                   "datapoints" => [[1, 1000], [1, 1001], [1, 1002], [nil, 1003], [2, 1004]]},
                  {"target" => "One_LowerThresholdNonCritical",
                   "datapoints" => [[2, 1000], [2, 1001], [2, 1002], [nil, 1003], [3, 1004]]}
                 ]
  end

  describe "#query_string" do
    it "should summarize when units are supplied" do
      q = CGI.unescape(@m.query_string(nil, "1day"))
      expect(q).to match(/summarize\(asm.server.rspec..,'1day','avg'\)/)
    end

    it "should support a different from time" do
      q = @m.query_string("-1day", nil)
      expect(q).to match(/from=-1day/)
    end
  end

  describe "#get_data" do
    before do
      @response = mock
      @response.stubs(:code).returns("200")
      @response.stubs(:body).returns(JSON.dump(@stub_data))

      Net::HTTP.stubs(:get_response).returns(@response)
    end

    it "should fetch from the configured graphite server using the correct query" do
      m = ASM::DeviceMetrics.new("rspec", "rspec", 10)

      m.expects(:query_string).with("from", "units").returns("/rspec")
      Net::HTTP.expects(:get_response).with("rspec", "/rspec", 10).returns(@response)

      m.get_data("from", "units")
    end

    it "should return JSON parsed data on success" do
      m = ASM::DeviceMetrics.new("rspec", "rspec", 10)
      expect(m.get_data("from", nil)).to eq(@cleaned_stub_data)
    end

    it "should delete newest nils from the data" do
      m = ASM::DeviceMetrics.new("rspec", "rspec", 10)
      expect(m.get_data("from", "units")).to eq(@cleaned_stub_data)
    end

    it "should raise on failure" do
      @response.stubs(:code).returns("500")
      @response.stubs(:body).returns("internal server error")

      Net::HTTP.expects(:get_response).returns(@response)

      expect { @m.get_data("from", "units") }.to raise_error("Failed to query graphite: 500: internal server error")
    end
  end

  describe "#delete_trailing_nils!" do
    it "should delete the correct nil data points" do
      cloned_data = Marshal.load(Marshal.dump(@stub_data))
      expected_data = Marshal.load(Marshal.dump(@stub_data))

      3.times {|i| cloned_data[i]["datapoints"][-2][0] = nil }
      3.times {|i| [-2, -1].each {|j| expected_data[i]["datapoints"].delete_at(j)} }

      expect(@m.delete_trailing_nils!(cloned_data)).to eq(expected_data)
    end

    it "should only delete nil data points" do
      cloned_data = Marshal.load(Marshal.dump(@stub_data))
      expected_data = Marshal.load(Marshal.dump(@stub_data))

      3.times {|i| expected_data[i]["datapoints"].delete_at(-1)}

      expect(@m.delete_trailing_nils!(cloned_data)).to eq(expected_data)
    end

    it "should only delete maximum 2 nil data points" do
      cloned_data = Marshal.load(Marshal.dump(@stub_data))
      expected_data = Marshal.load(Marshal.dump(@stub_data))

      3.times {|i| cloned_data[i]["datapoints"][-2][0] = nil }
      3.times {|i| cloned_data[i]["datapoints"][-3][0] = nil }
      3.times {|i| [-2, -1].each {|j| expected_data[i]["datapoints"].delete_at(j)} }

      expect(@m.delete_trailing_nils!(cloned_data)).to eq(expected_data)
    end

    it "should not delete data if there is only 2 points" do
      cloned_data = Marshal.load(Marshal.dump(@stub_data))

      3.times {|i| 4.times {|j| cloned_data[i]["datapoints"].delete_at(0)}}

      expected_data = Marshal.load(Marshal.dump(cloned_data))

      expect(@m.delete_trailing_nils!(cloned_data)).to eq(expected_data)
    end

    it "should not delete 2nd to last nil if the last item is not nil" do
      cloned_data = Marshal.load(Marshal.dump(@stub_data))

      3.times do |i|
        cloned_data[i]["datapoints"][-1][0] = cloned_data[i]["datapoints"][-2][0]
        cloned_data[i]["datapoints"][-2][0] = nil
      end

      expected_data = Marshal.load(Marshal.dump(cloned_data))

      expect(@m.delete_trailing_nils!(cloned_data)).to eq(expected_data)
    end
  end

  describe "#threshold_metric?" do
    it "should correctly find all supported threshold types" do
      ["LowerThresholdCritical", "LowerThresholdNonCritical",
        "UpperThresholdCritical", "UpperThresholdNonCritical"].each do |t|
        expect(@m.threshold_metric?("Foo_%s" % t)).to be_truthy
        end
    end

    it "should fail on unsupported types" do
      expect(@m.threshold_metric?("Foo_Bar")).to be_falsey
    end
  end

  describe "#related_metric_name" do
    it "should find the correct related threshold" do
      ["LowerThresholdCritical", "LowerThresholdNonCritical",
        "UpperThresholdCritical", "UpperThresholdNonCritical"].each do |t|
        expect(@m.related_metric_name("Rspec_%s" % t)).to eq("Rspec")
        end
    end
  end

  describe "#threshold_name" do
    it "should get the correct threshold names" do
      expect(@m.threshold_name("Foo_LowerThresholdCritical")).to eq("LowerThresholdCritical")
      expect(@m.threshold_name("Foo_LowerThresholdNonCritical")).to eq("LowerThresholdNonCritical")
      expect(@m.threshold_name("Foo_UpperThresholdCritical")).to eq("UpperThresholdCritical")
      expect(@m.threshold_name("Foo_UpperThresholdNonCritical")).to eq("UpperThresholdNonCritical")
    end
  end

  describe "#related_metric" do
    it "should find the correct related metric" do
      expect(@m.related_metric(@stub_data, "One_LowerThresholdCritical")).to eq(@stub_data[0])
    end

    it "should return nil when it cannot find anything" do
      expect(@m.related_metric(@stub_data, "x")).to be_nil
    end
  end

  describe "#last_value_for_metric" do
    it "should fetch the correct last non nil value for a metric" do
      expect(@m.last_value_for_metric(@stub_data[0])).to be(5)
    end
  end

  describe "#calculate_thresholds!" do
    it "should gather the correct thresholds" do
      @m.calculate_thresholds!(@stub_data)
      expect(@stub_data[0]["thresholds"]).to eq({"LowerThresholdCritical"=>2, "LowerThresholdNonCritical"=>3})
    end
  end

  describe "#delete_threshold_targets!" do
    it "should delete all the threshold data" do
      @m.delete_threshold_targets!(@stub_data)

      expect(@stub_data.size).to eq(1)
      expect(@stub_data[0]["target"]).to eq("One")
    end
  end

  describe "#metric_sum" do
    it "should calculate the correct sum" do
      expect(@m.metric_sum(@stub_data[0])).to be(11)
    end
  end

  describe "#metric_average" do
    it "should calculate the correct average" do
      expect(@m.metric_average(@stub_data[0])).to eq(2.75)
    end

    it 'should handle no samples' do
      @stub_data = [
        {"target" => "One",
          "datapoints" => [[nil, 1000], [nil, 1001], [nil, 1002], [nil, 1003], [nil, 1004], [nil, 1005]]},
      ]
      expect(@m.metric_average(@stub_data[0])).to be_nil
    end
  end

  describe "#metric_max" do
    it "should calculate the correct max" do
      expect(@m.metric_max(@stub_data[0])).to eq([5, 1004])
    end
  end

  describe "#metric_min" do
    it "should calculate the correct min" do
      expect(@m.metric_min(@stub_data[0])).to eq([1, 1000])
    end
  end

  describe "#device_metadata" do
    it "should fetch the correct metadata" do
      expect(@m.device_metadata).to eq(JSON.parse(File.read(@fixture_file)))
    end

    it "should return good empty data when no metadata exist" do
      @m.expects(:device_metadata_filename).returns("/nonexisting")
      expect(@m.device_metadata).to eq({})
    end
  end

  describe "#metric_all_time_peak" do
    it "should fetch the correct peak values" do
      expect(@m.metric_all_time_peak("One")).to eq([35, 1424839593])
    end

    it "should return a good default when no metadata exist" do
      @m.expects(:device_metadata_filename).returns("/nonexisting")
      expect(@m.metric_all_time_peak("One")).to eq([nil, nil])
    end
  end

  describe "#device_first_seen" do
    it "should return the correct first seen time" do
      expect(@m.device_first_seen).to be(1424839593)
    end
  end

  describe "#device_last_seen" do
    it "should return the correct last seen time" do
      expect(@m.device_last_seen).to be(1424839812)
    end
  end

  describe "#calculate_summaries!" do
    it "should get the correct summaries" do
      @m.calculate_summaries!(@stub_data)
      expect(@stub_data[0]["summary"]).to eq({"average" => 2.75,
        "max" => [5, 1004],
        "min" => [1, 1000],
        "all_time_peak" => [35, 1424839593],
        "device_first_seen" => 1424839593,
        "device_last_seen" => 1424839812})
    end
  end

  describe "#metric" do
    it "should return the correct data" do
      @m.expects(:get_data).returns(@stub_data)
      expected = [{"target" => "One",
        "datapoints" => [[1, 1000], [2, 1001],
          [3, 1002], [nil, 1003],
          [5, 1004], [nil, 1005]],
          "thresholds" => {"LowerThresholdCritical" => 2,
            "LowerThresholdNonCritical" => 3},
            "summary" => {"average" => 2.75,
              "max" => [5, 1004],
              "min" => [1, 1000],
              "all_time_peak" => [35, 1424839593],
              "device_first_seen" => 1424839593,
              "device_last_seen" => 1424839812}}]
      expect(@m.metrics(nil, nil)).to eq(expected)
    end

    it 'should add in required targets' do
      @m.expects(:get_data).returns(@stub_data)
      expected = [{"target" => "One",
        "datapoints" => [[1, 1000], [2, 1001],
          [3, 1002], [nil, 1003],
          [5, 1004], [nil, 1005]],
          "thresholds" => {"LowerThresholdCritical" => 2,
            "LowerThresholdNonCritical" => 3},
            "summary" => {"average" => 2.75,
              "max" => [5, 1004],
              "min" => [1, 1000],
              "all_time_peak" => [35, 1424839593],
              "device_first_seen" => 1424839593,
              "device_last_seen" => 1424839812}}]
      required_targets = %w(CPU IO MEM SYS).map { |x| "System_Board_#{x}_Usage" }
      required_targets.each do |target|
        expected << {'target' => target,
          "datapoints" => [[nil, 1000], [nil, 1001],
            [nil, 1002], [nil, 1003],
            [nil, 1004], [nil, 1005]],
            "summary" => {"average" => nil,
              "max" => [nil, 1000],
              "min" => [nil, 1000],
              "all_time_peak" => [nil, nil],
              "device_first_seen" => 1424839593,
              "device_last_seen" => 1424839812}}

      end
      expect(@m.metrics(nil, nil, required_targets)).to eq(expected)
    end

    it 'should raise NotFoundException' do
      @m.expects(:get_data).returns([])
      expect do
        @m.metrics(nil, nil)
      end.to raise_error(ASM::NotFoundException)
    end
  end
end

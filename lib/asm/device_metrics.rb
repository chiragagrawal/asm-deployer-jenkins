require 'asm'

module ASM
  class DeviceMetrics
    THRESHOLD_MATCH = /(.+)_((Lower|Upper)Threshold.+)$/
    METADATA_DIR = "/var/lib/carbon"

    def initialize(ref_id, graphite_server="localhost", graphite_port=8082)
      @device = ref_id
      @graphite_server = graphite_server
      @graphite_port = graphite_port
    end

    def query_string(from, units)
      target = "asm.server.%s.*" % @device
      target = "summarize(%s,'%s','avg')" % [target, CGI.escape(units)] if units
      target = "aliasByNode(%s, 3)" % target

      query = {"from"   => from || "-2hours",
               "until"  => "now",
               "format" => "json",
               "target" => target}

      "/render?%s" % query.map {|k, v| "%s=%s" % [CGI.escape(k), CGI.escape(v)]}.join("&")
    end

    def get_data(from, units)
      response = Net::HTTP.get_response(@graphite_server, query_string(from, units), @graphite_port)

      if response.code == "200"
        data = JSON.parse(response.body)
        delete_trailing_nils!(data)
        data
      else
        raise("Failed to query graphite: %s: %s" % [response.code, response.body])
      end
    end

    # graphite stores data in buckets of 300 seconds in our case.  Any data
    # received with the timestamp inside a bucket goes in that bucket.  This
    # means if data comes 20 seconds into the minute there is a period of 20
    # seconds where a bucket is returned but it's empty.  
    #
    # This makes for ugly graphs, this method delete up to 2 most recent buckets
    # worth of nil data, any more than that is something else happening like a
    # server being down and no data being received at all.
    #
    # If the data series have only 2 points it won't delete anything. If the last
    # point is not nil then the 2nd last will not be deleted, that would indicate
    # data was not received rather than this bucket issue
    def delete_trailing_nils!(data)
      data.each do |target|
        next if target["datapoints"].size < 3
        next if !target["datapoints"].last[0].nil?

        [-2, -1].each do |idx|
          target["datapoints"].delete_at(idx) if target["datapoints"][idx][0].nil?
        end
      end
    end

    def threshold_metric?(target)
      !!(target =~ THRESHOLD_MATCH)
    end

    def related_metric_name(target)
      if target =~ THRESHOLD_MATCH
        return $1
      end

      nil
    end

    def threshold_name(target)
      if target =~ THRESHOLD_MATCH
        return $2
      end

      nil
    end

    def related_metric(data, target)
      targets = data.map{|m| m["target"]}

      if name = related_metric_name(target)
        return data[ targets.index(name) ]
      end

      nil
    end

    def last_value_for_metric(metric)
      metric["datapoints"].map{|m| m[0]}.compact.last
    end

    def calculate_thresholds!(data)
      data.each do |metric|
        if threshold_metric?(metric["target"])
          related_metric = related_metric(data, metric["target"])
          threshold_name = threshold_name(metric["target"])

          if (related_metric && threshold_name)
            related_metric["thresholds"] ||= {}
            related_metric["thresholds"][threshold_name] = last_value_for_metric(metric)
          end
        end
      end
    end

    def delete_threshold_targets!(data)
      targets = data.map{|m| m["target"]}

      targets.grep(/Threshold/).clone.each do |threshold|
        index = data.index {|d| d["target"] == threshold}
        data.delete_at(index) if index
      end
    end

    def metric_sum(metric)
      metric["datapoints"].map{|p| p[0] || 0}.inject{|sum, el| sum + el}
    end

    def metric_average(metric)
      n_points = metric["datapoints"].map{|p| p[0]}.compact.length
      metric_sum(metric) / Float(n_points) if n_points > 0
    end

    def metric_max(metric)
      metric["datapoints"].max_by{|p| p[0] || -1.0/0.0}
    end

    def metric_min(metric)
      metric["datapoints"].min_by{|p| p[0] || +1.0/0.0}
    end

    def device_metadata_filename
      File.join(METADATA_DIR, "%s-asm-metadata.json" % @device)
    end

    def device_metadata
      @metadata ||= JSON.parse(File.read(device_metadata_filename))
    rescue
      {}
    end

    def metric_all_time_peak(metric_name)
      data = device_metadata.fetch(metric_name, {"value" => nil, "time" => nil})

      [data["value"], data["time"]]
    end

    def device_first_seen
      device_metadata["first_seen"]
    end

    def device_last_seen
      device_metadata["last_seen"]
    end

    def calculate_summaries!(data)
      data.each do |metric|
        metric["summary"] = {}

        metric["summary"]["average"] = metric_average(metric)
        metric["summary"]["max"] = metric_max(metric)
        metric["summary"]["min"] = metric_min(metric)
        metric["summary"]["all_time_peak"] = metric_all_time_peak(metric["target"])
        metric["summary"]["device_first_seen"] = device_first_seen
        metric["summary"]["device_last_seen"] = device_last_seen
      end
    end

    def metrics(from, units, required = [])
      data = get_data(from, units)
      raise ASM::NotFoundException if data.empty?

      # Add in required targets if missing
      targets = data.map { |elem| elem['target'] }
      required.each do |target|
        unless targets.include?(target)
          empty_datapoints ||= data.first['datapoints'].map do |point|
            _, timestamp = point
            [nil, timestamp]
          end
          data << {'target' => target, 'datapoints' => empty_datapoints}
        end
      end

      calculate_thresholds!(data)
      delete_threshold_targets!(data)
      calculate_summaries!(data)

      data
    end
  end
end

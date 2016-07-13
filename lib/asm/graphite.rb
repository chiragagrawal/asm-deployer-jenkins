require 'json'
require 'socket'

module ASM
  class Graphite
    # These are hardcoded because this is an internal call
    # External clients use this through the rest interface /graphite/
    HOST = 'localhost'
    PORT = 2003


    def submit_metrics(metrics)
      success = 0
      starttime = Time.now
      connect = TCPSocket.open(HOST, PORT)
      metrics.each do |k, v|
        ASM::Util.block_and_retry_until_ready(60, Errno::EPIPE) do
          metric = "%s %s %s" % [k, v["value"], v["time"]]
          connect.puts metric
        end
        success += 1
      end
    rescue => e
      #print a message to stdout, this will get caught in server.log
      puts "Failed to submit metrics to graphite %s:%d: %s: %s" % [HOST, PORT, e.class, e.backtrace]
    ensure
      connect.close if connect
      return [success, Time.now - starttime]
    end
  end
end

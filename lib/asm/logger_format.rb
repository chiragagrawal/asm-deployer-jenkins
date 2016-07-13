module ASM
  class LoggerFormat < ::Logger::Formatter
    def call(severity, time, progname, msg)
      format = "%-5s [%s] %d: %s: %s\n"
      format % [severity, format_datetime(time).strip, Thread.current.object_id, from, msg2str(msg)]
    end

    def from
      file_line_method = caller.map do |stack|
        next if stack.match(/logger_format.rb/)
        next if stack.match(/logger.rb/)
        next if stack.match(/logger\/colors.rb/)

        stack
      end.compact.first

      path, line, method = file_line_method.split(/:(\d+)/)
      pieces = path.split(File::SEPARATOR)

      # for asm/foo/bar shorten the path to foo/bar otherwise full path is shown
      # this might become nasty with 3rd party libraries so we might need to make
      # some further plan based on how things look - I don't think we tend to
      # pass loggers into 3rd parties though so might not be a problem at all
      if pieces.include?("asm")
        path = pieces[pieces.index("asm") + 1..-1].join(File::SEPARATOR)
      else
        path = pieces.join(File::SEPARATOR)
      end

      "%s:%s%s" % [path, line, method]
    end
  end
end

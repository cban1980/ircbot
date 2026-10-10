require "time"

module Rubicon
  # Log formatter that escapes control characters, so text from IRC users
  # or web pages (e.g. ANSI escape sequences) cannot forge log lines or
  # manipulate the terminal of whoever reads the log. Every record is also
  # handed to LogTap (for plugins' :log events).
  class LogFormatter
    # progname: the network, when the bot runs on several (see Supervisor).
    def call(severity, time, progname, message)
      text = message.is_a?(Exception) ? "#{message.class}: #{message.message}" : message.to_s
      LogTap.publish(severity, time, progname, text)
      text = "[#{progname}] #{text}" if progname
      "#{time.utc.iso8601(3)} #{severity.ljust(5)} #{escape(text)}\n"
    end

    private

    def escape(text)
      text.gsub(/[\x00-\x1f\x7f\u0080-\u009f‪-‮⁦-⁩]/) { |c| format("\\u{%x}", c.ord) }
    end
  end
end

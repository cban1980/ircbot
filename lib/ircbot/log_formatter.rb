require "time"

module IRCBot
  # Log formatter that escapes control characters, so text from IRC users
  # or web pages (e.g. ANSI escape sequences) cannot forge log lines or
  # manipulate the terminal of whoever reads the log.
  class LogFormatter
    def call(severity, time, _progname, message)
      text = message.is_a?(Exception) ? "#{message.class}: #{message.message}" : message.to_s
      "#{time.utc.iso8601(3)} #{severity.ljust(5)} #{escape(text)}\n"
    end

    private

    def escape(text)
      text.gsub(/[\x00-\x1f\x7f\u0080-\u009f‪-‮⁦-⁩]/) { |c| format("\\u{%x}", c.ord) }
    end
  end
end

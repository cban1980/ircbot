module Gemdrop
  # Hands the bot's own log records, as they are written, to whoever
  # subscribed (running bots, which pass them to plugins as :log events).
  # Fed by LogFormatter, so records are already level-filtered and redacted.
  #
  # Records logged while a :log hook runs, or while records are being handed
  # out, are not handed out again, so a plugin that logs can't loop.
  module LogTap
    @subscribers = {}
    @lock = Mutex.new

    class << self
      # The block gets (severity, time, progname, text). Returns a token
      # for unsubscribe.
      def subscribe(&block)
        token = Object.new
        @lock.synchronize { @subscribers[token] = block }
        token
      end

      def unsubscribe(token) = @lock.synchronize { @subscribers.delete(token) }

      def publish(severity, time, progname, text)
        return if Thread.current[:gemdrop_log_tap] || Thread.current[:gemdrop_log_hook]

        subscribers = @lock.synchronize { @subscribers.values }
        return if subscribers.empty?

        begin
          Thread.current[:gemdrop_log_tap] = true
          subscribers.each do |subscriber|
            subscriber.call(severity, time, progname, text)
          rescue StandardError
            nil # a subscriber's problem must never break logging
          end
        ensure
          Thread.current[:gemdrop_log_tap] = nil
        end
      end
    end
  end
end

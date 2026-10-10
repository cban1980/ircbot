module Rubicon
  # Unix signals for Bot and Supervisor, which both provide reload_config,
  # request_reconnect and stop.
  #
  #   HUP        re-read config.yml and apply it without restarting
  #   USR1       drop the IRC connection(s) and reconnect
  #   TERM, INT  quit IRC cleanly and exit
  module SignalHandling
    SIGNALS = { "HUP" => :reload, "USR1" => :reconnect, "TERM" => :stop, "INT" => :stop }.freeze

    private

    def install_signal_handlers
      actions = Queue.new
      SIGNALS.each do |signal, action|
        Signal.trap(signal) { actions << action } # trap context: only enqueue
      end
      Thread.new do
        Thread.current.name = "rubicon-signals"
        loop { perform(actions.pop) }
      end
    end

    def perform(action)
      case action
      when :reload then reload_config
      when :reconnect then request_reconnect
      when :stop then stop
      end
    rescue StandardError => e
      @log.error("#{action} failed: #{e.class}: #{e.message}")
    end
  end
end

module Gemdrop
  # Keeping the connection alive and the bot responsive:
  #
  # - Dead links: when nothing has arrived for LINK_IDLE seconds, the bot
  #   pings the server; with no answer within LINK_TIMEOUT more, it drops
  #   the connection and reconnects (instead of waiting for the socket's
  #   10-minute read timeout).
  # - Stuck registration: a server that accepts the connection but doesn't
  #   finish registering within REGISTRATION_TIMEOUT is dropped too.
  # - Fallback servers: after a connection fails before registering, the
  #   next attempt goes to the network's next server (fallback_servers).
  # - Watchdog: if the bot's lock can't be taken for WATCHDOG_LIMIT seconds
  #   (a deadlock or a hung handler), it logs every thread's backtrace and
  #   exits with an error, so Docker or systemd restarts it.
  class Bot
    LINK_IDLE = 120
    LINK_TIMEOUT = 90
    REGISTRATION_TIMEOUT = 90
    WATCHDOG_INTERVAL = 15
    WATCHDOG_LIMIT = 180
    BUSY_PLUGIN = 60 # seconds one plugin job may run before it is reported

    # Called when the watchdog fires; tests replace it.
    class << self
      attr_writer :watchdog_action

      def watchdog_action
        @watchdog_action ||= lambda do |bot, log|
          log.fatal("The bot has been stuck for over #{WATCHDOG_LIMIT}s (#{bot.network_id}); exiting so it gets restarted")
          Thread.list.each do |thread|
            log.fatal("Thread #{thread.name || thread.object_id}: #{(thread.backtrace || []).first(12).join(' <- ')}")
          end
          exit!(70)
        end
      end
    end

    private

    # Called by the ticker while connected.
    def check_link
      return unless @link_since

      now = @clock.call
      if !@welcomed && now - @link_since > REGISTRATION_TIMEOUT
        return drop_link("the server didn't finish registration within #{REGISTRATION_TIMEOUT}s")
      end

      idle = now - (@last_received || @link_since)
      if idle > LINK_IDLE + LINK_TIMEOUT
        drop_link("nothing from the server for #{idle.round}s, not even an answer to a PING")
      elsif idle > LINK_IDLE && !@link_pinged
        @link_pinged = true
        send_raw("PING :#{LINK_PING}", urgent: true)
      end
    end

    LINK_PING = "gemdrop-alive".freeze

    # A plugin job running very long (an endless loop, a hung request) only
    # holds up that plugin, but it should be visible: logged once per job.
    def report_busy_plugins
      busy = @plugin_jobs.busy(BUSY_PLUGIN)
      busy.each do |key, seconds|
        next if @reported_busy&.[](key)

        @log.warn("Plugin #{key.delete_prefix('plugin:')} has been busy for #{seconds.round}s in one hook, command " \
                  "or timer; its other events wait (slow work belongs in background)")
      end
      @reported_busy = busy.keys.to_h { |key| [key, true] }
    end

    def line_received
      @last_received = @clock.call
      @link_pinged = false
    end

    def drop_link(reason)
      @log.warn("Dropping the connection: #{reason}; reconnecting")
      @dropped_link = true
      @conn.close # wakes the read loop; the run loop reconnects
    end

    # [host, port] of every server for this network: server first, then
    # fallback_servers in order.
    def servers
      [[@config["server"], @config["port"]]] + Array(@config["fallback_servers"]).map do |entry|
        host, port = entry.to_s.split(":", 2)
        [host, port ? port.to_i : @config["port"]]
      end
    end

    def current_server = servers[@server_index % servers.size]

    # After a connection that never registered, try the next server.
    def next_server
      return if servers.size < 2

      @server_index = (@server_index + 1) % servers.size
      @rebuild_connection = true
      host, port = current_server
      @log.info("Next attempt goes to #{host}:#{port}")
    end

    def start_watchdog
      Thread.new do
        Thread.current.name = "gemdrop-watchdog-#{@network_id}"
        last_ok = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        loop do
          sleep WATCHDOG_INTERVAL
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if @lock.try_enter
            @lock.exit
            last_ok = now
          elsif now - last_ok > WATCHDOG_LIMIT
            Bot.watchdog_action.call(self, @log)
            last_ok = now
          end
        end
      end
    end
  end
end

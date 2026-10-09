require "json"
require "time"
require "fileutils"

module IRCBot
  # The bot's process lifecycle: the connect/reconnect loop, Unix signals,
  # live config reload, and the status file.
  #
  # Run on its own, a Bot handles the signals itself (see SignalHandling);
  # under a Supervisor (several networks), the supervisor does, and passes
  # each network its part of the reloaded config. A reload also loads new
  # plugin files and reloads changed ones.
  class Bot
    include SignalHandling

    # Settings that only take effect on a new connection; changing them on
    # reload makes the bot reconnect.
    CONNECTION_SETTINGS = %w[
      server port tls tls_verify tls_min_version tls_fingerprint tls_ciphers
      tls_self_signed tls_known_servers allow_insecure network user realname
    ].freeze
    # Files opened at startup; changing these needs a restart.
    RESTART_SETTINGS = %w[data_file pepper_file status_file].freeze

    RECONNECT_MIN = 5
    RECONNECT_MAX = 300

    def run(handle_signals: true)
      install_signal_handlers if handle_signals
      backoff = RECONNECT_MIN
      until @stopping
        run_connection
        break if @stopping

        if @reconnect_now
          @reconnect_now = false
          backoff = RECONNECT_MIN
          next
        end
        backoff = RECONNECT_MIN if @had_welcome
        @log.info("Reconnecting in #{backoff}s")
        @wake.pop(timeout: backoff)
        backoff = [backoff * 2, RECONNECT_MAX].min
      end
      @log.info("Stopped.")
    ensure
      @lock.synchronize { @plugins.unload_all }
      write_status("stopped")
    end

    # Re-reads config.yml and applies it. A broken config is rejected and
    # the bot keeps running with the previous settings. Returns success.
    def reload_config
      unless @config_path
        @log.warn("Reload requested, but the bot was started without a config file path")
        return false
      end

      new_config = Config.network(Config.load(@config_path), @network_id) or
        raise ConfigError, "network #{@network_id} is no longer in the config"
      apply_network_config(new_config)
      true
    rescue ConfigError, Psych::Exception => e
      @log.error("Config reload failed; still running with the previous settings: #{e.message}")
      false
    end

    # Applies this network's part of a reloaded config (see reload_config).
    def apply_network_config(new_config)
      @lock.synchronize { apply_config(new_config) }
    end

    def request_reconnect(reason = "Reconnecting")
      @log.info("Reconnect requested: #{reason}")
      @reconnect_now = true
      quit_and_close(reason)
      @wake << :reconnect
    end

    def stop(reason = "Shutting down")
      @log.info("Stopping: #{reason}")
      @stopping = true
      quit_and_close(reason)
      @wake << :stop
    end

    private

    # One connection, from connect to disconnect. Errors end the connection;
    # the caller decides whether and when to reconnect.
    def run_connection
      @wake.clear
      @had_welcome = false
      @lock.synchronize do
        @conn = Connection.from_config(@config) if @rebuild_connection && @own_connection
        @rebuild_connection = false
      end
      @log.info("Connecting to #{@config['server']}:#{@config['port']}")
      write_status("connecting")
      @conn.connect
      log_security
      @lock.synchronize do
        @connected_at = Time.now.utc
        register_connection
      end
      ticker = start_nick_checks
      while (line = @conn.gets)
        @log.debug("<< #{redact(line.chomp)}")
        @lock.synchronize { handle(line) }
      end
      @log.warn("Connection closed by server") unless intentional_disconnect?
    rescue IOError, SystemCallError, SocketError, OpenSSL::SSL::SSLError => e
      @log.error("Connection error: #{e.class}: #{e.message}") unless intentional_disconnect?
    ensure
      ticker&.kill
      @lock.synchronize do
        @plugins.emit(:disconnected) if @welcomed
        @conn.close
        @had_welcome = @welcomed
        reset_state
        @connected_at = nil
        write_status("disconnected") unless @stopping
      end
    end

    # Checks for the main nick in the background (see Bot#check_nick).
    def start_nick_checks
      Thread.new do
        Thread.current.name = "ircbot-nick-#{@network_id}"
        loop do
          sleep NICK_CHECK_INTERVAL
          @lock.synchronize { check_nick }
        rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
          nil # the read loop notices the broken connection
        end
      end
    end

    def intentional_disconnect? = @reconnect_now || @stopping

    def log_security
      if @conn.first_use?
        @log.warn("Connected: #{@conn.security}. Recorded in tls_known_servers; " \
                  "a different key will be refused from now on.")
      else
        @log.info("Connected: #{@conn.security}")
      end
    end

    def quit_and_close(reason)
      @lock.synchronize do
        send_raw("QUIT :#{reason}") if @welcomed
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
        nil
      end
      @conn.close # also wakes the read loop if it is waiting for data
    end

    def apply_config(new_config)
      old = @config
      RESTART_SETTINGS.each do |name|
        next if old[name] == new_config[name]

        @log.warn("#{name} changed in the config; that only takes effect after a restart")
        new_config[name] = old[name]
      end
      changed = new_config.keys.reject { |name| old[name] == new_config[name] }
      @config = new_config
      @log.info(changed.empty? ? "Config reloaded; no settings changed" : "Config reloaded; changed: #{changed.join(', ')}")

      @accounts.configure(session_ttl: @config["session_ttl_hours"] * 3600, max_accounts: @config["max_accounts"])
      sync_plugins # also picks up new and changed plugin files

      if changed.intersect?(CONNECTION_SETTINGS)
        @rebuild_connection = true
        return request_reconnect("Applying new connection settings")
      end

      if @welcomed
        if changed.include?("nick")
          send_raw("NICK #{@config['nick']}") unless self?(@config["nick"])
          watch_primary_nick
        end
        send_raw("MODE #{@nick} #{@config['umodes']}") if changed.include?("umodes") && !@config["umodes"].empty?
      end
      sync_channels
    end

    # Joins configured and registered channels the bot is not in, and parts
    # channels that are neither (e.g. after CHANDROP from the command line).
    def sync_channels
      return unless @joined

      wanted = (@config["channels"] + @channels.names + plugin_channel_names).uniq { |c| key(c) }
      current = @roster.channels_of(@nick)
      wanted.reject { |c| current.any? { |j| Casemap.eq?(j, c) } }.each { |c| send_raw("JOIN #{c}") }
      current.reject { |j| wanted.any? { |c| Casemap.eq?(c, j) } }.each { |c| send_raw("PART #{c} :No longer configured") }
    end

    # Writes the bot's state for "ircbot-docker status" and health checks,
    # or hands it to the supervisor, which writes all networks' states.
    def write_status(state = nil)
      @status_state = state if state
      @channel_snapshot = @roster.channels_of(@nick).sort.freeze
      now = Time.now.utc
      status = {
        "state" => @status_state || "starting",
        "id" => @network_id,
        "server" => @config["server"],
        "port" => @config["port"],
        "network" => @network_name,
        "nick" => @nick,
        "channels" => @channel_snapshot,
        "connected_since" => @connected_at&.iso8601,
        "plugins" => @plugins&.status || {},
        "updated_at" => now.iso8601,
        "updated_at_unix" => now.to_i
      }
      return @status_sink.call(@network_id, status) if @status_sink

      path = @config["status_file"] or return
      Bot.write_status_file(path, status)
    rescue SystemCallError, IOError => e
      @log.warn("Could not write the status file: #{e.message}")
    end

    # Replaces the status file atomically, readable only by the bot's user.
    def self.write_status_file(path, status)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      tmp = "#{path}.#{Process.pid}.#{Thread.current.object_id}.tmp"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC | File::NOFOLLOW, 0o600) do |file|
        file.write(JSON.pretty_generate(status))
      end
      File.rename(tmp, path)
    end
  end
end

module Rubicon
  # Runs one Bot per network in config["networks"], each on its own thread.
  # The bots share the data store (accounts are valid on every network)
  # and the password hasher; channels, sessions and plugin data are per
  # network. The supervisor handles the Unix signals (see SignalHandling),
  # applies reloaded configs, starting added networks and disconnecting
  # removed ones, and writes the status file for all networks.
  class Supervisor
    include SignalHandling

    # connection_factory: ->(network config) { connection } for tests.
    def initialize(config, config_path: nil, logger: Logger.new($stdout), store: nil, hasher: nil,
                   connection_factory: nil)
      @config = config
      @config_path = config_path
      @log = logger
      @connection_factory = connection_factory
      @store = store || Store.new(config["data_file"])
      @store.on_error = ->(message) { @log.warn(message) }
      @hasher = hasher || Supervisor.hasher_for(config, @log)
      adopt_legacy_channels
      @mutex = Mutex.new        # @bots and @threads; never held while calling into a bot
      @status_mutex = Mutex.new # @statuses and the status file; may take @mutex, never the reverse
      @bots = {}                # network key => Bot
      @threads = {}
      @errors = {}              # network key => why it stopped
      @statuses = {}
      config["networks"].each { |net| @bots[key(net["id"])] = build_bot(net) }
    end

    # The password hasher for a config: scrypt in hash_workers processes.
    def self.hasher_for(config, logger)
      workers = config.fetch("hash_workers", 0).positive? ? HashWorkers.new(size: config["hash_workers"], logger: logger) : nil
      PasswordHasher.new(pepper: Pepper.load(path: config["pepper_file"]), workers: workers, logger: logger)
    end

    def bots = @mutex.synchronize { @bots.values }

    def bot(network) = @mutex.synchronize { @bots[key(network)] }

    # Network names in config order.
    def network_ids = @config["networks"].map { |net| net["id"] }

    # Runs until stopped. A network that fails for good (e.g. the server is
    # on the wrong network) stops alone; if every network has failed, the
    # errors are raised as a ConfigError.
    def run(handle_signals: true)
      install_signal_handlers if handle_signals
      @mutex.synchronize do
        @running = true
        @bots.each_value { |bot| start(bot) }
      end
      while (thread = @mutex.synchronize { @threads.values.find(&:alive?) })
        thread.join
      end
      errors = @mutex.synchronize { @errors.values }
      raise ConfigError, errors.join("; ") if errors.any? && !@stopping
    ensure
      @hasher.shutdown if @hasher.respond_to?(:shutdown)
    end

    # Re-reads config.yml and applies it to every network. A broken config
    # is rejected and everything keeps running. Returns success.
    def reload_config
      unless @config_path
        @log.warn("Reload requested, but the bot was started without a config file path")
        return false
      end

      apply_config(Config.load(@config_path))
      true
    rescue ConfigError, Psych::Exception => e
      @log.error("Config reload failed; still running with the previous settings: #{e.message}")
      false
    end

    def request_reconnect(reason = "Reconnecting")
      bots.each { |bot| bot.request_reconnect(reason) }
    end

    def stop(reason = "Shutting down")
      @stopping = true
      bots.each { |bot| bot.stop(reason) }
    end

    private

    def key(network) = Channels.network_key(network)

    # Channels registered before networks existed belong to the first one.
    def adopt_legacy_channels
      network = @config["networks"].first["id"]
      moved = Channels.adopt_legacy!(@store, network)
      @log.info("Moved #{moved} registered channel(s) to network #{network}") if moved.positive?
    end

    def build_bot(net)
      bot = nil
      logger = @log.dup
      logger.progname = net["id"] if @config["networks"].size > 1 || net["id"] != Config::DEFAULT_NETWORK
      bot = Bot.new(net, connection: @connection_factory&.call(net), store: @store, hasher: @hasher,
                         config_path: @config_path, logger: logger, supervisor: self,
                         status_sink: ->(_network, status) { update_status(bot, status) })
    end

    # Callers hold @mutex.
    def start(bot)
      network = key(bot.network_id)
      @errors.delete(network)
      @threads[network] = Thread.new do
        Thread.current.name = "rubicon-#{bot.network_id}"
        bot.run(handle_signals: false)
      rescue StandardError => e
        message = "#{bot.network_id}: #{e.message}"
        @log.error("Network #{bot.network_id} stopped: #{e.class}: #{e.message}")
        @mutex.synchronize { @errors[network] = message if @bots[network].equal?(bot) }
      end
    end

    def apply_config(new_config)
      Bot::RESTART_SETTINGS.each do |name|
        next if @config[name] == new_config[name]

        @log.warn("#{name} changed in the config; that only takes effect after a restart")
        ([new_config] + new_config["networks"]).each { |config| config[name] = @config[name] }
      end
      @config = new_config

      wanted = new_config["networks"].to_h { |net| [key(net["id"]), net] }
      current, threads, running = @mutex.synchronize { [@bots.dup, @threads.dup, @running] }
      (current.keys - wanted.keys).each { |network| remove(network, current[network]) }
      wanted.each do |network, net|
        bot = current[network]
        if bot && (threads[network]&.alive? || !running)
          bot.apply_network_config(net)
        else
          # A new network, or one that stopped on an error: start it afresh.
          @log.info("Starting network #{net['id']}")
          bot = build_bot(net)
          @mutex.synchronize do
            @bots[network] = bot
            start(bot) if @running
          end
        end
      end
    end

    def remove(network, bot)
      @log.info("Network #{bot.network_id} was removed from the config; disconnecting")
      @mutex.synchronize { @bots.delete(network) }
      bot.stop("Leaving this network")
      @status_mutex.synchronize do
        @statuses.delete(network)
        write_status_file
      end
    end

    def update_status(bot, status)
      return unless bot

      network = key(bot.network_id)
      return unless @mutex.synchronize { @bots[network].equal?(bot) }

      @status_mutex.synchronize do
        @statuses[network] = status
        write_status_file
      end
    end

    # The combined status: "state" is "connected" only when every network
    # is, which is what the Docker health check looks for, and
    # "updated_at_unix" is the oldest network update.
    def write_status_file
      path = @config["status_file"] or return
      # Networks that haven't reported yet count as starting.
      ids = @mutex.synchronize { @bots.values.map(&:network_id) }
      statuses = ids.map { |id| @statuses[key(id)] || { "id" => id, "state" => "starting" } }
      states = statuses.map { |status| status["state"] }.uniq
      state = if states == ["connected"] then "connected"
              elsif states.include?("connected") then "partly connected"
              else states.first || "starting"
              end
      now = Time.now.utc
      Bot.write_status_file(path, {
        "state" => state,
        "networks" => statuses.to_h { |status| [status["id"], status.except("id")] },
        "plugins" => statuses.first&.fetch("plugins", {}) || {},
        "updated_at" => now.iso8601,
        "updated_at_unix" => statuses.filter_map { |status| status["updated_at_unix"] }.min || now.to_i
      })
    rescue SystemCallError, IOError => e
      @log.warn("Could not write the status file: #{e.message}")
    end
  end
end

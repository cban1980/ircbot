module Rubicon
  # Protocol event handling and the private-message command interface.
  class Bot
    Context = Data.define(:nick, :userhost)

    COMMANDS = {
      "HELP" => :cmd_help,
      "REGISTER" => :cmd_register,
      "IDENTIFY" => :cmd_identify,
      "LOGOUT" => :cmd_logout,
      "PASSWORD" => :cmd_password,
      "WHOAMI" => :cmd_whoami,
      "CHANREGISTER" => :cmd_chanregister,
      "CHANDROP" => :cmd_chandrop,
      "ACCESS" => :cmd_access,
      "UP" => :cmd_up,
      "DOWN" => :cmd_down,
      "OP" => :cmd_mode,
      "DEOP" => :cmd_mode,
      "VOICE" => :cmd_mode,
      "DEVOICE" => :cmd_mode,
      "PLUGIN" => :cmd_plugin
    }.freeze

    MODE_COMMANDS = { "OP" => "+o", "DEOP" => "-o", "VOICE" => "+v", "DEVOICE" => "-v" }.freeze

    HELP = [
      "Account commands:",
      "  REGISTER <password>               register your current nick",
      "  IDENTIFY [account] <password>     log in",
      "  LOGOUT                            log out",
      "  PASSWORD <old> <new>              change your password",
      "  WHOAMI                            show who you are identified as",
      "Channel commands:",
      "  UP <#chan> / DOWN <#chan>          give or remove your own modes",
      "  OP|DEOP|VOICE|DEVOICE <#chan> [nick]",
      "  ACCESS <#chan> LIST",
      "  ACCESS <#chan> ADD <account> <voice|op>",
      "  ACCESS <#chan> DEL <account>",
      "  ACCESS <#chan> ADDMASK <nick!user@host> <voice|op>   (bot admins only)",
      "  ACCESS <#chan> DELMASK <nick!user@host>              (bot admins only)",
      "  CHANREGISTER <#chan> <owner>      (bot admins only)",
      "  CHANDROP <#chan>                  (channel owner)",
      "  PLUGIN LIST|LOAD|UNLOAD|RELOAD [name]   (bot admins only)"
    ].freeze

    # Commands carrying a password; only accepted from users connected via TLS.
    SECRET_COMMANDS = %w[REGISTER IDENTIFY PASSWORD].freeze

    # Message text that carries a password, including a mistyped "/msg Bot ...".
    SECRET_TEXT = /\A\s*(?:\/?msg\s+\S+\s+)?(?:REGISTER|IDENTIFY|PASSWORD)(?:\s+\S+){1,2}\s*\z/i
    SECRET_LINE = /\A(.*?(?:PRIVMSG|NOTICE) \S+ :\s*(?:\/?msg\s+\S+\s+)?(?:REGISTER|IDENTIFY|PASSWORD)\b).*/i

    # PLUGIN SET of a secret-looking setting (an API key or token).
    SECRET_SETTING = /\A\s*(?:\/?msg\s+\S+\s+)?PLUGIN\s+SET\s+\S+\s+\S*(?:key|token|secret|password)\S*\s/i
    SECRET_SETTING_LINE = /\A(.*?(?:PRIVMSG|NOTICE) \S+ :\s*(?:\/?msg\s+\S+\s+)?PLUGIN\s+SET\s+\S+\s+\S*(?:key|token|secret|password)\S*)\s.*/i

    # How a user's TLS status shows up in WHOIS: 671 on most networks,
    # 320 "is a Secure Connection (SSL/TLS)" on IRCnet (ircd 2.11.3+).
    SECURE_WHOIS_TEXT = /secure connection|SSL|TLS/i
    WHOIS_TIMEOUT = 30

    # Failed password attempts allowed per 15 minutes, by key type.
    LOGIN_WINDOW = 15 * 60
    LOGIN_LIMITS = { pair: 5, host: 10, account: 25 }.freeze
    # Accounts that may be registered per host per hour.
    REGISTER_WINDOW = 60 * 60
    REGISTER_LIMIT = 3

    # IRC formatting codes, other control characters, and bidirectional
    # overrides that could disguise text; removed from replies.
    UNSAFE_CHARS = /[\x00-\x1f\x7f\u0080-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069]/

    # Commands (private messages) per 30 seconds, per host and in total.
    # Over the limit, the bot stays silent so it can't be used to flood.
    COMMAND_WINDOW = 30
    COMMAND_LIMIT_PER_HOST = 8
    COMMAND_LIMIT_TOTAL = 60
    HELP_COST = 4 # HELP sends many lines
    MAX_PENDING_WHOIS = 50

    # Without the main nick, how often to check whether it is free (ISON).
    # Servers with MONITOR also report it the moment it is.
    NICK_CHECK_INTERVAL = 60
    TICK_INTERVAL = 5 # seconds between the ticker's checks (rejoins, nick)

    # Threads for users' commands and for plugins' queues (see KeyedExecutor).
    COMMAND_THREADS = 2
    PLUGIN_THREADS = 4

    # Jobs that may wait per user (commands) and per plugin (events ...):
    # plenty for bursts, but bounded so a runaway can't eat all memory.
    COMMANDS_PER_USER = 200
    JOBS_PER_PLUGIN = 5_000

    # Makes the executors; tests swap in InlineExecutor.
    class << self
      attr_writer :executor_factory

      def executor_factory
        @executor_factory ||= lambda do |name, size, logger, max_per_key|
          KeyedExecutor.new(size: size, name: name, logger: logger, max_per_key: max_per_key)
        end
      end
    end

    attr_reader :nick, :network_id, :isupport, :plugin_jobs

    # Channels the bot is in, as of its last status update; safe to read
    # from other threads (Plugin::Remote).
    attr_reader :channel_snapshot

    # config: one network's flat config (see Config.network); a whole loaded
    # config means its first network. status_sink: called with (network,
    # status hash) instead of writing the status file (see Supervisor).
    # http and plugin_pool replace the plugins' HTTP client and worker
    # threads (for tests).
    def initialize(config, connection: nil, store: nil, hasher: nil, clock: nil, http: nil, plugin_pool: nil,
                   config_path: nil, status_sink: nil, supervisor: nil, logger: Logger.new($stdout))
      config = Config.network(config)
      @config = config
      @network_id = config["id"] || Config::DEFAULT_NETWORK
      @status_sink = status_sink
      @supervisor = supervisor # the other networks, for plugins
      @isupport = ISupport.new
      @plugin_channels = {}    # plugin name => channels it joined
      @plugin_channel_keys = {} # channel key => the key a plugin joined it with
      @rejoins = {}            # channel key => retry state (see bot_rejoin.rb)
      @channel_snapshot = [].freeze
      @remote_lock = Mutex.new
      @server_index = 0 # which of servers (see bot_health.rb) to connect to
      @plugin_channels_lock = Monitor.new
      @command_jobs = Bot.executor_factory.call("commands-#{@network_id}", COMMAND_THREADS, logger, COMMANDS_PER_USER)
      @plugin_jobs = Bot.executor_factory.call("plugins-#{@network_id}", PLUGIN_THREADS, logger, JOBS_PER_PLUGIN)
      @config_path = config_path # enables reloading on SIGHUP
      @log = logger
      @own_connection = connection.nil? # rebuilt when connection settings change
      @conn = connection || Connection.from_config(config)
      @lock = Monitor.new # serializes IRC handling with reloads from the signal thread
      @wake = Queue.new   # interrupts the reconnect delay
      @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      store ||= Store.new(config["data_file"])
      store.on_error = ->(message) { @log.warn(message) } unless supervisor # the supervisor reports for all networks
      @store = store
      hasher ||= Supervisor.hasher_for(config, logger)
      @accounts = Accounts.new(store, hasher, clock: @clock,
                                              session_ttl: config.fetch("session_ttl_hours", 24) * 3600,
                                              max_accounts: config.fetch("max_accounts", Accounts::DEFAULT_MAX_ACCOUNTS))
      @channels = Channels.new(store, network: @network_id)
      @roster = Roster.new
      @login_limiter = RateLimiter.new(window: LOGIN_WINDOW, clock: @clock)
      @register_limiter = RateLimiter.new(window: REGISTER_WINDOW, clock: @clock)
      @command_limiter = RateLimiter.new(window: COMMAND_WINDOW, clock: @clock)
      @secure_users = {}  # nick key => userhost confirmed as using TLS
      @pending_whois = {} # nick key => secret command waiting for a TLS check
      @plugin_http = http
      @plugin_pool = plugin_pool
      @nick = config["nick"]
      @nick_attempts = 0
      @welcomed = false
      @joined = false
      setup_plugins
    end

    # (run, signal handling, config reload and the status file are in
    # bot_runtime.rb; plugin support is in bot_plugins.rb)

    def connected? = @welcomed

    # Runs the block on this bot's turn, from another network's plugin
    # (Plugin::Remote, publish everywhere). Jobs run in order on one thread.
    # Returns false if the queue is full.
    def queue_remote(&job)
      @remote_lock.synchronize do
        @remote_queue ||= WorkerPool.new(size: 1, max_queue: 500, logger: @log)
        @remote_queue.submit { @lock.synchronize(&job) }
      end
    end

    # Handles one line from the server. Nothing a remote party sends may
    # crash the bot: unexpected errors are logged and the line is dropped.
    def handle(line)
      line_received
      msg = Message.parse(line)
      dispatch_line(msg)
      notify_plugins(msg)
    rescue WrongNetworkError
      raise # stops this network (see Supervisor)
    rescue StandardError => e
      @log.error("Dropped line #{redact(line.chomp).inspect}: #{e.class}: #{e.message} " \
                 "(#{e.backtrace&.first})")
    end

    private

    def dispatch_line(msg)
      @roster.note_userhost(msg.nick, msg.userhost) if msg.userhost
      case msg.command
      when "PING" then on_ping(msg)
      when "001" then on_welcome(msg)
      when "005" then on_isupport(msg)
      when "376", "422" then on_end_of_motd # end of MOTD / no MOTD
      when "303" then on_ison(msg)
      when "731" then on_monitor_offline(msg)
      # 432 erroneous, 433 in use, 437 unavailable (IRCnet nick delay; for
      # a channel, the channel is unavailable)
      when "437" then @isupport.channel?(msg.params[1]) ? on_join_failed(msg) : on_nick_rejected
      when "432", "433" then on_nick_rejected
      when *JOIN_ERRORS.keys then on_join_failed(msg)
      when "353" then @roster.add_names(msg.params[2], msg.params[3].to_s.split, @isupport.prefixes.invert)
      when "324" then on_channel_modes(msg)
      when "332" then @roster.set_topic(msg.params[1], msg.params[2])
      when "333" then @roster.set_topic_origin(msg.params[1], msg.params[2], msg.params[3].to_i)
      when "MODE" then on_mode(msg)
      when "TOPIC" then @roster.set_topic(msg.params[0], msg.params[1], by: msg.nick, at: Time.now.to_i)
      when "311" then on_whois_user(msg)
      when "320", "671" then on_whois_secure(msg)
      when "318" then on_end_of_whois(msg)
      when "JOIN" then on_join(msg)
      when "PART" then on_part(msg.params[0], msg.nick)
      when "KICK" then on_kick(msg)
      when "QUIT" then on_quit(msg.nick)
      when "NICK" then on_nick(msg.nick, msg.params[0])
      when "PRIVMSG" then on_privmsg(msg)
      when "482" then @log.warn("Not a channel operator on #{msg.params[1]}; cannot set modes")
      end
    end

    # --- connection lifecycle -------------------------------------------

    def register_connection
      send_raw("NICK #{@nick}")
      send_raw("USER #{@config['user']} 0 * :#{@config['realname']}")
    end

    def reset_state
      @welcomed = false
      @joined = false
      @network_name = nil
      @nick = @config["nick"]
      @nick_attempts = 0
      @monitor_supported = false
      @monitoring = false
      @isupport.clear
      @link_since = nil
      @last_received = nil
      @link_pinged = false
      @rejoins.clear # a new connection joins everything again
      @roster.clear
      @accounts.clear_sessions
      @secure_users.clear
      @pending_whois.clear
    end

    def on_welcome(msg)
      @welcomed = true
      @nick = msg.params[0]
      send_raw("MODE #{@nick} #{@config['umodes']}") unless @config["umodes"].empty?
      join_channels unless @config["network"]
      write_status("connected")
    end

    # With "network" configured, channels are only joined once the server
    # has confirmed the network name (ISUPPORT NETWORK=...).
    def on_isupport(msg)
      tokens = msg.params[1..-2].to_a
      @isupport.update(tokens)
      @monitor_supported ||= @isupport.key?("MONITOR")
      token = tokens.find { |param| param.start_with?("NETWORK=") } or return

      actual = token.delete_prefix("NETWORK=")
      @network_name = actual
      write_status
      expected = @config["network"] or return
      return join_channels if actual.casecmp?(expected)

      wrong_network!("this server is on the #{actual} network, not #{expected}")
    end

    def on_end_of_motd
      watch_primary_nick
      return unless @config["network"] && !@joined

      wrong_network!("the server did not report its network name, so it can't be confirmed as #{@config['network']}")
    end

    def wrong_network!(reason)
      send_raw("QUIT :Wrong network", urgent: true)
      raise WrongNetworkError, "Not joining any channels: #{reason}. Check the server setting."
    end

    def join_channels
      return if @joined

      @joined = true
      channels = @config["channels"] + @channels.names + plugin_channel_names
      channels.uniq { |c| Casemap.downcase(c) }.each { |c| send_raw(join_line(c)) }
    end

    # The server pings every few minutes; use that to retry the primary nick.
    def on_ping(msg)
      send_raw("PONG :#{msg.params.last}", urgent: true)
      regain_nick
      write_status # doubles as the health check heartbeat
    end

    # During registration, work through nick, then alt_nicks, then a
    # numbered fallback. Once connected, a rejected regain attempt is ignored.
    def on_nick_rejected
      return if @welcomed

      @nick_attempts += 1
      candidates = [@config["nick"]] + @config["alt_nicks"]
      @nick = candidates[@nick_attempts] || "#{@config['nick'][0, 6]}#{rand(100..999)}"
      send_raw("NICK #{@nick}")
    end

    def regain_nick
      send_raw("NICK #{@config['nick']}") if @welcomed && !self?(@config["nick"])
    end

    # Asks the server to report when the main nick goes offline (MONITOR),
    # so it is retaken at once, even with no channel in common with its
    # holder. Also called when the nick setting changes.
    def watch_primary_nick
      return unless @monitor_supported && @welcomed

      send_raw("MONITOR C") if @monitoring
      send_raw("MONITOR + #{@config['nick']}")
      @monitoring = true
    end

    # Called every NICK_CHECK_INTERVAL while connected: without the main
    # nick, asks whether it is in use (answered by 303, see on_ison).
    def check_nick
      send_raw("ISON #{@config['nick']}") if @welcomed && !self?(@config["nick"])
    end

    # RPL_ISON: the nicks from the ISON request that are online.
    def on_ison(msg)
      online = msg.params.last.to_s.split
      regain_nick unless online.any? { |nick| Casemap.eq?(nick, @config["nick"]) }
    end

    # RPL_MONOFFLINE: watched nicks that just went offline.
    def on_monitor_offline(msg)
      offline = msg.params.last.to_s.split(",").map { |target| target.split("!", 2).first }
      regain_nick if offline.any? { |nick| Casemap.eq?(nick, @config["nick"]) }
    end

    # --- channel membership ------------------------------------------------

    def on_join(msg)
      channel = msg.params[0]
      @roster.join(channel, msg.nick, msg.userhost)
      if self?(msg.nick)
        @rejoins[key(channel)]&.store(:at, nil) # back in; the entry remembers the backoff
        send_raw("MODE #{channel}") # learn the channel modes (324)
        return write_status
      end
      return unless @channels.registered?(channel)

      # The higher of the identified account's level and any matching mask.
      account = @accounts.account_for(msg.nick, msg.userhost)
      account_level = account && level_for(channel, account)
      mask_level, mask = @channels.mask_level(channel, msg.prefix)
      if Channels.rank(mask_level) > Channels.rank(account_level)
        @log.info("#{msg.prefix} matches mask #{mask} on #{channel}: giving #{mask_level}")
        set_mode(channel, "+#{Channels::MODES[mask_level]}", msg.nick)
      elsif account_level
        set_mode(channel, "+#{Channels::MODES[account_level]}", msg.nick)
      end
    end

    # Keeps the roster's status modes and channel modes current.
    def on_mode(msg)
      channel = msg.params[0]
      return unless @isupport.channel?(channel)

      lists = @isupport.chanmode_groups.first
      status = @isupport.prefixes.keys
      mode_changes(msg).each do |change|
        if status.include?(change.mode)
          @roster.set_member_mode(channel, change.param, change.mode, change.set) if change.param
        elsif !lists.include?(change.mode)
          @roster.set_channel_mode(channel, change.mode, change.set, change.param)
        end
      end
    end

    # RPL_CHANNELMODEIS: me, channel, modes, parameters...
    def on_channel_modes(msg)
      _me, channel, modes, *params = msg.params
      @roster.reset_channel_modes(channel)
      @isupport.parse_modes(modes, params).each do |change|
        @roster.set_channel_mode(channel, change.mode, change.set, change.param)
      end
    end

    def mode_changes(msg) = @isupport.parse_modes(msg.params[1], msg.params[2..] || [])

    def on_part(channel, nick)
      return @roster.part(channel, nick) unless self?(nick)

      @roster.leave(channel)
      write_status
    end

    def on_quit(nick)
      @roster.quit(nick)
      @accounts.logout(nick)
      @secure_users.delete(key(nick))
      @pending_whois.delete(key(nick))
      regain_nick if Casemap.eq?(nick, @config["nick"])
    end

    def on_nick(old_nick, new_nick)
      if self?(old_nick)
        @nick = new_nick
        @log.info("Got the main nick #{new_nick} back") if Casemap.eq?(new_nick, @config["nick"])
        write_status
      end
      @roster.rename(old_nick, new_nick)
      @accounts.rename(old_nick, new_nick)
      @pending_whois.delete(key(old_nick))
      userhost = @secure_users.delete(key(old_nick))
      @secure_users[key(new_nick)] = userhost if userhost
      regain_nick if Casemap.eq?(old_nick, @config["nick"])
    end

    # --- TLS check for password commands ----------------------------------

    # Holds a password command until WHOIS confirms the sender uses TLS.
    # "WHOIS nick nick" asks the user's own server, which knows for sure.
    def await_secure_check(ctx, command, args)
      now = @clock.call
      @pending_whois.delete_if { |_, entry| now - entry[:at] > WHOIS_TIMEOUT }
      if @pending_whois.size >= MAX_PENDING_WHOIS && !@pending_whois.key?(key(ctx.nick))
        raise Error, "The bot is busy. Please try again in a minute."
      end

      send_raw("WHOIS #{ctx.nick} #{ctx.nick}") unless @pending_whois.key?(key(ctx.nick))
      @pending_whois[key(ctx.nick)] = { ctx: ctx, command: command, args: args, at: now }
    end

    def on_whois_user(msg)
      _me, nick, user, host = msg.params
      entry = @pending_whois[key(nick)]
      entry[:whois_userhost] = "#{user}@#{host}" if entry
    end

    def on_whois_secure(msg)
      return if msg.command == "320" && !msg.params.last.to_s.match?(SECURE_WHOIS_TEXT)

      entry = @pending_whois[key(msg.params[1])]
      entry[:secure] = true if entry
    end

    def on_end_of_whois(msg)
      entry = @pending_whois.delete(key(msg.params[1])) or return
      ctx = entry[:ctx]
      # The user@host check guards against the nick changing hands meanwhile.
      if entry[:secure] && entry[:whois_userhost] == ctx.userhost
        @secure_users[key(ctx.nick)] = ctx.userhost
        queue_command(ctx.userhost) { dispatch(ctx, entry[:command], entry[:args]) }
      else
        @log.warn("Refused #{entry[:command]} from #{ctx.nick}!#{ctx.userhost}: not connected via TLS")
        reply(ctx, "Refused: you are not connected to IRC over TLS, so your password can be read " \
                   "in transit. Reconnect to a TLS port (usually 6697) and try again. If you sent " \
                   "a real password, change it once you are on TLS.")
      end
    end

    def secure?(ctx)
      !@config["require_secure_users"] || @secure_users[key(ctx.nick)] == ctx.userhost
    end

    # --- commands ----------------------------------------------------------

    def on_privmsg(msg)
      target, text = msg.params
      return unless msg.nick && text
      if channel?(target) && text.match?(SECRET_TEXT)
        return if throttled?(msg.userhost)

        return warn_public_secret(msg.nick, target)
      end
      if channel?(target)
        return handle_ctcp(msg, target, text) if text.start_with?("\x01") # actions are left to plugins
        return if plugin_channel_command(msg, target, text)

        return @plugins.emit(:message, nick: msg.nick, userhost: msg.userhost, channel: target, text: text, message: msg)
      end
      return unless self?(target)
      return handle_ctcp(msg, target, text) if text.start_with?("\x01")

      name, *args = text.strip.split
      return unless name

      command = name.upcase
      return if throttled?(msg.userhost, cost: command == "HELP" ? HELP_COST : 1)

      ctx = Context.new(nick: msg.nick, userhost: msg.userhost)
      queue_command(ctx.userhost) do
        COMMANDS.key?(command) ? dispatch(ctx, command, args) : run_private_plugin_command(ctx, command, args)
      end
    end

    # Runs a user's command off the line-reading thread, so the bot keeps
    # handling the server (PINGs, joins, modes) and other users meanwhile.
    # One user's commands run in order (IDENTIFY, then OP ...).
    def queue_command(userhost, &job)
      return if @command_jobs.submit("user:#{host_of(userhost)}") { @lock.synchronize(&job) }

      @log.warn("Too many commands waiting from #{host_of(userhost)}; ignoring one")
    end

    # Runs slow work (password hashing) without the bot's lock, so the
    # bot carries on meanwhile; the lock is taken back afterwards.
    def without_lock
      depth = 0
      while @lock.mon_owned?
        @lock.mon_exit
        depth += 1
      end
      yield
    ensure
      depth.times { @lock.mon_enter }
    end

    # Counts a command against the per-host and global limits; true means
    # over the limit, and the command is silently ignored.
    def throttled?(userhost, cost: 1)
      host_key = "host:#{host_of(userhost)}"
      if @command_limiter.blocked_for(host_key, limit: COMMAND_LIMIT_PER_HOST) ||
         @command_limiter.blocked_for("total", limit: COMMAND_LIMIT_TOTAL)
        @log.debug("Ignoring command from #{userhost}: rate limited")
        return true
      end

      cost.times do
        @command_limiter.hit(host_key)
        @command_limiter.hit("total")
      end
      false
    end

    def dispatch(ctx, command, args)
      if SECRET_COMMANDS.include?(command) && !secure?(ctx)
        await_secure_check(ctx, command, args)
      else
        send(COMMANDS.fetch(command), ctx, command, args)
      end
    rescue Error => e
      reply(ctx, e.message)
    end

    def cmd_help(ctx, _command, _args)
      (HELP + @plugins.help_lines(admin: admin?(current_account(ctx)))).each { |line| reply(ctx, line) }
    end

    def cmd_register(ctx, _command, args)
      usage!("REGISTER <password>") unless args.size == 1
      raise Error, "You are already identified. LOGOUT first." if current_account(ctx)
      # Admin accounts are only created locally with bin/rubicon-account, so
      # nobody can claim an admin name over IRC first.
      raise Error, "That name is reserved." if admin?(ctx.nick)

      limit_key = "register:#{host_of(ctx.userhost)}"
      if (wait = @register_limiter.blocked_for(limit_key, limit: REGISTER_LIMIT))
        raise Error, "Too many registrations from your host. Try again in #{minutes(wait)}."
      end

      account = without_lock { @accounts.register(ctx.nick, args[0]) }
      @register_limiter.hit(limit_key)
      @accounts.login(ctx.nick, ctx.userhost, account)
      @log.info("Account registered: #{account} by #{ctx.nick}!#{ctx.userhost}")
      reply(ctx, "Account #{account} registered. You are now identified.")
      @plugins.emit(:identified, nick: ctx.nick, userhost: ctx.userhost, account: account)
    end

    def cmd_identify(ctx, _command, args)
      usage!("IDENTIFY [account] <password>") unless [1, 2].include?(args.size)

      account = verify_password(ctx, args.size == 2 ? args[0] : ctx.nick, args.last)
      @accounts.login(ctx.nick, ctx.userhost, account)
      reply(ctx, "You are now identified as #{account}.")
      apply_modes(ctx.nick, account)
      @plugins.emit(:identified, nick: ctx.nick, userhost: ctx.userhost, account: account)
    end

    def cmd_logout(ctx, _command, _args)
      account = require_account(ctx)
      @accounts.logout(ctx.nick)
      reply(ctx, "You are now logged out.")
      @plugins.emit(:logout, nick: ctx.nick, userhost: ctx.userhost, account: account)
    end

    def cmd_password(ctx, _command, args)
      account = require_account(ctx)
      usage!("PASSWORD <old> <new>") unless args.size == 2

      verify_password(ctx, account, args[0])
      without_lock { @accounts.set_password(account, args[1]) }
      # The change ended all sessions of the account; keep this one.
      @accounts.login(ctx.nick, ctx.userhost, account)
      @log.info("Password changed for #{account} by #{ctx.nick}!#{ctx.userhost}")
      reply(ctx, "Password changed.")
    end

    def cmd_whoami(ctx, _command, _args)
      account = current_account(ctx)
      reply(ctx, account ? "You are identified as #{account}." : "You are not identified.")
    end

    def cmd_chanregister(ctx, _command, args)
      account = require_account(ctx)
      usage!("CHANREGISTER <#chan> <owner>") unless args.size == 2
      raise Error, "Only bot admins can register channels." unless admin?(account)

      channel, owner_name = args
      owner = @accounts.canonical(owner_name) or raise Error, "No account named #{owner_name}."
      @channels.register(channel, owner)
      @log.info("#{account} registered #{channel} for #{owner}")
      send_raw("JOIN #{channel}") unless @roster.on?(channel, @nick)
      reply(ctx, "#{channel} registered with owner #{owner}.")
    end

    def cmd_chandrop(ctx, _command, args)
      usage!("CHANDROP <#chan>") unless args.size == 1

      channel = args[0]
      account, = require_level(ctx, channel, "owner")
      @channels.drop(channel)
      @log.info("#{account} dropped #{channel}")
      send_raw("PART #{channel}") unless @config["channels"].any? { |c| Casemap.eq?(c, channel) }
      reply(ctx, "#{channel} has been dropped.")
    end

    def cmd_access(ctx, _command, args)
      channel, sub, *rest = args
      usage!("ACCESS <#chan> LIST|ADD|DEL|ADDMASK|DELMASK ...") unless channel && sub
      return cmd_access_mask(ctx, channel, sub.upcase, rest) if %w[ADDMASK DELMASK].include?(sub.upcase)

      account, my_level = require_level(ctx, channel, "op")
      case sub.upcase
      when "LIST"
        @channels.access_list(channel).each { |name, level| reply(ctx, "#{channel}: #{name} #{level}") }
        @channels.masks(channel).each { |mask, level, by| reply(ctx, "#{channel}: mask #{mask} #{level} (added by #{by})") }
      when "ADD"
        usage!("ACCESS <#chan> ADD <account> <voice|op>") unless rest.size == 2

        target = existing_account(rest[0])
        level = rest[1].downcase
        unless Channels.rank(level) < Channels.rank(my_level)
          raise Error, "You can only grant levels below your own (#{my_level})."
        end

        check_outranks(channel, target, my_level)
        @channels.set_access(channel, target, level)
        @log.info("#{account} gave #{target} #{level} access on #{channel}")
        reply(ctx, "#{target} now has #{level} access on #{channel}.")
      when "DEL"
        usage!("ACCESS <#chan> DEL <account>") unless rest.size == 1

        target = existing_account(rest[0])
        check_outranks(channel, target, my_level)
        @channels.remove_access(channel, target)
        @log.info("#{account} removed #{target}'s access on #{channel}")
        reply(ctx, "Removed #{target} from #{channel}.")
      else
        usage!("ACCESS <#chan> LIST|ADD|DEL|ADDMASK|DELMASK ...")
      end
    end

    # Hostmask entries give voice/op on join without identifying, so only
    # bot admins may manage them (on any registered channel).
    def cmd_access_mask(ctx, channel, sub, rest)
      account = require_account(ctx)
      raise Error, "Only bot admins can manage masks." unless admin?(account)
      raise Error, "#{channel} is not registered." unless @channels.registered?(channel)

      if sub == "ADDMASK"
        usage!("ACCESS <#chan> ADDMASK <nick!user@host> <voice|op>") unless rest.size == 2

        mask = @channels.add_mask(channel, rest[0], rest[1].downcase, added_by: account)
        @log.info("#{account} added mask #{mask} (#{rest[1].downcase}) on #{channel}")
        reply(ctx, "Mask #{mask} now gets #{rest[1].downcase} on #{channel} when joining.")
      else
        usage!("ACCESS <#chan> DELMASK <nick!user@host>") unless rest.size == 1

        @channels.remove_mask(channel, rest[0])
        @log.info("#{account} removed mask #{rest[0]} on #{channel}")
        reply(ctx, "Removed mask #{rest[0]} from #{channel}.")
      end
    end

    def cmd_up(ctx, _command, args)
      usage!("UP <#chan>") unless args.size == 1

      channel = args[0]
      _account, level = require_level(ctx, channel, "voice")
      require_on_channel(channel, ctx.nick)
      set_mode(channel, "+#{Channels::MODES[level]}", ctx.nick)
    end

    def cmd_down(ctx, _command, args)
      usage!("DOWN <#chan>") unless args.size == 1

      channel = args[0]
      _account, level = require_level(ctx, channel, "voice")
      require_on_channel(channel, ctx.nick)
      set_mode(channel, "-#{Channels::MODES[level]}", ctx.nick)
    end

    def cmd_mode(ctx, command, args)
      usage!("#{command} <#chan> [nick]") unless [1, 2].include?(args.size)

      channel, target = args
      target ||= ctx.nick
      account, my_level = require_level(ctx, channel, "op")
      raise Error, "I don't change my own modes." if self?(target)

      require_on_channel(channel, target)

      mode = MODE_COMMANDS.fetch(command)
      if mode.start_with?("-") && !Casemap.eq?(target, ctx.nick)
        # Protect users whose stored access is not below the requester's.
        target_account = @accounts.session_account(target)
        if target_account && Channels.rank(level_for(channel, target_account)) >= Channels.rank(my_level)
          raise Error, "#{target} has equal or higher access on #{channel}."
        end
      end
      @log.info("#{account} (#{ctx.nick}) set #{mode} on #{target} in #{channel}")
      set_mode(channel, mode, target)
    end

    # --- warnings -------------------------------------------------------------

    # Someone typed a password command into a channel instead of a query.
    def warn_public_secret(nick, channel)
      @log.warn("#{nick} sent a password command to #{channel} publicly")
      send_raw("NOTICE #{nick} :Careful: you sent that to #{channel}, where everyone can read it. " \
               "Always use /msg #{@nick} ... for account commands. If that was a real password, " \
               "change it now with /msg #{@nick} PASSWORD <old> <new>.")
    end

    # --- helpers -------------------------------------------------------------

    # Checks a password with brute-force limits per account+host, per host
    # and per account. Returns the canonical account name or raises.
    def verify_password(ctx, name, password)
      limits = login_limits(name, host_of(ctx.userhost))
      wait = limits.filter_map { |limit_key, limit| @login_limiter.blocked_for(limit_key, limit: limit) }.max
      raise Error, "Too many failed attempts. Try again in #{minutes(wait)}." if wait

      account = without_lock { @accounts.authenticate(name, password) }
      if account
        @login_limiter.reset(limits.keys.first)
        return account
      end

      limits.each_key { |limit_key| @login_limiter.hit(limit_key) }
      @log.warn("Failed password for #{name} from #{ctx.nick}!#{ctx.userhost}")
      raise Error, "Invalid account or password."
    end

    def login_limits(name, host)
      account = key(name)
      {
        "pair:#{account}:#{host}" => LOGIN_LIMITS[:pair],
        "host:#{host}" => LOGIN_LIMITS[:host],
        "account:#{account}" => LOGIN_LIMITS[:account]
      }
    end

    def host_of(userhost) = userhost.to_s.split("@", 2).last.to_s.downcase

    def minutes(seconds)
      count = (seconds / 60.0).ceil
      "#{count} minute#{'s' unless count == 1}"
    end

    def channel?(target) = target.to_s.match?(/\A[#&!+]/)

    def key(name) = Casemap.downcase(name)

    def current_account(ctx) = @accounts.account_for(ctx.nick, ctx.userhost)

    def require_account(ctx)
      current_account(ctx) or raise Error, "You must IDENTIFY first."
    end

    def admin?(account)
      account && @config["admins"].any? { |a| Casemap.eq?(a, account) }
    end

    # Bot admins are treated as owners of every registered channel.
    def level_for(channel, account)
      admin?(account) ? "owner" : @channels.level(channel, account)
    end

    # Returns [account, level] or raises if the user lacks min_level.
    def require_level(ctx, channel, min_level)
      account = require_account(ctx)
      raise Error, "#{channel} is not registered." unless @channels.registered?(channel)

      level = level_for(channel, account)
      if Channels.rank(level) < Channels.rank(min_level)
        raise Error, "You need #{min_level} access on #{channel} for that."
      end

      [account, level]
    end

    def require_on_channel(channel, nick)
      raise Error, "#{nick} is not on #{channel}." unless @roster.on?(channel, nick)
    end

    def existing_account(name)
      @accounts.canonical(name) or raise Error, "No account named #{name}."
    end

    def check_outranks(channel, target, my_level)
      return if Channels.rank(level_for(channel, target)) < Channels.rank(my_level)

      raise Error, "#{target} has equal or higher access on #{channel}."
    end

    def usage!(text)
      raise Error, "Usage: #{text}"
    end

    def apply_modes(nick, account)
      @roster.channels_of(nick).each { |channel| apply_modes_in(channel, nick, account) }
    end

    def apply_modes_in(channel, nick, account)
      return unless @channels.registered?(channel)

      level = level_for(channel, account)
      set_mode(channel, "+#{Channels::MODES[level]}", nick) if level
    end

    def set_mode(channel, mode, nick)
      send_raw("MODE #{channel} #{mode} #{nick}")
    end

    # Replies can echo user input (channel or account names), so control
    # and formatting characters are removed first.
    def reply(ctx, text)
      send_raw("NOTICE #{ctx.nick} :#{text.gsub(UNSAFE_CHARS, '')}")
    end

    # Queues a line for the server (see Connection#write); urgent lines go
    # first. Returns false if it was dropped because too much is queued.
    def send_raw(line, urgent: false)
      @log.debug(">> #{redact(line)}")
      sent = @conn.write(line, urgent: urgent)
      notify_outgoing(line) unless sent == false
      sent != false
    end

    def self?(nick) = Casemap.eq?(nick, @nick)

    # Hides everything after a password command in logged lines.
    def redact(line)
      line.sub(SECRET_LINE, '\1 [redacted]').sub(SECRET_SETTING_LINE, '\1 [redacted]')
    end
  end
end

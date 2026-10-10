module Rubicon
  # Plugin support for the bot: loading plugins, routing commands and
  # events to them, and the admin-only PLUGIN command. Plugins live in
  # plugins_dir and are configured under "plugins:" in config.yml; a config
  # reload (SIGHUP) loads new files and reloads changed ones without
  # reconnecting. See Plugin and PluginManager.
  class Bot
    # The part of the bot that plugins can reach (see Plugin). Plugin code
    # runs under the bot's lock (hooks, commands, timers) or on a worker
    # thread (background jobs), so everything here is safe to call from
    # either.
    class PluginHost
      def initialize(bot) = @bot = bot
      def nick = @bot.nick
      def network = @bot.network_id
      def network_name = @bot.__send__(:plugin_network_name)
      def networks = @bot.__send__(:plugin_networks)
      def primary? = @bot.__send__(:primary_network?)
      def connected? = @bot.connected?
      def server = @bot.__send__(:plugin_server)
      def isupport = @bot.isupport
      def remote(network, owner:) = @bot.__send__(:plugin_remote, network, owner)

      # False while disconnected; plugin output is dropped then.
      def write(line)
        @bot.__send__(:send_raw, line)
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
        false
      end

      def join(owner, channel, key) = guarded { @bot.__send__(:plugin_join, owner, channel, key) }
      def part(owner, channel, reason) = guarded { @bot.__send__(:plugin_part, owner, channel, reason) }
      def plugin_unloaded(name) = guarded { @bot.__send__(:plugin_channels_released, name) }

      def plugin_jobs = @bot.plugin_jobs

      # Plugins changed outside a reload (e.g. loaded once their gems
      # arrived): refresh the status file.
      def status_changed = @bot.__send__(:write_status)

      # Queues a job in the plugin's own queue; skipped once the plugin is
      # being unloaded. False if its queue is full.
      def run_plugin_job(plugin, &job)
        @bot.plugin_jobs.submit("plugin:#{plugin.name}") { job.call if plugin.accepting? }
      end
      def protected_channel?(channel) = @bot.__send__(:core_channel?, channel)

      # These never take the bot's lock: the roster, sessions and data file
      # have their own, so plugin threads can't hold up (or deadlock) the bot.
      def channels = @bot.__send__(:own_channels)
      def members(channel) = @bot.__send__(:roster).members(channel)
      def member(channel, nick) = @bot.__send__(:roster).member(channel, nick)
      def topic(channel) = @bot.__send__(:roster).topic(channel)
      def channel_modes(channel) = @bot.__send__(:roster).channel_modes(channel)
      def userhost_of(nick) = @bot.__send__(:roster).userhost_of(nick)

      def account_for(nick, userhost) = @bot.__send__(:plugin_account, nick, userhost)
      def admin?(account) = @bot.__send__(:admin?, account)
      def level_for(channel, account) = @bot.__send__(:level_for, channel, account)
      def account_name(name) = @bot.__send__(:accounts).canonical(name)
      def admins = @bot.__send__(:plugin_admins)
      def identified_users = @bot.__send__(:plugin_identified_users)
      def registered_channels = @bot.__send__(:registered_channels).names
      def channel_registered?(channel) = @bot.__send__(:registered_channels).registered?(channel)
      def channel_access(channel) = @bot.__send__(:registered_channels).access_list(channel)
      def bot_config = @bot.__send__(:plugin_bot_config)

      def plugin(name) = @bot.__send__(:plugin_manager).plugin(name)
      def publish(topic, payload, from:, everywhere:) = @bot.__send__(:plugin_publish, topic, payload, from, everywhere)

      # The bot's lock; for the plugin manager only, never from plugin code.
      def synchronize(&) = @bot.__send__(:synchronize, &)
      def submit(&) = @bot.__send__(:plugin_pool).submit(&)
      def data_dir = @bot.__send__(:plugin_data_dir)
      def http = @bot.__send__(:plugin_http)
      def gems = @bot.__send__(:plugin_gems)
      def plugin_state = @bot.__send__(:plugin_state)

      private

      def guarded
        yield
        true
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
        false
      end
    end

    PLUGIN_USAGE = "PLUGIN LIST | LOAD <name> | UNLOAD <name> | RELOAD [name] | SETTINGS <name> | " \
                   "SET <name> <setting> <value> | UNSET <name> <setting>".freeze

    private

    def setup_plugins
      @plugins = PluginManager.new(host: PluginHost.new(self), logger: @log, reserved: COMMANDS.keys)
      sync_plugins
    end

    def sync_plugins
      @plugins.sync(@config["plugins_dir"], @config["plugins"])
    end

    # Passes protocol events on to plugins, after the bot has handled them.
    def notify_plugins(msg)
      from = { nick: msg.nick, userhost: msg.userhost, message: msg }
      case msg.command
      when "001" then @plugins.emit(:connected, message: msg)
      when "MODE"
        target = msg.params[0]
        @plugins.emit(:mode, channel: target, modes: mode_changes(msg), **from) if @isupport.channel?(target)
      when "TOPIC" then @plugins.emit(:topic, channel: msg.params[0], text: msg.params[1], **from)
      when "INVITE" then @plugins.emit(:invite, target: msg.params[0], channel: msg.params[1], **from)
      when "PRIVMSG", "NOTICE" then notify_text(msg, from)
      when "JOIN" then @plugins.emit(:join, channel: msg.params[0], **from)
      when "PART" then @plugins.emit(:part, channel: msg.params[0], text: msg.params[1], **from)
      when "QUIT" then @plugins.emit(:quit, text: msg.params[0], **from)
      when "NICK" then @plugins.emit(:nick, new_nick: msg.params[0], **from)
      when "KICK" # nick is the user kicked; message.nick is who kicked
        @plugins.emit(:kick, channel: msg.params[0], nick: msg.params[1], text: msg.params[2], message: msg)
      end
      # Lines carrying a password command are never shown to plugins.
      secret = %w[PRIVMSG NOTICE].include?(msg.command) && secret_text?(msg.params[1])
      @plugins.emit(:line, message: msg) unless secret
    end

    # Private messages, notices, actions and CTCP. Text carrying a password
    # command is never shown to plugins.
    def notify_text(msg, from)
      target, text = msg.params
      return if text.nil? || secret_text?(text)

      channel = target if @isupport.channel?(target)
      if text.start_with?("\x01")
        command, args = text.delete("\x01").split(" ", 2)
        command = command.to_s.upcase
        if command == "ACTION" && msg.command == "PRIVMSG"
          @plugins.emit(:action, channel: channel, target: target, text: args.to_s, **from)
        elsif !command.empty?
          type = msg.command == "PRIVMSG" ? :ctcp : :ctcp_reply
          @plugins.emit(type, channel: channel, target: target, ctcp: command, text: args, **from)
        end
      elsif msg.command == "NOTICE"
        @plugins.emit(:notice, channel: channel, target: target, text: text, **from)
      elsif channel.nil? && self?(target)
        @plugins.emit(:private_message, target: target, text: text, **from)
      end
    end

    # Tells plugins about a line the bot sent, once per line: lines sent
    # by :outgoing hooks themselves are not reported again.
    def notify_outgoing(line)
      return if @plugins.nil? || Thread.current[:rubicon_outgoing_hook]

      safe = redact(line)
      @plugins.emit(:outgoing, text: safe, message: Message.parse(safe))
    end

    # --- CTCP ---------------------------------------------------------------------

    CTCP_CORE = %w[VERSION PING TIME CLIENTINFO].freeze

    # Answers a CTCP request (other than ACTION): a plugin's ctcp_handler
    # first, then the bot's own VERSION, PING, TIME and CLIENTINFO.
    def handle_ctcp(msg, target, text)
      command, args = text.delete("\x01").split(" ", 2)
      command = command.to_s.upcase
      return if command.empty? || command == "ACTION" || !command.match?(PluginIRC::CTCP_COMMAND)
      return if self?(msg.nick) || throttled?(msg.userhost)

      fields = { nick: msg.nick, userhost: msg.userhost, target: target,
                 channel: (target if @isupport.channel?(target)), text: args, message: msg }
      asked = @plugins.answer_ctcp(command, **fields) do |answer|
        send_ctcp_answer(msg.nick, command, answer || core_ctcp_answer(command, args))
      end
      send_ctcp_answer(msg.nick, command, core_ctcp_answer(command, args)) unless asked
    end

    def send_ctcp_answer(nick, command, answer)
      return unless answer

      answer = answer.gsub(/[\r\n\0\x01]+/, " ").strip
      answer = answer.byteslice(0, PluginIRC::MAX_LINE_BYTES).scrub("") if answer.bytesize > PluginIRC::MAX_LINE_BYTES
      send_raw("NOTICE #{nick} :\x01#{command}#{" #{answer}" unless answer.empty?}\x01")
    end

    def core_ctcp_answer(command, args)
      return nil unless @config.fetch("ctcp", Config::CTCP_DEFAULTS)["enabled"]

      case command
      when "VERSION" then @config.fetch("ctcp", Config::CTCP_DEFAULTS)["version"]
      when "PING" then args.to_s[0, 64]
      when "TIME" then Time.now.utc.strftime("%a %b %d %H:%M:%S %Y UTC")
      when "CLIENTINFO" then (["ACTION"] + CTCP_CORE + @plugins.ctcp_commands).uniq.join(" ")
      end
    end

    # --- the bot's log as :log events ---------------------------------------------

    # While the bot runs, its log records reach plugins as :log events.
    def start_log_events
      @log_tap ||= LogTap.subscribe { |severity, time, progname, text| log_record(severity, time, progname, text) }
    end

    def stop_log_events
      LogTap.unsubscribe(@log_tap) if @log_tap
      @log_tap = nil
    end

    # Records go to the network they're about (progname "IRCnet" or
    # "IRCnet/links"); others (startup, gem installs) to the first network.
    def log_record(severity, time, progname, text)
      owner = plugin_networks.find { |n| progname == n || progname.to_s.start_with?("#{n}/") }
      return unless owner ? Casemap.eq?(owner, @network_id) : primary_network?

      @plugins.emit(:log, level: severity.to_s.downcase, source: progname, text: text, at: time.utc)
    end

    # --- channels joined by plugins -------------------------------------------------

    # plugin name => [channel, ...]; joined again after reconnects and kept
    # by config reloads.
    def plugin_channel_names = @plugin_channels_lock.synchronize { @plugin_channels.values.flatten.uniq { |c| key(c) } }

    def plugin_join(owner, channel, channel_key)
      @plugin_channels_lock.synchronize { plugin_join_locked(owner, channel, channel_key) }
    end

    def plugin_join_locked(owner, channel, channel_key)
      list = (@plugin_channels[owner] ||= [])
      list << channel unless list.any? { |c| Casemap.eq?(c, channel) }
      if channel_key
        @plugin_channel_keys[key(channel)] = channel_key
      else
        @plugin_channel_keys.delete(key(channel))
      end
      send_raw(join_line(channel)) if @welcomed && !@roster.on?(channel, @nick)
    end

    def plugin_part(owner, channel, reason)
      @plugin_channels_lock.synchronize { plugin_part_locked(owner, channel, reason) }
    end

    def plugin_part_locked(owner, channel, reason)
      if core_channel?(channel)
        raise ArgumentError, "#{channel} is in the config or registered; plugins can't part it"
      end

      @plugin_channels[owner]&.reject! { |c| Casemap.eq?(c, channel) }
      @plugin_channels.delete(owner) if @plugin_channels[owner]&.empty?
      return if plugin_channel_names.any? { |c| Casemap.eq?(c, channel) } # another plugin still wants it

      send_raw("PART #{channel}#{" :#{reason}" if reason}") if @welcomed && @roster.on?(channel, @nick)
    end

    # A plugin was unloaded: leave the channels only it wanted.
    def plugin_channels_released(name)
      released = @plugin_channels_lock.synchronize { @plugin_channels.delete(name) } or return
      released.each do |channel|
        next if core_channel?(channel) || plugin_channel_names.any? { |c| Casemap.eq?(c, channel) }

        send_raw("PART #{channel}") if @welcomed && @roster.on?(channel, @nick)
      end
    end

    def core_channel?(channel)
      (@config["channels"] + @channels.names).any? { |c| Casemap.eq?(c, channel) }
    end

    # Handles "!command ..." in a channel for plugins with a prefix.
    # Returns true if the message was a plugin command.
    def plugin_channel_command(msg, channel, text)
      return false if self?(msg.nick)

      invocation = @plugins.channel_command(channel, text) or return false
      return true if throttled?(msg.userhost)

      # Through the user's queue, so it comes after their earlier commands.
      queue_command(msg.userhost) { @plugins.run(invocation, nick: msg.nick, userhost: msg.userhost, channel: channel) }
      true
    end

    def run_private_plugin_command(ctx, command, args)
      invocation = @plugins.private_command(command, args) or return reply(ctx, "Unknown command. Try HELP.")

      @plugins.run(invocation, nick: ctx.nick, userhost: ctx.userhost)
    end

    # PLUGIN commands act on this network. UNLOAD and SET are remembered
    # for this network across restarts (see PluginState).
    def cmd_plugin(ctx, _command, args)
      account = require_account(ctx)
      raise Error, "Only bot admins can manage plugins." unless admin?(account)

      sub, name, *rest = args
      usage!(PLUGIN_USAGE) unless sub
      name = name&.downcase
      case [sub.upcase, name.nil?, rest.size]
      in ["LIST", true, 0]
        status = @plugins.status
        reply(ctx, "No plugins in #{@config['plugins_dir']}.") if status.empty?
        status.each { |plugin, info| reply(ctx, plugin_summary(plugin, info)) }
      in ["LOAD" | "RELOAD", false, 0]
        if @plugins.load(name) == :installing
          reply(ctx, "Plugin #{name} is installing the gems it needs; it loads when they are in.")
        else
          @log.info("#{account} loaded plugin #{name}")
          reply(ctx, "Plugin #{name} loaded on #{@network_id}.")
        end
      in ["RELOAD", true, 0]
        sync_plugins
        @log.info("#{account} reloaded the plugins folder")
        loaded, other = @plugins.status.partition { |_, info| info["state"] == "loaded" }
        reply(ctx, "Plugins reloaded. Loaded: #{loaded.map(&:first).join(', ').then { |s| s.empty? ? 'none' : s }}")
        other.each { |plugin, info| reply(ctx, plugin_summary(plugin, info)) }
      in ["UNLOAD", false, 0]
        @plugins.unload(name, hold: true)
        @log.info("#{account} unloaded plugin #{name} on #{@network_id}")
        reply(ctx, "Plugin #{name} unloaded on #{@network_id}; it stays unloaded here, also after restarts, " \
                   "until PLUGIN LOAD #{name}.")
      in ["SETTINGS", false, 0]
        rows = @plugins.settings_report(name)
        reply(ctx, "#{name} has no settings.") if rows.empty?
        rows.each do |key, value, saved|
          reply(ctx, "#{name}: #{key} = #{PluginState.show(key, value)}#{' (saved with PLUGIN SET)' if saved}")
        end
      in ["SET", false, 2..]
        key = rest.first.downcase
        value = PluginState.parse_value(rest.drop(1).join(" "))
        result = @plugins.set_setting(name, key, value)
        @log.info("#{account} set #{name} #{key} on #{@network_id}")
        reply(ctx, "#{name}: #{key} = #{PluginState.show(key, value)} saved for #{@network_id}#{setting_result(result)}")
      in ["UNSET", false, 1]
        key = rest.first.downcase
        result = @plugins.unset_setting(name, key)
        @log.info("#{account} unset #{name} #{key} on #{@network_id}")
        reply(ctx, "#{name}: #{key} is back to config.yml's value (or the default) on #{@network_id}#{setting_result(result)}")
      else
        usage!(PLUGIN_USAGE)
      end
      write_status
    end

    def setting_result(result)
      case result
      when :reloaded then "; plugin reloaded."
      when :installing then "; the plugin loads when its gems are installed."
      else "; it applies when the plugin is loaded."
      end
    end

    # Text that must never reach plugins or logs.
    def secret_text?(text)
      text = text.to_s
      text.match?(SECRET_TEXT) || text.match?(SECRET_SETTING)
    end

    def plugin_summary(name, info)
      case info["state"]
      when "loaded"
        where = [("private messages" if info["private"]), ("#{info['prefix']} in channels" if info["prefix"])].compact
        commands = info["commands"].empty? ? "no commands" : "commands #{info['commands'].join(', ')}"
        text = "#{name}: loaded, #{commands} (#{where.empty? ? 'events only' : where.join(', ')})"
        text += ". #{info['description']}" unless info["description"].to_s.empty?
        text += ". Last load failed: #{info['error']}" if info["error"]
        text
      when "error" then "#{name}: failed to load: #{info['error']}"
      when "unloaded" then "#{name}: unloaded#{' (kept unloaded with PLUGIN UNLOAD; PLUGIN LOAD to load it)' if info['kept_unloaded']}"
      when "installing" then "#{name}: installing gems #{info['gems'].join(', ')}; loads when done"
      else "#{name}: #{info['state']}"
      end
    end

    # --- what PluginHost exposes ----------------------------------------------

    def own_channels = @roster.channels_of(@nick)

    def roster = @roster
    def accounts = @accounts
    def registered_channels = @channels
    def plugin_manager = @plugins
    def plugin_network_name = @network_name
    def plugin_server = current_server[0]
    def plugin_admins = @config["admins"].dup

    def plugin_networks
      @supervisor ? @supervisor.network_ids : [@network_id]
    end

    def primary_network?
      @supervisor.nil? || Casemap.eq?(@supervisor.network_ids.first, @network_id)
    end

    def plugin_remote(network, owner)
      bot = @supervisor ? @supervisor.bot(network) : (self if Casemap.eq?(network, @network_id))
      bot && Plugin::Remote.new(bot: bot, owner: owner)
    end

    def plugin_identified_users
      @accounts.identified.to_h
    end

    # The settings a plugin may see: everything but secrets and file paths.
    def plugin_bot_config
      config = @config.slice(*%w[nick alt_nicks user realname umodes server port tls network channels admins])
      config["ctcp"] = @config.fetch("ctcp", Config::CTCP_DEFAULTS)
      config["id"] = @network_id
      JSON.parse(JSON.generate(config)).freeze
    end

    # Delivers to listeners here, and with everywhere to other networks'
    # plugins on their own turn.
    def plugin_publish(topic, payload, from, everywhere)
      delivered = @plugins.deliver(topic, payload, from: from, network: @network_id)
      if everywhere && @supervisor
        @supervisor.bots.each do |bot|
          next if bot.equal?(self)

          network = @network_id
          bot.queue_remote { bot.__send__(:plugin_manager).deliver(topic, payload, from: from, network: network) }
        end
      end
      delivered
    end

    def plugin_http
      @plugin_http ||= SafeHttp.new(user_agent: "Mozilla/5.0 (compatible; Rubicon)")
    end

    def plugin_state = @plugin_state ||= PluginState.new(@store, network: @network_id)

    # Shared by every network in the process (one gems folder).
    def plugin_gems
      dir = File.expand_path(@config["gems_dir"] || "gems")
      logger = @log.dup
      logger.progname = "gems"
      PluginGems.for(dir, logger: logger)
    end

    def plugin_account(nick, userhost)
      userhost ? @accounts.account_for(nick, userhost) : @accounts.session_account(nick)
    end

    def synchronize(&) = @lock.synchronize(&)

    def plugin_pool = @plugin_pool ||= WorkerPool.new(size: 2, max_queue: 50, logger: @log)

    def plugin_data_dir = @config["plugin_data_dir"] || File.join(File.dirname(@config["data_file"]), "plugins")
  end
end

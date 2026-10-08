module IRCBot
  # Plugin support for the bot: loading plugins, routing commands and
  # events to them, and the admin-only PLUGIN command. Plugins live in
  # plugins_dir and are configured under "plugins:" in config.yml; a config
  # reload (SIGHUP) loads new files and reloads changed ones without
  # reconnecting. See Plugin and PluginManager.
  class Bot
    # The part of the bot that plugins can reach (see Plugin).
    class PluginHost
      def initialize(bot) = @bot = bot
      def nick = @bot.nick

      # False while disconnected; plugin output is dropped then.
      def write(line)
        @bot.__send__(:send_raw, line)
        true
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
        false
      end

      def channels = @bot.__send__(:own_channels)
      def account_for(nick, userhost) = @bot.__send__(:plugin_account, nick, userhost)
      def admin?(account) = @bot.__send__(:admin?, account)
      def level_for(channel, account) = @bot.__send__(:level_for, channel, account)
      def synchronize(&) = @bot.__send__(:synchronize, &)
      def submit(&) = @bot.__send__(:plugin_pool).submit(&)
      def data_dir = @bot.__send__(:plugin_data_dir)
    end

    PLUGIN_USAGE = "PLUGIN LIST | LOAD <name> | UNLOAD <name> | RELOAD [name]".freeze

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
      when "JOIN" then @plugins.emit(:join, channel: msg.params[0], **from)
      when "PART" then @plugins.emit(:part, channel: msg.params[0], text: msg.params[1], **from)
      when "QUIT" then @plugins.emit(:quit, text: msg.params[0], **from)
      when "NICK" then @plugins.emit(:nick, new_nick: msg.params[0], **from)
      when "KICK" # nick is the user kicked; message.nick is who kicked
        @plugins.emit(:kick, channel: msg.params[0], nick: msg.params[1], text: msg.params[2], message: msg)
      end
      # Lines carrying a password command are never shown to plugins.
      secret = %w[PRIVMSG NOTICE].include?(msg.command) && msg.params[1].to_s.match?(SECRET_TEXT)
      @plugins.emit(:line, message: msg) unless secret
    end

    # Handles "!command ..." in a channel for plugins with a prefix.
    # Returns true if the message was a plugin command.
    def plugin_channel_command(msg, channel, text)
      return false if self?(msg.nick)

      invocation = @plugins.channel_command(channel, text) or return false
      return true if throttled?(msg.userhost)

      @plugins.run(invocation, nick: msg.nick, userhost: msg.userhost, channel: channel)
      true
    end

    def run_private_plugin_command(ctx, command, args)
      invocation = @plugins.private_command(command, args) or return reply(ctx, "Unknown command. Try HELP.")

      @plugins.run(invocation, nick: ctx.nick, userhost: ctx.userhost)
    end

    def cmd_plugin(ctx, _command, args)
      account = require_account(ctx)
      raise Error, "Only bot admins can manage plugins." unless admin?(account)

      sub, name, *extra = args
      usage!(PLUGIN_USAGE) unless sub && extra.empty?

      case [sub.upcase, name.nil?]
      in ["LIST", true]
        status = @plugins.status
        reply(ctx, "No plugins in #{@config['plugins_dir']}.") if status.empty?
        status.each { |plugin, info| reply(ctx, plugin_summary(plugin, info)) }
      in ["LOAD" | "RELOAD", false]
        @plugins.load(name.downcase)
        @log.info("#{account} loaded plugin #{name.downcase}")
        reply(ctx, "Plugin #{name.downcase} loaded.")
      in ["RELOAD", true]
        sync_plugins
        @log.info("#{account} reloaded the plugins folder")
        loaded, other = @plugins.status.partition { |_, info| info["state"] == "loaded" }
        reply(ctx, "Plugins reloaded. Loaded: #{loaded.map(&:first).join(', ').then { |s| s.empty? ? 'none' : s }}")
        other.each { |plugin, info| reply(ctx, plugin_summary(plugin, info)) }
      in ["UNLOAD", false]
        @plugins.unload(name.downcase, hold: true)
        @log.info("#{account} unloaded plugin #{name.downcase}")
        reply(ctx, "Plugin #{name.downcase} unloaded; it stays unloaded until loaded again or the bot restarts.")
      else
        usage!(PLUGIN_USAGE)
      end
      write_status
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
      else "#{name}: #{info['state']}"
      end
    end

    # --- what PluginHost exposes ----------------------------------------------

    def own_channels = @roster.channels_of(@nick)

    def plugin_account(nick, userhost)
      userhost ? @accounts.account_for(nick, userhost) : @accounts.session_account(nick)
    end

    def synchronize(&) = @lock.synchronize(&)

    def plugin_pool = @plugin_pool ||= WorkerPool.new(size: 2, max_queue: 50, logger: @log)

    def plugin_data_dir = @config["plugin_data_dir"] || File.join(File.dirname(@config["data_file"]), "plugins")
  end
end

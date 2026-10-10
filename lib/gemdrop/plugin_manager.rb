require "digest"

module Gemdrop
  # Finds, loads, reloads and unloads plugins (see Plugin), and routes
  # commands and events to them.
  #
  # Plugin code (hooks, commands, listeners, CTCP handlers, timers) runs
  # in each plugin's own queue (Bot#plugin_jobs): one job at a time per
  # plugin, in order, while plugins run in parallel with each other and
  # with the bot. setup and teardown run in the caller's thread, while the
  # plugin's queue is idle. The table of loaded plugins is replaced, never
  # changed in place, so other threads can always read it.
  #
  # Each plugin is one file, <plugins_dir>/<name>.rb. Loading evaluates it
  # inside a fresh anonymous module, so a reload replaces the old code
  # completely; if the new version fails to load, the old one keeps running.
  # The folder and files must belong to the bot's user and not be writable
  # by others, since their code runs with the bot's privileges.
  class PluginManager
    NAME = /\A[a-z][a-z0-9_]{0,31}\z/
    SETTING_NAME = /\A[a-z][a-z0-9_]{0,63}\z/
    # Plugin options that only config.yml can set.
    CONFIG_ONLY = %w[enabled networks network_settings].freeze

    Entry = Struct.new(:name, :plugin, :digest, :config, keyword_init: true)
    Invocation = Data.define(:entry, :command, :args, :prefix)

    def initialize(host:, logger:, reserved: [])
      @host = host
      @log = logger
      @reserved = reserved # core command names plugins may not take
      @loaded = {}         # name => Entry
      @errors = {}         # name => why the file failed to load
      @state = host.plugin_state # unloaded plugins and saved settings, per network (see PluginState)
      @dir = nil
      @base_config = {}    # the plugins section of config.yml
      @config = {}         # with the settings saved by PLUGIN SET on top
      @cooldowns = {}      # seconds => RateLimiter
      @cooldown_lock = Mutex.new
      @full_warned = {}    # plugin name => when a full queue was last logged
      @dropped = Hash.new(0) # plugin name => jobs dropped since it was last told
      @drop_lock = Mutex.new
      @installing = {}     # name => gems being installed before it loads
    end

    # Syntax-checks the plugin files without running them, for --check.
    # Returns name => nil (fine) or an error message.
    def self.check(dir, config)
      plugin_files(dir).to_h do |name, path|
        next [name, "disabled in config.yml"] if config.dig(name, "enabled") == false

        RubyVM::InstructionSequence.compile(read_file(path), path)
        [name, nil]
      rescue SyntaxError, ConfigError => e
        [name, e.message.lines.first.strip]
      end
    end

    # name => path of every plugin file, checking the folder is safe.
    def self.plugin_files(dir)
      return {} unless dir && File.directory?(dir)

      stat = File.stat(dir)
      raise ConfigError, "#{dir} is not owned by this user" unless stat.owned?
      raise ConfigError, "#{dir} is writable by other users; run: chmod go-w #{dir}" if stat.mode.anybits?(0o022)

      Dir.children(dir).select { |f| f.end_with?(".rb") }.sort.to_h do |file|
        [File.basename(file, ".rb"), File.join(dir, file)]
      end
    end

    # The plugin class a file defines, without loading the plugin (for
    # checks like the command-line tool's). Raises Error, ScriptError ...
    def self.plugin_class(path)
      namespace = Module.new
      namespace.module_eval(read_file(path), path, 1)
      classes = namespace.constants.map { |c| namespace.const_get(c) }.select { |c| c.is_a?(Class) && c < Plugin }
      raise Error, "#{File.basename(path)} defines no Gemdrop::Plugin subclass at its top level" if classes.empty?
      raise Error, "#{File.basename(path)} defines more than one plugin class" if classes.size > 1

      classes.first
    end

    def self.read_file(path)
      stat = File.lstat(path)
      raise ConfigError, "#{path} must be a regular file, not a symlink" unless stat.file?
      raise ConfigError, "#{path} is not owned by this user" unless stat.owned?
      raise ConfigError, "#{path} is writable by other users; run: chmod go-w #{path}" if stat.mode.anybits?(0o022)

      File.open(path, File::RDONLY | File::NOFOLLOW, &:read)
    end

    # Brings the loaded plugins in line with the folder and config: loads
    # new files, reloads changed files or settings, unloads removed or
    # disabled plugins. Problems are logged; the bot keeps going.
    def sync(dir, config)
      @dir = dir
      @base_config = config || {}
      refresh_config
      files = available
      @loaded.keys.each do |name|
        unload(name) unless wanted?(name, files)
      end
      @installing.select! { |name, _| wanted?(name, files) }
      @errors.select! { |name, _| files.key?(name) && enabled?(name) }
      files.each do |name, path|
        next unless wanted?(name, files)

        entry = @loaded[name]
        next if entry && entry.digest == file_digest(path) && entry.config == @config[name]

        begin
          load(name)
        rescue Error
          nil # logged by load
        end
      end
    end

    # Loads or reloads one plugin. Raises Error (with a message for the
    # user). Returns :installing when the plugin's gems are being installed
    # first; it loads by itself when they are in.
    def load(name)
      raise Error, "#{name.inspect} is not a valid plugin name." unless name.match?(NAME)

      path = available[name] or raise Error, "No plugin file #{name}.rb in #{@dir}."
      raise Error, "#{name} is disabled in config.yml." unless enabled?(name)

      @state.set_unloaded(name, false)
      load_file(name, path)
    end

    # hold: stay unloaded on this network, across reloads and restarts,
    # until loaded again.
    def unload(name, hold: false, quiet: false)
      entry = @loaded[name]
      @loaded = @loaded.except(name) if entry
      if entry.nil? && @installing.delete(name)
        @state.set_unloaded(name, true) if hold
        return @log.info("Plugin #{name} won't load after its gems are installed")
      end
      raise Error, "#{name} is not loaded." unless entry

      @state.set_unloaded(name, true) if hold
      entry.plugin.retire! # takes no new jobs
      unless @host.plugin_jobs.wait("plugin:#{name}", timeout: TEARDOWN_WAIT)
        @log.warn("Plugin #{name} is still busy after #{TEARDOWN_WAIT}s; unloading it anyway")
      end
      entry.plugin.safely("teardown") { entry.plugin.teardown }
      entry.plugin.stop!
      @host.plugin_unloaded(name) unless reloading?(name)
      @log.info("Plugin #{name} unloaded") unless quiet
    end

    # At shutdown: also forgets plugins waiting for gems.
    def unload_all
      @stopped = true
      @installing.clear
      @loaded.keys.each { |name| unload(name) }
    end

    # --- commands and events ------------------------------------------------------

    # A command sent by private message, or nil if no plugin has it.
    def private_command(name, args)
      @loaded.each_value do |entry|
        next unless entry_settings(entry)["private"]

        command = entry.plugin.class.commands[name] or next
        return Invocation.new(entry: entry, command: command, args: args, prefix: "")
      end
      nil
    end

    # The plugin that takes private messages that aren't commands (see
    # Plugin.private_text), as an invocation for these words, or nil.
    def private_text(words)
      entry = @loaded.values.find { |e| e.plugin.class.private_text_handler } or return nil

      Invocation.new(entry: entry, command: entry.plugin.class.private_text_handler, args: words, prefix: "")
    end

    # A prefixed command in a channel ("!roll 2"), or nil.
    def channel_command(channel, text)
      @loaded.each_value do |entry|
        options = entry_settings(entry)
        prefix = options["prefix"]
        next unless prefix && text.start_with?(prefix)
        next unless options["channels"].empty? || options["channels"].any? { |c| Casemap.eq?(c, channel) }

        name, *args = text.delete_prefix(prefix).split
        command = name && entry.plugin.class.commands[name.upcase] or next
        return Invocation.new(entry: entry, command: command, args: args, prefix: prefix)
      end
      nil
    end

    # Queues the command in the plugin's queue.
    def run(invocation, nick:, userhost:, channel: nil)
      post(invocation.entry) { run_now(invocation, nick: nick, userhost: userhost, channel: channel) }
    end

    def run_now(invocation, nick:, userhost:, channel:)
      plugin = invocation.entry.plugin
      command = invocation.command
      args = invocation.args
      target_channel = channel
      # A level command by private message names its channel first.
      if command.level && channel.nil? && args.first.to_s.match?(Channels::NAME)
        target_channel, *args = args
      end
      ctx = Plugin::Context.new(plugin: plugin, nick: nick, userhost: userhost, channel: channel,
                                command: command, prefix: invocation.prefix, args: args,
                                target_channel: target_channel)
      begin
        check_invocation!(ctx, command, channel, target_channel)
        plugin.instance_exec(ctx, args, &command.handler)
      rescue Error => e
        ctx.reply_privately(e.message)
      rescue StandardError => e
        @log.error("Plugin #{plugin.name}: command #{command.name} failed: #{e.class}: #{e.message} " \
                   "(#{e.backtrace&.first})")
        ctx.reply_privately("Sorry, #{invocation.prefix}#{command.name} failed.")
      end
    end

    # Queues the event for every plugin with hooks for it. Lines plugins
    # send from :outgoing hooks are not reported again (no loops).
    def emit(type, **fields)
      event = nil
      @loaded.each_value do |entry|
        hooks = entry.plugin.class.hooks[type] or next
        next unless entry.plugin.wants_event?(type)

        event ||= Plugin::Event.new(type: type, network: @host.network, **{ at: Time.now.utc }.merge(fields))
        post(entry) do
          flag = GUARDED_EVENTS[type]
          Thread.current[flag] = true if flag
          hooks.each { |hook| entry.plugin.safely("#{type} hook") { entry.plugin.instance_exec(event, &hook) } }
        ensure
          Thread.current[flag] = nil if flag
        end
      end
    end

    # Asks the plugin that answers this CTCP command, in its queue; then
    # yields its answer (text, or nil for none). False if no plugin answers it.
    def answer_ctcp(command, **fields, &on_answer)
      entry = @loaded.values.find { |e| e.plugin.class.ctcp_handlers.key?(command) } or return false

      event = Plugin::Event.new(type: :ctcp, network: @host.network, ctcp: command, **fields)
      post(entry) do
        handler = entry.plugin.class.ctcp_handlers[command]
        answer = entry.plugin.safely("CTCP #{command} handler") { entry.plugin.instance_exec(event, &handler) }
        on_answer.call(answer&.to_s)
      end
    end

    # CTCP commands plugins answer, for CLIENTINFO.
    def ctcp_commands = @loaded.values.flat_map { |entry| entry.plugin.class.ctcp_handlers.keys }.uniq

    # IRCv3 capabilities the loaded plugins want (see Plugin.wants_cap).
    def wanted_caps = @loaded.values.flat_map { |entry| entry.plugin.class.wanted_caps }.uniq

    # Hands a published message to the plugins listening for its topic,
    # except the sender itself. Returns how many listeners got it.
    def deliver(topic, payload, from:, network:)
      info = { plugin: from, network: network }.freeze
      @loaded.values.sum do |entry|
        next 0 if entry.name == from && network == @host.network

        handlers = entry.plugin.class.listeners[topic] or next 0
        post(entry) do
          handlers.each do |handler|
            entry.plugin.safely("listener for #{topic}") { entry.plugin.instance_exec(payload, info, &handler) }
          end
        end
        handlers.size
      end
    end

    # A loaded plugin instance, or nil.
    def plugin(name) = @loaded[name]&.plugin

    # --- settings saved per network (PLUGIN SET) ---------------------------------

    # Saves a setting on this network and reloads the plugin with it.
    # Values the bot or the plugin rejects are not saved. Returns :saved
    # (plugin not loaded), :reloaded or :installing.
    def set_setting(name, key, value)
      check_settable!(name, key)
      check_unlocked!(name, key)
      previous = @state.settings(name)
      begin
        Config.plugins(name => self.class.merge_saved(@base_config[name] || {}, previous.merge(key => value)))
      rescue ConfigError => e
        raise Error, e.message.sub(/\Aplugins: /, "")
      end
      plugin = @loaded[name]&.plugin
      if (spec = plugin&.class&.settings_spec&.[](key)) && (problem = plugin.__send__(:setting_problem, spec, value))
        raise Error, "#{key} #{problem}."
      end

      @state.set(name, key, value)
      apply_setting_change(name) { previous.key?(key) ? @state.set(name, key, previous[key]) : @state.unset(name, key) }
    end

    # Saves one setting for one channel on this network: in
    # channel_settings under the network's name (see Plugin#settings_for),
    # keeping the channel's other settings.
    def set_channel_setting(name, channel, key, value)
      check_settable!(name, key)
      raise Error, "#{channel} is not a channel name." unless channel.match?(Channels::NAME)

      saved = deep_copy(@state.settings(name)["channel_settings"] || {})
      net = network_entry(name, saved)
      table = (saved[net] ||= {})
      entry = channel_entry(name, net, table, channel)
      table[entry] = (table[entry] || {}).merge(key => value)
      set_setting(name, "channel_settings", saved)
    end

    # Forgets a setting saved for one channel on this network.
    def unset_channel_setting(name, channel, key)
      check_settable!(name, key)
      saved = deep_copy(@state.settings(name)["channel_settings"] || {})
      net = network_entry(name, saved)
      table = saved[net] || {}
      entry = table.keys.find { |c| Casemap.eq?(c, channel) }
      raise Error, "#{name} has no saved #{key} for #{channel} on #{@state.network}." unless entry && table[entry].key?(key)

      table[entry].delete(key)
      table.delete(entry) if table[entry].empty?
      saved.delete(net) if table.empty?
      return set_setting(name, "channel_settings", saved) if saved.any?

      unset_setting(name, "channel_settings")
    end

    # Saved settings on top of config.yml's. channel_settings merge all
    # the way down, so saving one channel's setting keeps config.yml's
    # other settings for it, and for other channels and networks.
    def self.merge_saved(base, saved)
      merged = base.merge(saved)
      from_file = base["channel_settings"]
      from_state = saved["channel_settings"]
      merged["channel_settings"] = deep_merge(from_file, from_state) if from_file.is_a?(Hash) && from_state.is_a?(Hash)
      merged
    end

    def self.deep_merge(a, b)
      a.merge(b) { |_key, x, y| x.is_a?(Hash) && y.is_a?(Hash) ? deep_merge(x, y) : y }
    end

    # Forgets a saved setting, so config.yml's value (or the default) applies again.
    def unset_setting(name, key)
      check_settable!(name, key)
      check_unlocked!(name, key)
      previous = @state.settings(name)
      raise Error, "#{name} has no saved #{key} on #{@state.network}." unless previous.key?(key)

      @state.unset(name, key)
      apply_setting_change(name) { @state.set(name, key, previous[key]) }
    end

    # [[key, value, saved?], ...]: the bot's options for the plugin and the
    # plugin's own settings on this network (with its defaults when loaded).
    def settings_report(name)
      raise Error, "No plugin file #{name}.rb in #{@dir}." unless available.key?(name) || @loaded.key?(name)

      saved = @state.settings(name)
      own = @loaded[name] ? @loaded[name].plugin.settings : settings_for(name)
      options = Config::PLUGIN_DEFAULTS.merge(@config[name] || {}).slice("private", "prefix", "channels")
      options.merge(own).sort.map { |key, value| [key, value, saved.key?(key)] }
    end

    # --- listing ------------------------------------------------------------------------

    # Everything the bot can do, for help plugins: core_commands (the
    # bot's own, see Bot::CORE_HELP) and every loaded plugin's commands and
    # topics, as they work on this network (prefix, private).
    def help_catalog(core_commands)
      plugins = @loaded.values.map do |entry|
        klass = entry.plugin.class
        options = entry_settings(entry)
        commands = klass.commands.values.uniq.filter_map do |command|
          in_private = options["private"] && command.where != :channel
          in_channel = options["prefix"] && command.where != :private
          next unless in_private || in_channel

          HelpCatalog::Command.new(
            name: command.name, source: entry.name, group: klass.help_group || entry.name, usage: command.usage,
            help: command.help,
            details: command.details, aliases: command.aliases, access: access_of(command),
            private: in_private ? true : false, prefix: (options["prefix"] if in_channel)
          )
        end
        topics = klass.help_topics.map do |name, topic|
          text = topic[:text]
          if topic[:block]
            plugin = entry.plugin
            text = -> { plugin.safely("help topic #{name}") { plugin.instance_exec(&topic[:block]) }.to_s }
          end
          HelpCatalog::Topic.new(name: name, source: entry.name, summary: topic[:summary], text: text)
        end
        HelpCatalog::PluginInfo.new(name: entry.name, description: klass.description, commands: commands, topics: topics)
      end
      HelpCatalog::Catalog.new(commands: core_commands + plugins.flat_map(&:commands),
                               topics: plugins.flat_map(&:topics), plugins: plugins)
    end

    # name => { state, description, commands, prefix, private, error } for
    # every plugin file and failed load, as shown by PLUGIN LIST and status.
    def status
      names = (available.keys | @loaded.keys | @errors.keys).sort
      names.to_h do |name|
        entry = @loaded[name]
        info = if entry
                 options = entry_settings(entry)
                 { "state" => "loaded", "description" => entry.plugin.class.description,
                   "commands" => entry.plugin.class.commands.values.uniq.map(&:name),
                   "private" => options["private"], "prefix" => options["prefix"],
                   "error" => @errors[name] }.compact
               elsif @installing.key?(name)
                 { "state" => "installing", "gems" => @installing[name].map(&:to_s) }
               elsif @errors.key?(name) then { "state" => "error", "error" => @errors[name] }
               elsif !enabled?(name) then { "state" => "disabled" }
               elsif @state.unloaded?(name) then { "state" => "unloaded", "kept_unloaded" => true }
               else { "state" => "unloaded" }
               end
        [name, info]
      end
    end

    private

    def available
      self.class.plugin_files(@dir).select do |name, path|
        next true if name.match?(NAME)

        @log.warn("Ignoring plugin file #{path}: names are lowercase letters, digits and _")
        false
      end
    rescue ConfigError => e
      @log.error("Not loading plugins: #{e.message}")
      {}
    end

    def enabled?(name) = @config.dig(name, "enabled") != false

    def access_of(command)
      if command.access then command.access
      elsif command.admin then "admin"
      elsif command.level then command.level
      elsif command.identified then "identified"
      else "anyone"
      end
    end

    TEARDOWN_WAIT = 5 # seconds unload waits for a plugin's running job

    # Events whose hooks mustn't cause more of the same: lines sent from
    # :outgoing hooks and records logged from :log hooks aren't reported.
    GUARDED_EVENTS = { outgoing: :gemdrop_outgoing_hook, log: :gemdrop_log_hook }.freeze

    # Queues plugin code in the plugin's own queue; a full queue (a plugin
    # far behind) drops the job, logged at most once a minute. Once the
    # queue has room again, the plugin's events_dropped(count) runs first,
    # in order, so it knows exactly where it missed something.
    def post(entry, &job)
      lost = @drop_lock.synchronize { @dropped.delete(entry.name) }
      if lost
        told = @host.run_plugin_job(entry.plugin) do
          entry.plugin.safely("events_dropped") { entry.plugin.events_dropped(lost) }
        end
        @drop_lock.synchronize { @dropped[entry.name] += lost } unless told
      end
      return true if (lost.nil? || told) && @host.run_plugin_job(entry.plugin, &job)

      @drop_lock.synchronize { @dropped[entry.name] += 1 }
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if now - @full_warned.fetch(entry.name, -60) >= 60
        @full_warned[entry.name] = now
        @log.warn("Plugin #{entry.name} is falling behind; dropping events and commands for it")
      end
      false
    end

    def wanted?(name, files) = files.key?(name) && enabled?(name) && !@state.unloaded?(name)

    # config.yml's plugin sections with the saved settings on top.
    def refresh_config
      saved = @state.all_settings
      merged = @base_config.merge(saved.to_h { |name, settings| [name, self.class.merge_saved(@base_config[name] || {}, settings)] })
      @config = begin
        Config.plugins(merged)
      rescue ConfigError => e
        @log.error("Ignoring plugin settings saved with PLUGIN SET: #{e.message}")
        @base_config
      end
    end

    # Reloads a plugin after its saved settings changed. If it fails to
    # load with them, the block undoes the change, the plugin is loaded
    # again with its previous settings, and Error is raised.
    def apply_setting_change(name)
      refresh_config
      return :saved unless @loaded.key?(name)

      load(name) == :installing ? :installing : :reloaded
    rescue Error => e
      yield
      refresh_config
      restore(name)
      raise Error, "Not saved: #{e.message}"
    end

    # Loads a plugin with its current settings after a failed change (its
    # setup may have failed after the old instance was unloaded).
    def restore(name)
      @errors.delete(name)
      load(name) unless @loaded.key?(name)
    rescue Error
      nil # logged by load
    end

    def check_settable!(name, key)
      raise Error, "#{name.inspect} is not a valid plugin name." unless name.to_s.match?(NAME)
      raise Error, "No plugin file #{name}.rb in #{@dir}." unless available.key?(name) || @loaded.key?(name)
      raise Error, "#{key.inspect} is not a valid setting name." unless key.to_s.match?(SETTING_NAME)
      raise Error, "#{key} can only be changed in config.yml." if CONFIG_ONLY.include?(key)
    end

    # Locked settings (see Plugin.setting) are only set in config.yml. A
    # plugin that isn't loaded can't say; what is saved for it meanwhile is
    # dropped when it loads (settings_for).
    # This network's and the channel's keys as config.yml spells them, so
    # saved and configured entries merge.
    def network_entry(name, saved)
      known = saved.keys + base_channel_settings(name).keys
      known.find { |key| !key.to_s.match?(Channels::NAME) && key.to_s.casecmp?(@state.network) } || @state.network
    end

    def channel_entry(name, net, table, channel)
      configured = base_channel_settings(name)[net]
      known = table.keys + (configured.is_a?(Hash) ? configured.keys : [])
      known.find { |c| Casemap.eq?(c, channel) } || channel
    end

    def base_channel_settings(name)
      table = (@base_config[name] || {})["channel_settings"]
      table.is_a?(Hash) ? table : {}
    end

    def deep_copy(value) = Marshal.load(Marshal.dump(value))

    def check_unlocked!(name, key)
      return unless @loaded[name]&.plugin&.class&.settings_spec&.dig(key)&.locked

      raise Error, "#{key} can only be changed in config.yml."
    end

    def reloading?(name) = @reloading == name

    # Raises Error (sent to the user) unless the invocation is allowed.
    def check_invocation!(ctx, command, channel, target_channel)
      raise Error, "#{command.name} only works in channels." if command.where == :channel && channel.nil?
      raise Error, "#{command.name} only works by private message." if command.where == :private && channel
      raise Error, "You must IDENTIFY first." if command.identified && !ctx.account
      raise Error, "Only bot admins can use that." if command.admin && !ctx.admin?
      if command.level
        ctx.usage! unless target_channel
        if Channels.rank(ctx.access_level(target_channel)) < Channels.rank(command.level)
          raise Error, "You need #{command.level} access on #{target_channel} for that."
        end
      end
      check_cooldown!(command, ctx) if command.cooldown
    end

    def check_cooldown!(command, ctx)
      key = "#{command.name}:#{ctx.userhost.to_s.split('@', 2).last.to_s.downcase}"
      wait = @cooldown_lock.synchronize do
        limiter = (@cooldowns[command.cooldown] ||= RateLimiter.new(window: command.cooldown))
        limiter.blocked_for(key, limit: 1).tap { |blocked| limiter.hit(key) unless blocked }
      end
      return unless wait

      raise Error, "Please wait #{wait} second#{'s' unless wait == 1} before using #{command.name} again."
    end

    # The plugin's logger: the bot's, with lines marked network/plugin.
    def plugin_logger(name)
      logger = @log.dup
      logger.progname = [@log.progname, name].compact.join("/")
      logger
    end

    def entry_settings(entry) = Config::PLUGIN_DEFAULTS.merge(entry.config || {})

    # The plugin's own settings: its config section minus the bot's options.
    # With the class: locked settings come from config.yml only.
    def settings_for(name, klass = nil)
      settings = (@config[name] || {}).except(*Config::PLUGIN_DEFAULTS.keys)
      locked = klass ? klass.settings_spec.values.select(&:locked).map(&:name) & @state.settings(name).keys : []
      return settings if locked.empty?

      @log.warn("Ignoring #{name} #{locked.join(', ')} saved with PLUGIN SET: only config.yml sets that")
      base = @base_config[name] || {}
      locked.each { |key| base.key?(key) ? settings[key] = base[key] : settings.delete(key) }
      settings
    end

    def file_digest(path)
      Digest::SHA256.hexdigest(self.class.read_file(path))
    rescue ConfigError, SystemCallError
      nil
    end

    def load_file(name, path)
      source = self.class.read_file(path)
      gems = PluginGems.requirements(source)
      missing = gems.empty? ? [] : @host.gems.missing(gems)
      return wait_for_gems(name, missing) if missing.any?

      klass = evaluate(path, source)
      check_commands!(name, klass)
      plugin = klass.new(name: name, settings: settings_for(name, klass), host: @host, logger: plugin_logger(name))
      previous = @loaded[name]
      reloading = !previous.nil?
      if reloading
        @reloading = name # keeps the channels it joined
        begin
          unload(name, quiet: true)
        ensure
          @reloading = nil
        end
      end
      begin
        plugin.setup
      rescue StandardError
        plugin.stop!
        restore_previous(name, previous) if previous
        raise
      end
      @loaded = @loaded.merge(name => Entry.new(name: name, plugin: plugin, digest: Digest::SHA256.hexdigest(source),
                                                config: @config[name]))
      @errors.delete(name)
      @log.info("Plugin #{name} #{reloading ? 'reloaded' : 'loaded'}#{commands_note(klass)}")
    rescue ScriptError, StandardError => e
      @errors[name] = (e.is_a?(Error) ? e.message : "#{e.class}: #{e.message}").lines.first.strip
      saved = @state.settings(name).keys
      if saved.any?
        @errors[name] += " (it has settings saved with PLUGIN SET: #{saved.join(', ')}; " \
                         "PLUGIN UNSET #{name} <setting> puts one back to config.yml's value)"
      end
      @log.error("Plugin #{name} failed to load#{' (the previous version keeps running)' if @loaded.key?(name)}: " \
                 "#{@errors[name]} (#{e.backtrace&.first})")
      raise Error, "#{name} failed to load: #{@errors[name]}"
    end

    # Installs a plugin's missing gems in the background; the plugin (or
    # its new version) loads when they are in. A loaded old version keeps
    # running meanwhile.
    def wait_for_gems(name, missing)
      return :installing if @installing.key?(name)

      @installing[name] = missing
      @errors.delete(name)
      @log.info("Plugin #{name} needs #{missing.join(', ')}; installing, it loads when done")
      @host.gems.install(missing) { |error| @host.synchronize { gems_ready(name, error) } }
      :installing
    end

    def gems_ready(name, error)
      return if @stopped || !@installing.delete(name)

      if error
        @errors[name] = "couldn't install its gems: #{error}"
        @log.error("Plugin #{name} not loaded: #{@errors[name]}")
      else
        begin
          load(name)
        rescue Error
          nil # logged by load
        end
      end
      @host.status_changed
    end

    # The new version's setup failed after the old one was unloaded: starts
    # the old version again, with the settings it had.
    def restore_previous(name, previous)
      old = previous.plugin
      plugin = old.class.new(name: name, settings: (previous.config || {}).except(*Config::PLUGIN_DEFAULTS.keys),
                             host: @host, logger: plugin_logger(name))
      plugin.setup
      @loaded = @loaded.merge(name => previous.dup.tap { |entry| entry.plugin = plugin })
    rescue StandardError => e
      plugin&.stop!
      @log.error("Plugin #{name}: the previous version couldn't be restarted either: #{e.class}: #{e.message}")
    end

    def evaluate(path, source)
      namespace = Module.new
      namespace.module_eval(source, path, 1)
      classes = namespace.constants.map { |c| namespace.const_get(c) }.select { |c| c.is_a?(Class) && c < Plugin }
      raise Error, "#{File.basename(path)} defines no Gemdrop::Plugin subclass at its top level" if classes.empty?
      raise Error, "#{File.basename(path)} defines more than one plugin class" if classes.size > 1

      classes.first
    end

    def check_commands!(name, klass)
      if klass.private_text_handler
        other = @loaded.values.find { |e| e.name != name && e.plugin.class.private_text_handler }
        raise Error, "private chat is already handled by plugin #{other.name}" if other
      end
      klass.ctcp_handlers.each_key do |ctcp|
        other = @loaded.values.find { |e| e.name != name && e.plugin.class.ctcp_handlers.key?(ctcp) }
        raise Error, "CTCP #{ctcp} is already answered by plugin #{other.name}" if other
      end
      klass.commands.each_key do |command|
        raise Error, "command #{command} is a built-in command" if @reserved.include?(command)

        other = @loaded.values.find { |e| e.name != name && e.plugin.class.commands.key?(command) }
        raise Error, "command #{command} is already provided by plugin #{other.name}" if other
      end
    end

    def commands_note(klass)
      klass.commands.empty? ? "" : " (commands: #{klass.commands.values.uniq.map(&:name).join(', ')})"
    end
  end
end

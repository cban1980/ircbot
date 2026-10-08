require "digest"

module IRCBot
  # Finds, loads, reloads and unloads plugins (see Plugin), and routes
  # commands and events to them.
  #
  # Each plugin is one file, <plugins_dir>/<name>.rb. Loading evaluates it
  # inside a fresh anonymous module, so a reload replaces the old code
  # completely; if the new version fails to load, the old one keeps running.
  # The folder and files must belong to the bot's user and not be writable
  # by others, since their code runs with the bot's privileges.
  class PluginManager
    NAME = /\A[a-z][a-z0-9_]{0,31}\z/

    Entry = Struct.new(:name, :plugin, :digest, :config, keyword_init: true)
    Invocation = Data.define(:entry, :command, :args, :prefix)

    def initialize(host:, logger:, reserved: [])
      @host = host
      @log = logger
      @reserved = reserved # core command names plugins may not take
      @loaded = {}         # name => Entry
      @errors = {}         # name => why the file failed to load
      @held = []           # unloaded with PLUGIN UNLOAD; skipped by sync until loaded again
      @dir = nil
      @config = {}
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
      @config = config || {}
      files = available
      @loaded.keys.each do |name|
        unload(name) unless files.key?(name) && enabled?(name)
      end
      @errors.select! { |name, _| files.key?(name) && enabled?(name) }
      files.each do |name, path|
        next if !enabled?(name) || @held.include?(name)

        entry = @loaded[name]
        next if entry && entry.digest == file_digest(path) && entry.config == @config[name]

        begin
          load(name)
        rescue Error
          nil # logged by load
        end
      end
    end

    # Loads or reloads one plugin. Raises Error (with a message for the user).
    def load(name)
      raise Error, "#{name.inspect} is not a valid plugin name." unless name.match?(NAME)

      path = available[name] or raise Error, "No plugin file #{name}.rb in #{@dir}."
      raise Error, "#{name} is disabled in config.yml." unless enabled?(name)

      load_file(name, path)
    end

    # hold: stay unloaded on config reloads until loaded again.
    def unload(name, hold: false, quiet: false)
      entry = @loaded.delete(name)
      raise Error, "#{name} is not loaded." unless entry

      @held |= [name] if hold
      entry.plugin.safely("teardown") { entry.plugin.teardown }
      entry.plugin.stop!
      @log.info("Plugin #{name} unloaded") unless quiet
    end

    def unload_all = @loaded.keys.each { |name| unload(name) }

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

    def run(invocation, nick:, userhost:, channel: nil)
      plugin = invocation.entry.plugin
      command = invocation.command
      ctx = Plugin::Context.new(plugin: plugin, nick: nick, userhost: userhost, channel: channel,
                                command: command, prefix: invocation.prefix)
      begin
        raise Error, "You must IDENTIFY first." if command.identified && !ctx.account
        raise Error, "Only bot admins can use that." if command.admin && !ctx.admin?

        plugin.instance_exec(ctx, invocation.args, &command.handler)
      rescue Error => e
        ctx.reply_privately(e.message)
      rescue StandardError => e
        @log.error("Plugin #{plugin.name}: command #{command.name} failed: #{e.class}: #{e.message} " \
                   "(#{e.backtrace&.first})")
        ctx.reply_privately("Sorry, #{invocation.prefix}#{command.name} failed.")
      end
    end

    def emit(type, **fields)
      event = nil
      @loaded.each_value do |entry|
        hooks = entry.plugin.class.hooks[type] or next

        event ||= Plugin::Event.new(type: type, **fields)
        hooks.each { |hook| entry.plugin.safely("#{type} hook") { entry.plugin.instance_exec(event, &hook) } }
      end
    end

    # --- listing ------------------------------------------------------------------------

    # HELP lines for plugin commands; admin-only ones only for admins.
    def help_lines(admin:)
      lines = @loaded.values.flat_map do |entry|
        options = entry_settings(entry)
        entry.plugin.class.commands.values.filter_map do |command|
          next if command.admin && !admin

          where = options["private"] ? command.usage : "#{options['prefix']}#{command.usage}"
          notes = [command.help]
          notes << "(also #{options['prefix']}#{command.name.downcase} in channels)" if options["private"] && options["prefix"]
          notes << "(bot admins only)" if command.admin
          "  #{where.ljust(33)} #{notes.reject(&:empty?).join(' ')}"
        end
      end
      lines.empty? ? [] : ["Plugin commands:", *lines]
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
                   "commands" => entry.plugin.class.commands.keys,
                   "private" => options["private"], "prefix" => options["prefix"],
                   "error" => @errors[name] }.compact
               elsif @errors.key?(name) then { "state" => "error", "error" => @errors[name] }
               elsif !enabled?(name) then { "state" => "disabled" }
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

    def entry_settings(entry) = Config::PLUGIN_DEFAULTS.merge(entry.config || {})

    # The plugin's own settings: its config section minus the bot's options.
    def settings_for(name) = (@config[name] || {}).except(*Config::PLUGIN_DEFAULTS.keys)

    def file_digest(path)
      Digest::SHA256.hexdigest(self.class.read_file(path))
    rescue ConfigError, SystemCallError
      nil
    end

    def load_file(name, path)
      source = self.class.read_file(path)
      klass = evaluate(path, source)
      check_commands!(name, klass)
      plugin = klass.new(name: name, settings: settings_for(name), host: @host, logger: @log)
      reloading = @loaded.key?(name)
      unload(name, quiet: true) if reloading
      @held.delete(name)
      begin
        plugin.setup
      rescue StandardError
        plugin.stop!
        raise
      end
      @loaded[name] = Entry.new(name: name, plugin: plugin, digest: Digest::SHA256.hexdigest(source), config: @config[name])
      @errors.delete(name)
      @log.info("Plugin #{name} #{reloading ? 'reloaded' : 'loaded'}#{commands_note(klass)}")
    rescue ScriptError, StandardError => e
      @errors[name] = (e.is_a?(Error) ? e.message : "#{e.class}: #{e.message}").lines.first.strip
      @log.error("Plugin #{name} failed to load#{' (the previous version keeps running)' if @loaded.key?(name)}: " \
                 "#{@errors[name]} (#{e.backtrace&.first})")
      raise Error, "#{name} failed to load: #{@errors[name]}"
    end

    def evaluate(path, source)
      namespace = Module.new
      namespace.module_eval(source, path, 1)
      classes = namespace.constants.map { |c| namespace.const_get(c) }.select { |c| c.is_a?(Class) && c < Plugin }
      raise Error, "#{File.basename(path)} defines no IRCBot::Plugin subclass at its top level" if classes.empty?
      raise Error, "#{File.basename(path)} defines more than one plugin class" if classes.size > 1

      classes.first
    end

    def check_commands!(name, klass)
      klass.commands.each_key do |command|
        raise Error, "command #{command} is a built-in command" if @reserved.include?(command)

        other = @loaded.values.find { |e| e.name != name && e.plugin.class.commands.key?(command) }
        raise Error, "command #{command} is already provided by plugin #{other.name}" if other
      end
    end

    def commands_note(klass)
      klass.commands.empty? ? "" : " (commands: #{klass.commands.keys.join(', ')})"
    end
  end
end

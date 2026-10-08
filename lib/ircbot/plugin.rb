module IRCBot
  # Base class for plugins: Ruby files in the plugins folder (one plugin
  # class per file, at the top level) that add commands and react to IRC
  # events. They are loaded, reloaded and unloaded while the bot stays
  # connected. Examples are in contrib/plugins/.
  #
  #   class Dice < IRCBot::Plugin
  #     description "Rolls dice"
  #     defaults "sides" => 6
  #
  #     command "ROLL", usage: "ROLL [count]", help: "roll some dice" do |ctx, args|
  #       count = (args.first || 1).to_i.clamp(1, 10)
  #       ctx.reply(Array.new(count) { rand(1..settings["sides"]) }.join(" "))
  #     end
  #
  #     on :join do |event|
  #       notice(event.nick, "Try !roll") unless event.nick == bot_nick
  #     end
  #   end
  #
  # Command and hook blocks run with the plugin as self, one at a time with
  # all other IRC handling, so slow work (HTTP and the like) belongs in
  # #background. Plugins run inside the bot with its full privileges: only
  # install code you trust.
  class Plugin
    Command = Data.define(:name, :usage, :help, :admin, :identified, :handler)

    # connected: registered with the server     message: channel message
    # join, part, kick, quit, nick: membership  line: every line received
    EVENTS = %i[connected message join part kick quit nick line].freeze

    Event = Data.define(:type, :nick, :userhost, :channel, :text, :new_nick, :message) do
      def initialize(type:, nick: nil, userhost: nil, channel: nil, text: nil, new_nick: nil, message: nil) = super
    end

    COMMAND_NAME = /\A[A-Z][A-Z0-9_-]{0,31}\z/
    MAX_LINE_BYTES = 400 # leaves room for the prefix the server adds
    MAX_LINES = 10       # per say/notice call
    MIN_INTERVAL = 1     # seconds, for #every
    MAX_TIMERS = 20

    # --- class-level declarations ------------------------------------------

    class << self
      def description(text = nil)
        text ? @description = text.to_s : @description.to_s
      end

      # Default settings; config.yml's plugins.<name> section overrides them.
      def defaults(hash = nil)
        hash ? @defaults = hash.transform_keys(&:to_s) : (@defaults || {})
      end

      # admin: only bot admins; identified: only users logged in to the bot.
      def command(name, usage: nil, help: nil, admin: false, identified: false, &handler)
        name = name.to_s.upcase
        raise ArgumentError, "invalid command name #{name.inspect}" unless name.match?(COMMAND_NAME)
        raise ArgumentError, "command #{name} needs a block" unless handler

        commands[name] = Command.new(name: name, usage: usage || name, help: help.to_s, admin: admin,
                                     identified: identified || admin, handler: handler)
      end

      def commands = (@commands ||= {})

      def on(event, &handler)
        raise ArgumentError, "unknown event #{event.inspect} (one of: #{EVENTS.join(', ')})" unless EVENTS.include?(event)
        raise ArgumentError, "on #{event.inspect} needs a block" unless handler

        (hooks[event] ||= []) << handler
      end

      def hooks = (@hooks ||= {})
    end

    attr_reader :name, :settings

    def initialize(name:, settings:, host:, logger:)
      @name = name
      @settings = self.class.defaults.merge(settings)
      @host = host
      @log = logger
      @timers = []
      @active = true
    end

    # Called after loading and before unloading; override as needed.
    def setup; end
    def teardown; end

    # --- talking to IRC ------------------------------------------------------

    # Text is split on line breaks; long lines are cut. Returns false if
    # nothing was sent: while disconnected, or once the plugin has been
    # unloaded (e.g. from a leftover background job).
    def say(target, text) = send_text("PRIVMSG", target, text)
    def notice(target, text) = send_text("NOTICE", target, text)
    def action(target, text) = send_text("PRIVMSG", target, "\x01ACTION #{text}\x01")

    def bot_nick = @host.nick

    # Channels the bot is currently in.
    def channels = @host.channels

    # --- accounts and access -----------------------------------------------------

    # The bot account a nick is identified as, or nil. With userhost, the
    # session must also belong to that user@host (Context#account does this).
    def account_for(nick, userhost = nil) = @host.account_for(nick, userhost)
    def admin?(account) = @host.admin?(account)

    # "voice", "op", "owner" or nil; bot admins are owner everywhere.
    def access_level(channel, account) = account && @host.level_for(channel, account)

    # --- state, background work, timers ---------------------------------------------

    # Persistent JSON storage in data/plugins/<name>.json (see Storage).
    def data = @data ||= Storage.new(File.join(@host.data_dir, "#{@name}.json"))

    # Runs a slow job on a worker thread, outside the IRC handling. Returns
    # false if the queue is full and the job was dropped.
    def background(&job)
      @host.submit { safely("background job") { instance_exec(&job) } if active? }
    end

    # Runs the block every `seconds` (or once, after `seconds`) like a hook.
    # Timers stop when the plugin is unloaded.
    def every(seconds, &block) = start_timer(seconds, repeat: true, &block)
    def after(seconds, &block) = start_timer(seconds, repeat: false, &block)

    def log = @log

    # Ends a command with "Usage: ..." sent back to the user.
    def usage!(text) = raise(Error, "Usage: #{text}")

    def active? = @active

    # --- used by PluginManager ---------------------------------------------------------

    # Runs plugin code; errors are logged, never passed on to the bot.
    def safely(what)
      yield
    rescue StandardError => e
      @log.error("Plugin #{@name}: #{what} failed: #{e.class}: #{e.message} (#{e.backtrace&.first})")
      nil
    end

    def stop!
      @active = false
      @timers.each(&:kill)
      @timers.clear
    end

    private

    def send_text(command, target, text)
      return false unless active?
      raise ArgumentError, "invalid target #{target.inspect}" unless target.to_s.match?(/\A[^\s,\0]+\z/)

      text.to_s.split(/[\r\n]+/).reject(&:empty?).first(MAX_LINES).all? do |line|
        line = line.delete("\0")
        line = line.byteslice(0, MAX_LINE_BYTES).scrub("") if line.bytesize > MAX_LINE_BYTES
        @host.write("#{command} #{target} :#{line}")
      end
    end

    def start_timer(seconds, repeat:, &block)
      raise ArgumentError, "timer interval must be at least #{MIN_INTERVAL}s" if repeat && seconds < MIN_INTERVAL

      @timers.select!(&:alive?)
      raise ArgumentError, "too many timers (max #{MAX_TIMERS})" if @timers.size >= MAX_TIMERS

      thread = Thread.new do
        Thread.current.name = "plugin-#{@name}-timer"
        loop do
          sleep seconds
          @host.synchronize { safely("timer") { instance_exec(&block) } if active? }
          break unless repeat && active?
        end
      end
      @timers << thread
      thread
    end

    # A command invocation, passed to command blocks.
    class Context
      attr_reader :nick, :userhost, :channel, :command

      def initialize(plugin:, nick:, userhost:, channel:, command:, prefix:)
        @plugin = plugin
        @nick = nick
        @userhost = userhost
        @channel = channel
        @command = command
        @prefix = prefix
      end

      # nil for commands sent by private message.
      def channel? = !@channel.nil?

      # In a channel: a message to the channel; in private: a notice.
      def reply(text) = channel? ? @plugin.say(@channel, text) : @plugin.notice(@nick, text)
      def reply_privately(text) = @plugin.notice(@nick, text)

      def account = @plugin.account_for(@nick, @userhost)
      def admin? = @plugin.admin?(account)
      def access_level(channel = @channel) = channel && @plugin.access_level(channel, account)

      # Raises with the command's usage, written the way it was invoked.
      def usage! = @plugin.usage!("#{@prefix}#{@command.usage}")
    end

    # A plugin's JSON file, safe to use from hooks, timers and background
    # jobs. Reads return copies; change data with []=, delete or update.
    class Storage
      def initialize(path)
        @store = Store.new(path, sections: [])
      end

      def [](key) = @store.read { |data| copy(data[key.to_s]) }
      def to_h = @store.read { |data| copy(data) }

      def []=(key, value)
        @store.transaction { |data| data[key.to_s] = copy(value) }
      end

      def delete(key) = @store.transaction { |data| data.delete(key.to_s) }

      # Yields the whole hash for several changes in one atomic write.
      def update(&) = @store.transaction(&)

      private

      def copy(value) = value.nil? ? nil : JSON.parse(JSON.generate(value))
    end
  end
end

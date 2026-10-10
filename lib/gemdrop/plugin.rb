require "json"
require "monitor"
require "fileutils"

module Gemdrop
  # Base class for plugins: Ruby files in the plugins folder (one plugin
  # class per file, at the top level) that add commands, react to IRC
  # events and act on channels. They are loaded, reloaded and unloaded
  # while the bot stays connected. The full API is documented in
  # docs/plugins.md; examples are in contrib/plugins/.
  #
  #   class Dice < Gemdrop::Plugin
  #     description "Rolls dice"
  #     setting "sides", default: 6, type: :integer, min: 2
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
  # With several networks, each network runs its own instance of every
  # plugin. Command, hook, timer and listener blocks run with the plugin as
  # self, one at a time per plugin, in the plugin's own queue: plugins run
  # in parallel with each other and with the bot, so a slow plugin only
  # delays itself. Slow work (HTTP and the like) still belongs in
  # #background, which runs alongside the plugin's queue. Plugins run
  # inside the bot with its full privileges: only install code you trust.
  class Plugin
    include PluginIRC

    Command = Data.define(:name, :usage, :help, :details, :admin, :identified, :aliases, :where, :level, :cooldown,
                          :access, :handler)
    Setting = Data.define(:name, :default, :type, :values, :min, :max, :desc, :locked, :channel)

    # connected, disconnected               the connection to the network
    # message, action                       channel messages and /me (action also in private)
    # private_message, notice               text sent to the bot, notices
    # ctcp, ctcp_reply                      CTCP requests and answers
    # join, part, kick, quit, nick          membership
    # mode, topic, invite                   channel changes, invitations
    # identified, logout                    users logging in to bot accounts
    # outgoing                              every line the bot sends
    # line                                  every line received
    # log                                   the bot's own log records
    EVENTS = %i[
      connected disconnected message action private_message notice ctcp ctcp_reply
      join part kick quit nick mode topic invite identified logout outgoing line log
    ].freeze

    # at: when it happened (hooks run a moment later, in the plugin's
    # queue). level and source: for :log events ("info", "IRCnet/links").
    Event = Data.define(:type, :network, :nick, :userhost, :channel, :target, :text, :new_nick, :modes, :ctcp,
                        :account, :message, :at, :level, :source) do
      def initialize(type:, network: nil, nick: nil, userhost: nil, channel: nil, target: nil, text: nil,
                     new_nick: nil, modes: nil, ctcp: nil, account: nil, message: nil, at: nil, level: nil,
                     source: nil) = super

      def channel? = !channel.nil?
      def prefix = nick && userhost ? "#{nick}!#{userhost}" : nick
    end

    COMMAND_NAME = /\A[A-Z][A-Z0-9_-]{0,31}\z/
    WHERE = %i[any channel private].freeze
    MIN_INTERVAL = 1 # seconds, for #every
    MAX_TIMERS = 20
    SETTING_TYPES = %i[string integer number boolean list hash channel nick].freeze

    # --- class-level declarations ------------------------------------------

    class << self
      def description(text = nil)
        text ? @description = text.to_s : @description.to_s
      end

      # Default settings; config.yml's plugins.<name> section overrides them.
      # Settings declared with #setting are included.
      def defaults(hash = nil)
        return @defaults = hash.transform_keys(&:to_s) if hash

        defaults = settings_spec.transform_values(&:default).compact
        defaults["channel_settings"] = {} if channel_settings?
        defaults.merge(@defaults || {})
      end

      # True if some settings can be set per channel (see #setting). A
      # plugin that declares channel_settings itself handles it alone.
      def channel_settings? = settings_spec.each_value.any?(&:channel) && !settings_spec.key?("channel_settings")

      # Declares a setting with a default and checks: type (:string,
      # :integer, :number, :boolean, :list, :hash, :channel or :nick),
      # values (allowed values), min and max (numbers, or lengths of
      # strings and lists). A config value that fails a check stops the
      # plugin from loading, with the reason in "plugin list". locked: only
      # config.yml sets it, never PLUGIN SET (for settings that decide where
      # secrets are sent, such as an API's address). channel: it can be set
      # per channel, under channel_settings (see #settings_for).
      def setting(name, default: nil, type: nil, values: nil, min: nil, max: nil, desc: nil, locked: false,
                  channel: false)
        raise ArgumentError, "unknown setting type #{type.inspect}" if type && !SETTING_TYPES.include?(type)
        raise ArgumentError, "a locked setting can't be set per channel" if locked && channel

        settings_spec[name.to_s] = Setting.new(name: name.to_s, default: default, type: type, values: values,
                                               min: min, max: max, desc: desc.to_s, locked: locked,
                                               channel: channel)
      end

      def settings_spec = (@settings_spec ||= {})

      # Declares IRCv3 capabilities the plugin wants (e.g. "account-notify",
      # "server-time"); the bot asks the server for them. Check with cap?.
      def wants_cap(*names) = wanted_caps.concat(names.map { |n| n.to_s.downcase }).uniq!
      def wanted_caps = (@wanted_caps ||= [])

      # Declares a gem the plugin needs, e.g. requires_gem "nokogiri", "~> 1.16".
      # The bot installs missing gems into the instance's gems folder before
      # loading the plugin (see PluginGems); here the gem is activated and
      # required. require: what to require, if not the gem's name (false:
      # nothing). Put it at the top of the class; a plain require of the gem
      # works after it.
      def requires_gem(name, *requirements, require: name)
        PluginGems.synchronize do
          Kernel.send(:gem, name.to_s, *requirements)
          Kernel.require(require.to_s) if require
        rescue Gem::LoadError => e
          raise Error, "gem #{[name, *requirements].join(' ')} is not available: #{e.message}"
        end
        required_gems << [name.to_s, requirements]
      end

      def required_gems = (@required_gems ||= [])

      # admin: only bot admins; identified: only users logged in to the bot.
      # aliases: other names for the command. where: :any, :channel or
      # :private. level: "voice", "op" or "owner" access needed on the
      # channel (the one it's used in, or, by private message, the first
      # argument). cooldown: seconds before the same user may use it again.
      # help: one line for command lists; details: more, for HELP <command>
      # (line breaks start new lines). access: who may use it, for help
      # only, when the command checks that itself (see HelpCatalog::ACCESS).
      def command(name, usage: nil, help: nil, details: nil, admin: false, identified: false, aliases: [], where: :any,
                  level: nil, cooldown: nil, access: nil, &handler)
        name = name.to_s.upcase
        aliases = Array(aliases).map { |a| a.to_s.upcase }
        ([name] + aliases).each do |n|
          raise ArgumentError, "invalid command name #{n.inspect}" unless n.match?(COMMAND_NAME)
        end
        raise ArgumentError, "command #{name} needs a block" unless handler
        raise ArgumentError, "where: must be one of #{WHERE.join(', ')}" unless WHERE.include?(where)
        raise ArgumentError, "level: must be voice, op or owner" if level && !Channels::LEVELS.key?(level.to_s)
        raise ArgumentError, "cooldown: must be a positive number of seconds" if cooldown && !cooldown.to_f.positive?
        raise ArgumentError, "access: must be one of #{HelpCatalog::ACCESS.join(', ')}" if access && !HelpCatalog::ACCESS.include?(access.to_s)

        command = Command.new(name: name, usage: usage || name, help: help.to_s, details: details&.to_s, admin: admin,
                              identified: identified || admin || !level.nil?, aliases: aliases, where: where,
                              level: level&.to_s, cooldown: cooldown, access: access&.to_s, handler: handler)
        ([name] + aliases).each { |n| commands[n] = command }
      end

      # name and alias => Command
      def commands = (@commands ||= {})

      def on(event, &handler)
        raise ArgumentError, "unknown event #{event.inspect} (one of: #{EVENTS.join(', ')})" unless EVENTS.include?(event)
        raise ArgumentError, "on #{event.inspect} needs a block" unless handler

        (hooks[event] ||= []) << handler
      end

      def hooks = (@hooks ||= {})

      # Answers a CTCP request: the block gets the event and returns the
      # reply text (or nil for no reply). Listed in CLIENTINFO.
      def ctcp_handler(name, &handler)
        name = name.to_s.upcase
        raise ArgumentError, "invalid CTCP command #{name.inspect}" unless name.match?(PluginIRC::CTCP_COMMAND)
        raise ArgumentError, "ctcp_handler #{name} needs a block" unless handler

        ctcp_handlers[name] = handler
      end

      def ctcp_handlers = (@ctcp_handlers ||= {})

      # Handles private messages that aren't commands (a conversation),
      # instead of the bot's "Unknown command." The block gets a command
      # context (ctx.text is the message) and its words. One loaded plugin
      # at a time. Text that looks like a mistyped password command
      # ("identfy secret") never gets here.
      def private_text(&handler)
        raise ArgumentError, "private_text needs a block" unless handler

        @private_text = Command.new(name: "(chat)", usage: "", help: "", details: nil, admin: false,
                                    identified: false, aliases: [], where: :private, level: nil, cooldown: nil,
                                    access: "anyone", handler: handler)
      end

      def private_text_handler = @private_text

      # Receives messages that other plugins #publish under the topic. The
      # block gets (payload, info), info being { plugin:, network: } of the sender.
      def listen(topic, &handler)
        raise ArgumentError, "listen #{topic.inspect} needs a block" unless handler

        (listeners[topic.to_s] ||= []) << handler
      end

      def listeners = (@listeners ||= {})

      # A help page, shown by the help plugin as HELP <name>; text may have
      # several lines. summary: one line for topic lists. With a block
      # instead of text, the text is made when someone asks (the block runs
      # with the plugin as self, so it can use settings and state).
      def help_topic(name, text = nil, summary: nil, &block)
        name = name.to_s.downcase
        raise ArgumentError, "invalid help topic name #{name.inspect}" unless name.match?(/\A[a-z0-9][a-z0-9_-]{0,31}\z/)
        raise ArgumentError, "help_topic #{name} needs text or a block, not both" unless text.nil? ^ block.nil?

        help_topics[name] = { text: text&.to_s, block: block, summary: summary.to_s }
      end

      def help_topics = (@help_topics ||= {})

      # The heading the plugin's commands are listed under (default: the
      # plugin's name); plugins with the same group share it.
      def help_group(name = nil)
        name ? @help_group = name.to_s : @help_group
      end
    end

    attr_reader :name, :settings

    def initialize(name:, settings:, host:, logger:)
      @name = name
      @settings = self.class.defaults.merge(settings)
      @host = host
      @log = logger
      @timers = []
      @rate_limiters = {}
      @rate_lock = Mutex.new # rate_limit is also used from background jobs
      @active = true
      @retiring = false
      check_settings!
    end

    # Called after loading and before unloading; override as needed.
    def setup; end
    def teardown; end

    # Called (in the plugin's queue, in order) when events or commands for
    # the plugin had to be dropped because its queue was full; count is how
    # many, since the previous call. Override to note the gap.
    def events_dropped(count)
      log.warn("#{count} event(s) or command(s) for this plugin were dropped: it fell too far behind")
    end

    # Whether to queue events of this type for the plugin's hooks; override
    # to skip, by settings, events a hook would ignore anyway (they then
    # take no place in the plugin's queue). Called on the bot's thread:
    # keep it a quick check.
    def wants_event?(_type) = true

    # IRCv3 capabilities enabled on this connection (see wants_cap).
    def caps = @host.caps
    def cap?(name) = caps.include?(name.to_s.downcase)

    # (say, notice, action, ctcp, ctcp_reply, join, part, mode, op, deop,
    # voice, devoice, ban, unban, kick, kickban, ban_mask, set_topic, invite
    # and raw come from PluginIRC.)

    # --- the network -----------------------------------------------------------

    # This instance's network, as named in config.yml ("IRCnet").
    def network = @host.network

    # The name the server reports (ISUPPORT NETWORK), or nil.
    def network_name = @host.network_name

    # Every network the bot is on, in config order.
    def networks = @host.networks

    # True on the first network only: for work that must happen once per
    # bot, not once per network (e.g. a web listener).
    def primary? = @host.primary?

    def connected? = @host.connected?
    def server = @host.server

    # The server's ISUPPORT tokens: { "PREFIX" => "(ov)@+", "MONITOR" => "100", ... }.
    def isupport = @host.isupport.to_h

    # Another network, to send to (see Plugin::Remote), or nil if the bot
    # isn't on it. Sending there happens shortly after, on its own turn.
    def on_network(name) = @host.remote(name, owner: @name)

    # --- the bot and its channels -------------------------------------------------

    def bot_nick = @host.nick

    # Channels the bot is currently in.
    def channels = @host.channels

    def in_channel?(channel) = channels.any? { |c| Casemap.eq?(c, channel) }

    # Members of a channel the bot is in, as Roster::Member (nick,
    # userhost, modes, op?, voice?, halfop?).
    def users(channel) = @host.members(channel)
    def user(channel, nick) = @host.member(channel, nick)
    def op?(channel, nick = bot_nick) = user(channel, nick)&.op? || false
    def voice?(channel, nick = bot_nick) = user(channel, nick)&.voice? || false

    # Roster::Topic (text, by, at) or nil.
    def topic(channel) = @host.topic(channel)

    # { "n" => true, "t" => true, "k" => "key", "l" => "10" }
    def channel_modes(channel) = @host.channel_modes(channel)

    # user@host of a nick sharing a channel with the bot, or nil.
    def userhost_of(nick) = @host.userhost_of(nick)

    # --- accounts and access -----------------------------------------------------

    # The bot account a nick is identified as, or nil. With userhost, the
    # session must also belong to that user@host (Context#account does this).
    def account_for(nick, userhost = nil) = @host.account_for(nick, userhost)
    def admin?(account) = @host.admin?(account)

    # "voice", "op", "owner" or nil; bot admins are owner everywhere.
    def access_level(channel, account) = account && @host.level_for(channel, account)

    # The account name as registered, or nil if there is none.
    def account_name(name) = @host.account_name(name)
    def account_exists?(name) = !account_name(name).nil?
    def admins = @host.admins

    # { nick => account } of users identified on this network.
    def identified_users = @host.identified_users

    # Channels registered with the bot on this network.
    def registered_channels = @host.registered_channels
    def channel_registered?(channel) = @host.channel_registered?(channel)

    # [[account, level], ...], the owner first.
    def channel_access(channel) = @host.channel_access(channel)
    def channel_owner(channel) = channel_access(channel).first&.first

    # --- configuration -------------------------------------------------------------

    # The bot's settings for this network, without secrets: nick,
    # alt_nicks, user, realname, umodes, server, port, tls, network,
    # channels, admins, ctcp.
    def bot_config = @host.bot_config

    # --- other plugins -----------------------------------------------------------------

    # Another loaded plugin on this network, to call its methods, or nil.
    def plugin(name) = @host.plugin(name.to_s)

    # Every command (the core's and loaded plugins') and help topic, as
    # they work on this network: a HelpCatalog::Catalog. For help plugins.
    def help_catalog = @host.help_catalog

    # CTCP commands loaded plugins answer (see ctcp_handler).
    def ctcp_commands = @host.ctcp_commands

    # This network's registered channels, their access lists and masks
    # (a Gemdrop::Channels). For channel services; changes are saved at once.
    def registry = @host.registry

    # After registering or dropping a channel: joins the channels the bot
    # should be in and leaves the others.
    def sync_channels(part_reason: "No longer configured") = @host.sync_channels(part_reason)

    # Sends payload to the #listen blocks of other plugins: on this
    # network right away, and with everywhere: true also on the other
    # networks (shortly after). Returns how many listeners got it here.
    def publish(topic, payload = nil, everywhere: false)
      @host.publish(topic.to_s, payload, from: @name, everywhere: everywhere)
    end

    # State shared by this plugin's instances on every network (and kept
    # across reloads until the bot restarts). See Plugin::Shared.
    def shared = Shared.for(@name)

    # --- state, background work, timers, helpers ---------------------------------------

    # Persistent JSON storage in data/plugins/<name>.json (or
    # data/plugins/<network>/<name>.json with several networks).
    def data = @data ||= Storage.new(File.join(@host.data_dir, "#{@name}.json"))

    # A private folder for the plugin's own files (logs, caches),
    # created on first use.
    def data_dir
      dir = File.join(@host.data_dir, @name)
      FileUtils.mkdir_p(dir, mode: 0o700)
      dir
    end

    # Runs a slow job on a worker thread, outside the IRC handling. Returns
    # false if the queue is full and the job was dropped.
    def background(&job)
      @host.submit do
        Thread.current[:gemdrop_background] = true
        safely("background job") { instance_exec(&job) } if active?
      ensure
        Thread.current[:gemdrop_background] = nil
      end
    end

    # Runs the block every `seconds` (or once, after `seconds`) like a hook.
    # Timers stop when the plugin is unloaded; #cancel stops one earlier.
    def every(seconds, &block) = start_timer(seconds, repeat: true, &block)
    def after(seconds, &block) = start_timer(seconds, repeat: false, &block)

    def cancel(timer)
      @timers.delete(timer)
      timer&.kill
      nil
    end

    # Counts one use of key; false once it was used `limit` times in the
    # last `per` seconds. E.g. return unless rate_limit("hello:#{nick}", limit: 1, per: 60)
    def rate_limit(key, limit:, per:)
      @rate_lock.synchronize do
        limiter = (@rate_limiters[per] ||= RateLimiter.new(window: per))
        next false if limiter.blocked_for(key.to_s, limit: limit)

        limiter.hit(key.to_s)
        true
      end
    end

    # HTTP GET through the bot's guarded client (public addresses only,
    # size and time limits, see SafeHttp). Only inside #background, since
    # it waits. types: content types whose body is read. headers: extra
    # request headers (e.g. an API token), sent only to the URL's host.
    # Returns a SafeHttp::Response (url, status, content_type,
    # content_length, body).
    def http_get(url, accept: "*/*", types: /\A(?:text\/|application\/(?:[\w.+-]+\+)?(?:json|xml))/, headers: {})
      raise ArgumentError, "http_get must run inside background { ... }" unless Thread.current[:gemdrop_background]

      @host.http.get(url.to_s, body_types: types, accept: accept, headers: headers)
    rescue SafeHttp::Refused, Timeout::Error, IOError, SystemCallError, SocketError, OpenSSL::SSL::SSLError,
           Net::HTTPBadResponse, Net::ProtocolError, URI::Error => e
      raise Error, "Can't fetch that: #{e.message}."
    end

    # GET and parse JSON (inside #background). Raises Error unless the
    # answer is a 200 with a JSON body.
    def http_json(url, headers: {})
      response = http_get(url, accept: "application/json", types: %r{\Aapplication/(?:[\w.+-]+\+)?json\z},
                               headers: headers)
      raise Error, "Got HTTP #{response.status} from #{url}." unless response.status == 200 && response.body

      JSON.parse(response.body)
    rescue JSON::ParserError
      raise Error, "#{url} did not return valid JSON."
    end

    # POSTs body (a Hash, sent as JSON) to an API, inside #background.
    # Returns a SafeHttp::Response whatever the status, body as UTF-8 text
    # (parse it yourself: error pages are not always JSON). No redirects
    # are followed. local: true also reaches localhost, private networks
    # and any port; only for an address from config.yml, never one a user
    # gave. Raises Error if the request can't be made or times out.
    def http_post_json(url, body, headers: {}, timeout: 60, max_bytes: 1024 * 1024, local: false)
      http_request(:post, url, json: body, headers: headers, timeout: timeout, max_bytes: max_bytes, local: local)
    end

    # Any HTTP request to an API, inside #background, with the rules of
    # http_post_json (no redirects; local: for config.yml's addresses).
    # method: :get, :post, :put, :patch, :delete or :head. The body is one
    # of json: (a Hash or Array, sent as JSON), form: (a Hash, sent
    # URL-encoded) or body: (a String, with content_type:). Returns a
    # SafeHttp::Response whatever its status, the body as UTF-8 text.
    def http_request(method, url, body: nil, json: nil, form: nil, content_type: nil, accept: "*/*", headers: {},
                     timeout: 60, max_bytes: 1024 * 1024, local: false)
      raise ArgumentError, "http_request must run inside background { ... }" unless Thread.current[:gemdrop_background]
      raise ArgumentError, "give at most one of body:, json:, form:" if [body, json, form].compact.size > 1

      if json
        body = JSON.generate(json)
        content_type ||= "application/json"
        accept = "application/json" if accept == "*/*"
      elsif form
        body = URI.encode_www_form(form)
        content_type ||= "application/x-www-form-urlencoded"
      end
      response = @host.http.request(method, url.to_s, body: body, content_type: content_type, accept: accept,
                                                      headers: headers, timeout: timeout, max_bytes: max_bytes,
                                                      local: local)
      response.body&.force_encoding(Encoding::UTF_8)&.scrub!
      response
    rescue SafeHttp::Refused, Timeout::Error, IOError, SystemCallError, SocketError, OpenSSL::SSL::SSLError,
           Net::HTTPBadResponse, Net::ProtocolError, URI::Error => e
      raise Error, "Request failed: #{e.message}."
    end

    # Reads a secret (an API key) from a file in the bot's secret folder
    # (secret/ in an instance): name is a plain file name, the file must be
    # private to the bot's user. Returns the content without surrounding
    # whitespace. Raises Error if it is missing, unsafe or too big.
    def secret_file(name)
      name = name.to_s
      raise Error, "#{name.inspect} is not a plain file name." unless name.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/)

      path = File.join(@host.secrets_dir, name)
      SecureFile.check!(path)
      raise Error, "#{name} is too big for a secret." if File.size(path) > 8192

      File.read(path).strip
    rescue ConfigError, SystemCallError => e
      raise Error, "secret file #{name}: #{e.message}"
    end

    # The settings for a channel on this network (see Plugin.setting's
    # channel:): the plugin's, then channel_settings' entry for the channel
    # on every network ("#chan"), then the one for this network's channel
    # ("IRCnet" => { "#chan" => ... }). Without a channel, just #settings.
    def settings_for(channel)
      table = settings["channel_settings"]
      return settings unless channel && table.is_a?(Hash) && !table.empty?

      here = table.find { |key, value| value.is_a?(Hash) && !key.to_s.match?(Channels::NAME) && key.to_s.casecmp?(network.to_s) }
      [table, here&.last || {}].reduce(settings) do |merged, level|
        overrides = level.find { |key, _| key.to_s.match?(Channels::NAME) && Casemap.eq?(key, channel) }&.last
        overrides.is_a?(Hash) ? merged.merge(overrides.transform_keys(&:to_s)) : merged
      end
    end

    # The plugin's logger; lines are marked with the network and plugin.
    def log = @log

    # Ends a command with "Usage: ..." sent back to the user.
    def usage!(text) = raise(Error, "Usage: #{text}")

    def active? = @active

    # True while the plugin takes new jobs (hooks, commands, timers ...).
    def accepting? = @active && !@retiring

    # --- used by PluginManager ---------------------------------------------------------

    # Runs plugin code; errors are logged, never passed on to the bot.
    def safely(what)
      yield
    rescue StandardError => e
      @log.error("#{what} failed: #{e.class}: #{e.message} (#{e.backtrace&.first})")
      nil
    end

    # Being unloaded: no new jobs, though teardown can still send.
    def retire! = @retiring = true

    def stop!
      @active = false
      @timers.each(&:kill)
      @timers.clear
    end

    private

    # PluginIRC sends through these.
    def irc_write(line) = active? && @host.write(line)
    def irc_join(channel, key) = active? && @host.join(@name, channel, key)
    def irc_part(channel, reason) = active? && @host.part(@name, channel, reason)
    def irc_isupport = @host.isupport
    def irc_userhost(nick) = @host.userhost_of(nick)
    def irc_protected?(channel) = @host.protected_channel?(channel)

    def start_timer(seconds, repeat:, &block)
      raise ArgumentError, "timer interval must be at least #{MIN_INTERVAL}s" if repeat && seconds < MIN_INTERVAL

      @timers.select!(&:alive?)
      raise ArgumentError, "too many timers (max #{MAX_TIMERS})" if @timers.size >= MAX_TIMERS

      thread = Thread.new do
        Thread.current.name = "plugin-#{@name}-timer"
        loop do
          sleep seconds
          @host.run_plugin_job(self) { safely("timer") { instance_exec(&block) } }
          break unless repeat && accepting?
        end
      end
      @timers << thread
      thread
    end

    def check_settings!
      self.class.settings_spec.each_value do |spec|
        value = @settings[spec.name]
        next if value.nil? && spec.default.nil?

        problem = setting_problem(spec, value)
        raise Error, "setting #{spec.name} #{problem} (got #{value.inspect})" if problem
      end
      check_channel_settings!
    end

    # channel_settings: { "#chan" => { setting => value } }, only for
    # settings declared with channel: true, each passing that setting's checks.
    def check_channel_settings!
      overrides = @settings["channel_settings"]
      return if overrides.nil? || overrides == {} || self.class.settings_spec.key?("channel_settings")
      raise Error, "channel_settings: #{@name} has no settings that can be set per channel" unless
        self.class.channel_settings?
      raise Error, "channel_settings must be a mapping of channel to settings" unless overrides.is_a?(Hash)

      overrides.each do |key, values|
        raise Error, "channel_settings: #{key} must be a mapping" unless values.is_a?(Hash)
        next check_channel_overrides(key, values) if key.to_s.match?(Channels::NAME)

        # A network's own channels: { "IRCnet" => { "#chan" => {...} } }
        unless networks.any? { |id| id.casecmp?(key.to_s) }
          raise Error, "channel_settings: #{key.inspect} is neither a channel nor a network (networks: #{networks.join(', ')})"
        end
        values.each do |channel, inner|
          raise Error, "channel_settings: #{key}: #{channel.inspect} is not a channel" unless channel.to_s.match?(Channels::NAME)
          raise Error, "channel_settings: #{key}: #{channel} must be a mapping" unless inner.is_a?(Hash)

          check_channel_overrides("#{key} #{channel}", inner)
        end
      end
    end

    def check_channel_overrides(label, values)
      per_channel = self.class.settings_spec.values.select(&:channel).map(&:name)
      values.each do |name, value|
        spec = self.class.settings_spec[name.to_s]
        unless per_channel.include?(name.to_s)
          raise Error, "channel_settings: #{label}: #{name} can't be set per channel " \
                       "(these can: #{per_channel.join(', ')})"
        end
        problem = setting_problem(spec, value)
        raise Error, "channel_settings: #{label}: #{name} #{problem} (got #{value.inspect})" if problem
      end
    end

    def setting_problem(spec, value)
      type_ok = case spec.type
                when nil then true
                when :string then value.is_a?(String)
                when :integer then value.is_a?(Integer)
                when :number then value.is_a?(Numeric)
                when :boolean then [true, false].include?(value)
                when :list then value.is_a?(Array)
                when :hash then value.is_a?(Hash)
                when :channel then value.to_s.match?(Channels::NAME)
                when :nick then value.to_s.match?(Config::NICK)
                end
      return "must be #{spec.type == :integer ? 'a whole number' : "a #{spec.type}"}" unless type_ok
      return "must be one of #{spec.values.map(&:inspect).join(', ')}" if spec.values && !spec.values.include?(value)

      size = value.is_a?(Numeric) ? value : (value.respond_to?(:size) ? value.size : nil)
      return "must be at least #{spec.min}" if spec.min && size && size < spec.min
      return "must be at most #{spec.max}" if spec.max && size && size > spec.max

      nil
    end

    # A command invocation, passed to command blocks.
    class Context
      attr_reader :nick, :userhost, :channel, :command, :args, :target_channel

      def initialize(plugin:, nick:, userhost:, channel:, command:, prefix:, args: [], target_channel: nil)
        @plugin = plugin
        @nick = nick
        @userhost = userhost
        @channel = channel
        @command = command
        @prefix = prefix
        @args = args
        @target_channel = target_channel || channel
      end

      # nil for commands sent by private message.
      def channel? = !@channel.nil?

      def network = @plugin.network

      # The arguments as one string.
      def text = @args.join(" ")

      # In a channel: a message to the channel; in private: a notice.
      def reply(text) = channel? ? @plugin.say(@channel, text) : @plugin.notice(@nick, text)
      def reply_privately(text) = @plugin.notice(@nick, text)
      def reply_action(text) = @plugin.action(channel? ? @channel : @nick, text)

      def account = @plugin.account_for(@nick, @userhost)
      def admin? = @plugin.admin?(account)
      def access_level(channel = @target_channel) = channel && @plugin.access_level(channel, account)

      # Raises with the command's usage, written the way it was invoked.
      def usage! = @plugin.usage!("#{@prefix}#{@command.usage}")
    end

    # Another network, as seen from a plugin (Plugin#on_network). It has
    # the PluginIRC actions (say, notice, join, mode, kick ...) except
    # kickban/ban_mask, which need that network's user list. Actions are
    # queued and run on the other network's turn, so they return true when
    # queued; problems there are logged.
    class Remote
      include PluginIRC

      def initialize(bot:, owner:)
        @bot = bot
        @owner = owner
      end

      def network = @bot.network_id
      def connected? = @bot.connected?
      def nick = @bot.nick
      def channels = @bot.channel_snapshot

      private

      def irc_write(line) = queue { @bot.__send__(:send_raw, line) }
      def irc_join(channel, key) = queue { @bot.__send__(:plugin_join, @owner, channel, key) }
      def irc_part(channel, reason) = queue { @bot.__send__(:plugin_part, @owner, channel, reason) }
      def irc_isupport = @bot.isupport
      def irc_userhost(_nick) = nil
      def irc_protected?(channel) = @bot.__send__(:core_channel?, channel)

      def queue(&) = @bot.connected? && @bot.queue_remote(&)
    end

    # State shared by one plugin's instances across networks, e.g. a cache
    # or counters. Values are plain Ruby objects (not saved to disk; use
    # #data for that).
    #
    #   shared["hits"] = 0
    #   shared.synchronize { |hash| hash["hits"] += 1 }
    class Shared
      REGISTRY = {}
      LOCK = Mutex.new
      private_constant :REGISTRY, :LOCK

      def self.for(name) = LOCK.synchronize { REGISTRY[name] ||= new }

      def initialize
        @data = {}
        @lock = Monitor.new
      end

      def [](key) = @lock.synchronize { @data[key.to_s] }
      def []=(key, value)
        @lock.synchronize { @data[key.to_s] = value }
      end
      def delete(key) = @lock.synchronize { @data.delete(key.to_s) }
      def to_h = @lock.synchronize { @data.dup }

      # Yields the hash for several changes at once.
      def synchronize = @lock.synchronize { yield @data }
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

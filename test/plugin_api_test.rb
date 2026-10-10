require "test_helper"
require "stringio"

# The plugin API beyond the basics in plugin_test.rb: channel state, IRC
# actions, the newer events, CTCP, command options, typed settings,
# plugin-to-plugin messages, per-network config and other networks.
class PluginApiTest < Minitest::Test
  include StoreHelper

  def setup
    super
    @plugins_dir = File.join(@tmpdir, "plugins")
    Dir.mkdir(@plugins_dir, 0o700)
    @log = StringIO.new
  end

  def write_plugin(name, source)
    File.write(File.join(@plugins_dir, "#{name}.rb"), source, perm: 0o600)
  end

  def config_yaml(extra = "")
    <<~YAML + extra
      server: irc.example.net
      nick: Gemdrop
      admins: [root]
      channels: ["#chan"]
      require_secure_users: false
    YAML
  end

  def start(extra = "", isupport: "PREFIX=(ov)@+ CHANMODES=beI,k,l,imnpst MODES=3 NETWORK=Example")
    @config_path = File.join(@tmpdir, "config.yml")
    File.write(@config_path, config_yaml(extra), perm: 0o600)
    @conn = FakeConnection.new
    @bot = Gemdrop::Bot.new(Gemdrop::Config.load(@config_path), config_path: @config_path, connection: @conn,
                                                                store: @store, hasher: TEST_HASHER, logger: Logger.new(@log))
    @bot.handle(":server 001 Gemdrop :Welcome")
    @bot.handle(":server 005 Gemdrop #{isupport} :are supported")
    @bot.handle(":Gemdrop!bot@host JOIN #chan")
    @bot.handle(":server 353 Gemdrop = #chan :@Gemdrop +alice bob")
    @conn.clear
  end

  def plugin(name) = @bot.send(:plugin_manager).plugin(name)
  def say(nick, text) = @bot.handle(":#{nick}!#{nick}@#{nick}.host PRIVMSG Gemdrop :#{text}")
  def say_in(channel, nick, text) = @bot.handle(":#{nick}!#{nick}@#{nick}.host PRIVMSG #{channel} :#{text}")
  def notices_to(nick) = @conn.lines.grep(/\ANOTICE #{nick} :/).map { |l| l.split(" :", 2).last }

  def register(name)
    Gemdrop::Accounts.new(@store, TEST_HASHER).register(name, "password123")
    say(name, "IDENTIFY password123")
  end

  # A plugin that records the events it gets.
  RECORDER = <<~RUBY.freeze
    class Recorder < Gemdrop::Plugin
      attr_reader :events

      def setup = @events = []

      Gemdrop::Plugin::EVENTS.each do |type|
        on(type) { |event| @events << event unless type == :line || type == :outgoing }
      end
      on(:outgoing) { |event| (@outgoing ||= []) << event.text; say("#chan", "echo") if event.text == "PRIVMSG #chan :ping" }

      def outgoing = @outgoing || []
      def of(type) = @events.select { |e| e.type == type }
    end
  RUBY

  # A plugin whose methods tests call directly.
  BARE = "class Bare < Gemdrop::Plugin; end\n".freeze

  # --- ISUPPORT and the roster -------------------------------------------------

  def test_isupport_parses_modes_by_type
    isupport = Gemdrop::ISupport.new
    isupport.update(%w[PREFIX=(ohv)@%+ CHANMODES=beI,k,l,imnpst MODES=4 MONITOR NETWORK=Test\\x20Net])

    assert_equal({ "o" => "@", "h" => "%", "v" => "+" }, isupport.prefixes)
    assert_equal 4, isupport.max_modes
    assert_equal "Test Net", isupport["NETWORK"]
    assert isupport.key?("MONITOR")
    changes = isupport.parse_modes("+ob-l+kv", %w[alice *!*@x.example key bob])
    assert_equal ["+o alice", "+b *!*@x.example", "-l", "+k key", "+v bob"], changes.map(&:to_s)

    isupport.update(%w[-MONITOR])
    refute isupport.key?("MONITOR")
  end

  def test_roster_tracks_status_modes_topic_and_hosts
    write_plugin("bare", BARE)
    start
    bare = plugin("bare")

    assert bare.op?("#chan")
    assert bare.voice?("#chan", "alice")
    refute bare.op?("#chan", "bob")

    @bot.handle(":alice!a@alice.example MODE #chan +o-v+l bob alice 20")
    assert bare.op?("#chan", "bob")
    refute bare.voice?("#chan", "alice")
    assert_equal "20", bare.channel_modes("#chan")["l"]
    assert_equal "a@alice.example", bare.userhost_of("alice"), "learned from the MODE line"

    @bot.handle(":server 324 Gemdrop #chan +ntk secret")
    assert_equal({ "n" => true, "t" => true, "k" => "secret" }, bare.channel_modes("#chan"))

    @bot.handle(":server 332 Gemdrop #chan :Old topic")
    @bot.handle(":server 333 Gemdrop #chan alice 1700000000")
    assert_equal ["Old topic", "alice", 1_700_000_000], bare.topic("#chan").to_h.values_at(:text, :by, :at)
    @bot.handle(":bob!b@bob.example TOPIC #chan :New topic")
    assert_equal %w[New\ topic bob], bare.topic("#chan").to_h.values_at(:text, :by)

    assert_equal %w[Gemdrop alice bob], bare.users("#chan").map(&:nick).sort
    assert_equal ["#chan"], bare.channels
  end

  def test_join_asks_for_channel_modes
    start
    @bot.handle(":Gemdrop!bot@host JOIN #new")
    assert_equal ["MODE #new"], @conn.lines
  end

  # --- IRC actions ---------------------------------------------------------------

  def test_mode_actions_respect_the_servers_limit
    write_plugin("bare", BARE)
    start
    bare = plugin("bare")

    assert bare.op("#chan", "a", "b", "c", "d")
    bare.devoice("#chan", %w[x y])
    bare.mode("#chan", "+l", 10)
    assert_equal ["MODE #chan +ooo a b c", "MODE #chan +o d", "MODE #chan -vv x y", "MODE #chan +l 10"], @conn.lines
    assert_raises(ArgumentError) { bare.mode("#chan", "o alice") }
    assert_raises(ArgumentError) { bare.op("#chan", "bad nick") }
    assert_raises(ArgumentError) { bare.op("nochannel", "alice") }
  end

  def test_kick_ban_topic_invite_and_ctcp
    write_plugin("bare", BARE)
    start
    bare = plugin("bare")
    @bot.handle(":bob!~bobby@bob.example JOIN #chan")
    @conn.clear

    bare.kickban("#chan", "bob", "Bye\r\nQUIT :haha")
    bare.set_topic("#chan", "Hello")
    bare.invite("carol", "#chan")
    bare.ctcp("carol", "version")
    bare.ctcp_reply("carol", "FINGER", "none")
    bare.action("#chan", "waves")
    assert_equal ["MODE #chan +b *!*bobby@bob.example", "KICK #chan bob :Bye QUIT :haha", "TOPIC #chan :Hello",
                  "INVITE carol #chan", "PRIVMSG carol :\x01VERSION\x01", "NOTICE carol :\x01FINGER none\x01",
                  "PRIVMSG #chan :\x01ACTION waves\x01"], @conn.lines

    error = assert_raises(Gemdrop::Error) { bare.kickban("#chan", "stranger") }
    assert_match(/don't know stranger's host/, error.message)
  end

  def test_raw_lines_are_checked
    write_plugin("bare", BARE)
    start
    bare = plugin("bare")

    assert bare.raw("WHOIS alice")
    assert_equal ["WHOIS alice"], @conn.lines
    %w[NICK QUIT PASS].each do |command|
      assert_raises(ArgumentError) { bare.raw("#{command} something") }
    end
    assert_raises(ArgumentError) { bare.raw("PRIVMSG #chan :a\r\nQUIT") }
  end

  def test_text_from_users_cant_become_ctcp
    write_plugin("bare", BARE)
    start
    bare = plugin("bare")

    bare.say("#chan", "\x01DCC SEND evil 1 2 3\x01")
    bare.notice("alice", "a\x01VERSION\x01b")
    bare.action("#chan", "waves \x01 hi")
    assert_equal ["PRIVMSG #chan :DCC SEND evil 1 2 3", "NOTICE alice :aVERSIONb", "PRIVMSG #chan :\x01ACTION waves   hi\x01"],
                 @conn.lines
  end

  def test_raw_cant_bypass_channel_protection
    write_plugin("bare", BARE)
    start
    bare = plugin("bare")
    @bot.handle(":Gemdrop!bot@host JOIN #extra")
    @conn.clear

    assert_raises(ArgumentError) { bare.raw("JOIN 0") }
    assert_raises(ArgumentError) { bare.raw("JOIN #a,0") }
    assert_raises(ArgumentError) { bare.raw("PART #chan :bye") }
    assert_raises(ArgumentError) { bare.raw("PART #extra,#CHAN") }
    assert_raises(ArgumentError) { bare.raw(":Gemdrop NICK other") }
    assert_raises(ArgumentError) { bare.raw("@tag=1 QUIT") }
    assert bare.raw("PART #extra")
    assert bare.raw("JOIN #new")
    assert_equal ["PART #extra", "JOIN #new"], @conn.lines

    assert_raises(ArgumentError) { bare.on_network("default").raw("PART #chan") }
  end

  def test_plugin_channels_survive_reload_and_leave_with_the_plugin
    write_plugin("bare", BARE)
    start
    bare = plugin("bare")

    bare.join("#extra")
    assert_equal ["JOIN #extra"], @conn.lines
    @bot.handle(":Gemdrop!bot@host JOIN #extra")
    @conn.clear

    assert @bot.reload_config
    refute_includes @conn.lines, "PART #extra :No longer configured"
    assert_raises(ArgumentError) { bare.part("#chan") }

    @bot.send(:reset_state) # a reconnect rejoins it
    @bot.handle(":server 001 Gemdrop :Welcome")
    assert_includes @conn.lines, "JOIN #extra"
    @bot.handle(":Gemdrop!bot@host JOIN #extra")
    @conn.clear

    File.delete(File.join(@plugins_dir, "bare.rb"))
    @bot.reload_config
    assert_includes @conn.lines, "PART #extra"
  end

  # --- events --------------------------------------------------------------------

  def test_new_events_reach_plugins
    write_plugin("recorder", RECORDER)
    start
    rec = plugin("recorder")
    register("alice")

    @bot.handle(":alice!alice@alice.host MODE #chan +v bob")
    @bot.handle(":alice!alice@alice.host TOPIC #chan :Hi")
    @bot.handle(":alice!alice@alice.host INVITE Gemdrop #elsewhere")
    @bot.handle(":alice!alice@alice.host NOTICE #chan :heads up")
    @bot.handle(":alice!alice@alice.host PRIVMSG #chan :\x01ACTION waves\x01")
    @bot.handle(":alice!alice@alice.host PRIVMSG Gemdrop :hello bot")
    @bot.handle(":alice!alice@alice.host PRIVMSG Gemdrop :\x01FINGER\x01")
    @bot.handle(":alice!alice@alice.host NOTICE Gemdrop :\x01VERSION Some client\x01")
    say("alice", "LOGOUT")

    mode = rec.of(:mode).first
    assert_equal ["+v bob"], mode.modes.map(&:to_s)
    assert_equal "default", mode.network
    assert_equal "Hi", rec.of(:topic).first.text
    assert_equal "#elsewhere", rec.of(:invite).first.channel
    assert_equal "heads up", rec.of(:notice).first.text
    assert_equal "waves", rec.of(:action).first.text
    assert_empty rec.of(:message), "actions are not channel messages"
    assert_equal ["hello bot", "LOGOUT"], rec.of(:private_message).map(&:text)
    assert_equal "FINGER", rec.of(:ctcp).first.ctcp
    assert_equal ["VERSION", "Some client"], rec.of(:ctcp_reply).first.to_h.values_at(:ctcp, :text)
    assert_equal ["alice"], rec.of(:identified).map(&:account)
    assert_equal ["alice"], rec.of(:logout).map(&:account)
    refute(rec.of(:private_message).any? { |e| e.text.include?("password") }, "password lines stay hidden")
  end

  def test_outgoing_lines_are_reported_once
    write_plugin("recorder", RECORDER)
    start
    rec = plugin("recorder")
    rec.instance_variable_set(:@outgoing, [])

    rec.say("#chan", "ping")
    assert_equal ["PRIVMSG #chan :ping", "PRIVMSG #chan :echo"], @conn.lines
    assert_equal ["PRIVMSG #chan :ping"], rec.outgoing, "lines sent by an outgoing hook aren't reported again"
  end

  # --- CTCP ------------------------------------------------------------------------

  def test_core_ctcp_answers
    install_plugins(@plugins_dir, "ctcp")
    start(%(plugins:\n  ctcp:\n    version: "TestBot 1.0"\n))

    say("alice", "\x01VERSION\x01")
    say("alice", "\x01PING 12345\x01")
    say("alice", "\x01CLIENTINFO\x01")
    say_in("#chan", "bob", "\x01VERSION\x01")
    assert_equal ["\x01VERSION TestBot 1.0\x01", "\x01PING 12345\x01", "\x01CLIENTINFO ACTION VERSION PING TIME CLIENTINFO\x01"],
                 notices_to("alice")
    assert_equal ["\x01VERSION TestBot 1.0\x01"], notices_to("bob")
  end

  def test_plugins_answer_ctcp_and_core_answers_can_be_off
    write_plugin("finger", <<~RUBY)
      class Finger < Gemdrop::Plugin
        ctcp_handler("FINGER") { |event| "\#{event.nick} pokes back" }
        ctcp_handler("VERSION") { |_event| "Custom version" }
      end
    RUBY
    start(%(plugins:\n  ctcp:\n    enabled: false\n))

    say("alice", "\x01FINGER\x01")
    say("alice", "\x01VERSION\x01")
    say("alice", "\x01TIME\x01")
    assert_equal ["\x01FINGER alice pokes back\x01", "\x01VERSION Custom version\x01"], notices_to("alice")
  end

  # --- command options ---------------------------------------------------------------

  COMMANDS = <<~RUBY.freeze
    class Tools < Gemdrop::Plugin
      command "HELLO", aliases: %w[HI HEY] do |ctx, _args|
        ctx.reply("hello \#{ctx.nick}")
      end

      command "HERE", where: :channel do |ctx, _args|
        ctx.reply("here in \#{ctx.channel}")
      end

      command "TOPICSET", usage: "TOPICSET <#chan> <text>", level: "op" do |ctx, args|
        set_topic(ctx.target_channel, args.join(" "))
      end

      command "SLOW", cooldown: 60 do |ctx, _args|
        ctx.reply("done")
      end
    end
  RUBY

  def test_aliases_where_and_cooldown
    write_plugin("tools", COMMANDS)
    start(%(plugins:\n  tools:\n    prefix: "!"\n))

    say("alice", "HEY")
    say("alice", "HERE")
    say_in("#chan", "alice", "!here")
    say("alice", "SLOW")
    say("alice", "SLOW")
    assert_equal ["hello alice", "HERE only works in channels.", "done"], notices_to("alice").first(3)
    assert_match(/\APlease wait \d+ seconds before using SLOW again\.\z/, notices_to("alice").last)
    assert_includes @conn.lines, "PRIVMSG #chan :here in #chan"
  end

  def test_level_command_by_private_message_names_the_channel
    write_plugin("tools", COMMANDS)
    start
    register("root")
    register("alice")
    say("root", "CHANREGISTER #chan root")
    @conn.clear

    say("alice", "TOPICSET #chan Hello")
    assert_equal ["You need op access on #chan for that."], notices_to("alice")

    say("root", "TOPICSET #chan Hello there")
    assert_includes @conn.lines, "TOPIC #chan :Hello there"
    say("root", "TOPICSET")
    assert_equal "Usage: TOPICSET <#chan> <text>", notices_to("root").last
  end

  # --- settings ---------------------------------------------------------------------------

  TYPED = <<~RUBY.freeze
    class Typed < Gemdrop::Plugin
      setting "count", default: 3, type: :integer, min: 1, max: 10
      setting "mode", default: "fast", values: %w[fast slow]
      setting "home", type: :channel
    end
  RUBY

  def test_typed_settings_are_checked
    write_plugin("typed", TYPED)
    start
    assert_equal({ "count" => 3, "mode" => "fast" }, plugin("typed").settings.slice("count", "mode"))

    File.write(@config_path, config_yaml(%(plugins:\n  typed:\n    count: 50\n)), perm: 0o600)
    @bot.reload_config
    status = @bot.send(:plugin_manager).status["typed"]
    assert_match(/setting count must be at most 10 \(got 50\)/, status["error"])

    File.write(@config_path, config_yaml(%(plugins:\n  typed:\n    home: nochannel\n)), perm: 0o600)
    @bot.reload_config
    assert_match(/setting home must be a channel/, @bot.send(:plugin_manager).status["typed"]["error"])
  end

  # --- plugins talking to each other --------------------------------------------------

  def test_publish_listen_plugin_lookup_and_shared_state
    write_plugin("sender", <<~RUBY)
      class Sender < Gemdrop::Plugin
        def greeting = "hi from sender"
        command("SEND") { |_ctx, args| publish("news", { "text" => args.join(" ") }) }
      end
    RUBY
    write_plugin("receiver", <<~RUBY)
      class Receiver < Gemdrop::Plugin
        listen("news") { |payload, info| say("#chan", "\#{info[:plugin]}: \#{payload['text']}") }
        command("ASK") { |ctx, _args| ctx.reply(plugin("sender").greeting) }
      end
    RUBY
    start

    say("alice", "SEND big news")
    say("alice", "ASK")
    assert_includes @conn.lines, "PRIVMSG #chan :sender: big news"
    assert_equal ["hi from sender"], notices_to("alice")

    plugin("sender").shared["count"] = 1
    plugin("sender").shared.synchronize { |hash| hash["count"] += 1 }
    assert_equal 2, Gemdrop::Plugin::Shared.for("sender")["count"]
  end

  def test_http_only_in_background_and_bot_config_hides_secrets
    write_plugin("bare", BARE)
    start
    bare = plugin("bare")

    assert_raises(ArgumentError) { bare.http_get("https://example.com/") }
    config = bare.bot_config
    assert_equal "Gemdrop", config["nick"]
    refute config.key?("data_file")
    assert bare.primary?
    assert_equal ["default"], bare.networks
    assert_equal "Example", bare.network_name
    assert bare.rate_limit("k", limit: 2, per: 60)
    assert bare.rate_limit("k", limit: 2, per: 60)
    refute bare.rate_limit("k", limit: 2, per: 60)
  end

  # --- several networks -----------------------------------------------------------------

  NETWORKS = <<~YAML.freeze
    nick: Gemdrop
    require_secure_users: false
    networks:
      One:
        server: one.example.net
        channels: ["#a"]
      Two:
        server: two.example.net
        channels: ["#b"]
    plugins:
      relay:
        networks: [One, Two]
        network_settings:
          Two:
            prefix: "!"
      onlyone:
        networks: [one]
  YAML

  RELAY = <<~RUBY.freeze
    class Relay < Gemdrop::Plugin
      on(:message) do |event|
        other = (networks - [network]).first
        on_network(other)&.say(other == "One" ? "#a" : "#b", "<\#{event.nick}@\#{network}> \#{event.text}")
      end
    end
  RUBY

  def test_plugin_settings_per_network
    path = File.join(@tmpdir, "networks.yml")
    File.write(path, NETWORKS, perm: 0o600)
    one, two = Gemdrop::Config.load(path)["networks"]

    assert_nil one["plugins"]["relay"]["prefix"]
    assert_equal "!", two["plugins"]["relay"]["prefix"]
    assert one["plugins"]["onlyone"]["enabled"]
    refute two["plugins"]["onlyone"]["enabled"]

    File.write(path, NETWORKS.sub("networks: [one]", "networks: [Three]"), perm: 0o600)
    assert_raises(Gemdrop::ConfigError) { Gemdrop::Config.load(path) }.then { |e| assert_match(/no network Three/, e.message) }
  end

  def test_plugins_reach_other_networks
    write_plugin("relay", RELAY)
    path = File.join(@tmpdir, "networks.yml")
    File.write(path, "#{NETWORKS}plugins_dir: #{@plugins_dir}\n", perm: 0o600)
    conns = {}
    supervisor = Gemdrop::Supervisor.new(Gemdrop::Config.load(path), store: @store, hasher: TEST_HASHER,
                                                                   connection_factory: ->(net) { conns[net["id"]] = FakeConnection.new },
                                                                   logger: Logger.new(@log))
    %w[One Two].each do |id|
      supervisor.bot(id).handle(":server 001 Gemdrop :Welcome")
      supervisor.bot(id).handle(":Gemdrop!b@h JOIN #{id == 'One' ? '#a' : '#b'}")
    end

    supervisor.bot("One").handle(":alice!a@a.host PRIVMSG #a :hello there")
    deadline = Time.now + 5
    sleep 0.01 until conns["Two"].lines.include?("PRIVMSG #b :<alice@One> hello there") || Time.now > deadline
    assert_includes conns["Two"].lines, "PRIVMSG #b :<alice@One> hello there"
    assert_equal %w[One Two], supervisor.bot("One").send(:plugin_manager).plugin("relay").networks
    refute supervisor.bot("Two").send(:plugin_manager).plugin("relay").primary?
  end

  # --- the example plugins ----------------------------------------------------------------

  def example(name) = File.read(File.expand_path("../contrib/plugins/#{name}.rb", __dir__))

  def test_ops_example
    install_plugins(@plugins_dir, "chanserv") # CHANREGISTER, ACCESS
    write_plugin("ops", example("ops"))
    start(%(plugins:\n  ops:\n    prefix: "!"\n))
    register("root")
    register("alice")
    register("bob")
    say("root", "CHANREGISTER #chan root")
    say("root", "ACCESS #chan ADD alice op")
    say("root", "ACCESS #chan ADD bob op")
    @bot.handle(":bob!bob@bob.host JOIN #chan") # same user@host bob identified from
    @bot.handle(":mallory!~mal@evil.example JOIN #chan")
    @conn.clear

    say_in("#chan", "alice", "!kb mallory spam")
    say_in("#chan", "alice", "!k bob")
    say_in("#chan", "carol", "!kick mallory")
    say("alice", "TOPIC #chan Welcome all")
    assert_equal ["MODE #chan +b *!*mal@evil.example", "KICK #chan mallory :spam (alice)", "TOPIC #chan :Welcome all"],
                 @conn.lines.grep(/\A(MODE|KICK|TOPIC) /)
    assert_includes notices_to("alice"), "bob has equal or higher access on #chan."
    assert_equal ["You must IDENTIFY first."], notices_to("carol")
  end

  def test_chanlog_example
    write_plugin("chanlog", example("chanlog"))
    start
    @bot.handle(":alice!a@alice.example PRIVMSG #chan :hello")
    @bot.handle(":alice!a@alice.example PRIVMSG #chan :\x01ACTION waves\x01")
    plugin("chanlog").say("#chan", "hi alice")
    @bot.handle(":alice!a@alice.example QUIT :bye")

    log = File.read(Dir.glob(File.join(@tmpdir, "data/plugins/chanlog/#chan.*.log")).first)
    lines = log.lines.map { |line| line.split(" ", 2).last.chomp }
    assert_equal ["--> Gemdrop (bot@host) joined", "<alice> hello", "* alice waves", "<Gemdrop> hi alice",
                  "<-- alice quit (bye)"], lines
  end

  def test_relay_example
    write_plugin("relay", example("relay"))
    path = File.join(@tmpdir, "relay.yml")
    File.write(path, <<~YAML, perm: 0o600)
      nick: Gemdrop
      plugins_dir: #{@plugins_dir}
      networks:
        IRCnet:
          server: one.example.net
          channels: ["#linux.se"]
        EFnet:
          server: two.example.net
          channels: ["#gunnit"]
      plugins:
        relay:
          links:
            - ["IRCnet/#linux.se", "EFnet/#gunnit"]
    YAML
    conns = {}
    supervisor = Gemdrop::Supervisor.new(Gemdrop::Config.load(path), store: @store, hasher: TEST_HASHER,
                                                                   connection_factory: ->(net) { conns[net["id"]] = FakeConnection.new },
                                                                   logger: Logger.new(@log))
    { "IRCnet" => "#linux.se", "EFnet" => "#gunnit" }.each do |id, channel|
      supervisor.bot(id).handle(":server 001 Gemdrop :Welcome")
      supervisor.bot(id).handle(":Gemdrop!b@h JOIN #{channel}")
    end

    supervisor.bot("EFnet").handle(":zphinx!z@z.host PRIVMSG #gunnit :hello from efnet")
    supervisor.bot("IRCnet").handle(":alice!a@a.host PRIVMSG #linux.se :\x01ACTION waves\x01")
    deadline = Time.now + 5
    sleep 0.01 until (conns["IRCnet"].lines.grep(/hello/).any? && conns["EFnet"].lines.grep(/waves/).any?) || Time.now > deadline
    assert_includes conns["IRCnet"].lines, "PRIVMSG #linux.se :[EFnet] <zphinx> hello from efnet"
    assert_includes conns["EFnet"].lines, "PRIVMSG #gunnit :[IRCnet] * alice waves"
  end

  def test_relay_rejects_bad_links
    write_plugin("relay", example("relay"))
    start(%(plugins:\n  relay:\n    links: [["default/#chan", "Nowhere/#x"]]\n))
    assert_match(/isn't on a network called Nowhere/, @bot.send(:plugin_manager).status["relay"]["error"])
  end
end

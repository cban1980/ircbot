require "test_helper"

# Channel services and CTCP answers as plugins (contrib/plugins/chanserv.rb,
# ctcp.rb): what holds when they are loaded, unloaded or set up.
class ChannelPluginsTest < Minitest::Test
  include StoreHelper

  def setup
    super
    @plugins_dir = install_plugins(File.join(@tmpdir, "plugins"), "chanserv", "ctcp")
    Gemdrop::Accounts.new(@store, TEST_HASHER).register("root", "password123")
    Gemdrop::Accounts.new(@store, TEST_HASHER).register("alice", "password123")
  end

  def start(plugins = "")
    path = File.join(@tmpdir, "config.yml")
    File.write(path, <<~YAML + plugins, perm: 0o600)
      server: irc.example.net
      nick: Gemdrop
      admins: [root]
      channels: ["#home"]
      require_secure_users: false
    YAML
    @now = 0
    @conn = FakeConnection.new
    @bot = Gemdrop::Bot.new(Gemdrop::Config.load(path), config_path: path, connection: @conn, store: @store,
                                                         hasher: TEST_HASHER, clock: -> { @now }, logger: Logger.new(nil))
    @bot.handle(":server 001 Gemdrop :Welcome")
    @bot.handle(":Gemdrop!bot@host JOIN #home")
  end

  def say(nick, text)
    @now += 31 # clear of the per-host command limit
    @conn.clear
    @bot.handle(":#{nick}!#{nick}@#{nick}.host PRIVMSG Gemdrop :#{text}")
    @conn.lines.grep(/\ANOTICE #{nick} :/).map { |l| l.split(" :", 2).last }
  end

  def manager = @bot.send(:plugin_manager)

  def test_unloading_chanserv_keeps_the_data_and_the_channels
    start
    say("root", "IDENTIFY password123")
    say("root", "CHANREGISTER #club alice")
    @bot.handle(":Gemdrop!bot@host JOIN #club")
    say("root", "ACCESS #club ADDMASK *!*bob@bob.example voice")

    say("root", "PLUGIN UNLOAD chanserv")
    assert_equal ["Unknown command."], say("root", "ACCESS #club LIST")
    @conn.clear
    @bot.handle(":bob!bob@bob.example JOIN #club")
    assert_empty @conn.lines.grep(/MODE/), "no automatic modes without channel services"

    registry = Gemdrop::Channels.new(@store)
    assert registry.registered?("#club")
    assert_equal [["*!*bob@bob.example", "voice", "root"]], registry.masks("#club")
    @bot.send(:reset_state)
    @bot.handle(":server 001 Gemdrop :Welcome")
    assert_includes @conn.lines, "JOIN #club", "registered channels are still joined"

    @bot.handle(":Gemdrop!bot@host JOIN #club")
    say("root", "IDENTIFY password123")
    say("root", "PLUGIN LOAD chanserv")
    @conn.clear
    @bot.handle(":bob!bob@bob.example JOIN #club")
    assert_includes @conn.lines, "MODE #club +v bob", "back with the same data"
  end

  def test_chanserv_commands_in_help
    install_plugins(@plugins_dir, "help")
    start
    say("root", "IDENTIFY password123")
    groups = say("root", "LIST").first
    assert_includes groups, "Channel (9)"
    assert_equal "CHANREGISTER <#chan> <owner>: register a channel with the bot. Bot admins; " \
                 "/msg Gemdrop CHANREGISTER. (chanserv plugin)", say("root", "HELP chanregister").first
    assert_equal ["No help for chanregister. LIST shows the command groups."], say("alice", "HELP chanregister"),
                 "admin-only commands are hidden from others"
  end

  def test_replies_strip_formatting_from_echoed_input
    start
    say("root", "IDENTIFY password123")
    assert_equal ["#badx is not registered."], say("root", "UP #bad\x02x")
  end

  def test_no_ctcp_answers_without_the_plugin
    start
    @bot.handle(":alice!a@a.host PRIVMSG Gemdrop :\x01VERSION\x01")
    assert_includes @conn.lines, "NOTICE alice :\x01VERSION Gemdrop (Ruby)\x01"

    File.delete(File.join(@plugins_dir, "ctcp.rb"))
    @bot.reload_config
    @conn.clear
    @now += 31
    @bot.handle(":alice!a@a.host PRIVMSG Gemdrop :\x01VERSION\x01")
    assert_empty @conn.lines
  end

  def test_ctcp_settings_and_clientinfo
    File.write(File.join(@plugins_dir, "finger.rb"), <<~RUBY, perm: 0o600)
      class Finger < Gemdrop::Plugin
        ctcp_handler("FINGER") { |_e| "no fingering" }
      end
    RUBY
    start(%(plugins:\n  ctcp:\n    version: "Linuks 2.0"\n    answer: [VERSION, CLIENTINFO]\n))
    replies = lambda do |ctcp|
      @now += 31
      @conn.clear
      @bot.handle(":alice!a@a.host PRIVMSG Gemdrop :\x01#{ctcp}\x01")
      @conn.lines.grep(/\ANOTICE alice/).map { |l| l.split(" :", 2).last.delete("\x01") }
    end
    assert_equal ["VERSION Linuks 2.0"], replies.call("VERSION")
    assert_empty replies.call("TIME 1"), "TIME is turned off"
    assert_equal ["CLIENTINFO ACTION VERSION CLIENTINFO FINGER"], replies.call("CLIENTINFO")
  end

  def test_ctcp_rejects_unknown_answers
    start(%(plugins:\n  ctcp:\n    answer: [VERSION, DCC]\n))
    assert_match(/unknown CTCP DCC/, manager.status["ctcp"]["error"])
  end

end

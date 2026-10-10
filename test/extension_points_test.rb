require "test_helper"
require "stringio"

# Plugin extension points that need nothing from the core per plugin:
# private conversations (private_text) and IRCv3 capabilities (wants_cap).
class ExtensionPointsTest < Minitest::Test
  include StoreHelper

  CHAT = <<~RUBY.freeze
    class Chat < Gemdrop::Plugin
      private_text { |ctx, words| ctx.reply_privately("heard \#{words.size}: \#{ctx.text}") }
    end
  RUBY

  CAPS = <<~RUBY.freeze
    class Caps < Gemdrop::Plugin
      wants_cap "account-notify", "server-time"
      command("CAPS") { |ctx, _args| ctx.reply_privately(caps.sort.join(",") + (cap?("server-time") ? " st" : "")) }
    end
  RUBY

  def setup
    super
    @plugins_dir = File.join(@tmpdir, "plugins")
    Dir.mkdir(@plugins_dir, 0o700)
    @log = StringIO.new
  end

  def write_plugin(name, source) = File.write(File.join(@plugins_dir, "#{name}.rb"), source, perm: 0o600)

  def start(welcome: true)
    path = File.join(@tmpdir, "config.yml")
    File.write(path, "server: irc.example.net\nnick: Gemdrop\nrequire_secure_users: false\n", perm: 0o600)
    @now = 0
    @conn = FakeConnection.new
    @bot = Gemdrop::Bot.new(Gemdrop::Config.load(path), config_path: path, connection: @conn, store: @store,
                                                         hasher: TEST_HASHER, clock: -> { @now }, logger: Logger.new(@log))
    @bot.send(:register_connection)
    @bot.handle(":server 001 Gemdrop :Welcome") if welcome
  end

  def say(nick, text)
    @now += 31
    @conn.clear
    @bot.handle(":#{nick}!#{nick}@#{nick}.host PRIVMSG Gemdrop :#{text}")
    @conn.lines.grep(/\ANOTICE #{nick} :/).map { |l| l.split(" :", 2).last }
  end

  # --- private conversations -------------------------------------------------------------------

  def test_private_text_gets_what_isnt_a_command
    write_plugin("chat", CHAT)
    start
    assert_equal ["heard 3: hello there you"], say("alice", "hello there you")
    assert_equal ["You are not identified."], say("alice", "WHOAMI"), "commands still work"
  end

  def test_without_a_handler_its_unknown
    start
    assert_equal ["Unknown command."], say("alice", "hello")
  end

  def test_text_like_a_password_command_never_reaches_plugins
    write_plugin("chat", CHAT)
    start
    %w[identfy idnetify regsiter pasword passwrd logn auht /identify].each do |typo|
      assert_equal ["Unknown command."], say("alice", "#{typo} hunter2"), typo
    end
    %w[both math logo hello].each do |word|
      assert_equal ["heard 2: #{word} there"], say("alice", "#{word} there"), "#{word} is just chat"
    end
  end

  def test_one_plugin_handles_private_text
    write_plugin("chat", CHAT)
    write_plugin("other", CHAT.sub("class Chat", "class Other"))
    start
    status = @bot.send(:plugin_manager).status
    errors = status.values.filter_map { |info| info["error"] }
    assert_equal 1, errors.size
    assert_match(/private chat is already handled by plugin/, errors.first)
  end

  # --- capabilities ------------------------------------------------------------------------------

  def test_no_cap_negotiation_unless_a_plugin_wants_one
    start(welcome: false)
    assert_equal ["NICK Gemdrop", "USER gemdrop 0 * :Gemdrop IRC bot"], @conn.lines
  end

  def test_negotiates_wanted_caps_at_registration
    write_plugin("caps", CAPS)
    start(welcome: false)
    assert_equal ["CAP LS 302", "NICK Gemdrop", "USER gemdrop 0 * :Gemdrop IRC bot"], @conn.lines
    @conn.clear
    @bot.handle(":irc.test CAP * LS * :multi-prefix sasl=PLAIN account-notify")
    assert_empty @conn.lines, "waits for the last LS line"
    @bot.handle(":irc.test CAP * LS :server-time away-notify")
    assert_equal ["CAP REQ :account-notify server-time"], @conn.lines
    @conn.clear
    @bot.handle(":irc.test CAP * ACK :account-notify server-time")
    assert_equal ["CAP END"], @conn.lines
    @bot.handle(":server 001 Gemdrop :Welcome")
    assert_equal ["account-notify,server-time st"], say("alice", "CAPS")
  end

  def test_ends_negotiation_when_nothing_is_offered_or_refused
    write_plugin("caps", CAPS)
    start(welcome: false)
    @conn.clear
    @bot.handle(":irc.test CAP * LS :multi-prefix")
    assert_equal ["CAP END"], @conn.lines

    start(welcome: false)
    @bot.handle(":irc.test CAP * LS :account-notify")
    @conn.clear
    @bot.handle(":irc.test CAP * NAK :account-notify")
    assert_equal ["CAP END"], @conn.lines
  end

  def test_a_server_without_cap_registers_anyway
    write_plugin("caps", CAPS)
    start(welcome: false)
    @conn.clear
    @now += Gemdrop::Bot::CAP_TIMEOUT + 1
    @bot.send(:check_caps)
    assert_equal ["CAP END"], @conn.lines, "stops waiting for an answer"
    @bot.handle(":server 001 Gemdrop :Welcome")
    @conn.clear
    @bot.send(:check_caps)
    assert_empty @conn.lines, "and doesn't keep asking"
  end

  def test_plugins_loaded_later_get_their_caps
    start
    write_plugin("caps", CAPS)
    @bot.reload_config
    @conn.clear
    @bot.send(:check_caps)
    assert_equal ["CAP LS 302"], @conn.lines
    @conn.clear
    @bot.handle(":irc.test CAP Gemdrop LS :server-time")
    assert_equal ["CAP REQ :server-time"], @conn.lines
    @conn.clear
    @bot.handle(":irc.test CAP Gemdrop ACK :server-time")
    assert_empty @conn.lines, "no CAP END after registration"
    assert @bot.cap?("server-time")
  end
end

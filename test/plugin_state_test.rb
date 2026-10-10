require "test_helper"
require "stringio"
require "open3"

# What admins change about plugins at runtime is remembered per network
# across restarts: PLUGIN UNLOAD/LOAD and PLUGIN SET/UNSET.
class PluginStateTest < Minitest::Test
  include StoreHelper

  GREETER = <<~RUBY.freeze
    class Greeter < Gemdrop::Plugin
      setting "greeting", default: "Hello", type: :string
      setting "times", default: 1, type: :integer, min: 1, max: 3
      setting "rooms", default: [], type: :list
      setting "api_key", type: :string
      def setup
        raise Gemdrop::Error, "greeting can't be BOOM" if settings["greeting"] == "BOOM"
      end
      command("GREET") { |ctx, _args| ctx.reply(([settings["greeting"]] * settings["times"]).join(" ")) }
    end
  RUBY

  def setup
    super
    @plugins_dir = File.join(@tmpdir, "plugins")
    Dir.mkdir(@plugins_dir, 0o700)
    File.write(File.join(@plugins_dir, "greeter.rb"), GREETER, perm: 0o600)
    @log = StringIO.new
    @config_path = File.join(@tmpdir, "config.yml")
    write_config("")
  end

  def write_config(plugins)
    File.write(@config_path, <<~YAML + plugins, perm: 0o600)
      server: irc.example.net
      nick: Gemdrop
      admins: [root]
      require_secure_users: false
    YAML
  end

  # A fresh bot on the same data file, as after a restart.
  def start
    @conn = FakeConnection.new
    logger = Logger.new(@log)
    logger.level = Logger::DEBUG
    @bot = Gemdrop::Bot.new(Gemdrop::Config.load(@config_path), config_path: @config_path, connection: @conn,
                                                                store: @store, hasher: TEST_HASHER, logger: logger)
    @bot.handle(":server 001 Gemdrop :Welcome")
    Gemdrop::Accounts.new(@store, TEST_HASHER).register("root", "password123") unless Gemdrop::Accounts.new(@store, TEST_HASHER).canonical("root")
    admin("IDENTIFY password123")
    @conn.clear
  end

  def admin(text) = @bot.handle(":root!r@root.host PRIVMSG Gemdrop :#{text}")
  def replies = @conn.lines.grep(/\ANOTICE root :/).map { |l| l.split(" :", 2).last }
  def plugins = @bot.send(:plugin_manager)
  def loaded?(name = "greeter") = plugins.status.dig(name, "state") == "loaded"

  def greet
    @conn.clear
    @bot.handle(":alice!a@a.host PRIVMSG Gemdrop :GREET")
    @conn.lines.grep(/\ANOTICE alice :/).map { |l| l.split(" :", 2).last }.first
  end

  def test_parse_value
    parse = ->(text) { Gemdrop::PluginState.parse_value(text) }
    assert_equal [true, false, nil, 5, -2, 1.5], %w[true false null 5 -2 1.5].map(&parse)
    assert_equal ["#linux.se", "#gunnit", 3], parse.call("[#linux.se, #gunnit, 3]")
    assert_equal "two words", parse.call(%("two words"))
    assert_equal "!", parse.call("!")
    assert_equal({ "a" => 1 }, parse.call("{a: 1}"))
    assert_equal [], parse.call("[]")
  end

  def test_unload_is_remembered_across_restarts_until_loaded
    start
    admin("PLUGIN UNLOAD greeter")
    assert_match(/stays unloaded here, also after restarts/, replies.last)

    start # restart
    refute loaded?
    assert plugins.status["greeter"]["kept_unloaded"]
    @bot.reload_config
    refute loaded?, "a config reload doesn't bring it back either"

    admin("PLUGIN LOAD greeter")
    start
    assert loaded?
  end

  def test_set_reloads_saves_and_survives_restarts
    start
    admin("PLUGIN SET greeter greeting Hi there")
    assert_equal "greeter: greeting = \"Hi there\" saved for default; plugin reloaded.", replies.last
    assert_equal "Hi there", greet

    admin("PLUGIN SET greeter times 2")
    start
    assert_equal "Hi there Hi there", greet

    @conn.clear
    admin("PLUGIN SETTINGS greeter")
    assert_includes replies, "greeter: greeting = \"Hi there\" (saved with PLUGIN SET)"
    assert_includes replies, "greeter: times = 2 (saved with PLUGIN SET)"
    assert_includes replies, "greeter: private = true"
  end

  def test_saved_settings_override_config_and_unset_restores_it
    write_config(%(plugins:\n  greeter:\n    greeting: Howdy\n))
    start
    assert_equal "Howdy", greet

    admin("PLUGIN SET greeter greeting Hej")
    assert_equal "Hej", greet
    admin("PLUGIN UNSET greeter greeting")
    assert_equal "Howdy", greet
    admin("PLUGIN UNSET greeter greeting")
    assert_equal "greeter has no saved greeting on default.", replies.last
  end

  def test_bad_values_are_not_saved
    start
    admin("PLUGIN SET greeter times 9")
    assert_equal "times must be at most 3.", replies.last
    admin("PLUGIN SET greeter prefix go")
    assert_match(/prefix must be 1-3 symbols/, replies.last)
    admin("PLUGIN SET greeter enabled false")
    assert_equal "enabled can only be changed in config.yml.", replies.last

    admin("PLUGIN SET greeter greeting BOOM")
    assert_match(/\ANot saved: greeter failed to load: greeting can't be BOOM/, replies.last)
    assert loaded?, "the previous version keeps running"
    assert_equal "Hello", greet
    assert_empty Gemdrop::PluginState.new(@store).settings("greeter")
  end

  def test_bot_options_can_be_set_too
    start
    admin("PLUGIN SET greeter prefix !")
    @conn.clear
    @bot.handle(":alice!a@a.host PRIVMSG #chan :!greet")
    assert_includes @conn.lines, "PRIVMSG #chan :Hello"
  end

  def test_secret_settings_are_hidden
    File.write(File.join(@plugins_dir, "spy.rb"), <<~RUBY, perm: 0o600)
      class Spy < Gemdrop::Plugin
        attr_reader :seen
        on(:line) { |e| (@seen ||= []) << e.message.params.last.to_s }
      end
    RUBY
    start
    admin("PLUGIN SET greeter api_key sekrit123")

    assert_equal "greeter: api_key = (hidden) saved for default; plugin reloaded.", replies.last
    refute_includes @log.string, "sekrit123"
    refute((plugins.plugin("spy").seen || []).any? { |text| text.include?("sekrit123") })
    assert_equal "sekrit123", Gemdrop::PluginState.new(@store).settings("greeter")["api_key"]
  end

  def test_state_is_per_network
    path = File.join(@tmpdir, "networks.yml")
    File.write(path, <<~YAML, perm: 0o600)
      nick: Gemdrop
      admins: [root]
      require_secure_users: false
      plugins_dir: #{@plugins_dir}
      networks:
        One:
          server: one.example.net
        Two:
          server: two.example.net
    YAML
    Gemdrop::Accounts.new(@store, TEST_HASHER).register("root", "password123")
    supervisor = lambda do
      Gemdrop::Supervisor.new(Gemdrop::Config.load(path), store: @store, hasher: TEST_HASHER,
                                                        connection_factory: ->(_net) { FakeConnection.new },
                                                        logger: Logger.new(nil))
    end
    sup = supervisor.call
    one = sup.bot("One")
    one.handle(":server 001 Gemdrop :Welcome")
    one.handle(":root!r@root.host PRIVMSG Gemdrop :IDENTIFY password123")
    one.handle(":root!r@root.host PRIVMSG Gemdrop :PLUGIN UNLOAD greeter")
    Gemdrop::PluginState.new(@store, network: "Two").set("greeter", "greeting", "Moi")

    sup = supervisor.call # restart
    refute_equal "loaded", sup.bot("One").send(:plugin_manager).status.dig("greeter", "state")
    assert_equal "Moi", sup.bot("Two").send(:plugin_manager).plugin("greeter").settings["greeting"]
  end

  # The tool opens the data file and pepper named in the config, so the
  # bot here uses the same ones.
  def test_command_line_tool
    File.write(@config_path, File.read(@config_path) + "data_file: tooldata/gemdrop.json\n", perm: 0o600)
    config = Gemdrop::Config.load(@config_path)
    @conn = FakeConnection.new
    @bot = Gemdrop::Bot.new(config, config_path: @config_path, connection: @conn, logger: Logger.new(nil),
                                   hasher: Gemdrop::PasswordHasher.new(pepper: Gemdrop::Pepper.load(path: config["pepper_file"]), log_n: 4))
    @bot.handle(":server 001 Gemdrop :Welcome")
    tool = File.expand_path("../bin/gemdrop-account", __dir__)
    run = ->(*args) { Open3.capture2e("ruby", tool, "-c", @config_path, *args) }

    out, status = run.call("plugin-set", "greeter", "greeting", "From", "the", "shell")
    assert status.success?, out
    assert_match(/default: greeter greeting = "From the shell"/, out)
    out, = run.call("plugin-unload", "greeter")
    assert_match(/kept unloaded/, out)
    out, = run.call("plugin-settings", "greeter")
    assert_match(/default: \(kept unloaded\)/, out)
    assert_match(/greeting = "From the shell"  \(saved\)/, out)

    @bot.reload_config
    refute loaded?
    run.call("plugin-load", "greeter")
    @bot.reload_config
    assert_equal "From the shell", greet

    out, status = run.call("plugin-set", "greeter", "enabled", "false")
    refute status.success?
    assert_match(/only be changed in config.yml/, out)
  end
end

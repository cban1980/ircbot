require "test_helper"
require "stringio"

# Plugins: loading from the folder, per-plugin command settings, reloading
# while connected, isolation of failures, and the PLUGIN admin command.
class PluginTest < Minitest::Test
  include StoreHelper

  ECHO = <<~RUBY.freeze
    class Echo < IRCBot::Plugin
      description "Repeats text"
      command "ECHO", usage: "ECHO <text>", help: "repeat text" do |ctx, args|
        ctx.usage! if args.empty?
        ctx.reply(args.join(" "))
      end
    end
  RUBY

  def setup
    super
    @plugins_dir = File.join(@tmpdir, "plugins")
    Dir.mkdir(@plugins_dir, 0o700)
    @log = StringIO.new
  end

  def write_plugin(name, source)
    File.write(File.join(@plugins_dir, "#{name}.rb"), source, perm: 0o600)
  end

  def config_yaml(plugins)
    <<~YAML + plugins
      server: irc.example.net
      nick: ModeBot
      admins: [root]
      channels: ["#chan"]
      require_secure_users: false
    YAML
  end

  def start(plugins = "")
    @config_path = File.join(@tmpdir, "config.yml")
    File.write(@config_path, config_yaml(plugins), perm: 0o600)
    @conn = FakeConnection.new
    @bot = IRCBot::Bot.new(IRCBot::Config.load(@config_path), config_path: @config_path, connection: @conn,
                                                                store: @store, hasher: TEST_HASHER, logger: Logger.new(@log))
    @bot.handle(":server 001 ModeBot :Welcome")
    @bot.handle(":ModeBot!bot@host JOIN #chan")
    @conn.clear
  end

  def reconfigure(plugins)
    File.write(@config_path, config_yaml(plugins), perm: 0o600)
    assert @bot.reload_config
  end

  def say(nick, text) = @bot.handle(":#{nick}!#{nick}@#{nick}.host PRIVMSG ModeBot :#{text}")
  def say_in(channel, nick, text) = @bot.handle(":#{nick}!#{nick}@#{nick}.host PRIVMSG #{channel} :#{text}")
  def notices_to(nick) = @conn.lines.grep(/\ANOTICE #{nick} :/).map { |l| l.split(" :", 2).last }
  def plugin_status = @bot.send(:instance_variable_get, :@plugins).status
  def plugin_instance(name) = @bot.send(:instance_variable_get, :@plugins).instance_variable_get(:@loaded)[name].plugin
  def plugin_instance_loaded?(name) = plugin_status.dig(name, "state") == "loaded"

  def identify_admin
    IRCBot::Accounts.new(@store, TEST_HASHER).register("root", "password123")
    say("root", "IDENTIFY password123")
    @conn.clear
  end

  # --- commands and their per-plugin settings ---------------------------------

  def test_private_command_by_default_but_not_in_channels
    write_plugin("echo", ECHO)
    start

    say("alice", "echo hello there")
    assert_equal ["hello there"], notices_to("alice")

    @conn.clear
    say_in("#chan", "alice", "!echo hello")
    assert_empty @conn.lines
  end

  def test_prefix_enables_channel_commands
    write_plugin("echo", ECHO)
    start(%(plugins:\n  echo:\n    prefix: "!"\n))

    say_in("#chan", "alice", "!ECHO hi all")
    assert_equal ["PRIVMSG #chan :hi all"], @conn.lines

    @conn.clear
    say_in("#chan", "alice", "!echo")
    assert_equal ["Usage: !ECHO <text>"], notices_to("alice")
  end

  def test_channel_only_plugin_and_channel_limit
    write_plugin("echo", ECHO)
    start(%(plugins:\n  echo:\n    prefix: "."\n    private: false\n    channels: ["#chan"]\n))

    say("alice", "ECHO hi")
    assert_equal ["Unknown command. Try HELP."], notices_to("alice")

    @bot.handle(":ModeBot!bot@host JOIN #other")
    @conn.clear
    say_in("#other", "alice", ".echo hi")
    say_in("#chan", "alice", ".echo hi")
    assert_equal ["PRIVMSG #chan :hi"], @conn.lines
  end

  def test_help_lists_plugin_commands
    write_plugin("echo", ECHO)
    start(%(plugins:\n  echo:\n    prefix: "!"\n))

    say("alice", "HELP")
    assert_includes notices_to("alice"), "Plugin commands:"
    assert(notices_to("alice").any? { |l| l.include?("ECHO <text>") && l.include?("(also !echo in channels)") })
  end

  def test_admin_and_identified_requirements
    write_plugin("secret", <<~RUBY)
      class Secret < IRCBot::Plugin
        command("SHUTDOWNX", admin: true) { |ctx, _| ctx.reply("ok \#{ctx.account}") }
        command("MINE", identified: true) { |ctx, _| ctx.reply("you are \#{ctx.account}") }
      end
    RUBY
    start
    say("bob", "MINE")
    assert_equal ["You must IDENTIFY first."], notices_to("bob")

    identify_admin
    say("root", "SHUTDOWNX")
    assert_equal ["ok root"], notices_to("root")
  end

  def test_settings_reach_the_plugin
    write_plugin("greet", <<~RUBY)
      class Greet < IRCBot::Plugin
        defaults "greeting" => "Hello", "punctuation" => "."
        command("GREET") { |ctx, _| ctx.reply(settings["greeting"] + settings["punctuation"]) }
      end
    RUBY
    start(%(plugins:\n  greet:\n    greeting: Howdy\n))

    say("alice", "GREET")
    assert_equal ["Howdy."], notices_to("alice")
  end

  # --- loading and reloading --------------------------------------------------------

  def test_config_reload_loads_new_and_changed_files_without_reconnecting
    start
    write_plugin("echo", ECHO)
    reconfigure("")
    say("alice", "ECHO one")
    assert_equal ["one"], notices_to("alice")

    write_plugin("echo", ECHO.sub("args.join(\" \")", "args.join(\"-\")"))
    reconfigure("")
    @conn.clear
    say("alice", "ECHO a b")
    assert_equal ["a-b"], notices_to("alice")
    refute @conn.closed
  end

  def test_broken_new_version_keeps_the_old_one_running
    write_plugin("echo", ECHO)
    start
    write_plugin("echo", "class Echo < IRCBot::Plugin\n  def broken(\nend\n")
    reconfigure("")

    say("alice", "ECHO still here")
    assert_equal ["still here"], notices_to("alice")
    assert_equal "loaded", plugin_status["echo"]["state"]
    assert_match(/SyntaxError/, plugin_status["echo"]["error"])
  end

  def test_removed_or_disabled_plugin_is_unloaded_with_teardown
    write_plugin("bye", <<~RUBY)
      class Bye < IRCBot::Plugin
        def teardown = say("#chan", "bye")
      end
    RUBY
    start
    reconfigure(%(plugins:\n  bye:\n    enabled: false\n))
    assert_equal ["PRIVMSG #chan :bye"], @conn.lines
    assert_equal "disabled", plugin_status["bye"]["state"]
  end

  def test_setting_change_reloads_the_plugin
    write_plugin("greet", <<~RUBY)
      class Greet < IRCBot::Plugin
        defaults "greeting" => "Hello"
        command("GREET") { |ctx, _| ctx.reply(settings["greeting"]) }
      end
    RUBY
    start
    reconfigure(%(plugins:\n  greet:\n    greeting: Moin\n))

    say("alice", "GREET")
    assert_equal ["Moin"], notices_to("alice")
  end

  def test_plugin_cannot_take_built_in_or_other_plugins_commands
    write_plugin("echo", ECHO)
    write_plugin("evil", "class Evil < IRCBot::Plugin\n  command('REGISTER') { |ctx, _| ctx.reply('gotcha') }\nend\n")
    write_plugin("echo2", ECHO.sub("class Echo", "class Echo2"))
    start

    assert_match(/built-in command/, plugin_status["evil"]["error"])
    assert_match(/already provided by plugin echo/, plugin_status["echo2"]["error"])
  end

  def test_refuses_a_folder_others_can_write
    write_plugin("echo", ECHO)
    File.chmod(0o777, @plugins_dir)
    start

    say("alice", "ECHO hi")
    assert_equal ["Unknown command. Try HELP."], notices_to("alice")
    assert_match(/writable by other users/, @log.string)
  end

  # --- failures stay inside the plugin ---------------------------------------------------

  def test_errors_in_commands_and_hooks_do_not_affect_the_bot
    write_plugin("boom", <<~RUBY)
      class Boom < IRCBot::Plugin
        command("BOOM") { |_ctx, _| raise "kaboom" }
        on(:join) { |_event| raise "hook kaboom" }
      end
    RUBY
    start

    say("alice", "BOOM")
    assert_equal ["Sorry, BOOM failed."], notices_to("alice")
    @bot.handle(":alice!alice@alice.host JOIN #chan")
    assert_match(/hook kaboom/, @log.string)

    @conn.clear
    @bot.handle("PING :x")
    assert_equal ["PONG :x"], @conn.lines
  end

  def test_output_cannot_inject_protocol_lines
    write_plugin("inject", <<~RUBY)
      class Inject < IRCBot::Plugin
        command("INJECT") { |ctx, _| ctx.reply("one\\r\\nQUIT :pwned\\0") }
      end
    RUBY
    start

    say("alice", "INJECT")
    assert_equal ["NOTICE alice :one", "NOTICE alice :QUIT :pwned"], @conn.lines
  end

  def test_output_while_disconnected_is_dropped
    write_plugin("hello", "class Hello < IRCBot::Plugin\n  def setup = @sent = say('#chan', 'hi')\nend\n")
    @conn = Object.new.tap { |c| c.define_singleton_method(:write) { |_| raise IOError, "not connected" } }
    config_path = File.join(@tmpdir, "config.yml")
    File.write(config_path, config_yaml(""), perm: 0o600)
    bot = IRCBot::Bot.new(IRCBot::Config.load(config_path), connection: @conn, store: @store,
                                                             hasher: TEST_HASHER, logger: Logger.new(@log))

    plugin = bot.send(:instance_variable_get, :@plugins).instance_variable_get(:@loaded)["hello"].plugin
    refute plugin.instance_variable_get(:@sent)
  end

  # --- events -------------------------------------------------------------------------

  def test_events_reach_hooks_but_password_lines_do_not
    write_plugin("spy", <<~RUBY)
      class Spy < IRCBot::Plugin
        on(:join) { |e| say("#chan", "join \#{e.nick} \#{e.channel}") }
        on(:message) { |e| say("#chan", "msg \#{e.nick}: \#{e.text}") }
        on(:line) { |e| say("#chan", "line \#{e.message.params.last}") if e.message.command == "PRIVMSG" }
      end
    RUBY
    start

    @bot.handle(":alice!alice@alice.host JOIN #chan")
    say_in("#chan", "alice", "hello")
    say("alice", "IDENTIFY hunter2")
    lines = @conn.lines.grep(/\APRIVMSG #chan/)
    assert_includes lines, "PRIVMSG #chan :join alice #chan"
    assert_includes lines, "PRIVMSG #chan :msg alice: hello"
    refute(lines.any? { |l| l.include?("hunter2") })
  end

  def test_timers_and_background_jobs_run_and_stop_on_unload
    write_plugin("tick", <<~RUBY)
      class Tick < IRCBot::Plugin
        command("TICK") do |_ctx, _args|
          after(0.01) { say("#chan", "timer") }
          background { say("#chan", "background") }
          every(60) { say("#chan", "every") }
        end
      end
    RUBY
    start
    say("alice", "TICK")
    deadline = Time.now + 2
    sleep 0.01 until @conn.lines.size >= 2 || Time.now > deadline
    assert_equal ["PRIVMSG #chan :background", "PRIVMSG #chan :timer"], @conn.lines.sort

    timers = plugin_instance("tick").instance_variable_get(:@timers)
    @bot.send(:instance_variable_get, :@plugins).unload("tick")
    sleep 0.05
    refute(timers.any?(&:alive?))
    refute plugin_instance_loaded?("tick")
  end

  # --- PLUGIN admin command --------------------------------------------------------------

  def test_plugin_command_is_admin_only
    start
    say("alice", "PLUGIN LIST")
    assert_equal ["You must IDENTIFY first."], notices_to("alice")
  end

  def test_admin_can_list_unload_and_load
    write_plugin("echo", ECHO)
    start
    identify_admin

    say("root", "PLUGIN LIST")
    assert_match(/\Aecho: loaded, commands ECHO \(private messages\)\. Repeats text\z/, notices_to("root").first)

    say("root", "PLUGIN UNLOAD echo")
    reconfigure("") # stays unloaded across config reloads
    say("alice", "ECHO hi")
    assert_equal ["Unknown command. Try HELP."], notices_to("alice")

    say("root", "PLUGIN LOAD echo")
    @conn.clear
    say("alice", "ECHO hi")
    assert_equal ["hi"], notices_to("alice")
  end

  def test_admin_reload_reports_failures
    start
    identify_admin
    write_plugin("bad", "class Bad\nend\n")

    say("root", "PLUGIN RELOAD")
    assert_equal ["Plugins reloaded. Loaded: none", "bad: failed to load: bad.rb defines no IRCBot::Plugin subclass at its top level"],
                 notices_to("root")
  end

  # --- storage and examples ------------------------------------------------------------

  def test_storage_persists_across_reloads
    write_plugin("counter", <<~RUBY)
      class Counter < IRCBot::Plugin
        command("COUNT") do |ctx, _|
          data.update { |d| d["n"] = d.fetch("n", 0) + 1 }
          ctx.reply(data["n"].to_s)
        end
      end
    RUBY
    start
    say("alice", "COUNT")
    identify_admin
    say("root", "PLUGIN RELOAD counter")
    @conn.clear
    say("alice", "COUNT")
    assert_equal ["2"], notices_to("alice")
    assert_equal 0o600, File.stat(File.join(@tmpdir, "data", "plugins", "counter.json")).mode & 0o777
  end

  def test_example_plugins_work
    examples = File.expand_path("../contrib/plugins", __dir__)
    write_plugin("dice", File.read(File.join(examples, "dice.rb")))
    start(%(plugins:\n  dice:\n    prefix: "!"\n))

    say_in("#chan", "alice", "!roll 3d6")
    assert_match(/\APRIVMSG #chan :alice rolls 3d6: \d+ \+ \d+ \+ \d+ = \d+\z/, @conn.lines.last)
  end

  def test_config_validates_plugin_sections
    path = File.join(@tmpdir, "bad.yml")
    { %(plugins:\n  Bad-Name: {}\n) => /lowercase/,
      %(plugins:\n  dice:\n    prefix: "go"\n) => /prefix must be/,
      %(plugins:\n  dice:\n    private: maybe\n) => /true or false/ }.each do |yaml, error|
      File.write(path, config_yaml(yaml), perm: 0o600)
      assert_raises(IRCBot::ConfigError) { IRCBot::Config.load(path) }.then { |e| assert_match(error, e.message) }
    end
  end
end

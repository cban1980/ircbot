require "test_helper"
require "stringio"

# Staying up and in channels: rejoining after kicks and failed joins,
# plugins surviving a broken reload, and a damaged data file.
class UptimeTest < Minitest::Test
  include StoreHelper

  def setup
    super
    @now = 0
    @log = StringIO.new
    @conn = FakeConnection.new
    config = Gemdrop::Config::DEFAULTS.merge(
      "server" => "irc.example.net", "nick" => "Gemdrop", "channels" => ["#home"],
      "status_file" => File.join(@tmpdir, "status.json"), "plugins_dir" => File.join(@tmpdir, "plugins")
    )
    @bot = Gemdrop::Bot.new(config, connection: @conn, store: @store, hasher: TEST_HASHER, clock: -> { @now },
                                   logger: Logger.new(@log))
    @bot.handle(":server 001 Gemdrop :Welcome")
    @bot.handle(":Gemdrop!bot@host JOIN #home")
    @conn.clear
  end

  def tick(seconds)
    @now += seconds
    @bot.send(:tick)
  end

  def joins = @conn.lines.grep(/\AJOIN /)

  # --- rejoining ---------------------------------------------------------------------

  def test_rejoins_after_a_kick_with_growing_delays
    @bot.handle(":op!o@host KICK #home Gemdrop :out")
    assert_match(/Kicked from #home by op \(out\)/, @log.string)
    tick(4)
    assert_empty joins
    tick(1)
    assert_equal ["JOIN #home"], joins

    @bot.handle(":Gemdrop!bot@host JOIN #home")
    @bot.handle(":op!o@host KICK #home Gemdrop :again")
    @conn.clear
    tick(9)
    assert_empty joins, "kicked again soon: waits longer"
    tick(1)
    assert_equal ["JOIN #home"], joins

    @bot.handle(":Gemdrop!bot@host JOIN #home")
    @now += Gemdrop::Bot::REJOIN_RESET
    @bot.send(:tick) # forgets the backoff once things are calm
    @bot.handle(":op!o@host KICK #home Gemdrop :later")
    @conn.clear
    tick(5)
    assert_equal ["JOIN #home"], joins
  end

  def test_failed_joins_are_logged_and_retried
    @bot.handle(":op!o@host KICK #home Gemdrop :out")
    tick(5)
    @bot.handle(":server 474 Gemdrop #home :Cannot join channel (+b)")
    assert_match(/Can't stay in #home: the bot is banned \(\+b\); joining again in 10s/, @log.string)
    @conn.clear
    tick(10)
    assert_equal ["JOIN #home"], joins

    @bot.handle(":server 437 Gemdrop #home :Nick/channel is temporarily unavailable")
    assert_match(/the channel is temporarily unavailable/, @log.string)
    refute(@conn.lines.any? { |l| l.start_with?("NICK") }, "a 437 for a channel isn't about the nick")
  end

  def test_delay_is_capped
    @bot.handle(":op!o@host KICK #home Gemdrop :out")
    12.times do
      tick(Gemdrop::Bot::REJOIN_MAX_DELAY)
      @bot.handle(":server 471 Gemdrop #home :Cannot join channel (+l)")
    end
    assert_match(/joining again in #{Gemdrop::Bot::REJOIN_MAX_DELAY}s\n\z/, @log.string)
  end

  def test_only_wanted_channels_are_rejoined
    @bot.handle(":Gemdrop!bot@host JOIN #visiting")
    @bot.handle(":op!o@host KICK #visiting Gemdrop :bye")
    @bot.handle(":server 473 Gemdrop #elsewhere :Cannot join channel (+i)")
    tick(60)
    assert_empty joins
  end

  def test_a_channel_dropped_meanwhile_is_not_rejoined
    Gemdrop::Accounts.new(@store, TEST_HASHER).register("alice", "password123")
    Gemdrop::Channels.new(@store).register("#reg", "alice")
    @bot.handle(":Gemdrop!bot@host JOIN #reg")
    @bot.handle(":op!o@host KICK #reg Gemdrop :bye")
    Gemdrop::Channels.new(@store).drop("#reg")
    tick(5)
    assert_empty joins
  end

  def test_plugin_channels_are_rejoined_with_their_key
    @bot.send(:plugin_join, "someplugin", "#secret", "hunter2")
    @bot.handle(":Gemdrop!bot@host JOIN #secret")
    @bot.handle(":op!o@host KICK #secret Gemdrop :bye")
    @conn.clear
    tick(5)
    assert_equal ["JOIN #secret hunter2"], joins
  end

  # --- plugins survive a broken reload ---------------------------------------------------

  def test_reload_with_failing_setup_keeps_the_old_version
    dir = File.join(@tmpdir, "plugins")
    Dir.mkdir(dir, 0o700)
    path = File.join(dir, "echo.rb")
    File.write(path, %(class Echo < Gemdrop::Plugin\n  command("ECHO") { |ctx, args| ctx.reply(args.join(" ")) }\nend\n), perm: 0o600)
    manager = @bot.send(:plugin_manager)
    @bot.send(:sync_plugins)
    assert_equal "loaded", manager.status["echo"]["state"]

    File.write(path, %(class Echo < Gemdrop::Plugin\n  def setup\n    raise Gemdrop::Error, "broken"\n  end\nend\n), perm: 0o600)
    @bot.send(:sync_plugins)
    assert_equal "loaded", manager.status["echo"]["state"]
    assert_equal "broken", manager.status["echo"]["error"]

    @conn.clear
    @bot.handle(":alice!a@a.host PRIVMSG Gemdrop :ECHO still here")
    assert_includes @conn.lines, "NOTICE alice :still here"
  end

  # --- the data file ---------------------------------------------------------------------

  def test_damaged_data_file_stops_startup_with_a_clear_message
    path = File.join(@tmpdir, "damaged.json")
    File.write(path, '{"accounts": {', perm: 0o600)
    error = assert_raises(Gemdrop::ConfigError) { Gemdrop::Store.new(path) }
    assert_match(/damaged\.json is damaged \(not valid JSON.*Restore it from a backup/, error.message)

    File.write(path, "[1, 2]", perm: 0o600)
    assert_raises(Gemdrop::ConfigError) { Gemdrop::Store.new(path) }.then { |e| assert_match(/JSON object/, e.message) }
  end

  def test_data_file_damaged_while_running_keeps_the_bot_going
    warnings = []
    @store.on_error = ->(message) { warnings << message }
    Gemdrop::Accounts.new(@store, TEST_HASHER).register("alice", "password123")
    path = File.join(@tmpdir, "data.json")
    File.write(path, "{ broken", perm: 0o600)

    accounts = Gemdrop::Accounts.new(@store, TEST_HASHER)
    assert accounts.canonical("alice"), "the data in memory is kept"
    assert accounts.canonical("alice")
    assert_equal 1, warnings.size, "reported once"
    assert_match(/Keeping the data in memory: .*is damaged/, warnings.first)

    accounts.register("bob", "password123") # the next save writes good data back
    assert_equal %w[alice bob], JSON.parse(File.read(path))["accounts"].keys.sort
  end

  def test_only_a_wrong_network_stops_a_network
    @bot.handle(":server 005 Gemdrop NETWORK=Example :are supported") # fine without a network setting
    @bot.send(:reset_state) # as after a reconnect: the welcome joins channels
    @store.stub(:read, ->(*) { raise Gemdrop::ConfigError, "data.json is not owned by this user" }) do
      @bot.handle(":server 001 Gemdrop :Welcome") # reads registered channels; logged, not raised
    end
    assert_match(/Dropped line.*not owned/, @log.string)

    wrong = Gemdrop::Bot.new(Gemdrop::Config::DEFAULTS.merge("server" => "x", "network" => "IRCnet",
                                                             "status_file" => File.join(@tmpdir, "wrong.json"),
                                                             "plugins_dir" => File.join(@tmpdir, "plugins")),
                            connection: FakeConnection.new, store: @store, hasher: TEST_HASHER, logger: Logger.new(nil))
    assert_raises(Gemdrop::WrongNetworkError) { wrong.handle(":server 005 Bot NETWORK=EFnet :are supported") }
  end
end

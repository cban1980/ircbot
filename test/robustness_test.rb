require "test_helper"
require "json"
require "stringio"
require "socket"
require "open3"

# Staying connected and recovering: dead links, stuck registration,
# fallback servers, unexpected errors, the watchdog, and clean shutdown.
class RobustnessTest < Minitest::Test
  include StoreHelper

  def setup
    super
    @now = 0
    @log = StringIO.new
  end

  def bot(overrides = {}, connection: FakeConnection.new)
    @conn = connection
    config = Rubicon::Config::DEFAULTS.merge("server" => "irc.example.net", "nick" => "ModeBot",
                                            "status_file" => File.join(@tmpdir, "status.json"),
                                            "plugins_dir" => File.join(@tmpdir, "plugins")).merge(overrides)
    @bot = Rubicon::Bot.new(config, connection: connection, store: @store, hasher: TEST_HASHER, clock: -> { @now },
                                   logger: Logger.new(@log))
  end

  def connected!
    @bot.instance_variable_set(:@link_since, @now)
    @bot.handle(":server 001 ModeBot :Welcome")
    @conn.clear
  end

  def tick_at(seconds)
    @now = seconds
    @bot.send(:tick)
  end

  def with_const(klass, name, value)
    old = klass.const_get(name)
    klass.send(:remove_const, name)
    klass.const_set(name, value)
    yield
  ensure
    klass.send(:remove_const, name)
    klass.const_set(name, old)
  end

  # --- dead links and stuck registration --------------------------------------------------

  def test_pings_a_quiet_server_and_drops_a_dead_link
    bot
    connected!
    tick_at(100)
    assert_empty @conn.lines
    tick_at(121)
    assert_equal ["PING :rubicon-alive"], @conn.lines
    tick_at(150)
    assert_equal 1, @conn.lines.size, "one ping, not one per tick"
    refute @conn.closed
    tick_at(212)
    assert @conn.closed
    assert_match(/Dropping the connection: nothing from the server for 212s/, @log.string)
  end

  def test_any_line_from_the_server_keeps_the_link
    bot
    connected!
    tick_at(121)
    @bot.handle(":server PONG server :rubicon-alive")
    tick_at(300)
    refute @conn.closed
    tick_at(330)
    assert_equal 2, @conn.lines.grep(/\APING/).size, "pings again after the next quiet spell"
  end

  def test_drops_a_server_that_never_finishes_registration
    bot
    @bot.instance_variable_set(:@link_since, 0)
    tick_at(80)
    refute @conn.closed
    tick_at(91)
    assert @conn.closed
    assert_match(/didn't finish registration within 90s/, @log.string)
  end

  # --- fallback servers --------------------------------------------------------------------

  def test_fallback_servers_are_validated
    path = File.join(@tmpdir, "c.yml")
    File.write(path, "server: a.example.net\nfallback_servers: [b.example.net, \"c.example.net:6667\"]\n", perm: 0o600)
    assert_equal %w[b.example.net c.example.net:6667], Rubicon::Config.load(path)["fallback_servers"]

    File.write(path, "server: a.example.net\nfallback_servers: [\"bad host\"]\n", perm: 0o600)
    assert_raises(Rubicon::ConfigError) { Rubicon::Config.load(path) }
    File.write(path, "server: a.example.net\nfallback_servers: [b.example.net]\ntls_fingerprint: #{'a' * 64}\n", perm: 0o600)
    assert_raises(Rubicon::ConfigError) { Rubicon::Config.load(path) }.then { |e| assert_match(/can't be used with fallback/, e.message) }
  end

  def test_moves_to_the_next_server_when_one_is_down
    down = TCPServer.new("127.0.0.1", 0)
    down_port = down.addr[1]
    down.close # nothing listens here now
    up = TCPServer.new("127.0.0.1", 0)
    config = Rubicon::Config::DEFAULTS.merge(
      "server" => "127.0.0.1", "port" => down_port, "fallback_servers" => ["127.0.0.1:#{up.addr[1]}"],
      "tls" => false, "allow_insecure" => true, "nick" => "ModeBot",
      "status_file" => File.join(@tmpdir, "status.json"), "plugins_dir" => File.join(@tmpdir, "plugins")
    )
    with_const(Rubicon::Bot, :RECONNECT_MIN, 0.1) do
      @bot = Rubicon::Bot.new(config, store: @store, hasher: TEST_HASHER, logger: Logger.new(@log))
      runner = Thread.new { @bot.run(handle_signals: false) }
      client = up.accept
      assert_match(/\ANICK ModeBot/, client.gets)
      assert_match(/Next attempt goes to 127.0.0.1:#{up.addr[1]}/, @log.string)
      @bot.stop("bye")
      assert runner.join(10)
      client.close
    end
  ensure
    up&.close
  end

  # --- unexpected errors, the watchdog, shutdown ---------------------------------------------

  # A connection whose first connect fails with a bug-like error.
  class FlakyConnection < FakeConnection
    attr_reader :connects

    def initialize = super() && (@connects = 0)
    def security = "test"

    def connect
      @connects += 1
      raise NoMethodError, "simulated bug" if @connects == 1
    end

    def gets = sleep(0.05) && nil # the server hangs up
  end

  def test_an_unexpected_error_reconnects_instead_of_stopping
    with_const(Rubicon::Bot, :RECONNECT_MIN, 0.05) do
      bot({}, connection: FlakyConnection.new)
      runner = Thread.new { @bot.run(handle_signals: false) }
      sleep 0.05 until @conn.connects >= 2 || !runner.alive?
      assert runner.alive?, "the network keeps going"
      assert_match(/Unexpected error; reconnecting: NoMethodError: simulated bug/, @log.string)
      @bot.stop("bye")
      assert runner.join(10)
    end
  end

  def test_watchdog_acts_when_the_bot_is_stuck
    fired = Queue.new
    old_action = Rubicon::Bot.watchdog_action
    Rubicon::Bot.watchdog_action = ->(stuck, _log) { fired << stuck.network_id }
    with_const(Rubicon::Bot, :WATCHDOG_INTERVAL, 0.02) do
      with_const(Rubicon::Bot, :WATCHDOG_LIMIT, 0.1) do
        bot
        watchdog = @bot.send(:start_watchdog)
        hog = Thread.new { @bot.send(:synchronize) { sleep 0.5 } }
        assert_equal "default", fired.pop(timeout: 3)
        hog.join
        watchdog.kill
      end
    end
  ensure
    Rubicon::Bot.watchdog_action = old_action
  end

  def test_worker_pool_threads_end_on_shutdown
    pool = Rubicon::WorkerPool.new(size: 2, max_queue: 5, logger: Logger.new(nil))
    done = Queue.new
    pool.submit { done << :ran }
    done.pop
    threads = pool.instance_variable_get(:@threads)
    pool.shutdown
    assert(threads.all? { |t| t.join(2) }, "threads exit")
    refute pool.submit { nil }, "no new jobs after shutdown"
  end

  # --- plugin settings ----------------------------------------------------------------------

  def test_command_line_set_checks_the_plugins_own_rules
    dir = File.join(@tmpdir, "plugins")
    Dir.mkdir(dir, 0o700)
    File.write(File.join(dir, "counter.rb"), <<~RUBY, perm: 0o600)
      class Counter < Rubicon::Plugin
        setting "times", default: 1, type: :integer, max: 3
      end
    RUBY
    path = File.join(@tmpdir, "config.yml")
    File.write(path, "server: irc.example.net\n", perm: 0o600)
    tool = File.expand_path("../bin/rubicon-account", __dir__)
    out, status = Open3.capture2e("ruby", tool, "-c", path, "plugin-set", "counter", "times", "9")
    refute status.success?
    assert_match(/times must be at most 3/, out)
    out, status = Open3.capture2e("ruby", tool, "-c", path, "plugin-set", "counter", "times", "2")
    assert status.success?, out
  end

  def test_a_load_error_points_at_saved_settings
    dir = File.join(@tmpdir, "plugins")
    Dir.mkdir(dir, 0o700)
    File.write(File.join(dir, "picky.rb"), <<~RUBY, perm: 0o600)
      class Picky < Rubicon::Plugin
        def setup
          raise Rubicon::Error, "mode must be calm" unless settings["mode"] == "calm"
        end
      end
    RUBY
    Rubicon::PluginState.new(@store).set("picky", "mode", "wild")
    bot({ "plugins" => { "picky" => { "mode" => "calm" } } })
    error = @bot.send(:plugin_manager).status["picky"]["error"]
    assert_match(/mode must be calm \(it has settings saved with PLUGIN SET: mode; PLUGIN UNSET picky <setting>/, error)
  end

  # --- hot-plugging -------------------------------------------------------------------------

  def test_status_shows_a_hot_installed_plugin_right_after_the_reload
    dir = File.join(@tmpdir, "plugins")
    Dir.mkdir(dir, 0o700)
    path = File.join(@tmpdir, "config.yml")
    File.write(path, "server: irc.example.net\nnick: ModeBot\n", perm: 0o600)
    @bot = Rubicon::Bot.new(Rubicon::Config.load(path), config_path: path, connection: FakeConnection.new, store: @store,
                                                       hasher: TEST_HASHER, logger: Logger.new(@log))
    @bot.handle(":server 001 ModeBot :Welcome")
    status = -> { JSON.parse(File.read(File.join(@tmpdir, "data/status.json")))["plugins"] }
    assert_empty status.call

    File.write(File.join(dir, "hello.rb"), "class Hello < Rubicon::Plugin; end\n", perm: 0o600)
    assert @bot.reload_config
    assert_equal "loaded", status.call.dig("hello", "state")

    File.delete(File.join(dir, "hello.rb"))
    @bot.reload_config
    assert_nil status.call["hello"]
  end

  def test_a_long_running_plugin_job_is_reported_once
    executor = Rubicon::KeyedExecutor.new(size: 1, name: "test")
    gate = Queue.new
    executor.submit("plugin:slowpoke") { gate.pop }
    with_const(Rubicon::Bot, :BUSY_PLUGIN, 0.05) do
      bot
      @bot.instance_variable_set(:@plugin_jobs, executor)
      sleep 0.1
      2.times { @bot.send(:report_busy_plugins) }
    end
    assert_equal 1, @log.string.scan(/Plugin slowpoke has been busy for \d+s/).size
  ensure
    gate&.push(:go)
    executor&.shutdown
  end
end

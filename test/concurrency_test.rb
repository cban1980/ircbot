require "test_helper"
require "stringio"

# The bot with real worker threads: commands and plugins run in parallel,
# in order per user and per plugin, without holding up the server's lines.
class ConcurrencyTest < Minitest::Test
  include StoreHelper

  # TEST_HASHER, but each check takes a while (like a real scrypt in a
  # worker process, it doesn't keep other threads from running).
  class SlowHasher
    def initialize(delay) = @delay = delay
    def hash(password) = TEST_HASHER.hash(password)
    def needs_rehash?(stored) = TEST_HASHER.needs_rehash?(stored)
    def pepper_id = TEST_HASHER.pepper_id

    def verify(password, stored)
      sleep @delay
      TEST_HASHER.verify(password, stored)
    end
  end

  def setup
    super
    @factory = Gemdrop::Bot.executor_factory
    Gemdrop::Bot.executor_factory = lambda do |name, size, logger, max|
      Gemdrop::KeyedExecutor.new(size: size, name: name, logger: logger, max_per_key: max)
    end
    @plugins_dir = File.join(@tmpdir, "plugins")
    Dir.mkdir(@plugins_dir, 0o700)
    @log = StringIO.new
  end

  def teardown
    Gemdrop::Bot.executor_factory = @factory
    super
  end

  def start(hasher: TEST_HASHER)
    path = File.join(@tmpdir, "config.yml")
    File.write(path, "server: irc.example.net\nnick: Gemdrop\nrequire_secure_users: false\nchannels: ['#c']\n", perm: 0o600)
    @conn = FakeConnection.new
    @lines = Queue.new
    lines = @lines
    @conn.define_singleton_method(:write) { |line, **| (lines << line) && true }
    @bot = Gemdrop::Bot.new(Gemdrop::Config.load(path), connection: @conn, store: @store, hasher: hasher,
                                                       logger: Logger.new(@log))
    server(":server 001 Gemdrop :Welcome")
    server(":Gemdrop!b@h JOIN #c")
  end

  # As the read loop does: each line under the bot's lock.
  def server(line) = @bot.send(:synchronize) { @bot.handle(line) }

  # Lines sent, in order, until one matches (or the time is up).
  def sent_until(pattern, timeout: 5)
    seen = []
    deadline = Time.now + timeout
    until seen.any? { |line| line.match?(pattern) } || Time.now > deadline
      begin
        seen << @lines.pop(timeout: 0.05)
      rescue ThreadError
        nil
      end
      seen.compact!
    end
    seen
  end

  def write_plugin(name, source) = File.write(File.join(@plugins_dir, "#{name}.rb"), source, perm: 0o600)

  def test_a_slow_login_holds_up_neither_the_server_nor_other_users
    Gemdrop::Accounts.new(@store, TEST_HASHER).register("alice", "password123")
    start(hasher: SlowHasher.new(0.5))

    server(":alice!a@a.host PRIVMSG Gemdrop :IDENTIFY password123")
    server("PING :server")
    server(":bob!b@b.host PRIVMSG Gemdrop :WHOAMI")
    lines = sent_until(/You are now identified/)

    pong = lines.index("PONG :server")
    bob = lines.index("NOTICE bob :You are not identified.")
    alice = lines.index { |l| l.include?("You are now identified as alice") }
    assert pong && bob && alice, lines.inspect
    assert_operator pong, :<, alice
    assert_operator bob, :<, alice, "bob doesn't wait for alice's password check"
  end

  def test_one_users_commands_run_in_order
    Gemdrop::Accounts.new(@store, TEST_HASHER).register("alice", "password123")
    start(hasher: SlowHasher.new(0.3))

    server(":alice!a@a.host PRIVMSG Gemdrop :IDENTIFY password123")
    server(":alice!a@a.host PRIVMSG Gemdrop :WHOAMI")
    lines = sent_until(/You are identified as alice/)
    assert_includes lines, "NOTICE alice :You are identified as alice.", "WHOAMI ran after IDENTIFY finished"
  end

  def test_a_slow_plugin_holds_up_neither_other_plugins_nor_the_bot
    write_plugin("slow", <<~RUBY)
      class Slow < Gemdrop::Plugin
        on(:message) { |e| sleep 0.5; say(e.channel, "slow done") }
      end
    RUBY
    write_plugin("quick", <<~RUBY)
      class Quick < Gemdrop::Plugin
        on(:message) { |e| say(e.channel, "quick done") }
        command("PINGME") { |ctx, _| ctx.reply("pong") }
      end
    RUBY
    start

    server(":alice!a@a.host PRIVMSG #c :hello")
    server("PING :server")
    server(":bob!b@b.host PRIVMSG Gemdrop :PINGME")
    lines = sent_until(/slow done/)
    %w[PONG\ :server PRIVMSG\ #c\ :quick\ done NOTICE\ bob\ :pong].each do |line|
      assert_operator lines.index(line), :<, lines.index("PRIVMSG #c :slow done"), "#{line} before the slow plugin"
    end
  end

  def test_one_plugins_events_arrive_in_order
    write_plugin("order", <<~RUBY)
      class Order < Gemdrop::Plugin
        on(:message) { |e| sleep(rand * 0.02); say(e.channel, "got \#{e.text}") }
      end
    RUBY
    start
    10.times { |i| server(":alice!a@a.host PRIVMSG #c :m#{i}") }
    lines = sent_until(/got m9/).grep(/got m/)
    assert_equal (0..9).map { |i| "PRIVMSG #c :got m#{i}" }, lines
  end

  def test_unload_waits_for_the_running_job_then_tears_down
    write_plugin("busy", <<~RUBY)
      class Busy < Gemdrop::Plugin
        on(:message) { |_e| sleep 0.3; $busy_log << :hook_done }
        def teardown = $busy_log << :teardown
      end
    RUBY
    $busy_log = Queue.new
    start
    server(":alice!a@a.host PRIVMSG #c :hello")
    sleep 0.05 # the hook is running
    @bot.send(:synchronize) { @bot.send(:plugin_manager).unload("busy") }
    assert_equal %i[hook_done teardown], [$busy_log.pop, $busy_log.pop]
  ensure
    $busy_log = nil
  end

  def test_executor_orders_per_key_and_runs_keys_in_parallel
    executor = Gemdrop::KeyedExecutor.new(size: 3, name: "test", max_per_key: 5)
    log = Queue.new
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    %w[a b c].each do |key|
      3.times { |i| executor.submit(key) { sleep 0.1; log << "#{key}#{i}" } }
    end
    results = Array.new(9) { log.pop }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    %w[a b c].each { |key| assert_equal %W[#{key}0 #{key}1 #{key}2], results.grep(/\A#{key}/) }
    assert_operator elapsed, :<, 0.6, "three keys ran side by side (0.3 s each, not 0.9 s)"

    gate = Queue.new
    executor.submit("full") { gate.pop }
    sleep 0.05
    assert_equal [true] * 5, Array.new(5) { executor.submit("full") { nil } }
    refute executor.submit("full") { nil }, "a full queue refuses more"
    refute executor.wait("full", timeout: 0.1)
    gate << :go
    assert executor.wait("full", timeout: 2)
  ensure
    executor&.shutdown
  end
end

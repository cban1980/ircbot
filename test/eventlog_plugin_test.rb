require "test_helper"
require "stringio"
require "zlib"

# The eventlog plugin (contrib/plugins/eventlog.rb): JSON Lines records of
# IRC events, the bot's messages and its log; reading them back.
class EventlogPluginTest < Minitest::Test
  include StoreHelper

  def setup
    super
    @plugins_dir = File.join(@tmpdir, "plugins")
    Dir.mkdir(@plugins_dir, 0o700)
    File.write(File.join(@plugins_dir, "eventlog.rb"),
               File.read(File.expand_path("../contrib/plugins/eventlog.rb", __dir__)), perm: 0o600)
    @log = StringIO.new
  end

  def teardown
    @bot&.send(:stop_log_events)
    super
  end

  def start(settings = "", extra_plugins: {})
    extra_plugins.each { |name, source| File.write(File.join(@plugins_dir, "#{name}.rb"), source, perm: 0o600) }
    path = File.join(@tmpdir, "config.yml")
    File.write(path, <<~YAML + settings.gsub(/^/, "    "), perm: 0o600)
      server: irc.example.net
      nick: ModeBot
      admins: [root]
      channels: ["#chan"]
      require_secure_users: false
      plugins:
        eventlog:
    YAML
    @conn = FakeConnection.new
    logger = Logger.new(@log)
    logger.formatter = Rubicon::LogFormatter.new # feeds :log events
    @bot = Rubicon::Bot.new(Rubicon::Config.load(path), connection: @conn, store: @store, hasher: TEST_HASHER,
                                                       plugin_pool: InlinePool.new, logger: logger)
    @bot.send(:start_log_events)
    @bot.handle(":server 001 ModeBot :Welcome")
    @bot.handle(":ModeBot!bot@host JOIN #chan")
    @logger = logger
  end

  def eventlog = @bot.send(:plugin_manager).plugin("eventlog")
  def dir = File.join(@tmpdir, "data/plugins/eventlog")
  def today_file = File.join(dir, "#{Time.now.utc.to_date.iso8601}.jsonl")
  def written = File.readlines(today_file).map { |line| JSON.parse(line) }
  def of_type(type) = written.select { |r| r["type"] == type }

  def test_records_channel_events_with_the_schema
    start
    @bot.handle(":alice!a@alice.example PRIVMSG #chan :hello there")
    @bot.handle(":alice!a@alice.example PRIVMSG #chan :\x01ACTION waves\x01")
    @bot.handle(":op!o@op.example MODE #chan +o alice")
    @bot.handle(":op!o@op.example TOPIC #chan :New topic")
    @bot.handle(":op!o@op.example KICK #chan alice :bye")

    message = of_type("message").first
    assert_equal({ "v" => 1, "network" => "default", "type" => "message", "channel" => "#chan", "nick" => "alice",
                   "userhost" => "a@alice.example", "text" => "hello there" }, message.except("ts"))
    assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/, message["ts"])
    assert_equal "waves", of_type("action").first["text"]
    assert_equal ["+o alice"], of_type("mode").first["modes"]
    assert_equal "New topic", of_type("topic").first["text"]
    kick = of_type("kick").first
    assert_equal %w[alice op bye], kick.values_at("nick", "by", "text")
    assert_equal ["#chan"], of_type("join").map { |r| r["channel"] }.uniq
  end

  def test_records_what_the_bot_says_but_not_pings
    start
    eventlog.say("#chan", "hello from the bot")
    @bot.handle("PING :server")
    outgoing = of_type("outgoing")
    assert_includes outgoing.map { |r| r.values_at("nick", "command", "channel", "text") },
                    ["ModeBot", "PRIVMSG", "#chan", "hello from the bot"]
    refute(outgoing.any? { |r| r["command"] == "PONG" })
  end

  def test_private_messages_hosts_channels_and_nicks
    start
    @bot.handle(":alice!a@a.example PRIVMSG ModeBot :secret-ish chat")
    assert_empty of_type("private_message"), "private messages are off by default"

    start("private_messages: true\nhide_hosts: true\nignore_channels: ['#noisy']\nignore_nicks: [spammer]\n")
    @bot.handle(":alice!a@a.example PRIVMSG ModeBot :now logged")
    @bot.handle(":bob!b@b.example PRIVMSG #noisy :not logged")
    @bot.handle(":spammer!s@s.example PRIVMSG #chan :not logged")
    private_message = of_type("private_message").last
    assert_equal "now logged", private_message["text"]
    refute private_message.key?("userhost")
    refute(written.any? { |r| r["text"] == "not logged" })
  end

  def test_records_the_bots_own_log_by_level
    start
    @logger.warn("Something odd happened")
    @logger.debug("chatter")
    record = of_type("log").find { |r| r["text"] == "Something odd happened" }
    assert_equal %w[warn], [record["level"]]
    refute(of_type("log").any? { |r| r["text"] == "chatter" })
  end

  def test_logging_from_a_log_hook_does_not_loop
    loud = <<~RUBY
      class Loud < Rubicon::Plugin
        on(:log) { |event| log.info("saw: \#{event.text}") unless event.text.start_with?("saw:") }
      end
    RUBY
    start(extra_plugins: { "loud" => loud })
    @logger.info("one record")
    assert_operator of_type("log").size, :<, 20
  end

  def test_records_query_filters_and_skips_damaged_lines
    start
    @bot.handle(":alice!a@a.example PRIVMSG #chan :I like Ruby")
    @bot.handle(":bob!b@b.example PRIVMSG #chan :and Python")
    @bot.handle(":alice!a@a.example PRIVMSG #other :ruby elsewhere")
    File.open(today_file, "a") { |f| f.write("{\"broken\n") }

    found = eventlog.records(types: %w[message], text: "ruby").map { |r| r["text"] }
    assert_equal ["I like Ruby", "ruby elsewhere"], found
    assert_equal ["I like Ruby"], eventlog.records(channel: "#CHAN", nick: "Alice", text: /ruby/i).map { |r| r["text"] }
    assert_equal 1, eventlog.records(types: %w[message], limit: 1).to_a.size
    assert eventlog.records.first.frozen?
  end

  def test_housekeeping_compresses_and_deletes_old_days
    start("compress_after_days: 2\nkeep_days: 10\n")
    today = Time.now.utc.to_date
    old = File.join(dir, "#{(today - 3).iso8601}.jsonl")
    ancient = File.join(dir, "#{(today - 11).iso8601}.jsonl")
    record = { "v" => 1, "ts" => "#{(today - 3).iso8601}T10:00:00.000Z", "network" => "default", "type" => "message",
               "channel" => "#chan", "nick" => "old", "text" => "from the past" }
    File.write(old, "#{JSON.generate(record)}\n", perm: 0o600)
    File.write(ancient, "{}\n", perm: 0o600)

    eventlog.send(:housekeeping)
    refute File.exist?(old)
    assert File.exist?("#{old}.gz")
    refute File.exist?(ancient)
    assert_equal ["from the past"], eventlog.records(from: today - 5).map { |r| r["text"] }.first(1)
  end

  def test_write_failures_are_reported_once_and_recovery_noticed
    start
    eventlog.send(:close_file)
    File.chmod(0o400, today_file)
    5.times { |i| @bot.handle(":alice!a@a.example PRIVMSG #chan :lost #{i}") }
    assert_equal 1, @log.string.scan("Can't write the event log").size
    File.chmod(0o600, today_file)
    @bot.handle(":alice!a@a.example PRIVMSG #chan :back")
    assert_match(/writable again; \d+ record\(s\) were lost/, @log.string)
    assert_equal "back", of_type("message").last["text"]
  ensure
    File.chmod(0o600, today_file) if File.exist?(today_file)
  end

  def test_logsearch_for_channel_ops
    Rubicon::Accounts.new(@store, TEST_HASHER).register("root", "password123")
    start
    @bot.handle(":root!r@root.host PRIVMSG ModeBot :IDENTIFY password123")
    @bot.handle(":alice!a@a.example PRIVMSG #chan :the deploy is broken")
    @bot.handle(":bob!b@b.example PRIVMSG #chan :unrelated")
    @conn.clear
    @bot.handle(":root!r@root.host PRIVMSG ModeBot :LOGSEARCH #chan deploy")
    assert_match(/\ANOTICE root :\d{4}-\d\d-\d\d \d\d:\d\d <alice> the deploy is broken\z/, @conn.lines.grep(/NOTICE root/).first)

    @bot.handle(":nobody!n@n.host PRIVMSG ModeBot :LOGSEARCH #chan deploy")
    assert_includes @conn.lines, "NOTICE nobody :You must IDENTIFY first."
  end

  def test_other_plugins_follow_records_live
    follower = <<~RUBY
      class Follower < Rubicon::Plugin
        attr_reader :seen
        listen("log.record") { |record, _info| (@seen ||= []) << record }
      end
    RUBY
    start(extra_plugins: { "follower" => follower })
    @bot.handle(":alice!a@a.example PRIVMSG #chan :live")
    seen = @bot.send(:plugin_manager).plugin("follower").seen
    record = seen.find { |r| r["type"] == "message" }
    assert_equal "live", record["text"]
    assert record.frozen?
  end

  def test_rejects_unknown_types
    start("types: [message, gossip]\n")
    assert_match(/unknown types: gossip/, @bot.send(:plugin_manager).status["eventlog"]["error"])
  end

  def test_log_records_go_to_the_network_they_are_about
    path = File.join(@tmpdir, "networks.yml")
    File.write(path, <<~YAML, perm: 0o600)
      nick: ModeBot
      plugins_dir: #{@plugins_dir}
      networks:
        One:
          server: one.example.net
        Two:
          server: two.example.net
    YAML
    logger = Logger.new(@log)
    logger.formatter = Rubicon::LogFormatter.new
    sup = Rubicon::Supervisor.new(Rubicon::Config.load(path), store: @store, hasher: TEST_HASHER, logger: logger,
                                                            connection_factory: ->(_net) { FakeConnection.new })
    bots = sup.bots
    bots.each { |b| b.send(:start_log_events) }
    two = logger.dup
    two.progname = "Two/links"
    two.warn("about Two")
    logger.warn("about the bot")

    texts = ->(id) { sup.bot(id).send(:plugin_manager).plugin("eventlog").records(types: %w[log]).map { |r| r["text"] } }
    assert_equal ["about the bot"], texts.call("One"), "records without a network go to the first one"
    assert_equal ["about Two"], texts.call("Two")
  ensure
    bots&.each { |b| b.send(:stop_log_events) }
  end

  # A full queue that refuses some jobs, then has room again.
  class FlakyQueue
    def initialize = @refuse = 0
    attr_writer :refuse

    def submit(_key)
      return false if (@refuse -= 1) >= 0

      yield
      true
    end

    def wait(*, **) = true
    def drop(_) = nil
    def shutdown = nil
  end

  def test_dropped_events_leave_a_gap_record
    start
    queue = FlakyQueue.new
    @bot.instance_variable_set(:@plugin_jobs, queue)
    queue.refuse = 3
    3.times { |i| @bot.handle(":alice!a@a.example PRIVMSG #chan :dropped #{i}") }
    @bot.handle(":alice!a@a.example PRIVMSG #chan :after the gap")

    # Refused: message 0, the bot's own "falling behind" warning (a log
    # record too) and message 1. The gap marks the spot, then it goes on.
    texts = written.filter_map { |r| r["type"] == "gap" ? "gap #{r['lost']}" : r["text"] if %w[gap message].include?(r["type"]) }
    assert_equal ["gap 3", "dropped 2", "after the gap"], texts
    assert_match(/3 event\(s\) or command\(s\) for this plugin were dropped/, @log.string)
  end
end

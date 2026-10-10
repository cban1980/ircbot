require "test_helper"
require "socket"

# The keeper (lib/gemdrop/keeper.rb) between bots (KeeperConnection) and a
# fake IRC server: connections outlive the bots that use them.
class KeeperTest < Minitest::Test
  # An IRC server that records what each connection sends.
  class FakeIrc
    attr_reader :connections, :port

    def initialize
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @connections = []
      @lock = Mutex.new
      @thread = Thread.new do
        loop do
          sock = @server.accept
          entry = { sock: sock, lines: Queue.new, all: [] }
          @lock.synchronize { @connections << entry }
          Thread.new do
            while (line = sock.gets)
              entry[:lines] << line.chomp
              entry[:all] << line.chomp
            end
          rescue IOError, SystemCallError
            nil
          ensure
            entry[:lines] << :closed
          end
        end
      rescue IOError
        nil
      end
    end

    def last = @lock.synchronize { @connections.last }
    # How many connections were made (after a moment, so one just made counts).
    def count
      sleep 0.2
      @lock.synchronize { @connections.size }
    end

    def say(line, conn = last) = conn[:sock].write("#{line}\r\n")

    # The next line from the connection matching re (skipping others).
    def expect(re, conn = nil, timeout: 5)
      deadline = Time.now + timeout
      sleep 0.02 until (conn ||= last) || Time.now > deadline
      return nil unless conn

      while (left = deadline - Time.now).positive?
        line = conn[:lines].pop(timeout: left)
        return line if line == :closed && re == :closed
        return line if line.is_a?(String) && line.match?(re)
      end
      nil
    end

    def stop
      @thread.kill
      @server.close
      @connections.each { |c| c[:sock].close rescue nil } # rubocop:disable Style/RescueModifier
    end
  end

  def setup
    @dir = Dir.mktmpdir("gemdrop-keeper")
    @path = File.join(@dir, "run", "keeper.sock")
    @irc = FakeIrc.new
    @logs = StringIO.new
    @keeper = Gemdrop::Keeper.new(@path, logger: Logger.new(@logs))
    @keeper_thread = Thread.new { @keeper.run(handle_signals: false) }
    sleep 0.05 until File.socket?(@path)
    @old_rate = Gemdrop::Connection::RATE
    silence_warnings { Gemdrop::Connection.const_set(:RATE, 100.0) }
  end

  def teardown
    @keeper.stop
    @keeper_thread.join(5)
    @irc.stop
    silence_warnings { Gemdrop::Connection.const_set(:RATE, @old_rate) }
    FileUtils.remove_entry(@dir)
  end

  def silence_warnings
    old = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = old
  end

  def params(port = @irc.port) = { "host" => "127.0.0.1", "port" => port, "tls" => false, "verify" => false,
                                    "min_version" => "1.2", "fingerprint" => nil, "ciphers" => "x", "known_servers" => nil }

  def bot(network = "IRCnet", params: self.params)
    conn = Gemdrop::KeeperConnection.new(path: @path, network: network, params: params)
    conn.connect
    conn
  end

  # The next line the bot gets matching re.
  def read(conn, re, timeout: 5)
    Timeout.timeout(timeout) do
      while (line = conn.gets)
        return line.chomp if line.chomp.match?(re)
      end
    end
    nil
  rescue Timeout::Error
    nil
  end

  # A registered, joined connection, as a bot would leave it.
  def registered_bot
    conn = bot
    refute conn.resumed?
    conn.write("NICK Bot")
    conn.write("USER bot 0 * :Bot")
    assert @irc.expect(/\AUSER bot/)
    @irc.say(":irc.test 001 Bot :Welcome")
    @irc.say(":irc.test 005 Bot NETWORK=Test PREFIX=(ov)@+ :are supported")
    @irc.say(":irc.test 376 Bot :End of MOTD")
    conn.write("JOIN #chan")
    @irc.say(":Bot!bot@bot.host JOIN #chan")
    @irc.say(":Bot!bot@bot.host NICK :Bot2")
    assert read(conn, /NICK :Bot2/)
    conn
  end

  def test_a_new_bot_takes_over_the_connection_as_it_was
    first = registered_bot
    first.detach
    sleep 0.1
    @irc.say("PING :irc.test")
    assert @irc.expect(/\APONG :irc.test/), "the keeper answers PINGs while no bot is attached"
    @irc.say(":alice!a@a.host PRIVMSG Bot2 :hello while you were away")

    second = bot
    assert second.resumed?
    assert_equal 1, @irc.count, "the IRC connection was kept"
    assert_equal first.link, second.link
    assert_equal ":irc.test 001 Bot2 :Welcome", read(second, / 001 /), "the welcome, with the current nick"
    assert read(second, / 005 Bot2 NETWORK=Test/)
    assert read(second, / 376 Bot2 /)
    assert_equal ":Bot2!bot@bot.host JOIN #chan", read(second, / JOIN /)
    assert read(second, /PRIVMSG Bot2 :hello while you were away/), "what arrived meanwhile"
    assert @irc.expect(/\ANAMES #chan/)
    assert @irc.expect(/\ATOPIC #chan/)

    second.write("PRIVMSG #chan :I'm back")
    assert @irc.expect(/\APRIVMSG #chan :I'm back/)
    @irc.say(":alice!a@a.host PRIVMSG #chan :wb")
    assert read(second, /:wb\z/)
    refute @irc.last[:all].any? { |l| l.start_with?("QUIT") }
  end

  def test_capabilities_carry_over
    first = registered_bot
    @irc.say(":irc.test CAP Bot2 ACK :server-time account-notify")
    assert read(first, / ACK /)
    first.detach
    second = bot
    assert_equal ":keeper CAP Bot2 ACK :server-time account-notify", read(second, / CAP /)
  end

  def test_a_bot_that_dies_leaves_the_connection_too
    first = registered_bot
    first.instance_variable_get(:@sock).close # killed: no DETACH
    sleep 0.1
    assert bot.resumed?
    assert_equal 1, @irc.count
  end

  def test_drop_quits_and_the_next_bot_gets_a_new_connection
    first = registered_bot
    first.write("QUIT :Reconnecting", urgent: true)
    first.close
    assert @irc.expect(/\AQUIT :Reconnecting/)
    assert_equal :closed, @irc.expect(:closed)

    second = bot
    refute second.resumed?
    assert_equal 2, @irc.count
  end

  def test_a_second_bot_takes_over_from_the_first
    first = registered_bot
    second = bot
    assert second.resumed?
    assert_nil first.gets, "the first bot is cut off"
    @irc.say(":alice!a@a.host PRIVMSG #chan :hi")
    assert read(second, /:hi\z/)
  end

  def test_changed_settings_make_a_new_connection
    registered_bot.detach
    other = FakeIrc.new
    conn = bot(params: params(other.port))
    refute conn.resumed?
    assert @irc.expect(/\AQUIT :Reconnecting/)
    assert_equal 1, other.count
  ensure
    other&.stop
  end

  def test_a_lost_server_connection_ends_the_bots
    conn = registered_bot
    @irc.last[:sock].close
    assert_nil Timeout.timeout(5) { conn.gets }
    refute bot.resumed?, "the next attach connects anew"
    assert_equal 2, @irc.count
  end

  def test_networks_are_separate
    registered_bot.detach
    efnet = bot("EFnet")
    refute efnet.resumed?
    assert_equal 2, @irc.count
    assert_equal %w[IRCnet EFnet].sort, @keeper.networks.sort
  end

  def test_connect_errors_reach_the_bot
    closed = TCPServer.new("127.0.0.1", 0)
    port = closed.addr[1]
    closed.close
    error = assert_raises(IOError) { bot(params: params(port)) }
    assert_match(/keeper refused: Errno::ECONNREFUSED/, error.message)
  end

  def test_stopping_the_keeper_quits_irc
    registered_bot.detach
    @keeper.stop("Bye")
    assert @irc.expect(/\AQUIT :Bye/)
    @keeper_thread.join(5)
    refute File.exist?(@path)
  end

  def test_one_keeper_per_socket
    error = assert_raises(Gemdrop::Error) { Gemdrop::Keeper.new(@path, logger: Logger.new(nil)).listen }
    assert_match(/already listening/, error.message)

    stale = File.join(@dir, "stale.sock")
    UNIXServer.new(stale).close # left behind by a keeper that died
    keeper = Gemdrop::Keeper.new(stale, logger: Logger.new(nil))
    keeper.listen
    assert File.socket?(stale)
    assert_equal "600", format("%o", File.stat(stale).mode & 0o777)
  end

  # --- the bot with a keeper --------------------------------------------------------------------

  def start_bot(config, store)
    bot = Gemdrop::Bot.new(config, store: store, hasher: TEST_HASHER, logger: Logger.new(@logs))
    [bot, Thread.new { bot.run(handle_signals: false) }]
  end

  def test_the_bot_restarts_without_leaving_irc
    path = File.join(@dir, "config.yml")
    File.write(path, <<~YAML, perm: 0o600)
      server: 127.0.0.1
      port: #{@irc.port}
      tls: false
      allow_insecure: true
      nick: Bot
      channels: ["#chan"]
      require_secure_users: false
      keeper_socket: run/keeper.sock
    YAML
    config = Gemdrop::Config.load(path)
    store = Gemdrop::Store.new(File.join(@dir, "data.json"))
    Gemdrop::Accounts.new(store, TEST_HASHER).register("alice", "password123")

    first, thread = start_bot(config, store)
    assert @irc.expect(/\AUSER /)
    @irc.say(":irc.test 001 Bot :Welcome")
    @irc.say(":irc.test 376 Bot :End of MOTD")
    assert @irc.expect(/\AJOIN #chan/)
    @irc.say(":Bot!bot@bot.host JOIN #chan")
    @irc.say(":alice!a@a.host PRIVMSG Bot :IDENTIFY password123")
    assert @irc.expect(/NOTICE alice :You are now identified as alice/)

    first.stop
    thread.join(5)
    refute @irc.last[:all].any? { |line| line.start_with?("QUIT") }, "a stopped bot doesn't quit IRC"

    second, thread = start_bot(config, store)
    assert @irc.expect(/\ANAMES #chan/), "the keeper asks for the channel's names for the new bot"
    @irc.say(":irc.test 353 Bot = #chan :@Bot alice")
    @irc.say(":alice!a@a.host PRIVMSG Bot :WHOAMI")
    assert @irc.expect(/NOTICE alice :You are identified as alice\./), "logins carry over"
    assert_equal 1, @irc.count, "no new connection"
    refute @irc.last[:all].count { |line| line.start_with?("USER ") } > 1, "no new registration"
    assert_equal ["#chan"], second.channel_snapshot
    assert_match(/Kept 1 login/, @logs.string)

    second.stop(quit: true)
    thread.join(5)
    assert @irc.expect(/\AQUIT :Shutting down/)
  end
end

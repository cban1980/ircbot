require "test_helper"
require "socket"

# The queued writer: sending never blocks the caller, urgent lines go
# first, a full queue drops lines, and close(flush: true) lets a QUIT out.
class ConnectionWriterTest < Minitest::Test
  # Faster than real flood control, so the tests don't take seconds.
  def setup
    @old_rate = Gemdrop::Connection::RATE
    Gemdrop::Connection.send(:remove_const, :RATE)
    Gemdrop::Connection.const_set(:RATE, 20.0)
    @server = TCPServer.new("127.0.0.1", 0)
    @conn = Gemdrop::Connection.new(host: "127.0.0.1", port: @server.addr[1], tls: false)
    @conn.connect
    @peer = @server.accept
  end

  def teardown
    @conn.close
    @peer.close
    @server.close
    Gemdrop::Connection.send(:remove_const, :RATE)
    Gemdrop::Connection.const_set(:RATE, @old_rate)
  end

  def received(count, timeout: 10)
    lines = []
    deadline = Time.now + timeout
    while lines.size < count && Time.now < deadline
      next unless @peer.wait_readable(0.1)

      line = @peer.gets or break
      lines << line.chomp
    end
    lines
  end

  def test_writes_return_at_once_and_arrive_in_order
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    8.times { |i| assert @conn.write("PRIVMSG #c :#{i}") }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.2, "the caller never waits for flood control"

    assert_equal (0..7).map { |i| "PRIVMSG #c :#{i}" }, received(8)
  end

  def test_urgent_lines_jump_the_queue
    10.times { |i| @conn.write("PRIVMSG #c :#{i}") }
    sleep 0.02 # the burst is out; the rest waits for flood control
    @conn.write("PONG :server", urgent: true)
    lines = received(11)
    assert_operator lines.index("PONG :server"), :<, lines.index("PRIVMSG #c :9")
  end

  def test_full_queue_drops_and_counts
    stub_const(:MAX_QUEUE, 3) do
      results = Array.new(20) { |i| @conn.write("PRIVMSG #c :#{i}") }
      assert_includes results, false
      assert_operator @conn.take_dropped, :>, 0
      assert_equal 0, @conn.take_dropped, "reset once read"
      assert @conn.write("PONG :x", urgent: true), "urgent lines are never dropped"
    end
  end

  def test_close_with_flush_sends_the_quit
    6.times { |i| @conn.write("PRIVMSG #c :#{i}") }
    @conn.write("QUIT :bye", urgent: true)
    @conn.close(flush: true)
    assert_includes received(7, timeout: 5), "QUIT :bye"
  end

  # At the real rate the QUIT waits for its turn after leaving the queue;
  # the flush must wait for that too.
  def test_close_with_flush_waits_for_the_line_being_sent
    stub_const(:RATE, 2.0) do
      6.times { |i| @conn.write("PRIVMSG #c :#{i}") } # 5 go at once, the 6th waits its turn
      sleep 0.05
      @conn.write("QUIT :bye", urgent: true) # the last line: waits its turn with the queue empty
      @conn.close(flush: true)
      assert_includes received(7, timeout: 5), "QUIT :bye"
    end
  end

  # SIGUSR1: the server hangs up on the QUIT and the bot reconnects while
  # the signal thread's close is still waiting; that close must not end
  # the new connection.
  def test_a_late_close_leaves_a_newer_connection_open
    stub_const(:RATE, 2.0) do
      6.times { |i| @conn.write("PRIVMSG #c :#{i}") } # the 6th waits its turn
      closer = Thread.new { @conn.close(flush: true) }
      received(6)
      # The last line is out; before the closer's next check: the read
      # loop's close, the reconnect and lines queued on the new connection.
      @conn.close
      @conn.connect
      8.times { |i| @conn.write("PRIVMSG #c :new #{i}") }
      second = @server.accept
      closer.join
      assert @conn.write("PRIVMSG #c :still open")
      assert_equal "PRIVMSG #c :new 0", second.gets&.chomp
    ensure
      second&.close
    end
  end

  def test_writing_after_close_raises
    @conn.close
    assert_raises(IOError) { @conn.write("PRIVMSG #c :late") }
  end

  private

  def stub_const(name, value)
    old = Gemdrop::Connection.const_get(name)
    Gemdrop::Connection.send(:remove_const, name)
    Gemdrop::Connection.const_set(name, value)
    yield
  ensure
    Gemdrop::Connection.send(:remove_const, name)
    Gemdrop::Connection.const_set(name, old)
  end
end

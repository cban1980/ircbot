require "test_helper"
require "stringio"

# Password hashing in worker processes.
class HashWorkersTest < Minitest::Test
  def setup
    @workers = Gemdrop::HashWorkers.new(size: 2)
    @hasher = Gemdrop::PasswordHasher.new(pepper: TEST_PEPPER, workers: @workers, log_n: 12)
  end

  def teardown = @workers.shutdown

  def test_same_results_as_hashing_in_process
    stored = @hasher.hash("password123")
    assert Gemdrop::PasswordHasher.new(pepper: TEST_PEPPER, log_n: 12).verify("password123", stored)
    assert @hasher.verify("password123", stored)
    refute @hasher.verify("wrong-password", stored)
  end

  def test_other_threads_keep_running_while_hashing
    stored = Gemdrop::PasswordHasher.new(pepper: TEST_PEPPER, log_n: 14).hash("password123")
    slow = Gemdrop::PasswordHasher.new(pepper: TEST_PEPPER, workers: @workers, log_n: 14)
    ticks = 0
    stop = false
    ticker = Thread.new do
      until stop
        ticks += 1
        sleep 0.001
      end
    end
    3.times { assert slow.verify("password123", stored) }
    stop = true
    ticker.join
    assert_operator ticks, :>, 5, "the bot's threads run while a worker hashes"
  end

  def test_parallel_hashes_from_many_threads
    stored = @hasher.hash("password123")
    results = Array.new(6) { Thread.new { @hasher.verify("password123", stored) } }.map(&:value)
    assert_equal [true] * 6, results
  end

  def test_a_killed_worker_is_replaced
    stored = @hasher.hash("password123")
    pids = @workers.instance_variable_get(:@all).map(&:pid)
    pids.each { |pid| Process.kill("KILL", pid) }
    assert @hasher.verify("password123", stored), "falls back for the failed call"
    assert @hasher.verify("password123", stored), "and starts a new worker"
  end

  def test_falls_back_to_hashing_in_process
    broken = Object.new
    def broken.scrypt(*, **) = raise(Gemdrop::HashWorkers::Failure, "no workers")
    log = StringIO.new
    hasher = Gemdrop::PasswordHasher.new(pepper: TEST_PEPPER, workers: broken, logger: Logger.new(log), log_n: 4)
    assert hasher.verify("password123", hasher.hash("password123"))
    assert_match(/hashing in the bot's process instead/, log.string)
  end
end

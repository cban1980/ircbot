require "minitest/autorun"
require "tmpdir"
require "rubicon"

# Low scrypt cost keeps tests fast.
TEST_PEPPER = "p" * 32
TEST_HASHER = Rubicon::PasswordHasher.new(pepper: TEST_PEPPER, log_n: 4)

class FakeConnection
  attr_reader :lines, :closed

  def initialize = @lines = []
  def write(line, urgent: false) = @lines << line
  def clear = @lines.clear
  def close(flush: false) = @closed = true
  def first_use? = false
end

# Commands and plugin jobs run right away in the calling thread, so tests
# see their effects immediately (concurrency tests set a real executor).
Rubicon::Bot.executor_factory = ->(*) { Rubicon::InlineExecutor.new }

# Runs worker-pool jobs immediately instead of on worker threads.
class InlinePool
  def submit
    yield
    true
  end
end

module StoreHelper
  def setup
    @tmpdir = Dir.mktmpdir("rubicon-test")
    @store = Rubicon::Store.new(File.join(@tmpdir, "data.json"))
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end
end

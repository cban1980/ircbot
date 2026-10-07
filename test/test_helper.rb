require "minitest/autorun"
require "tmpdir"
require "ircbot"

# Low scrypt cost keeps tests fast.
TEST_PEPPER = "p" * 32
TEST_HASHER = IRCBot::PasswordHasher.new(pepper: TEST_PEPPER, log_n: 4)

class FakeConnection
  attr_reader :lines, :closed

  def initialize = @lines = []
  def write(line) = @lines << line
  def clear = @lines.clear
  def close = @closed = true
  def first_use? = false
end

module StoreHelper
  def setup
    @tmpdir = Dir.mktmpdir("ircbot-test")
    @store = IRCBot::Store.new(File.join(@tmpdir, "data.json"))
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end
end

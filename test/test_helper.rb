require "minitest/autorun"
require "tmpdir"
require "gemdrop"

# Low scrypt cost keeps tests fast.
TEST_PEPPER = "p" * 32
TEST_HASHER = Gemdrop::PasswordHasher.new(pepper: TEST_PEPPER, log_n: 4)

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
Gemdrop::Bot.executor_factory = ->(*) { Gemdrop::InlineExecutor.new }

# Runs worker-pool jobs immediately instead of on worker threads.
class InlinePool
  def submit
    yield
    true
  end
end

# Copies plugins from contrib/plugins into dir (made if missing), as
# "gemdrop-docker plugin install" would; returns dir.
def install_plugins(dir, *names)
  FileUtils.mkdir_p(dir, mode: 0o700)
  names.each do |name|
    File.write(File.join(dir, "#{name}.rb"),
               File.read(File.expand_path("../contrib/plugins/#{name}.rb", __dir__)), perm: 0o600)
  end
  dir
end

module StoreHelper
  def setup
    @tmpdir = Dir.mktmpdir("gemdrop-test")
    @store = Gemdrop::Store.new(File.join(@tmpdir, "data.json"))
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end
end

require "test_helper"

class RateLimiterTest < Minitest::Test
  def setup
    @now = 0
    @limiter = IRCBot::RateLimiter.new(window: 100, clock: -> { @now })
  end

  def test_blocks_at_limit_until_oldest_hit_expires
    3.times { |i| @now = i * 10; @limiter.hit("k") }

    assert_nil @limiter.blocked_for("k", limit: 4)
    assert_equal 80, @limiter.blocked_for("k", limit: 3)

    @now = 101
    assert_nil @limiter.blocked_for("k", limit: 3)
  end

  def test_reset_and_independent_keys
    3.times { @limiter.hit("a") }

    assert @limiter.blocked_for("a", limit: 3)
    assert_nil @limiter.blocked_for("b", limit: 3)
    @limiter.reset("a")
    assert_nil @limiter.blocked_for("a", limit: 3)
  end
end

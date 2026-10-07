module IRCBot
  # Sliding-window counters over a fixed window, used to throttle password
  # guessing and account registration. In memory only; a restart clears them.
  class RateLimiter
    SWEEP_EVERY = 1_000

    def initialize(window:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @window = window
      @clock = clock
      @hits = {}
      @since_sweep = 0
    end

    # Seconds until the key is allowed again, or nil if it is not blocked.
    def blocked_for(key, limit:)
      times = prune(key)
      return nil if times.size < limit

      (times[-limit] + @window - @clock.call).ceil.clamp(1, @window)
    end

    def hit(key)
      (@hits[key] = prune(key)) << @clock.call
      sweep if (@since_sweep += 1) >= SWEEP_EVERY
    end

    def reset(key)
      @hits.delete(key)
    end

    private

    def prune(key)
      cutoff = @clock.call - @window
      (@hits[key] || []).reject { |t| t <= cutoff }
    end

    def sweep
      @since_sweep = 0
      @hits.keys.each do |key|
        times = prune(key)
        times.empty? ? @hits.delete(key) : @hits[key] = times
      end
    end
  end
end

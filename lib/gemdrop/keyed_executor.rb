module Gemdrop
  # Runs jobs on a few threads. Jobs with the same key (one user's
  # commands, one plugin's events) run one at a time, in the order they
  # were submitted; jobs with different keys run in parallel.
  #
  # Queues are bounded: past max_per_key waiting jobs for a key, new ones
  # are refused (submit returns false), so a flood can't build a backlog.
  class KeyedExecutor
    def initialize(size:, name:, logger: Logger.new(nil), max_per_key: 200)
      @size = size
      @name = name
      @log = logger
      @max_per_key = max_per_key
      @mutex = Mutex.new
      @done = ConditionVariable.new
      @ready = Queue.new # keys with jobs waiting and none running
      @queues = {}       # key => waiting jobs
      @running = {}      # key => thread running its job
      @started = {}      # key => when its running job started
      @threads = nil
    end

    def submit(key, &job)
      @mutex.synchronize do
        queue = (@queues[key] ||= [])
        return false if queue.size >= @max_per_key

        queue << job
        @ready << key if queue.size == 1 && !@running.key?(key)
        start
        true
      end
    end

    # Forgets a key's waiting jobs (one already running finishes).
    def drop(key) = @mutex.synchronize { @queues.delete(key) }

    # Waits until no job for the key is running, at most timeout seconds.
    # Returns at once when called from that key's own job.
    def wait(key, timeout:)
      deadline = now + timeout
      @mutex.synchronize do
        while @running.key?(key) && @running[key] != Thread.current
          left = deadline - now
          return false unless left.positive?

          @done.wait(@mutex, left)
        end
      end
      true
    end

    # { key => seconds } for jobs running longer than min_seconds.
    def busy(min_seconds)
      at = now
      @mutex.synchronize { @started.transform_values { |since| at - since }.select { |_, s| s >= min_seconds } }
    end

    def shutdown
      @mutex.synchronize do
        @queues.clear
        (@threads || []).each { @ready << :stop }
      end
    end

    private

    # Callers hold @mutex.
    def start
      @threads ||= Array.new(@size) do |i|
        Thread.new do
          Thread.current.name = "gemdrop-#{@name}-#{i}"
          work
        end
      end
    end

    def work
      while (key = @ready.pop) != :stop
        job = @mutex.synchronize do
          @running[key] = Thread.current
          @started[key] = now
          @queues[key]&.shift
        end
        run(key, job) if job
        @mutex.synchronize do
          @running.delete(key)
          @started.delete(key)
          if @queues[key]&.any?
            @ready << key
          else
            @queues.delete(key)
          end
          @done.broadcast
        end
      end
    end

    def run(key, job)
      job.call
    rescue StandardError, ScriptError => e
      @log.error("Job for #{key} failed: #{e.class}: #{e.message} (#{e.backtrace&.first})")
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Runs every job right away in the caller's thread; for tests, where
  # order and timing must be predictable.
  class InlineExecutor
    def submit(_key)
      yield
      true
    end

    def drop(_key) = nil
    def wait(_key, timeout: nil) = true
    def busy(_min_seconds) = {}
    def shutdown = nil
  end
end

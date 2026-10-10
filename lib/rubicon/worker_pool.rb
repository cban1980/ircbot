module Rubicon
  # A small fixed pool of threads for slow jobs (HTTP fetches), so they
  # never block the IRC read loop. The queue is bounded: when it is full,
  # new jobs are dropped rather than piling up.
  class WorkerPool
    def initialize(size:, max_queue:, logger:)
      @size = size
      @max_queue = max_queue
      @log = logger
      @queue = Queue.new
      @threads = nil
    end

    # Returns false if the job was dropped because the queue is full.
    def submit(&job)
      return false if @stopped || @queue.size >= @max_queue

      start
      @queue << job
      true
    end

    # Stops the threads once the queued jobs are done.
    def shutdown
      @stopped = true
      (@threads || []).each { @queue << :stop }
    end

    private

    def start
      @threads ||= Array.new(@size) do |i|
        Thread.new do
          Thread.current.name = "rubicon-worker-#{i}"
          while (job = @queue.pop) != :stop
            run(job)
          end
        end
      end
    end

    def run(job)
      job.call
    rescue StandardError => e
      @log.error("Worker job failed: #{e.class}: #{e.message}")
    end
  end
end

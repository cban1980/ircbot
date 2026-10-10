require "openssl"
require "rbconfig"

module Gemdrop
  # A few separate Ruby processes that run scrypt for PasswordHasher.
  #
  # scrypt is CPU and memory heavy (~200 ms, ~64 MiB per hash) and Ruby
  # can't run any other thread while OpenSSL computes it, so in-process
  # hashing freezes the whole bot for every IDENTIFY, REGISTER and
  # PASSWORD. In worker processes, hashes run in parallel on several cores
  # while the bot carries on.
  #
  # Workers only ever see the HMAC of the password with the pepper (see
  # PasswordHasher) and the salt, never the password or the pepper. They
  # are fresh processes (not forks of the bot), started when first needed
  # and restarted if one dies or hangs.
  class HashWorkers
    class Failure < StandardError; end

    TIMEOUT = 30 # seconds for one hash

    WORKER = <<~'RUBY'.freeze
      require "openssl"
      $stdout.sync = true
      while (line = $stdin.gets)
        input, salt, log_n, r, p = line.split
        begin
          digest = OpenSSL::KDF.scrypt(input.unpack1("m0"), salt: salt.unpack1("m0"), N: 2**Integer(log_n),
                                       r: Integer(r), p: Integer(p), length: 32)
          $stdout.puts [digest].pack("m0")
        rescue StandardError => e
          $stdout.puts "error #{e.class}"
        end
      end
    RUBY

    def initialize(size:, logger: Logger.new(nil))
      @log = logger
      @idle = Queue.new
      size.times { @idle << nil } # nil: a slot whose process starts on first use
      @all = []
      @lock = Mutex.new
    end

    def scrypt(input, salt:, log_n:, r:, p:)
      worker = @idle.pop
      worker = start if worker.nil?
      worker.puts([encode(input), encode(salt), log_n, r, p].join(" "))
      raise Failure, "hash worker took longer than #{TIMEOUT}s" unless IO.select([worker], nil, nil, TIMEOUT)

      line = worker.gets or raise Failure, "hash worker exited"
      raise Failure, "hash worker failed: #{line.chomp}" if line.start_with?("error")

      decode(line.chomp)
    rescue Failure, IOError, SystemCallError => e
      stop(worker)
      worker = nil
      raise Failure, e.message
    ensure
      @idle << worker
    end

    def shutdown
      @lock.synchronize { @all.dup }.each { |worker| stop(worker) }
    end

    private

    def start
      worker = IO.popen([RbConfig.ruby, "--disable-gems", "-e", WORKER], "r+")
      @lock.synchronize { @all << worker }
      worker
    end

    def stop(worker)
      return unless worker

      @lock.synchronize { @all.delete(worker) }
      Process.kill("KILL", worker.pid)
    rescue SystemCallError
      nil
    ensure
      begin
        worker&.close
      rescue IOError, SystemCallError
        nil
      end
    end

    def encode(bytes) = [bytes].pack("m0")
    def decode(text) = text.unpack1("m0")
  end
end

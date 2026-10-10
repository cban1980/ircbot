require "openssl"

module Gemdrop
  # Peppered scrypt password hashing.
  #
  # The password is first HMAC'd with a secret pepper that is never stored
  # next to the hashes, then stretched with scrypt (memory-hard, so GPU and
  # ASIC cracking is expensive). A leaked data file alone cannot be attacked
  # offline without the pepper. Stored format:
  #
  #   scrypt$<log2 N>$<r>$<p>$<salt>$<hash>
  class PasswordHasher
    SCHEME = "scrypt".freeze
    DEFAULT_COST = { log_n: 16, r: 8, p: 1 }.freeze # ~64 MiB and ~150 ms per hash
    MIN_PEPPER_BYTES = 32

    # workers: HashWorkers to run scrypt in, so hashing doesn't stall the
    # bot; nil hashes in this process.
    def initialize(pepper:, workers: nil, logger: Logger.new(nil), **cost)
      raise ArgumentError, "pepper must be at least #{MIN_PEPPER_BYTES} bytes" if pepper.bytesize < MIN_PEPPER_BYTES

      @pepper = pepper
      @cost = DEFAULT_COST.merge(cost)
      @workers = workers
      @log = logger
    end

    def shutdown = @workers&.shutdown

    def hash(password)
      salt = OpenSSL::Random.random_bytes(16)
      digest = derive(password, salt, **@cost)
      [SCHEME, @cost[:log_n], @cost[:r], @cost[:p], encode(salt), encode(digest)].join("$")
    end

    def verify(password, stored)
      params = parse(stored) or return false

      actual = derive(password, params[:salt], **params.slice(:log_n, :r, :p))
      OpenSSL.fixed_length_secure_compare(actual, params[:digest])
    rescue ArgumentError
      false
    end

    # True when a stored hash uses different cost settings than current ones.
    def needs_rehash?(stored)
      params = parse(stored)
      params.nil? || params.slice(:log_n, :r, :p) != @cost
    end

    # Non-secret fingerprint used to detect a lost or changed pepper. The
    # label keeps the bot's old name: data files store this fingerprint, so
    # changing it would make the bot refuse every existing data file.
    def pepper_id
      OpenSSL::HMAC.hexdigest("SHA256", @pepper, "ircbot-pepper-id")[0, 16]
    end

    private

    def parse(stored)
      scheme, log_n, r, p, salt, digest = stored.to_s.split("$")
      return nil unless scheme == SCHEME && digest

      { log_n: Integer(log_n), r: Integer(r), p: Integer(p), salt: decode(salt), digest: decode(digest) }
    rescue ArgumentError
      nil
    end

    # If the workers fail, hashes are done here instead: slower for the bot,
    # but logins keep working.
    def derive(password, salt, log_n:, r:, p:)
      peppered = OpenSSL::HMAC.digest("SHA256", @pepper, password)
      if @workers
        begin
          return @workers.scrypt(peppered, salt: salt, log_n: log_n, r: r, p: p)
        rescue HashWorkers::Failure => e
          @log.warn("Hash worker failed (#{e.message}); hashing in the bot's process instead")
        end
      end
      OpenSSL::KDF.scrypt(peppered, salt: salt, N: 2**log_n, r: r, p: p, length: 32)
    end

    def encode(bytes) = [bytes].pack("m0")
    def decode(str) = str.to_s.unpack1("m0")
  end
end

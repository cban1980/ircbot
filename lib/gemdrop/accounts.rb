require "time"

module Gemdrop
  # Registered accounts (persisted) plus live login sessions (in memory).
  #
  # A session is bound to the nick, the user@host it identified from, and
  # the account's session epoch, and it expires after a fixed time. A
  # password change or account deletion (also from bin/gemdrop-account)
  # bumps the epoch or removes the record, which ends every session.
  class Accounts
    extend Synchronized

    MIN_PASSWORD_LENGTH = 8
    MAX_PASSWORD_LENGTH = 200
    DEFAULT_SESSION_TTL = 24 * 60 * 60
    DEFAULT_MAX_ACCOUNTS = 5_000

    def initialize(store, hasher, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                   session_ttl: DEFAULT_SESSION_TTL, max_accounts: DEFAULT_MAX_ACCOUNTS)
      @store = store
      @hasher = hasher
      @clock = clock
      @session_ttl = session_ttl
      @max_accounts = max_accounts
      @sessions = {}
      @lock = Monitor.new # sessions; the stored accounts have the Store's lock
      check_pepper
    end

    # Applies changed limits on config reload.
    def configure(session_ttl:, max_accounts:)
      @session_ttl = session_ttl
      @max_accounts = max_accounts
    end

    # The account name as originally registered, or nil.
    def canonical(name)
      @store.read { |data| data["accounts"].dig(key(name), "name") }
    end

    def names
      @store.read { |data| data["accounts"].values.map { |record| record["name"] } }
    end

    def register(name, password)
      check_password(name, password)
      hashed = @hasher.hash(password)
      @store.transaction do |data|
        raise Error, "The account #{name} is already registered." if data["accounts"].key?(key(name))
        raise Error, "Registration is closed: the account limit is reached." if data["accounts"].size >= @max_accounts

        data["accounts"][key(name)] = {
          "name" => name,
          "password" => hashed,
          "session_epoch" => 0,
          "registered_at" => Time.now.utc.iso8601
        }
      end
      name
    end

    # Returns the canonical account name if the password matches, else nil.
    # Unknown accounts cost the same hashing work, so response time does not
    # reveal which accounts exist.
    def authenticate(name, password)
      record = @store.read { |data| data["accounts"][key(name)]&.dup }
      unless record
        @hasher.verify(password, dummy_hash)
        return nil
      end
      return nil unless @hasher.verify(password, record["password"])

      store_hash(name, @hasher.hash(password), new_epoch: false) if @hasher.needs_rehash?(record["password"])
      record["name"]
    end

    # Callers must have verified the current password first. Ends every
    # existing session of the account.
    def set_password(name, new_password)
      check_password(name, new_password)
      store_hash(name, @hasher.hash(new_password), new_epoch: true)
    end

    def delete(name)
      @store.transaction do |data|
        raise Error, "No account named #{name}." unless data["accounts"].delete(key(name))
      end
    end

    def login(nick, userhost, account)
      @sessions[key(nick)] = { nick: nick, account: account, userhost: userhost, epoch: epoch(account), at: @clock.call }
    end

    def logout(nick)
      @sessions.delete(key(nick))
    end

    def rename(old_nick, new_nick)
      session = @sessions.delete(key(old_nick))
      @sessions[key(new_nick)] = session.merge(nick: new_nick) if session
    end

    # The account a nick is identified to, or nil. Sessions from another
    # user@host, expired ones, and ones invalidated by a password change or
    # account deletion are discarded.
    def account_for(nick, userhost)
      session = @sessions[key(nick)]
      return nil unless session
      return session[:account] if valid?(session, userhost)

      @sessions.delete(key(nick))
      nil
    end

    # The account a nick last identified to, without checking user@host.
    # Only use this where a stale answer errs on the safe side.
    def session_account(nick)
      @sessions.dig(key(nick), :account)
    end

    # [[nick, account], ...] of current, valid sessions.
    def identified
      @sessions.values.select { |session| valid?(session, session[:userhost]) }.map { |s| [s[:nick], s[:account]] }
    end

    def clear_sessions
      @sessions.clear
    end

    # Sessions are used by the bot's, the commands' and plugins' threads.
    synchronize_methods :login, :logout, :rename, :account_for, :session_account, :identified, :clear_sessions

    private

    def key(name) = Casemap.downcase(name)

    def valid?(session, userhost)
      session[:userhost] == userhost &&
        @clock.call - session[:at] <= @session_ttl &&
        epoch(session[:account]) == session[:epoch]
    end

    # nil when the account no longer exists.
    def epoch(account)
      @store.read { |data| data["accounts"][key(account)]&.fetch("session_epoch", 0) }
    end

    def store_hash(name, hashed, new_epoch:)
      @store.transaction do |data|
        record = data["accounts"][key(name)] or raise Error, "No account named #{name}."
        record["password"] = hashed
        record["session_epoch"] = record.fetch("session_epoch", 0) + 1 if new_epoch
      end
    end

    def dummy_hash
      @dummy_hash ||= @hasher.hash(OpenSSL::Random.random_bytes(16).unpack1("H*"))
    end

    def check_password(name, password)
      if password.length < MIN_PASSWORD_LENGTH
        raise Error, "Passwords must be at least #{MIN_PASSWORD_LENGTH} characters long."
      end
      raise Error, "Passwords can be at most #{MAX_PASSWORD_LENGTH} characters long." if password.length > MAX_PASSWORD_LENGTH
      raise Error, "Your password must not contain your account name." if key(password).include?(key(name))
    end

    # Refuses to start with a different pepper than the existing hashes were
    # made with; otherwise every account would silently stop working.
    def check_pepper
      @store.transaction do |data|
        data["pepper_id"] ||= @hasher.pepper_id
        next if data["pepper_id"] == @hasher.pepper_id

        raise ConfigError, "The password pepper does not match the one this data file was created with. " \
                           "Restore the original pepper file or GEMDROP_PEPPER."
      end
    end
  end
end

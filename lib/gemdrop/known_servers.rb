require "openssl"
require "fileutils"

module Gemdrop
  # Trust-on-first-use store for servers with self-signed certificates,
  # like SSH's known_hosts: the first key seen for "host:port" is recorded,
  # and later connections must present the same key.
  #
  # File format, one server per line: "host:port sha256-of-public-key".
  class KnownServers
    def initialize(path)
      @path = path
    end

    # Returns :new (first sighting, now recorded) or :known (key matches).
    # Raises if the server presented a different key than recorded.
    # Holds a file lock, so concurrent checks can't lose each other's entries.
    def check!(server, fingerprint)
      with_lock do
        current = entries
        known = current[server]
        if known.nil?
          save(current.merge(server => fingerprint))
          :new
        elsif OpenSSL.secure_compare(known, fingerprint)
          :known
        else
          raise OpenSSL::SSL::SSLError,
                "the certificate key of #{server} CHANGED (recorded #{known}, now #{fingerprint}). " \
                "This could be a man-in-the-middle attack. If the server really changed its key, " \
                "remove its line from #{@path}."
        end
      end
    end

    def entries
      return {} unless File.exist?(@path)

      SecureFile.read(@path).lines.each_with_object({}) do |line, map|
        server, fingerprint = line.split
        map[server] = fingerprint if server && fingerprint
      end
    end

    private

    LOCK = Mutex.new # flock is per process; this covers threads
    private_constant :LOCK

    def with_lock
      FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
      LOCK.synchronize do
        File.open("#{@path}.lock", File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        end
      end
    end

    def save(map)
      tmp = "#{@path}.tmp"
      FileUtils.rm_f(tmp)
      File.open(tmp, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |file|
        map.sort.each { |server, fingerprint| file.puts("#{server} #{fingerprint}") }
        file.fsync
      end
      File.rename(tmp, @path)
    end
  end
end

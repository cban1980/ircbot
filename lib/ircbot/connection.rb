require "socket"
require "openssl"

module IRCBot
  # Line-oriented TCP/TLS connection with simple outgoing flood control.
  #
  # TLS is verified against the system CA store with hostname checking and
  # TLS 1.2+ by default. Servers with self-signed certificates can be
  # trusted in two ways:
  # - tls_fingerprint pins the server's public key (SHA-256 of its
  #   SubjectPublicKeyInfo); with tls_verify off, the pin alone is trusted.
  # - tls_self_signed trusts on first use (KnownServers): OpenSSL still
  #   verifies as usual, but a failed verification is accepted if the key
  #   matches the one recorded the first time, like SSH's known_hosts.
  class Connection
    READ_TIMEOUT = 600 # seconds of silence before treating the link as dead
    BURST = 5          # messages that may be sent back-to-back
    RATE = 1.0         # sustained messages per second after the burst
    MAX_LINE = 8_704   # IRCv3 tags (8191) + message (512); longer lines are dropped

    # TLS 1.2 suites with forward secrecy and authenticated encryption only.
    # (TLS 1.3 suites are all of that kind and are not affected.)
    DEFAULT_CIPHERS = "ECDHE+AESGCM:ECDHE+CHACHA20".freeze

    TLS_VERSIONS = {
      "1.2" => OpenSSL::SSL::TLS1_2_VERSION,
      "1.3" => OpenSSL::SSL::TLS1_3_VERSION
    }.freeze

    def self.from_config(config)
      new(
        host: config["server"], port: config["port"], tls: config["tls"], verify: config["tls_verify"],
        min_version: config["tls_min_version"], fingerprint: config["tls_fingerprint"],
        ciphers: config["tls_ciphers"] || DEFAULT_CIPHERS,
        known_servers: config["tls_self_signed"] ? KnownServers.new(config["tls_known_servers"]) : nil
      )
    end

    # Lines are UTF-8 when valid; otherwise (common on IRCnet) Latin-1.
    def self.decode(line)
      utf8 = line.dup.force_encoding(Encoding::UTF_8)
      utf8.valid_encoding? ? utf8 : line.dup.force_encoding(Encoding::ISO_8859_1).encode(Encoding::UTF_8)
    end

    def self.normalize_fingerprint(fingerprint)
      fingerprint.to_s.delete(":").downcase
    end

    # SHA-256 of the certificate's public key, as pinned by tls_fingerprint.
    def self.spki_fingerprint(cert)
      OpenSSL::Digest::SHA256.hexdigest(cert.public_key.public_to_der)
    end

    def initialize(host:, port:, tls: true, verify: true, min_version: "1.2", fingerprint: nil,
                   ciphers: DEFAULT_CIPHERS, known_servers: nil)
      @host = host
      @port = port
      @tls = tls
      @verify = verify
      @ciphers = ciphers
      @known_servers = known_servers
      @trust = nil
      @min_version = TLS_VERSIONS.fetch(min_version.to_s)
      @fingerprint = fingerprint && self.class.normalize_fingerprint(fingerprint)
      @socket = nil
      @write_lock = Mutex.new
    end

    def connect
      tcp = Socket.tcp(@host, @port, connect_timeout: 30)
      tcp.setsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE, true)
      tcp.timeout = READ_TIMEOUT
      @socket = @tls ? wrap_tls(tcp) : tcp
      @allowance = BURST.to_f
      @last_send = now
    end

    # Human-readable description of the transport, for logging.
    def security
      return "PLAINTEXT, NOT ENCRYPTED" unless @socket.is_a?(OpenSSL::SSL::SSLSocket)

      trust =
        case @trust
        when :tofu_new then "self-signed certificate, NEW key #{@peer_key} trusted on first use"
        when :tofu_known then "self-signed certificate, key matches the one trusted on first use"
        else @verify ? "certificate verified" : "certificate NOT verified"
        end
      trust += ", key pinned" if @fingerprint
      "#{@socket.ssl_version}, #{@socket.cipher.first}, #{trust}"
    end

    # True when this connection recorded a self-signed key for the first time.
    def first_use? = @trust == :tofu_new

    # The next line, decoded; overlong lines are skipped entirely. Returns
    # nil at end of stream, including when another thread called #close.
    def gets
      loop do
        socket = @socket or return nil
        line = socket.gets("\n", MAX_LINE) or return nil
        return self.class.decode(line) if line.end_with?("\n")

        skip_rest_of_line(socket) or return nil
      end
    end

    # Thread-safe: worker threads send link previews through here too.
    def write(line)
      @write_lock.synchronize do
        socket = @socket or raise IOError, "not connected"
        throttle
        socket.write("#{line.delete("\r\n")}\r\n")
      end
    end

    def close
      @socket&.close
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
      nil
    ensure
      @socket = nil
    end

    private

    def skip_rest_of_line(socket)
      loop do
        rest = socket.gets("\n", MAX_LINE) or return false
        return true if rest.end_with?("\n")
      end
    end

    def wrap_tls(tcp)
      context = OpenSSL::SSL::SSLContext.new
      context.set_params(
        verify_mode: @verify ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE,
        verify_hostname: @verify
      )
      context.min_version = @min_version
      context.ciphers = @ciphers
      failures = []
      if @verify && @known_servers && !@fingerprint
        # Let the handshake finish despite failed checks; the key decides below.
        context.verify_callback = lambda do |ok, store_context|
          failures << store_context.error_string unless ok
          true
        end
      end
      ssl = OpenSSL::SSL::SSLSocket.new(tcp, context)
      ssl.hostname = @host
      ssl.sync_close = true
      ssl.connect
      @trust = nil
      if failures.any?
        trust_on_first_use(ssl.peer_cert)
      elsif @verify
        ssl.post_connection_check(@host)
      end
      check_pin(ssl.peer_cert) if @fingerprint
      ssl
    rescue StandardError
      (ssl || tcp).close
      raise
    end

    def trust_on_first_use(cert)
      raise OpenSSL::SSL::SSLError, "server sent no certificate" unless cert

      @peer_key = self.class.spki_fingerprint(cert)
      @trust = @known_servers.check!("#{@host}:#{@port}", @peer_key) == :new ? :tofu_new : :tofu_known
    end

    def check_pin(cert)
      actual = self.class.spki_fingerprint(cert)
      return if OpenSSL.secure_compare(actual, @fingerprint)

      raise OpenSSL::SSL::SSLError, "server key fingerprint #{actual} does not match tls_fingerprint"
    end

    # Token bucket: up to BURST messages immediately, then RATE per second.
    def throttle
      current = now
      @allowance = [@allowance + (current - @last_send) * RATE, BURST].min
      @last_send = current
      if @allowance < 1
        sleep((1 - @allowance) / RATE)
        @allowance = 0
        @last_send = now
      else
        @allowance -= 1
      end
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end

require "socket"
require "openssl"

module Gemdrop
  # Line-oriented TCP/TLS connection with simple outgoing flood control.
  #
  # Outgoing lines are queued and sent by a writer thread at the flood
  # control rate, so sending never makes the caller wait (the bot's
  # handling of other lines carries on). Urgent lines (PONG, QUIT) jump the
  # queue. If far too much is queued (a runaway plugin), new lines are
  # dropped rather than letting the bot fall minutes behind.
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
    MAX_QUEUE = 300    # lines waiting to be sent (~5 minutes at RATE)
    FLUSH_TIMEOUT = 3  # seconds close(flush: true) waits for queued lines

    # TLS 1.2 suites with forward secrecy and authenticated encryption only.
    # (TLS 1.3 suites are all of that kind and are not affected.)
    DEFAULT_CIPHERS = "ECDHE+AESGCM:ECDHE+CHACHA20".freeze

    TLS_VERSIONS = {
      "1.2" => OpenSSL::SSL::TLS1_2_VERSION,
      "1.3" => OpenSSL::SSL::TLS1_3_VERSION
    }.freeze

    def self.from_config(config) = from_params(params(config))

    # A network's connection settings as plain data (what a KeeperConnection
    # hands the keeper; from_params makes the Connection from it).
    def self.params(config)
      { "host" => config["server"], "port" => config["port"], "tls" => config["tls"], "verify" => config["tls_verify"],
        "min_version" => config["tls_min_version"].to_s, "fingerprint" => config["tls_fingerprint"],
        "ciphers" => config["tls_ciphers"] || DEFAULT_CIPHERS,
        "known_servers" => config["tls_self_signed"] ? config["tls_known_servers"] : nil }
    end

    def self.from_params(params)
      new(host: params["host"], port: params["port"], tls: params["tls"], verify: params["verify"],
          min_version: params["min_version"], fingerprint: params["fingerprint"], ciphers: params["ciphers"],
          known_servers: params["known_servers"] && KnownServers.new(params["known_servers"]))
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
      @queued = ConditionVariable.new
      @urgent = []
      @normal = []
      @writer = nil
      @dropped = 0
    end

    # Lines dropped because the queue was full; reset when read.
    def take_dropped = @write_lock.synchronize { @dropped.tap { @dropped = 0 } }

    def connect
      tcp = Socket.tcp(@host, @port, connect_timeout: 30)
      tcp.setsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE, true)
      tcp.timeout = READ_TIMEOUT
      @socket = @tls ? wrap_tls(tcp) : tcp
      @allowance = BURST.to_f
      @last_send = now
      @write_lock.synchronize do
        @urgent.clear
        @normal.clear
      end
      start_writer
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

    # Queues a line; thread-safe. urgent: ahead of everything queued.
    # Raises IOError when not connected; returns false if the line was
    # dropped because the queue is full.
    def write(line, urgent: false)
      @write_lock.synchronize do
        raise IOError, "not connected" unless @socket

        if urgent
          @urgent << line.delete("\r\n")
        elsif @normal.size >= MAX_QUEUE
          @dropped += 1
          next false
        else
          @normal << line.delete("\r\n")
        end
        @queued.signal
        true
      end
    end

    # flush: first give queued lines (e.g. a QUIT) a moment to go out.
    # Closes the connection open when called: if the server hangs up on
    # the QUIT and the bot reconnects meanwhile, the new one stays open.
    def close(flush: false)
      target = @write_lock.synchronize { @socket }
      wait_for_queue(target) if flush
      socket = @write_lock.synchronize do
        next unless @socket && @socket.equal?(target)

        @queued.broadcast
        @socket.tap { @socket = nil }
      end
      return unless socket

      begin
        socket&.close
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
        nil
      end
      @writer&.join(1) unless Thread.current == @writer
    end

    private

    def start_writer
      @writer = Thread.new do
        Thread.current.name = "gemdrop-writer"
        write_loop
      end
    end

    def write_loop
      loop do
        line, socket = @write_lock.synchronize do
          @queued.wait(@write_lock) while @socket && @urgent.empty? && @normal.empty?
          @sending = true if @socket # a line is out of the queue but not yet sent
          @socket && [@urgent.shift || @normal.shift, @socket]
        end
        break unless socket

        throttle
        socket.write("#{line}\r\n")
        @write_lock.synchronize { @sending = false }
      end
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
      # A failed write ends the connection: the read loop sees it and the
      # bot reconnects; further writes raise instead of piling up.
      socket = @write_lock.synchronize { @socket.tap { @socket = nil } }
      begin
        socket&.close
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
        nil
      end
    end

    def wait_for_queue(socket)
      deadline = now + FLUSH_TIMEOUT
      sleep 0.05 while now < deadline && @write_lock.synchronize do
        socket && @socket.equal?(socket) && (@sending || @urgent.any? || @normal.any?)
      end
    end

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

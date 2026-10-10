require "socket"
require "json"
require "fileutils"

module Gemdrop
  # Keeps the bot's IRC connections open while the bot itself restarts,
  # so updating the bot (its core, plugins, anything) never makes it leave
  # IRC: no quit, no rejoin, same nick. A small, separate process that
  # rarely changes (bin/gemdrop-keeper); the bot reaches it through a Unix
  # socket (KeeperConnection) and runs everything else.
  #
  # Per network it holds one connection, opened when the bot first attaches
  # with that network's connection settings (TLS checks, flood control and
  # trust on first use are Connection's). While a bot is attached, lines
  # pass straight through. When it detaches (or dies), the keeper answers
  # the server's PINGs, keeps pinging a quiet server, and buffers what
  # arrives. The next bot to attach gets the connection back as if it had
  # just registered: the welcome and ISUPPORT lines (with the current nick),
  # the capabilities in use, a JOIN for each channel it is in (and the
  # server is asked for their names and topics), then what was buffered.
  #
  # The protocol, one line each way:
  #   bot:    ATTACH {"network":..., "params":{connection settings}}
  #   keeper: ATTACHED {"link":id, "resumed":bool, "security":..., "first_use":bool}
  #           or ERROR <reason> (the bot retries later)
  #   then    L <irc line>      both ways; from the bot also U <line> (urgent)
  #   bot:    DROP              send what is queued and close the IRC connection
  #           DETACH            leave; the connection stays for the next bot
  # A lost IRC connection closes the bot's socket; it attaches again for a
  # new one. A new bot attaching to a network takes over from the old one.
  class Keeper
    MAX_BUFFER = 2_000      # lines kept while no bot is attached
    BUFFER_SECONDS = 600    # and for at most this long
    IDLE_PING = 240         # seconds of server silence before pinging it
    CHECK_INTERVAL = 30
    CLIENT_SEND_TIMEOUT = 10 # seconds a stuck bot may block a write to it
    MAX_BURST = 60
    MAX_PATH = 107 # bytes in a Unix socket's path (Linux)
    # Registration lines replayed to a bot that takes over a connection.
    BURST = %w[001 002 003 004 005 042 900 903 376 422].freeze

    Link = Struct.new(:network, :params, :conn, :id, :nick, :userhost, :burst, :caps, :channels, :buffer,
                      :client, :last_rx, :pinged, :lock, :reader, :dropped, keyword_init: true)

    attr_reader :path

    # connector: makes the Connection for a network's settings (tests swap it).
    def initialize(path, logger:, connector: nil)
      @path = path
      @log = logger
      @connector = connector || ->(params) { Connection.from_params(params) }
      @links = {}
      @attach_locks = {} # network => Mutex: one attach at a time per network
      @lock = Mutex.new
      @next_id = 0
      @stopping = false
    end

    # Serves until #stop (or SIGTERM/SIGINT with handle_signals).
    def run(handle_signals: true)
      listen
      stops = Queue.new
      if handle_signals
        %w[TERM INT].each { |signal| Signal.trap(signal) { stops << "Shutting down" } }
      end
      @stops = stops
      acceptor = Thread.new { accept_loop }
      checker = Thread.new { check_loop }
      reason = stops.pop
      shutdown(reason)
      [acceptor, checker].each(&:kill)
    end

    def stop(reason = "Shutting down") = @stops&.push(reason)

    # The networks with a connection, for tests and logs.
    def networks = @lock.synchronize { @links.keys }

    def listen
      raise Error, "#{@path} is too long for a socket (at most #{MAX_PATH} bytes); use a shorter path" if @path.bytesize > MAX_PATH

      FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
      if File.exist?(@path)
        begin
          UNIXSocket.new(@path).close
          raise Error, "another keeper is already listening on #{@path}"
        rescue Errno::ECONNREFUSED, Errno::ENOENT
          File.delete(@path) # left over from a keeper that died
        end
      end
      @server = UNIXServer.new(@path)
      File.chmod(0o600, @path)
      @log.info("Keeper listening on #{@path}")
    end

    private

    def accept_loop
      loop do
        client = @server.accept
        Thread.new(client) { |sock| serve(sock) }
      end
    rescue IOError, SystemCallError
      nil # closed on shutdown
    end

    # --- a bot ------------------------------------------------------------------------------

    def serve(sock)
      sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDTIMEO, [CLIENT_SEND_TIMEOUT, 0].pack("l_2"))
      verb, body = sock.gets&.chomp&.split(" ", 2)
      return send_line(sock, "ERROR expected ATTACH") unless verb == "ATTACH"

      request = JSON.parse(body.to_s)
      network = request["network"].to_s
      params = request["params"]
      return send_line(sock, "ERROR missing network or params") if network.empty? || !params.is_a?(Hash)

      link = attach(network, params, sock) or return
      while (line = sock.gets)
        break unless from_bot(link, sock, line.chomp)
      end
    rescue JSON::ParserError
      send_line(sock, "ERROR invalid ATTACH")
    rescue IOError, SystemCallError
      nil
    ensure
      link&.lock&.synchronize { link.client = nil if link.client.equal?(sock) }
      begin
        sock.close
      rescue IOError
        nil
      end
    end

    # Hands the network's connection to this bot: the live one if its
    # settings are the same (resumed), else a new one. nil if that failed.
    def attach(network, params, sock)
      @lock.synchronize { @attach_locks[network] ||= Mutex.new }.synchronize { attach_now(network, params, sock) }
    end

    def attach_now(network, params, sock)
      link = @lock.synchronize { @links[network] }
      if link && link.params == params && link.reader&.alive?
        link.lock.synchronize do
          old = link.client
          link.client = sock
          close_quietly(old) if old && !old.equal?(sock) # a new bot takes over
          send_line(sock, "ATTACHED #{JSON.generate('link' => link.id, 'resumed' => true,
                                                    'security' => link.conn.security, 'first_use' => false)}")
          replay(link, sock)
        end
        @log.info("#{network}: a bot took over the connection (#{link.channels.size} channels, nick #{link.nick})")
        return link
      end

      drop(link, "Reconnecting") if link # different settings: a new connection
      open_link(network, params, sock)
    end

    def open_link(network, params, sock)
      conn = @connector.call(params)
      conn.connect
      link = Link.new(network: network, params: params, conn: conn, id: @lock.synchronize { @next_id += 1 },
                      nick: nil, userhost: nil, burst: [], caps: [], channels: {}, buffer: [], client: sock,
                      last_rx: now, pinged: false, lock: Mutex.new)
      @lock.synchronize { @links[network] = link }
      @log.info("#{network}: connected to #{params['host']}:#{params['port']} (#{conn.security})")
      link.lock.synchronize do
        send_line(sock, "ATTACHED #{JSON.generate('link' => link.id, 'resumed' => false,
                                                  'security' => conn.security, 'first_use' => conn.first_use?)}")
        link.reader = Thread.new { read_server(link) }
      end
      link
    rescue StandardError => e
      @log.warn("#{network}: can't connect to #{params['host']}:#{params['port']}: #{e.class}: #{e.message}")
      send_line(sock, "ERROR #{e.class}: #{e.message}".delete("\r\n"))
      nil
    end

    # A line from the bot; false once it is leaving.
    def from_bot(link, sock, line)
      return false unless link.lock.synchronize { link.client.equal?(sock) } # taken over

      case line
      when /\AL (.+)/m then write_server(link, Regexp.last_match(1))
      when /\AU (.+)/m then write_server(link, Regexp.last_match(1), urgent: true)
      when "DROP"
        drop(link, nil)
        return false
      when "DETACH"
        @log.info("#{link.network}: the bot detached; keeping the connection")
        link.lock.synchronize { link.client = nil }
        return false
      end
      true
    end

    def write_server(link, line, urgent: false)
      link.conn.write(line, urgent: urgent)
    rescue IOError
      nil # the reader notices the connection is gone
    end

    # Sends anything queued (a QUIT the bot sent before), closes the
    # connection and forgets it. reason: a QUIT of the keeper's own first.
    def drop(link, reason)
      link.dropped = true
      @lock.synchronize { @links.delete(link.network) if @links[link.network].equal?(link) }
      write_server(link, "QUIT :#{reason}", urgent: true) if reason
      link.conn.close(flush: true)
      @log.info("#{link.network}: connection closed#{" (#{reason})" if reason}")
    end

    # --- the server ---------------------------------------------------------------------------

    def read_server(link)
      while (line = link.conn.gets)
        line = line.chomp
        msg = Message.parse(line)
        link.lock.synchronize do
          link.last_rx = now
          link.pinged = false
          track(link, msg, line)
          next if link.client && send_line(link.client, "L #{line}")

          link.client = nil
          next write_server(link, "PONG :#{msg.params.last}", urgent: true) if msg.command == "PING"

          buffer(link, line)
        end
      end
      @log.warn("#{link.network}: the server closed the connection") unless link.dropped
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError => e
      @log.warn("#{link.network}: connection lost: #{e.class}: #{e.message}") unless link.dropped
    ensure
      lost(link)
    end

    # The connection ended: forget it and close the bot's socket, so the bot
    # attaches again for a new one.
    def lost(link)
      @lock.synchronize { @links.delete(link.network) if @links[link.network].equal?(link) }
      link.conn.close
      link.lock.synchronize do
        close_quietly(link.client) if link.client
        link.client = nil
      end
    end

    # What a bot taking over needs to know about the connection.
    def track(link, msg, line)
      case msg.command
      when "001"
        link.nick = msg.params[0]
        link.burst = [line]
        link.channels.clear
      when *BURST then link.burst << line if link.burst.size < MAX_BURST
      when "CAP" then track_caps(link, msg)
      when "NICK" then link.nick = msg.params[0] if self?(link, msg.nick)
      when "JOIN"
        if self?(link, msg.nick)
          link.channels[Casemap.downcase(msg.params[0])] = msg.params[0]
          link.userhost = msg.userhost
        end
      when "PART" then link.channels.delete(Casemap.downcase(msg.params[0])) if self?(link, msg.nick)
      when "KICK" then link.channels.delete(Casemap.downcase(msg.params[0])) if self?(link, msg.params[1])
      end
    end

    def track_caps(link, msg)
      list = msg.params.last.to_s.split
      case msg.params[1].to_s.upcase
      when "ACK" then list.each { |cap| cap.start_with?("-") ? link.caps.delete(cap[1..]) : link.caps |= [cap] }
      when "DEL" then link.caps -= list
      end
    end

    def self?(link, nick) = link.nick && nick && Casemap.eq?(nick, link.nick)

    def buffer(link, line)
      link.buffer << [now, line]
      link.buffer.shift while link.buffer.size > MAX_BUFFER
    end

    # Brings a bot taking over up to date (called with the link's lock).
    def replay(link, sock)
      nick = link.nick || "*"
      lines = link.burst.map { |line| line.sub(/\A((?:@\S+ )?:\S+ \d{3} )\S+/) { "#{Regexp.last_match(1)}#{nick}" } }
      lines.unshift(":keeper CAP #{nick} ACK :#{link.caps.join(' ')}") if link.caps.any?
      link.channels.each_value do |channel|
        lines << ":#{nick}!#{link.userhost || 'keeper@keeper'} JOIN #{channel}"
        write_server(link, "NAMES #{channel}")
        write_server(link, "TOPIC #{channel}")
      end
      cutoff = now - BUFFER_SECONDS
      lines.concat(link.buffer.filter_map { |at, line| line if at >= cutoff })
      link.buffer.clear
      lines.each { |line| send_line(sock, "L #{line}") }
    end

    # --- upkeep ---------------------------------------------------------------------------------

    # While no bot is attached, pings a server that has been quiet, so a
    # dead connection is noticed (Connection's read timeout then ends it).
    def check_loop
      loop do
        sleep CHECK_INTERVAL
        @lock.synchronize { @links.values }.each do |link|
          link.lock.synchronize do
            next if link.client || link.pinged || now - link.last_rx < IDLE_PING

            link.pinged = true
            write_server(link, "PING :keeper", urgent: true)
          end
        end
      end
    end

    def shutdown(reason)
      @stopping = true
      @log.info("Keeper stopping: #{reason}")
      @server&.close
      File.delete(@path) if File.socket?(@path)
      links = @lock.synchronize { @links.values }
      links.map { |link| Thread.new { drop(link, reason) } }.each(&:join)
      links.each { |link| link.lock.synchronize { close_quietly(link.client) if link.client } }
    end

    # false if the bot's socket is gone (or stuck).
    def send_line(sock, line)
      sock.write("#{line.delete("\r\n")}\n")
      true
    rescue IOError, SystemCallError
      close_quietly(sock)
      false
    end

    def close_quietly(sock)
      sock.close
    rescue IOError, SystemCallError
      nil
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end

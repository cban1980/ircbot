require "socket"
require "json"

module Gemdrop
  # The bot's side of a Keeper: works like a Connection, but the IRC
  # connection itself is the keeper's, so it outlives this process. Used
  # when the bot runs with a keeper (keeper_socket, or GEMDROP_KEEPER_SOCKET).
  #
  # close ends the IRC connection (the keeper sends anything queued, such
  # as a QUIT, first); detach leaves it to the keeper for the next bot.
  class KeeperConnection
    attr_reader :link, :security

    def initialize(path:, network:, params:)
      @path = path
      @network = network
      @params = params
      @lock = Mutex.new
      @sock = nil
    end

    # Attaches to the network's connection; raises IOError (or a
    # SystemCallError if the keeper isn't running) when it can't.
    def connect
      sock = UNIXSocket.new(@path)
      sock.write("ATTACH #{JSON.generate('network' => @network, 'params' => @params)}\n")
      answer = sock.gets.to_s.chomp
      verb, body = answer.split(" ", 2)
      unless verb == "ATTACHED"
        sock.close
        raise IOError, "the keeper refused: #{answer.delete_prefix('ERROR ').then { |s| s.empty? ? 'no answer' : s }}"
      end

      info = JSON.parse(body)
      @link = info["link"]
      @resumed = info["resumed"] == true
      @security = "#{info['security']}, kept by the keeper"
      @first_use = info["first_use"] == true
      @detached = false
      @lock.synchronize { @sock = sock }
    end

    # True when this took over a connection that was already registered
    # (the bot then doesn't register again; the keeper replays the state).
    def resumed? = @resumed
    def first_use? = @first_use

    def gets
      sock = @lock.synchronize { @sock } or return nil
      loop do
        line = sock.gets or return nil
        next unless line.start_with?("L ")

        return line.delete_prefix("L ").force_encoding(Encoding::UTF_8).scrub
      end
    rescue IOError, SystemCallError
      nil
    end

    # Raises IOError when not attached. The keeper does the flood control.
    def write(line, urgent: false)
      @lock.synchronize do
        raise IOError, "not connected" unless @sock

        @sock.write("#{urgent ? 'U' : 'L'} #{line.delete("\r\n")}\n")
        true
      end
    rescue SystemCallError => e
      raise IOError, e.message
    end

    # Ends the IRC connection (after what is queued, e.g. a QUIT). After
    # #detach, just closes the socket.
    def close(flush: false)
      _ = flush # the keeper always sends what is queued first
      finish(@detached ? nil : "DROP")
    end

    # Leaves the IRC connection to the keeper.
    def detach
      @detached = true
      finish("DETACH")
    end

    def take_dropped = 0

    private

    def finish(last_word)
      sock = @lock.synchronize { @sock.tap { @sock = nil } } or return
      begin
        sock.write("#{last_word}\n") if last_word
      rescue IOError, SystemCallError
        nil
      end
      sock.close
    rescue IOError, SystemCallError
      nil
    end
  end
end

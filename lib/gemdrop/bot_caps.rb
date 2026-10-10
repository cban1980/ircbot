module Gemdrop
  # IRCv3 capability negotiation (CAP), for plugins: they declare what they
  # want (Plugin.wants_cap) and the bot asks for whatever the server offers,
  # at registration, or once connected for plugins loaded later. Only when
  # some plugin wants a capability: otherwise the bot registers as it always
  # did, and servers without CAP (IRCnet's ircd) never see it.
  class Bot
    CAP_TIMEOUT = 10 # seconds registration waits for CAP replies

    def caps = @caps.dup
    def cap?(name) = @caps.include?(name.to_s.downcase)

    private

    # Asks what the server offers; at registration, the server holds it
    # until CAP END (see #cap_end).
    def cap_start(registering:)
      @cap_offered = {}
      @cap_listing = {}
      @cap_requested = []
      @cap_negotiating = registering
      @cap_deadline = @clock.call + CAP_TIMEOUT
      @cap_asked = true
      send_raw("CAP LS 302")
    end

    def reset_caps
      @caps = []
      @cap_offered = {}
      @cap_listing = {}
      @cap_requested = []
      @cap_negotiating = false
      @cap_asked = false
    end

    # CAP <me> <LS|ACK|NAK|NEW|DEL|LIST> [*] :<caps>
    def on_cap(msg)
      sub = msg.params[1].to_s.upcase
      more = msg.params[2] == "*" && msg.params.size > 3
      names = msg.params.last.to_s.split
      case sub
      when "LS", "NEW"
        names.each do |entry|
          name, value = entry.split("=", 2)
          @cap_listing[name.downcase] = value
        end
        return if more

        @cap_offered.merge!(@cap_listing)
        @cap_listing = {}
        cap_end unless request_caps
      when "ACK"
        names.each { |name| name.start_with?("-") ? @caps.delete(name[1..].downcase) : @caps |= [name.downcase] }
        @log.info("Capabilities enabled: #{@caps.join(' ')}") if @caps.any?
        cap_end
      when "NAK"
        @log.warn("The server refused capabilities: #{names.join(' ')}")
        cap_end
      when "DEL"
        names.each { |name| @caps.delete(name.downcase) && @cap_offered.delete(name.downcase) }
      end
    end

    # Requests the capabilities plugins want that the server offers and
    # weren't asked for yet. Returns true if it asked for any.
    def request_caps
      wanted = @plugins.wanted_caps & @cap_offered.keys
      missing = wanted - @caps - @cap_requested
      return false if missing.empty?

      @cap_requested |= missing
      send_raw("CAP REQ :#{missing.join(' ')}")
      true
    end

    def cap_end
      return unless @cap_negotiating

      @cap_negotiating = false
      send_raw("CAP END")
    end

    # From the ticker: a server that never finished CAP isn't waited for,
    # and plugins loaded since get what they want.
    def check_caps
      return cap_end if @cap_negotiating && @clock.call > @cap_deadline
      return unless @welcomed && !@cap_negotiating && @plugins.wanted_caps.any?

      @cap_asked ? request_caps : cap_start(registering: false)
    end
  end
end

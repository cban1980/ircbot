module IRCBot
  # IRC actions for plugins: messages, CTCP, joining and parting, modes,
  # kicks and bans, topics, invites and raw lines. Shared by Plugin (its
  # own network) and Plugin::Remote (another network).
  #
  # Everything is checked before it is sent: targets must be single words,
  # text is cut to fit one line and can't carry line breaks, so nothing a
  # plugin passes on from users can inject protocol lines. Each method
  # returns true if everything was sent, false if not (disconnected, or the
  # plugin is unloaded). Invalid arguments raise ArgumentError.
  #
  # Including classes provide irc_write(line), irc_join(channel, key),
  # irc_part(channel, reason), irc_isupport (an ISupport) and
  # irc_userhost(nick).
  module PluginIRC
    MAX_LINE_BYTES = 400 # leaves room for the prefix the server adds
    MAX_LINES = 10       # per say/notice call
    MAX_RAW_BYTES = 510
    # The bot manages these itself; a plugin sending them would break it.
    BLOCKED_RAW = %w[PASS USER NICK QUIT OPER SERVICE SQUIT KILL DIE RESTART CAP AUTHENTICATE].freeze

    TARGET = /\A[^\s,\0:][^\s,\0]*\z/
    WORD = /\A[^\s\0:][^\s\0]*\z/
    CTCP_COMMAND = /\A[A-Za-z0-9]{1,32}\z/
    MODES = /\A(?:[+-][A-Za-z]+)+\z/

    # --- messages and CTCP ------------------------------------------------------

    # Text is split on line breaks (at most MAX_LINES lines); long lines are cut.
    def say(target, text) = send_text("PRIVMSG", target, text)
    def notice(target, text) = send_text("NOTICE", target, text)

    # /me: one line.
    def action(target, text) = send_ctcp("PRIVMSG", target, "ACTION", text)

    # A CTCP request, e.g. ctcp("alice", "VERSION").
    def ctcp(target, command, text = nil) = send_ctcp("PRIVMSG", target, command, text)

    # A CTCP answer (a notice), e.g. ctcp_reply("alice", "FINGER", "...").
    def ctcp_reply(nick, command, text = nil) = send_ctcp("NOTICE", nick, command, text)

    # --- channels ----------------------------------------------------------------

    # Joins a channel and stays in it across reconnects and config reloads,
    # until #part or until the plugin is unloaded.
    def join(channel, key = nil)
      check_channel!(channel)
      raise ArgumentError, "invalid channel key" if key && !key.to_s.match?(/\A[^\s,\0:]{1,50}\z/)

      irc_join(channel.to_s, key&.to_s)
    end

    # Leaves a channel this plugin joined. Channels in the config or
    # registered with the bot can't be parted by plugins.
    def part(channel, reason = nil)
      check_channel!(channel)
      irc_part(channel.to_s, reason && clean(reason))
    end

    # mode("#chan", "+nt") or mode("#chan", "+l", 50) or mode("#chan", "+k-l", "key").
    def mode(channel, modes, *params)
      check_channel!(channel)
      raise ArgumentError, "modes must look like \"+nt\" or \"+o-v\"" unless modes.to_s.match?(MODES)

      params = params.flatten.map(&:to_s).each { |param| check_word!(param) }
      irc_write(["MODE", channel, modes, *params].join(" "))
    end

    # Status and ban modes for several nicks or masks at once; sent in as
    # few lines as the server's MODES limit allows.
    def op(channel, *nicks) = list_modes(channel, true, "o", nicks)
    def deop(channel, *nicks) = list_modes(channel, false, "o", nicks)
    def voice(channel, *nicks) = list_modes(channel, true, "v", nicks)
    def devoice(channel, *nicks) = list_modes(channel, false, "v", nicks)
    def ban(channel, *masks) = list_modes(channel, true, "b", masks)
    def unban(channel, *masks) = list_modes(channel, false, "b", masks)

    def kick(channel, nick, reason = nil)
      check_channel!(channel)
      check_word!(nick)
      irc_write("KICK #{channel} #{nick}#{" :#{clean(reason)}" if reason}")
    end

    # Bans *!*user@host of the nick, then kicks it. Raises Error when the
    # nick's user@host isn't known (it shares no channel with the bot).
    def kickban(channel, nick, reason = nil)
      mask = ban_mask(nick) or raise Error, "I don't know #{nick}'s host."
      ban(channel, mask) && kick(channel, nick, reason)
    end

    # "*!*user@host" for a nick whose user@host is known, else nil. A
    # leading "~" (no identd) is dropped from the user.
    def ban_mask(nick)
      userhost = irc_userhost(nick) or return nil
      user, host = userhost.split("@", 2)
      "*!*#{user.delete_prefix('~')}@#{host}"
    end

    def set_topic(channel, text)
      check_channel!(channel)
      irc_write("TOPIC #{channel} :#{clean(text)}")
    end

    def invite(nick, channel)
      check_word!(nick)
      check_channel!(channel)
      irc_write("INVITE #{nick} #{channel}")
    end

    # Any other protocol line, e.g. raw("WHOIS alice"). One line only;
    # commands the bot manages itself (NICK, QUIT, ...) are refused.
    def raw(line)
      line = line.to_s
      raise ArgumentError, "raw lines can't contain line breaks or NUL" if line.match?(/[\r\n\0]/)
      raise ArgumentError, "raw line is empty or too long" if line.strip.empty? || line.bytesize > MAX_RAW_BYTES

      command = line.split.first.upcase
      raise ArgumentError, "plugins can't send #{command}; the bot manages it" if BLOCKED_RAW.include?(command)

      irc_write(line)
    end

    private

    def send_text(command, target, text)
      check_target!(target)
      text.to_s.split(/[\r\n]+/).reject(&:empty?).first(MAX_LINES).all? do |line|
        irc_write("#{command} #{target} :#{fit(line.delete("\0"))}")
      end
    end

    def send_ctcp(command, target, ctcp, text)
      check_target!(target)
      raise ArgumentError, "invalid CTCP command #{ctcp.inspect}" unless ctcp.to_s.match?(CTCP_COMMAND)

      body = text.nil? ? "" : " #{clean(text)}"
      irc_write("#{command} #{target} :\x01#{ctcp.to_s.upcase}#{fit(body)}\x01")
    end

    def list_modes(channel, set, mode, args)
      check_channel!(channel)
      args = args.flatten.map(&:to_s).each { |arg| check_word!(arg) }
      args.each_slice(irc_isupport.max_modes).all? do |slice|
        irc_write("MODE #{channel} #{set ? '+' : '-'}#{mode * slice.size} #{slice.join(' ')}")
      end
    end

    # One line of text: no line breaks, NUL or CTCP delimiters, cut to fit.
    def clean(text) = fit(text.to_s.gsub(/[\r\n\0\x01]+/, " ").strip)

    def fit(line)
      line.bytesize > MAX_LINE_BYTES ? line.byteslice(0, MAX_LINE_BYTES).scrub("") : line
    end

    def check_target!(target)
      raise ArgumentError, "invalid target #{target.inspect}" unless target.to_s.match?(TARGET)
    end

    def check_word!(word)
      raise ArgumentError, "invalid nick or mask #{word.inspect}" unless word.to_s.match?(WORD)
    end

    def check_channel!(channel)
      return if irc_isupport.channel?(channel) && channel.to_s.match?(TARGET) && !channel.to_s.include?("\a")

      raise ArgumentError, "#{channel.inspect} is not a channel name"
    end
  end
end

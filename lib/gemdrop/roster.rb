module Gemdrop
  # In-memory view of the channels the bot is in: who is there (with their
  # status modes and, when known, user@host), the topic and channel modes.
  # Thread-safe: plugins read it from their own threads.
  class Roster
    extend Synchronized

    # A channel member as plugins see it. modes holds status mode letters
    # ("o", "v", "h" ...).
    Member = Data.define(:nick, :userhost, :modes) do
      def op? = modes.include?("o")
      def voice? = modes.include?("v")
      def halfop? = modes.include?("h")
    end

    Topic = Data.define(:text, :by, :at)

    DEFAULT_SYMBOLS = { "@" => "o", "+" => "v", "%" => "h", "&" => "a", "~" => "q" }.freeze

    def initialize
      @channels = {}
      @lock = Monitor.new
    end

    def join(channel, nick, userhost = nil)
      entry = channel_entry(channel)
      member = (entry[:members][key(nick)] ||= { nick: nick, userhost: nil, modes: [] })
      member[:nick] = nick
      member[:userhost] = userhost if userhost
    end

    # Members from a RPL_NAMREPLY (353): status symbols first (several with
    # multi-prefix), and nick!user@host with userhost-in-names.
    # symbols: { "@" => "o", "+" => "v" } from ISUPPORT PREFIX.
    def add_names(channel, names, symbols = DEFAULT_SYMBOLS)
      names.each do |name|
        modes = []
        while !name.empty? && symbols.key?(name[0])
          modes << symbols[name[0]]
          name = name[1..]
        end
        next if name.empty?

        nick, userhost = name.split("!", 2)
        join(channel, nick, userhost)
        member = @channels[key(channel)][:members][key(nick)]
        member[:modes] = (member[:modes] | modes)
      end
    end

    def part(channel, nick)
      @channels[key(channel)]&.dig(:members)&.delete(key(nick))
    end

    def leave(channel)
      @channels.delete(key(channel))
    end

    def quit(nick)
      @channels.each_value { |entry| entry[:members].delete(key(nick)) }
    end

    def rename(old_nick, new_nick)
      @channels.each_value do |entry|
        member = entry[:members].delete(key(old_nick)) or next
        member[:nick] = new_nick
        entry[:members][key(new_nick)] = member
      end
    end

    def on?(channel, nick)
      @channels[key(channel)]&.dig(:members)&.key?(key(nick)) || false
    end

    def channels_of(nick)
      @channels.each_value.select { |entry| entry[:members].key?(key(nick)) }.map { |entry| entry[:name] }
    end

    # Members of a channel the bot is in, as Member values.
    def members(channel)
      entry = @channels[key(channel)] or return []
      entry[:members].values.map { |m| Member.new(nick: m[:nick], userhost: m[:userhost], modes: m[:modes].dup.freeze) }
    end

    def member(channel, nick)
      m = @channels.dig(key(channel), :members, key(nick)) or return nil
      Member.new(nick: m[:nick], userhost: m[:userhost], modes: m[:modes].dup.freeze)
    end

    # Records a user@host seen for a nick (from any message it sent).
    def note_userhost(nick, userhost)
      return unless nick && userhost

      @channels.each_value do |entry|
        member = entry[:members][key(nick)]
        member[:userhost] = userhost if member
      end
    end

    # user@host of a nick in any shared channel, or nil if not known.
    def userhost_of(nick)
      @channels.each_value do |entry|
        userhost = entry[:members].dig(key(nick), :userhost)
        return userhost if userhost
      end
      nil
    end

    def set_member_mode(channel, nick, mode, set)
      member = @channels.dig(key(channel), :members, key(nick)) or return
      member[:modes] = set ? (member[:modes] | [mode]) : (member[:modes] - [mode])
    end

    # Channel modes other than status and list modes, e.g. "n" => true,
    # "k" => "key", "l" => "10".
    def set_channel_mode(channel, mode, set, param = nil)
      entry = @channels[key(channel)] or return
      if set
        entry[:modes][mode] = param || true
      else
        entry[:modes].delete(mode)
      end
    end

    # Replaces the channel modes, from RPL_CHANNELMODEIS (324).
    def reset_channel_modes(channel)
      entry = @channels[key(channel)] or return
      entry[:modes] = {}
    end

    def channel_modes(channel) = (@channels.dig(key(channel), :modes) || {}).dup

    def set_topic(channel, text, by: nil, at: nil)
      entry = @channels[key(channel)] or return
      entry[:topic] = text.to_s.empty? ? nil : { text: text, by: by, at: at }
    end

    # Adds who set the topic and when, from RPL_TOPICWHOTIME (333).
    def set_topic_origin(channel, by, at)
      topic = @channels.dig(key(channel), :topic) or return
      topic[:by] = by
      topic[:at] = at
    end

    def topic(channel)
      topic = @channels.dig(key(channel), :topic) or return nil
      Topic.new(text: topic[:text], by: topic[:by], at: topic[:at])
    end

    def clear
      @channels.clear
    end

    synchronize_methods(*public_instance_methods(false))

    private

    def channel_entry(channel)
      @channels[key(channel)] ||= { name: channel, members: {}, modes: {}, topic: nil }
    end

    def key(name) = Casemap.downcase(name)
  end
end

module IRCBot
  # In-memory view of which nicks are on which channels the bot is in.
  class Roster
    NAMES_PREFIXES = /\A[~&@%+]+/

    def initialize
      @channels = {}
    end

    def join(channel, nick)
      entry = (@channels[key(channel)] ||= { name: channel, members: {} })
      entry[:members][key(nick)] = nick
    end

    # Members from a RPL_NAMREPLY (353), which carry status prefixes.
    def add_names(channel, names)
      names.each { |name| join(channel, name.sub(NAMES_PREFIXES, "")) }
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
        entry[:members][key(new_nick)] = new_nick if entry[:members].delete(key(old_nick))
      end
    end

    def on?(channel, nick)
      @channels[key(channel)]&.dig(:members)&.key?(key(nick)) || false
    end

    def channels_of(nick)
      @channels.each_value.select { |entry| entry[:members].key?(key(nick)) }.map { |entry| entry[:name] }
    end

    def clear
      @channels.clear
    end

    private

    def key(name) = Casemap.downcase(name)
  end
end

require "time"

module IRCBot
  # Registered channels, their per-account access lists, and hostmask
  # entries (auto-voice/op on join by nick!user@host, managed by admins).
  class Channels
    LEVELS = { "voice" => 1, "op" => 2, "owner" => 3 }.freeze
    MODES = { "voice" => "v", "op" => "o", "owner" => "o" }.freeze
    GRANTABLE = %w[voice op].freeze
    # "#" or "&", then up to 49 characters that IRC allows in channel names.
    NAME = /\A[#&][^\x00-\x20,:]{1,49}\z/

    # nick!user@host. Nick and user may use the wildcards * and ?; the host
    # must be exact (letters, digits, . : - / _ and at least one . or :),
    # so a mask can never cover a whole network or provider.
    MASK = %r{\A(?<nick>[^!@\s]+)!(?<user>[^!@\s]+)@(?<host>[A-Za-z0-9.:/_-]+)\z}
    MAX_MASK_LENGTH = 200
    MAX_MASKS_PER_CHANNEL = 100

    def self.rank(level) = LEVELS.fetch(level.to_s, 0)

    # Raises Error unless the mask is acceptable; returns it normalized.
    def self.check_mask!(mask)
      match = mask.to_s.match(MASK)
      raise Error, "#{mask} is not a valid mask; use nick!user@host, e.g. *!*zphinx@home.example.net." unless match
      raise Error, "Masks can be at most #{MAX_MASK_LENGTH} characters long." if mask.length > MAX_MASK_LENGTH

      host = match[:host]
      unless host.match?(/[.:]/) && !host.start_with?(".", "-") && !host.end_with?(".", "-")
        raise Error, "The host in #{mask} must be a full hostname or IP address, without wildcards."
      end

      mask.downcase
    end

    # Case-insensitive wildcard match of a mask against nick!user@host.
    def self.mask_match?(mask, prefix)
      pattern = Regexp.escape(Casemap.downcase(mask)).gsub("\\*", ".*").gsub("\\?", ".")
      Casemap.downcase(prefix).match?(/\A#{pattern}\z/)
    end

    def initialize(store)
      @store = store
    end

    def registered?(channel)
      @store.read { |data| data["channels"].key?(key(channel)) }
    end

    def names
      @store.read { |data| data["channels"].values.map { |c| c["name"] } }
    end

    def register(channel, owner)
      raise Error, "#{channel} is not a valid channel name." unless channel.match?(NAME)

      @store.transaction do |data|
        raise Error, "#{channel} is already registered." if data["channels"].key?(key(channel))

        data["channels"][key(channel)] = {
          "name" => channel,
          "owner" => owner,
          "access" => {},
          "registered_at" => Time.now.utc.iso8601
        }
      end
    end

    def drop(channel)
      @store.transaction { |data| data["channels"].delete(key(channel)) }
    end

    # The access level name an account holds on a channel, or nil.
    def level(channel, account)
      @store.read do |data|
        chan = data["channels"][key(channel)]
        next nil unless chan && account
        next "owner" if Casemap.eq?(chan["owner"], account)

        chan["access"].dig(key(account), "level")
      end
    end

    def set_access(channel, account, level)
      raise Error, "Unknown level #{level}. Use voice or op." unless GRANTABLE.include?(level)

      modify(channel) { |chan| chan["access"][key(account)] = { "account" => account, "level" => level } }
    end

    def remove_access(channel, account)
      removed = modify(channel) { |chan| chan["access"].delete(key(account)) }
      raise Error, "#{account} has no access entry on #{channel}." unless removed
    end

    def add_mask(channel, mask, level, added_by:)
      normalized = self.class.check_mask!(mask)
      raise Error, "Unknown level #{level}. Use voice or op." unless GRANTABLE.include?(level)

      modify(channel) do |chan|
        masks = (chan["masks"] ||= {})
        if masks.size >= MAX_MASKS_PER_CHANNEL && !masks.key?(normalized)
          raise Error, "#{channel} already has #{MAX_MASKS_PER_CHANNEL} masks."
        end

        masks[normalized] = {
          "mask" => normalized, "level" => level, "added_by" => added_by, "added_at" => Time.now.utc.iso8601
        }
      end
      normalized
    end

    def remove_mask(channel, mask)
      removed = modify(channel) { |chan| chan.fetch("masks", {}).delete(mask.to_s.downcase) }
      raise Error, "#{mask} is not a mask on #{channel}." unless removed
    end

    # [[mask, level, added_by], ...], highest level first.
    def masks(channel)
      @store.read do |data|
        entries = data["channels"].dig(key(channel), "masks") || {}
        entries.values.map { |e| [e["mask"], e["level"], e["added_by"]] }
               .sort_by { |mask, level, _| [-self.class.rank(level), mask] }
      end
    end

    # The highest level granted to nick!user@host by the channel's masks,
    # with the mask that granted it: [level, mask], or nil.
    def mask_level(channel, prefix)
      return nil unless prefix

      masks(channel).find { |mask, _level, _by| self.class.mask_match?(mask, prefix) }&.first(2)&.reverse
    end

    # Channels owned by the account.
    def owned_by(account)
      @store.read do |data|
        data["channels"].values.select { |chan| Casemap.eq?(chan["owner"], account) }.map { |chan| chan["name"] }
      end
    end

    # Removes the account from every access list.
    def forget(account)
      @store.transaction { |data| data["channels"].each_value { |chan| chan["access"].delete(key(account)) } }
    end

    # [[account, level], ...] with the owner first, then by rank descending.
    def access_list(channel)
      @store.read do |data|
        chan = data["channels"][key(channel)]
        next [] unless chan

        entries = chan["access"].values.map { |e| [e["account"], e["level"]] }
        [[chan["owner"], "owner"]] + entries.sort_by { |name, lvl| [-self.class.rank(lvl), Casemap.downcase(name)] }
      end
    end

    private

    def key(name) = Casemap.downcase(name)

    def modify(channel)
      @store.transaction do |data|
        chan = data["channels"][key(channel)]
        raise Error, "#{channel} is not registered." unless chan

        yield chan
      end
    end
  end
end

require "time"

module IRCBot
  # Registered channels, their per-account access lists, and hostmask
  # entries (auto-voice/op on join by nick!user@host, managed by admins).
  #
  # Channels belong to one network: an instance sees only its network's
  # channels, stored under data["networks"][name]["channels"]. Accounts
  # are shared by all networks.
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

    def self.network_key(network) = network.to_s.downcase

    # Moves channels from the single-network data layout (a top-level
    # "channels" section) to the given network. Returns how many moved.
    def self.adopt_legacy!(store, network)
      return 0 unless store.read { |data| data.key?("channels") }

      store.transaction do |data|
        legacy = data.delete("channels") || {}
        section = network_section(data, network)
        section["channels"] = legacy.merge(section["channels"])
        legacy.size
      end
    end

    # { network name => [channel, ...] } for every network with channels.
    def self.by_network(store)
      store.read do |data|
        data["networks"].values.filter_map do |net|
          names = net.fetch("channels", {}).values.map { |c| c["name"] }
          [net["name"], names] if names.any?
        end.to_h
      end
    end

    # [[network, channel], ...] owned by the account, on every network.
    def self.owned_anywhere(store, account)
      store.read do |data|
        data["networks"].values.flat_map do |net|
          net.fetch("channels", {}).values.select { |chan| Casemap.eq?(chan["owner"], account) }
             .map { |chan| [net["name"], chan["name"]] }
        end
      end
    end

    def self.network_section(data, network)
      section = (data["networks"][network_key(network)] ||= { "name" => network.to_s })
      section["channels"] ||= {}
      section
    end

    attr_reader :network

    def initialize(store, network: Config::DEFAULT_NETWORK)
      @store = store
      @network = network.to_s
    end

    def registered?(channel)
      @store.read { |data| all(data).key?(key(channel)) }
    end

    def names
      @store.read { |data| all(data).values.map { |c| c["name"] } }
    end

    def register(channel, owner)
      raise Error, "#{channel} is not a valid channel name." unless channel.match?(NAME)

      @store.transaction do |data|
        channels = self.class.network_section(data, @network)["channels"]
        raise Error, "#{channel} is already registered." if channels.key?(key(channel))

        channels[key(channel)] = {
          "name" => channel,
          "owner" => owner,
          "access" => {},
          "registered_at" => Time.now.utc.iso8601
        }
      end
    end

    def drop(channel)
      @store.transaction { |data| all(data).delete(key(channel)) }
    end

    # The access level name an account holds on a channel, or nil.
    def level(channel, account)
      @store.read do |data|
        chan = all(data)[key(channel)]
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
        entries = all(data).dig(key(channel), "masks") || {}
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

    # Channels on this network owned by the account.
    def owned_by(account)
      @store.read do |data|
        all(data).values.select { |chan| Casemap.eq?(chan["owner"], account) }.map { |chan| chan["name"] }
      end
    end

    # Removes the account from every access list, on every network
    # (accounts are shared by all networks).
    def forget(account)
      @store.transaction do |data|
        data["networks"].each_value do |net|
          net.fetch("channels", {}).each_value { |chan| chan["access"].delete(key(account)) }
        end
      end
    end

    # [[account, level], ...] with the owner first, then by rank descending.
    def access_list(channel)
      @store.read do |data|
        chan = all(data)[key(channel)]
        next [] unless chan

        entries = chan["access"].values.map { |e| [e["account"], e["level"]] }
        [[chan["owner"], "owner"]] + entries.sort_by { |name, lvl| [-self.class.rank(lvl), Casemap.downcase(name)] }
      end
    end

    private

    def key(name) = Casemap.downcase(name)

    # This network's channels; read-only use (may be a throwaway hash).
    def all(data) = data["networks"].dig(self.class.network_key(@network), "channels") || {}

    def modify(channel)
      @store.transaction do |data|
        chan = all(data)[key(channel)]
        raise Error, "#{channel} is not registered." unless chan

        yield chan
      end
    end
  end
end

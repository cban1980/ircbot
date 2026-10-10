module Rubicon
  # What admins changed about plugins while the bot runs, remembered per
  # network across restarts: plugins unloaded (PLUGIN UNLOAD, or
  # "rubicon-docker plugin unload") and settings changed (PLUGIN SET). Kept in
  # the data file under networks.<network>.plugins:
  #
  #   "links": { "unloaded": true, "settings": { "message_type": "notice" } }
  #
  # Saved settings override the plugin's section in config.yml.
  class PluginState
    # Turns the text of a value typed on IRC or the command line into a
    # setting: true/false, null, whole and decimal numbers, "quoted" or
    # 'quoted' text, [a, b] lists (handy for channels, "#" included) and
    # {key: value} mappings; anything else is text.
    def self.parse_value(text)
      text = text.to_s.strip
      return text[1..-2].split(",").map(&:strip).reject(&:empty?).map { |item| parse_scalar(item) } if text.match?(/\A\[.*\]\z/m)

      if text.match?(/\A\{.*\}\z/m)
        value = YAML.safe_load(text)
        raise Error, "#{text} is not a valid mapping." unless value.is_a?(Hash)

        return value
      end
      parse_scalar(text)
    rescue Psych::Exception
      raise Error, "#{text} is not a valid mapping."
    end

    def self.parse_scalar(text)
      case text
      when "true" then true
      when "false" then false
      when "null", "~" then nil
      when /\A-?\d+\z/ then text.to_i
      when /\A-?\d+\.\d+\z/ then text.to_f
      when /\A"(.*)"\z/m, /\A'(.*)'\z/m then Regexp.last_match(1)
      else text
      end
    end

    # A value as shown to admins; secrets (by setting name) are hidden.
    def self.show(key, value)
      return "(hidden)" if key.to_s.match?(Config::SECRET_NAME) && !value.to_s.empty?

      JSON.generate(value)
    end

    attr_reader :network

    def initialize(store, network: Config::DEFAULT_NETWORK)
      @store = store
      @network = network.to_s
    end

    def unloaded?(name) = @store.read { |data| all(data).dig(name, "unloaded") == true }

    # Names of plugins kept unloaded on this network.
    def unloaded = @store.read { |data| all(data).select { |_, entry| entry["unloaded"] }.keys.sort }

    def set_unloaded(name, unloaded)
      return if unloaded?(name) == unloaded

      @store.transaction do |data|
        entry = (plugins!(data)[name] ||= {})
        unloaded ? entry["unloaded"] = true : entry.delete("unloaded")
        prune(data, name)
      end
    end

    # The saved settings of one plugin: { "key" => value }.
    def settings(name) = @store.read { |data| copy(all(data).dig(name, "settings") || {}) }

    # { plugin => saved settings } for every plugin with any.
    def all_settings
      @store.read do |data|
        all(data).filter_map { |name, entry| [name, copy(entry["settings"])] if entry["settings"]&.any? }.to_h
      end
    end

    def set(name, key, value)
      @store.transaction { |data| ((plugins!(data)[name] ||= {})["settings"] ||= {})[key] = copy(value) }
    end

    # True if there was a saved value.
    def unset(name, key)
      @store.transaction do |data|
        settings = plugins!(data).dig(name, "settings") or next false
        removed = settings.key?(key)
        settings.delete(key)
        prune(data, name)
        removed
      end
    end

    private

    def all(data) = data["networks"].dig(Channels.network_key(@network), "plugins") || {}

    def plugins!(data) = (Channels.network_section(data, @network)["plugins"] ||= {})

    # Drops empty entries so the data file stays tidy.
    def prune(data, name)
      plugins = plugins!(data)
      entry = plugins[name] or return
      entry.delete("settings") if entry["settings"]&.empty?
      plugins.delete(name) if entry.empty?
    end

    def copy(value) = value.nil? ? nil : JSON.parse(JSON.generate(value))
  end
end

require "yaml"

module IRCBot
  module Config
    DEFAULTS = {
      "server" => nil,
      "network" => nil, # e.g. "IRCnet": refuse to join anything on another network
      "port" => 6697,
      "tls" => true,
      "tls_verify" => true,
      "tls_min_version" => "1.2",
      "tls_fingerprint" => nil,
      "tls_ciphers" => nil, # nil: Connection::DEFAULT_CIPHERS
      "tls_self_signed" => false, # trust self-signed certificates on first use
      "tls_known_servers" => "data/known_servers",
      "allow_insecure" => false,
      "require_secure_users" => true,
      "nick" => "ModeBot",
      "alt_nicks" => [],
      "user" => "modebot",
      "realname" => "Ruby IRC registration bot",
      "umodes" => "+i",
      "data_file" => "data/ircbot.json",
      "pepper_file" => "secret/pepper.key",
      "status_file" => "data/status.json", # state for "ircbot-docker status" and health checks
      "session_ttl_hours" => 24,
      "max_accounts" => 5_000,
      "admins" => [],
      "channels" => [],
      "link_preview" => {},
      "plugins_dir" => "plugins",
      "plugins" => {} # plugin name => settings (see PLUGIN_DEFAULTS)
    }.freeze

    LINK_PREVIEW_DEFAULTS = {
      "enabled" => true,
      "message_type" => "privmsg", # "privmsg" (normal channel message) or "notice"
      "channels" => [],     # empty: every channel the bot is in
      "ignore_nicks" => [], # e.g. other bots
      "youtube_api_key" => nil
    }.freeze

    # The bot's options for each plugin; any other keys in a plugin's
    # section are the plugin's own settings.
    PLUGIN_DEFAULTS = {
      "enabled" => true,
      "private" => true, # commands by private message (/msg Bot ROLL)
      "prefix" => nil,   # e.g. "!": also commands in channels (!roll); nil: not in channels
      "channels" => []   # limit channel commands to these; empty: every channel
    }.freeze
    PLUGIN_PREFIX = /\A[\p{P}\p{S}]{1,3}\z/

    # Settings that can be set per network under "networks:". At the top
    # level they are defaults for every network, except NETWORK_ONLY ones.
    NETWORK_SETTINGS = %w[
      server network port tls tls_verify tls_min_version tls_fingerprint tls_ciphers tls_self_signed
      allow_insecure require_secure_users nick alt_nicks user realname umodes channels
    ].freeze
    NETWORK_ONLY = %w[server network tls_fingerprint channels].freeze
    # Network names, as used in "networks:", logs and the data file.
    NETWORK_NAME = /\A[A-Za-z][A-Za-z0-9_.-]{0,29}\z/
    # The network name of a single-server config without "network:".
    DEFAULT_NETWORK = "default".freeze

    module_function

    # Returns the global settings plus "networks": one flat config per
    # network (global settings merged with that network's, and "id" set to
    # the network name). A config without "networks:" is one network.
    def load(path)
      from_file = File.exist?(path) ? YAML.safe_load_file(path) || {} : {}
      raise ConfigError, "#{path} must contain a mapping of settings" unless from_file.is_a?(Hash)

      unknown = from_file.keys - DEFAULTS.keys - ["networks"]
      raise ConfigError, "Unknown setting(s) in #{path}: #{unknown.join(', ')}" if unknown.any?

      # A secret in the config file means the file itself must be private.
      SecureFile.check!(path) if from_file.dig("link_preview", "youtube_api_key")

      config = DEFAULTS.merge(from_file.except("networks"))
      # Relative paths are resolved against the config file's directory.
      base = File.dirname(File.expand_path(path))
      config["data_file"] = File.expand_path(config["data_file"], base)
      config["pepper_file"] = File.expand_path(config["pepper_file"], base)
      config["tls_known_servers"] = File.expand_path(config["tls_known_servers"], base)
      config["status_file"] = File.expand_path(config["status_file"], base)
      config["plugins_dir"] = File.expand_path(config["plugins_dir"].to_s, base)
      config["admins"] = Array(config["admins"])
      config["link_preview"] = link_preview(config["link_preview"])
      config["plugins"] = plugins(config["plugins"])
      normalize_network!(config)
      validate_access!(config)

      if from_file.key?("networks")
        misplaced = NETWORK_ONLY & from_file.keys
        if misplaced.any?
          raise ConfigError, "#{misplaced.join(', ')} must be set for each network under networks:, not at the top level"
        end

        config["networks"] = networks(from_file["networks"], config)
      else
        validate!(config)
        name = config["network"] || DEFAULT_NETWORK
        unless name.to_s.match?(NETWORK_NAME)
          raise ConfigError, "network #{name.inspect} must start with a letter and contain only letters, digits, _ . -"
        end

        config["networks"] = [config.merge("id" => name.to_s)]
      end
      config
    end

    # One network's flat config from a config loaded with load: the network
    # named id, or the only/first one. A flat config is returned as is.
    def network(config, id = nil)
      return config unless config.key?("networks")

      list = config["networks"]
      return list.first unless id

      list.find { |net| net["id"].casecmp?(id) }
    end

    def networks(section, config)
      unless section.is_a?(Hash) && section.any?
        raise ConfigError, "networks must be a mapping of network names to their settings"
      end

      list = section.map do |name, settings|
        name = name.to_s
        unless name.match?(NETWORK_NAME)
          raise ConfigError, "network name #{name.inspect} must start with a letter and contain only letters, digits, _ . -"
        end
        raise ConfigError, "networks: #{name} must be a mapping" unless settings.is_a?(Hash)

        unknown = settings.keys - NETWORK_SETTINGS
        if unknown.any?
          raise ConfigError, "networks: #{name}: #{unknown.join(', ')} can't be set per network " \
                             "(per network: #{NETWORK_SETTINGS.join(', ')})"
        end

        net = config.except("networks").merge(settings).merge(
          "id" => name,
          # Plugins keep separate data per network.
          "plugin_data_dir" => File.join(File.dirname(config["data_file"]), "plugins", name.downcase)
        )
        normalize_network!(net)
        begin
          validate!(net)
        rescue ConfigError => e
          raise ConfigError, "networks: #{name}: #{e.message}"
        end
        net
      end
      duplicate = list.map { |net| net["id"].downcase }.tally.find { |_, count| count > 1 }
      raise ConfigError, "networks: #{duplicate[0]} is listed more than once" if duplicate

      list
    end

    def normalize_network!(config)
      config["alt_nicks"] = Array(config["alt_nicks"]).map(&:to_s)
      config["umodes"] = config["umodes"].to_s
      config["channels"] = Array(config["channels"])
      config["tls_min_version"] = config["tls_min_version"].to_s
    end

    # RFC 2812 nick: a letter or special character, then letters, digits,
    # specials or "-".
    NICK = /\A[A-Za-z\[\]\\`_^{|}][A-Za-z0-9\[\]\\`_^{|}-]*\z/
    USER = /\A[^\s@\0]+\z/
    UMODES = /\A(?:[+-][A-Za-z]+)+\z/

    def link_preview(section)
      raise ConfigError, "link_preview must be a mapping" unless section.nil? || section.is_a?(Hash)

      unknown = (section || {}).keys - LINK_PREVIEW_DEFAULTS.keys
      raise ConfigError, "Unknown link_preview setting(s): #{unknown.join(', ')}" if unknown.any?

      preview = LINK_PREVIEW_DEFAULTS.merge(section || {})
      preview["channels"] = Array(preview["channels"]).map(&:to_s)
      preview["ignore_nicks"] = Array(preview["ignore_nicks"]).map(&:to_s)
      preview["youtube_api_key"] = ENV["IRCBOT_YOUTUBE_API_KEY"] if ENV["IRCBOT_YOUTUBE_API_KEY"]
      preview["message_type"] = preview["message_type"].to_s.downcase
      unless %w[privmsg notice].include?(preview["message_type"])
        raise ConfigError, "link_preview message_type must be privmsg or notice"
      end
      preview
    end

    def plugins(section)
      raise ConfigError, "plugins must be a mapping of plugin name to settings" unless section.nil? || section.is_a?(Hash)

      (section || {}).to_h do |name, settings|
        name = name.to_s
        raise ConfigError, "plugin name #{name.inspect} must be lowercase letters, digits and _" unless name.match?(PluginManager::NAME)
        raise ConfigError, "plugins: #{name} must be a mapping" unless settings.nil? || settings.is_a?(Hash)

        settings = PLUGIN_DEFAULTS.merge(settings || {})
        %w[enabled private].each do |key|
          raise ConfigError, "plugins: #{name} #{key} must be true or false" unless [true, false].include?(settings[key])
        end
        settings["prefix"] = nil if settings["prefix"].to_s.empty?
        prefix = settings["prefix"]
        unless prefix.nil? || prefix.to_s.match?(PLUGIN_PREFIX)
          raise ConfigError, "plugins: #{name} prefix must be 1-3 symbols like \"!\" (quoted), or empty for no channel commands"
        end
        settings["channels"] = Array(settings["channels"]).map(&:to_s)
        settings["channels"].each do |channel|
          raise ConfigError, "plugins: #{name}: #{channel.inspect} is not a valid channel name" unless channel.match?(Channels::NAME)
        end
        [name, settings]
      end
    end

    # Checks one network's settings (a legacy config is one network).
    def validate!(config)
      raise ConfigError, "server is not set" if config["server"].to_s.empty?
      validate_identity!(config)
      config["channels"].each do |channel|
        raise ConfigError, "#{channel.inspect} is not a valid channel name" unless channel.to_s.match?(Channels::NAME)
      end
      unless Connection::TLS_VERSIONS.key?(config["tls_min_version"])
        raise ConfigError, "tls_min_version must be one of #{Connection::TLS_VERSIONS.keys.join(', ')}"
      end
      validate_ciphers!(config["tls_ciphers"]) if config["tls_ciphers"]
      %w[tls tls_verify tls_self_signed allow_insecure require_secure_users].each do |name|
        raise ConfigError, "#{name} must be true or false" unless [true, false].include?(config[name])
      end

      pin = config["tls_fingerprint"]
      if pin && !Connection.normalize_fingerprint(pin).match?(/\A\h{64}\z/)
        raise ConfigError, "tls_fingerprint must be a SHA-256 hex digest (64 hex characters)"
      end

      return if config["allow_insecure"]

      unless config["tls"]
        raise ConfigError, "tls is disabled, so everything including the bot's traffic is sent " \
                           "unencrypted. Set allow_insecure: true if you really mean it."
      end
      return if config["tls_verify"] || pin

      raise ConfigError, "tls_verify is off without tls_fingerprint, so the server's identity is " \
                         "not checked. Pin the key with tls_fingerprint or set allow_insecure: true."
    end

    def validate_ciphers!(ciphers)
      OpenSSL::SSL::SSLContext.new.ciphers = ciphers.to_s
    rescue OpenSSL::SSL::SSLError
      raise ConfigError, "tls_ciphers #{ciphers.inspect} matches no usable cipher"
    end

    def validate_access!(config)
      config["admins"].each do |admin|
        raise ConfigError, "admin #{admin.inspect} is not a valid IRC nick" unless admin.to_s.match?(NICK)
      end
      %w[session_ttl_hours max_accounts].each do |name|
        value = config[name]
        raise ConfigError, "#{name} must be a positive whole number" unless value.is_a?(Integer) && value.positive?
      end
    end

    def validate_identity!(config)
      ([config["nick"]] + config["alt_nicks"]).each do |nick|
        raise ConfigError, "#{nick.inspect} is not a valid IRC nick" unless nick.to_s.match?(NICK)
      end
      raise ConfigError, "user #{config['user'].inspect} must be one word without @" unless config["user"].to_s.match?(USER)

      realname = config["realname"].to_s
      raise ConfigError, "realname must not be empty or contain line breaks" if realname.strip.empty? || realname.match?(/[\r\n\0]/)

      umodes = config["umodes"]
      unless umodes.empty? || umodes.match?(UMODES)
        raise ConfigError, "umodes #{umodes.inspect} must look like \"+i\" or \"+iw-s\""
      end
      raise ConfigError, "umodes cannot grant operator status" if umodes.match?(/\+[A-Za-z]*[oO]/)
    end
  end
end

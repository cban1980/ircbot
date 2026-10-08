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

    module_function

    def load(path)
      from_file = File.exist?(path) ? YAML.safe_load_file(path) || {} : {}
      raise ConfigError, "#{path} must contain a mapping of settings" unless from_file.is_a?(Hash)

      unknown = from_file.keys - DEFAULTS.keys
      raise ConfigError, "Unknown setting(s) in #{path}: #{unknown.join(', ')}" if unknown.any?

      # A secret in the config file means the file itself must be private.
      SecureFile.check!(path) if from_file.dig("link_preview", "youtube_api_key")

      config = DEFAULTS.merge(from_file)
      # Relative paths are resolved against the config file's directory.
      base = File.dirname(File.expand_path(path))
      config["data_file"] = File.expand_path(config["data_file"], base)
      config["pepper_file"] = File.expand_path(config["pepper_file"], base)
      config["tls_known_servers"] = File.expand_path(config["tls_known_servers"], base)
      config["status_file"] = File.expand_path(config["status_file"], base)
      config["plugins_dir"] = File.expand_path(config["plugins_dir"].to_s, base)
      config["alt_nicks"] = Array(config["alt_nicks"]).map(&:to_s)
      config["umodes"] = config["umodes"].to_s
      config["admins"] = Array(config["admins"])
      config["channels"] = Array(config["channels"])
      config["tls_min_version"] = config["tls_min_version"].to_s
      config["link_preview"] = link_preview(config["link_preview"])
      config["plugins"] = plugins(config["plugins"])
      validate!(config)
      config
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

    def validate!(config)
      raise ConfigError, "server is not set" if config["server"].to_s.empty?
      validate_identity!(config)
      validate_access!(config)
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
      config["channels"].each do |channel|
        raise ConfigError, "#{channel.inspect} is not a valid channel name" unless channel.to_s.match?(Channels::NAME)
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

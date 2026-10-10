require "yaml"

module Gemdrop
  module Config
    DEFAULTS = {
      "server" => nil,
      "fallback_servers" => [], # tried in turn when the server can't be reached ("host" or "host:port")
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
      "nick" => "Gemdrop",
      "alt_nicks" => [],
      "user" => "gemdrop",
      "realname" => "Gemdrop IRC bot",
      "umodes" => "+i",
      "data_file" => "data/gemdrop.json",
      "pepper_file" => "secret/pepper.key",
      "status_file" => "data/status.json", # state for "gemdrop-docker status" and health checks
      "session_ttl_hours" => 24,
      "hash_workers" => 2, # processes for password hashing, so logins don't stall the bot; 0: in the bot's process
      "max_accounts" => 5_000,
      "admins" => [],
      "channels" => [],
      "plugins_dir" => "plugins",
      "gems_dir" => "gems", # gems plugins need, installed by the bot (lock file: gems.lock next to it)
      "plugins" => {} # plugin name => settings (see PLUGIN_DEFAULTS)
    }.freeze

    # The bot's options for each plugin; any other keys in a plugin's
    # section are the plugin's own settings.
    PLUGIN_DEFAULTS = {
      "enabled" => true,
      "private" => true, # commands by private message (/msg Bot ROLL)
      "prefix" => nil,   # e.g. "!": also commands in channels (!roll); nil: not in channels
      "channels" => [],  # limit channel commands to these; empty: every channel
      "networks" => [],  # load only on these networks; empty: every network
      "network_settings" => {} # network name => settings overriding the ones above there
    }.freeze
    PLUGIN_PREFIX = /\A[\p{P}\p{S}]{1,3}\z/

    # Settings that can be set per network under "networks:". At the top
    # level they are defaults for every network, except NETWORK_ONLY ones.
    NETWORK_SETTINGS = %w[
      server fallback_servers network port tls tls_verify tls_min_version tls_fingerprint tls_ciphers tls_self_signed
      allow_insecure require_secure_users nick alt_nicks user realname umodes channels
    ].freeze
    NETWORK_ONLY = %w[server fallback_servers network tls_fingerprint channels].freeze
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

      if from_file.key?("link_preview")
        raise ConfigError, "link_preview: link previews are now the \"links\" plugin. Install it " \
                           "(gemdrop-docker plugin install contrib/plugins/links.rb) and move the settings " \
                           "to plugins: links: (channels becomes only_channels; see docs/links.md)"
      end
      move_ctcp_section!(from_file)
      unknown = from_file.keys - DEFAULTS.keys - ["networks"]
      raise ConfigError, "Unknown setting(s) in #{path}: #{unknown.join(', ')}" if unknown.any?

      # A secret in the config file means the file itself must be private.
      SecureFile.check!(path) if secrets?(from_file["plugins"])

      config = DEFAULTS.merge(from_file.except("networks"))
      # Relative paths are resolved against the config file's directory.
      base = File.dirname(File.expand_path(path))
      config["data_file"] = File.expand_path(config["data_file"], base)
      config["pepper_file"] = File.expand_path(config["pepper_file"], base)
      config["tls_known_servers"] = File.expand_path(config["tls_known_servers"], base)
      config["status_file"] = File.expand_path(config["status_file"], base)
      config["plugins_dir"] = File.expand_path(config["plugins_dir"].to_s, base)
      config["gems_dir"] = File.expand_path(config["gems_dir"].to_s, base)
      config["admins"] = Array(config["admins"])
      plugins_section = config["plugins"]
      config["plugins"] = plugins(plugins_section)
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
      apply_plugin_networks!(config, plugins_section)
      config
    end

    # Gives each network its view of the plugin settings: plugins limited to
    # other networks are disabled there, and network_settings are applied.
    def apply_plugin_networks!(config, section)
      ids = config["networks"].map { |net| net["id"] }
      config["plugins"].each do |name, settings|
        (settings["networks"] + settings["network_settings"].keys).each do |id|
          next if ids.any? { |known| known.casecmp?(id) }

          raise ConfigError, "plugins: #{name}: there is no network #{id} (networks: #{ids.join(', ')})"
        end
      end
      config["networks"].each do |net|
        net["plugins"] = plugins((section || {}).to_h do |name, settings|
          settings ||= {}
          limit = Array(settings["networks"]).map(&:to_s)
          overrides = (settings["network_settings"] || {}).find { |id, _| id.to_s.casecmp?(net["id"]) }&.last || {}
          view = settings.merge(overrides)
          view = view.merge("enabled" => false) if limit.any? && limit.none? { |id| id.casecmp?(net["id"]) }
          [name, view]
        end)
      end
    end

    # CTCP answers are the ctcp plugin now: an old top-level "ctcp:"
    # section (enabled, version) becomes that plugin's settings.
    def move_ctcp_section!(from_file)
      return unless from_file.key?("ctcp")

      old = from_file.delete("ctcp") || {}
      raise ConfigError, "ctcp must be a mapping" unless old.is_a?(Hash)

      plugins = (from_file["plugins"] ||= {})
      raise ConfigError, "plugins must be a mapping of plugin name to settings" unless plugins.is_a?(Hash)

      settings = (plugins["ctcp"] ||= {})
      settings["version"] ||= old["version"].to_s if old.key?("version")
      settings["enabled"] = false if old["enabled"] == false && !settings.key?("enabled")
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
      config["fallback_servers"] = Array(config["fallback_servers"]).map(&:to_s)
      config["tls_min_version"] = config["tls_min_version"].to_s
    end

    # RFC 2812 nick: a letter or special character, then letters, digits,
    # specials or "-".
    NICK = /\A[A-Za-z\[\]\\`_^{|}][A-Za-z0-9\[\]\\`_^{|}-]*\z/
    USER = /\A[^\s@\0]+\z/
    UMODES = /\A(?:[+-][A-Za-z]+)+\z/

    SECRET_NAME = /key|token|secret|password/i

    # True if a plugin section holds something that looks like a secret.
    def secrets?(section)
      return false unless section.is_a?(Hash)

      section.values.any? do |settings|
        next false unless settings.is_a?(Hash)

        settings.any? { |name, value| name.to_s.match?(SECRET_NAME) && !value.to_s.empty? } ||
          secrets?(settings["network_settings"]) || secrets?(settings["channel_settings"])
      end
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
        settings["networks"] = Array(settings["networks"]).map(&:to_s)
        unless settings["network_settings"].is_a?(Hash) && settings["network_settings"].values.all? { |v| v.is_a?(Hash) }
          raise ConfigError, "plugins: #{name} network_settings must map network names to settings"
        end
        if settings["network_settings"].values.any? { |v| v.key?("networks") || v.key?("network_settings") }
          raise ConfigError, "plugins: #{name}: networks and network_settings can't be set inside network_settings"
        end
        [name, settings]
      end
    end

    # Checks one network's settings (a legacy config is one network).
    def validate!(config)
      raise ConfigError, "server is not set" if config["server"].to_s.empty?
      config["fallback_servers"].each do |entry|
        unless entry.match?(/\A[A-Za-z0-9.-]+(?::\d{1,5})?\z/)
          raise ConfigError, "fallback_servers: #{entry.inspect} must be a host name, optionally with :port"
        end
      end
      if config["tls_fingerprint"] && config["fallback_servers"].any?
        raise ConfigError, "tls_fingerprint pins one server's key, so it can't be used with fallback_servers"
      end
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
      unless config["hash_workers"].is_a?(Integer) && config["hash_workers"].between?(0, 16)
        raise ConfigError, "hash_workers must be a whole number from 0 to 16"
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

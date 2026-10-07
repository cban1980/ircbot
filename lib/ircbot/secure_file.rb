module IRCBot
  # Reads secret files, refusing ones that other users own or can access.
  module SecureFile
    module_function

    def read(path)
      check!(path)
      File.read(path)
    end

    def check!(path)
      raise ConfigError, "#{path} does not exist" unless File.exist?(path)

      stat = File.stat(path)
      raise ConfigError, "#{path} is not owned by this user" unless stat.owned?
      return unless stat.mode.anybits?(0o077)

      raise ConfigError, "#{path} is accessible by other users; run: chmod 600 #{path}"
    end
  end
end

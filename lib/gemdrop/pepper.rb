require "openssl"
require "fileutils"

module Gemdrop
  # Loads the secret pepper for password hashing, from GEMDROP_PEPPER (hex)
  # or a key file. The key file is created on first run with mode 0600.
  module Pepper
    BYTES = 32

    module_function

    def load(path:, env: ENV)
      hex = env["GEMDROP_PEPPER"] || read_file(path) || generate(path)
      unless hex.match?(/\A\h{#{BYTES * 2},}\z/)
        raise ConfigError, "Pepper must be at least #{BYTES * 2} hex characters"
      end

      [hex].pack("H*")
    end

    def read_file(path)
      SecureFile.read(path).strip if File.exist?(path)
    end

    def generate(path)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      hex = OpenSSL::Random.random_bytes(BYTES).unpack1("H*")
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.puts(hex) }
      hex
    end
  end
end

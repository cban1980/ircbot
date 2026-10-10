require "json"
require "fileutils"

module Gemdrop
  # JSON file persistence, safe to share between the running bot and the
  # bin/gemdrop-account tool.
  #
  # - Mutations go through #transaction, which holds an exclusive file lock,
  #   reloads the file if another process changed it, and atomically
  #   replaces it (write + fsync to a temp file, rename, fsync the directory).
  # - The directory must belong to us and not be writable by others; the
  #   data file must be a regular file we own. Symlinks are not followed.
  class Store
    # sections: top-level keys that always exist (hashes).
    # on_error: called with a message when a changed file can't be read
    # while running (see #refresh); e.g. a logger's warn.
    attr_writer :on_error

    def initialize(path, sections: %w[accounts networks])
      @path = path
      @sections = sections
      @dir = File.dirname(path)
      @mutex = Mutex.new
      prepare_directory
      @data = load
    end

    def read
      @mutex.synchronize do
        refresh
        yield @data
      end
    end

    def transaction
      @mutex.synchronize do
        with_file_lock do
          refresh
          result = yield @data
          flush
          result
        end
      end
    end

    private

    def prepare_directory
      FileUtils.mkdir_p(@dir, mode: 0o700)
      stat = File.stat(@dir)
      raise ConfigError, "#{@dir} is not owned by this user" unless stat.owned?
      if stat.mode.anybits?(0o022)
        raise ConfigError, "#{@dir} is writable by other users; run: chmod 700 #{@dir}"
      end
    end

    def load
      @stamp = stamp
      data = @stamp ? parse(read_file) : {}
      @sections.each { |section| data[section] ||= {} }
      data
    end

    # Reloads when the file was replaced since we last read or wrote it.
    # While running, a file that can't be read (e.g. damaged by a hand edit)
    # is reported once and the data in memory is kept, so the bot stays up;
    # the next save writes the good data back.
    def refresh
      current = stamp
      return if current == @stamp

      @data = load
      @reported = nil
    rescue ConfigError, SystemCallError, IOError => e
      @stamp = current if current
      report("Keeping the data in memory: #{e.message}")
    end

    # Each problem is reported once, not on every read.
    def report(message)
      return if @reported == message

      @reported = message
      @on_error&.call(message)
    end

    def parse(text)
      data = JSON.parse(text)
      raise ConfigError, "#{@path} must contain a JSON object" unless data.is_a?(Hash)

      data
    rescue JSON::ParserError => e
      raise ConfigError, "#{@path} is damaged (not valid JSON: #{e.message.lines.first.to_s.strip[0, 120]}). " \
                         "Restore it from a backup (gemdrop-docker restore) or repair it by hand."
    end

    def stamp
      stat = File.lstat(@path)
      raise ConfigError, "#{@path} must be a regular file, not a symlink" unless stat.file?
      raise ConfigError, "#{@path} is not owned by this user" unless stat.owned?

      [stat.ino, stat.size, stat.mtime.to_r]
    rescue Errno::ENOENT
      nil
    end

    def read_file
      File.open(@path, File::RDONLY | File::NOFOLLOW, &:read)
    end

    def flush
      tmp = "#{@path}.tmp"
      FileUtils.rm_f(tmp)
      File.open(tmp, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |file|
        file.write(JSON.pretty_generate(@data))
        file.fsync
      end
      File.rename(tmp, @path)
      File.open(@dir, File::RDONLY, &:fsync)
      @stamp = stamp
    end

    def with_file_lock
      File.open("#{@path}.lock", File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end
  end
end

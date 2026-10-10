require "rubygems"
require "rubygems/dependency_installer"
require "fileutils"

module Rubicon
  # Gems for plugins, kept in the instance's gems folder (gems_dir, by
  # default next to config.yml) so they survive image rebuilds.
  #
  # A plugin declares what it needs with requires_gem. Before loading a
  # plugin, PluginManager asks which of its gems are missing; those are
  # downloaded from rubygems.org on a background thread, and the plugin is
  # loaded when they are in. Installs happen once per process (shared by
  # all networks), and the exact versions installed are recorded in
  # gems.lock next to the folder, so a reinstall (e.g. on a new server
  # after a restore) gets the same versions.
  #
  # Gems with native extensions need a compiler, which the Docker image
  # doesn't have; most popular ones (nokogiri, sqlite3, ffi ...) ship
  # precompiled for Linux and install fine.
  class PluginGems
    Requirement = Data.define(:name, :requirements) do
      def to_s = requirements.empty? ? name : "#{name} (#{requirements.join(', ')})"
      def key = [name, requirements.sort]
    end

    # requires_gem "name", "~> 1.2", ">= 1.2.3" in a plugin's source.
    DECLARATION = /^\s*requires_gem[\s(]+["']([A-Za-z0-9_.-]+)["']((?:\s*,\s*["'][^"'\n]+["'])*)/
    NAME = /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,99}\z/

    REGISTRY = {}
    REGISTRY_LOCK = Mutex.new
    private_constant :REGISTRY, :REGISTRY_LOCK

    # RubyGems' list of installed gems is shared by the whole process:
    # refreshing it while another thread activates a gem can break the
    # activation. Both happen under this lock (installs themselves don't,
    # so they never hold up plugin loading).
    LOCK = Monitor.new

    def self.synchronize(&) = LOCK.synchronize(&)

    # The manager for a gems folder; one per folder per process.
    def self.for(dir, logger: Logger.new(nil))
      REGISTRY_LOCK.synchronize { REGISTRY[File.expand_path(dir)] ||= new(dir, logger: logger) }
    end

    # The gems a plugin's source declares, read without running it (the
    # file may require them at the top).
    def self.requirements(source)
      source.scan(DECLARATION).map do |name, rest|
        Requirement.new(name: name, requirements: rest.scan(/["']([^"']+)["']/).flatten.map(&:strip))
      end.uniq
    end

    attr_reader :dir, :lock_file

    # installer: ->(name, requirement, dir) { version } replaces the real
    # download (for tests).
    def initialize(dir, logger: Logger.new(nil), installer: nil)
      @dir = File.expand_path(dir)
      @lock_file = File.join(File.dirname(@dir), "gems.lock")
      @log = logger
      @installer = installer || method(:download)
      @mutex = Mutex.new
      @pending = {} # requirement key => [callbacks]
      @queue = Queue.new
      @worker = nil
      use_folder
    end

    attr_writer :installer

    # The requirements that no installed gem satisfies.
    def missing(requirements)
      @mutex.synchronize { requirements.reject { |req| installed?(req) } }
    end

    # Installs the requirements in the background (each once, however many
    # plugins or networks ask), then calls done with nil or an error message.
    # done runs on the install thread, without any of this class's locks.
    def install(requirements, &done)
      return done.call(nil) if requirements.empty?

      state = Mutex.new
      remaining = requirements.map(&:key)
      errors = []
      requirements.each do |req|
        callback = lambda do |error|
          all_done = state.synchronize do
            errors << "#{req}: #{error}" if error
            remaining.delete(req.key)
            remaining.empty?
          end
          done.call(errors.empty? ? nil : errors.join("; ")) if all_done
        end
        first = @mutex.synchronize do
          waiting = (@pending[req.key] ||= [])
          waiting << callback
          waiting.size == 1
        end
        enqueue(req) if first
      end
    end

    # Requirements being installed right now.
    def installing = @mutex.synchronize { @pending.keys.map(&:first) }

    # name => version from gems.lock.
    def locked
      return {} unless File.exist?(@lock_file)

      File.readlines(@lock_file, chomp: true).each_with_object({}) do |line, map|
        name, version = line.split
        map[name] = version if name&.match?(NAME) && version
      end
    end

    private

    # Makes gems in the folder loadable, along with the system's.
    def use_folder
      FileUtils.mkdir_p(@dir, mode: 0o700)
      paths = ([@dir] + Gem.path).uniq
      PluginGems.synchronize do
        Gem.paths = { "GEM_HOME" => @dir, "GEM_PATH" => paths.join(File::PATH_SEPARATOR) }
        Gem::Specification.reset
      end
    end

    def installed?(req)
      PluginGems.synchronize do
        Gem::Specification.reset
        !Gem::Specification.find_all_by_name(req.name, *req.requirements).empty?
      end
    end

    def enqueue(req)
      @queue << req
      @mutex.synchronize do
        @worker = nil unless @worker&.alive?
        @worker ||= Thread.new do
          Thread.current.name = "rubicon-gems"
          loop { work(@queue.pop) }
        end
      end
    end

    def work(req)
      error = nil
      begin
        requirement = locked_requirement(req)
        @log.info("Installing gem #{req.name} #{requirement} into #{@dir} for plugins")
        version = @installer.call(req.name, requirement, @dir)
        PluginGems.synchronize { Gem::Specification.reset }
        record(req.name, version)
        @log.info("Installed gem #{req.name} #{version}")
      rescue StandardError, ScriptError => e # gem installs can fail in many ways; the worker carries on
        error = describe(e)
        @log.error("Installing gem #{req} failed: #{e.class}: #{error}")
      end
      callbacks = @mutex.synchronize { @pending.delete(req.key) || [] }
      callbacks.each { |callback| callback.call(error) }
    end

    def describe(error)
      text = error.message.lines.first.to_s.strip
      return text unless error.is_a?(Gem::Ext::BuildError)

      built = error.message[%r{/gems/([^/\s]+)\s+for inspection}, 1] || "a gem"
      "#{built} needs compiling, and the bot's image has no compiler (#{text})"
    end

    # The version in gems.lock if it satisfies the plugin, else the plugin's
    # own requirement (the newest matching version is installed).
    def locked_requirement(req)
      requirement = Gem::Requirement.create(req.requirements.empty? ? [">= 0"] : req.requirements)
      version = locked[req.name]
      version && requirement.satisfied_by?(Gem::Version.new(version)) ? Gem::Requirement.create("= #{version}") : requirement
    end

    # Installs into GEM_HOME (the gems folder, see use_folder) rather than
    # with install_dir: that way gems the system already has, such as the
    # ones bundled with Ruby, count for dependencies and aren't fetched
    # again (a newer racc, say, would need a compiler).
    def download(name, requirement, dir)
      options = { document: [], env_shebang: true, wrappers: false, minimal_deps: true }
      options[:install_dir] = dir unless File.expand_path(Gem.dir) == dir
      installer = Gem::DependencyInstaller.new(options)
      installer.install(name, requirement)
      spec = installer.installed_gems.find { |s| s.name == name } ||
             Gem::Specification.find_all_by_name(name, requirement).max_by(&:version)
      spec&.version.to_s
    end

    def record(name, version)
      return if version.to_s.empty?

      entries = locked.merge(name => version.to_s)
      File.write(@lock_file, entries.sort.map { |n, v| "#{n} #{v}\n" }.join, perm: 0o600)
    end
  end
end

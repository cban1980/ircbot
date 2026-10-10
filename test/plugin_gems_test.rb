require "test_helper"

# Gems for plugins: declared with requires_gem, installed by the bot into
# the gems folder in the background, then the plugin loads.
class PluginGemsTest < Minitest::Test
  include StoreHelper

  def setup
    super
    @plugins_dir = File.join(@tmpdir, "plugins")
    @gems_dir = File.join(@tmpdir, "gems")
    Dir.mkdir(@plugins_dir, 0o700)
    @installed = []
  end

  def write_plugin(name, source) = File.write(File.join(@plugins_dir, "#{name}.rb"), source, perm: 0o600)

  # A stand-in for downloading from rubygems.org: writes a tiny gem whose
  # module answers hello.
  def fake_installer(version: "1.2.0", fail_with: nil)
    installed = @installed
    lambda do |name, requirement, dir|
      raise Gem::InstallError, fail_with if fail_with

      installed << [name, requirement.to_s]
      spec = Gem::Specification.new do |s|
        s.name = name
        s.version = version
        s.summary = "test gem"
        s.authors = ["test"]
        s.files = ["lib/#{name}.rb"]
        s.require_paths = ["lib"]
      end
      FileUtils.mkdir_p(File.join(dir, "specifications"))
      File.write(File.join(dir, "specifications", "#{name}-#{version}.gemspec"), spec.to_ruby)
      lib = File.join(dir, "gems", "#{name}-#{version}", "lib")
      FileUtils.mkdir_p(lib)
      mod = name.split("_").map(&:capitalize).join
      File.write(File.join(lib, "#{name}.rb"), "module #{mod}; def self.hello = 'hi from #{name}'; end\n")
      version
    end
  end

  def start(installer)
    Gemdrop::PluginGems.for(@gems_dir).installer = installer
    path = File.join(@tmpdir, "config.yml")
    File.write(path, "server: irc.example.net\nnick: Gemdrop\nrequire_secure_users: false\n", perm: 0o600)
    @conn = FakeConnection.new
    @bot = Gemdrop::Bot.new(Gemdrop::Config.load(path), connection: @conn, store: @store, hasher: TEST_HASHER,
                                                       logger: Logger.new(nil))
    @bot.handle(":server 001 Gemdrop :Welcome")
  end

  def status(name) = @bot.send(:plugin_manager).status[name]

  def wait_for(name, state)
    deadline = Time.now + 5
    sleep 0.01 until status(name)&.dig("state") == state || Time.now > deadline
    assert_equal state, status(name)&.dig("state"), status(name).inspect
  end

  def plugin_using(gem_name, requirement)
    mod = gem_name.split("_").map(&:capitalize).join
    <<~RUBY
      class Fancy < Gemdrop::Plugin
        requires_gem "#{gem_name}", "#{requirement}"
        command("FANCY") { |ctx, _args| ctx.reply(#{mod}.hello) }
      end
    RUBY
  end

  def test_reads_requirements_without_running_the_plugin
    source = <<~RUBY
      require "nokogiri"
      class X < Gemdrop::Plugin
        requires_gem "nokogiri", "~> 1.16", ">= 1.16.2"
        requires_gem("faraday")
        requires_gem 'mini_mime', require: false
      end
    RUBY
    assert_equal ["nokogiri (~> 1.16, >= 1.16.2)", "faraday", "mini_mime"],
                 Gemdrop::PluginGems.requirements(source).map(&:to_s)
  end

  def test_installs_missing_gems_then_loads_the_plugin
    write_plugin("fancy", plugin_using("gemdrop_fake_one", "~> 1.2"))
    start(fake_installer)

    wait_for("fancy", "loaded")
    assert_equal [["gemdrop_fake_one", "~> 1.2"]], @installed
    assert_equal "gemdrop_fake_one 1.2.0\n", File.read(File.join(@tmpdir, "gems.lock"))

    @bot.handle(":alice!a@a.host PRIVMSG Gemdrop :FANCY")
    assert_includes @conn.lines, "NOTICE alice :hi from gemdrop_fake_one"
  end

  def test_installed_gems_load_right_away_and_lock_pins_the_version
    write_plugin("fancy", plugin_using("gemdrop_fake_two", ">= 1.0"))
    File.write(File.join(@tmpdir, "gems.lock"), "gemdrop_fake_two 1.1.0\n")
    start(fake_installer(version: "1.1.0"))
    wait_for("fancy", "loaded")
    assert_equal [["gemdrop_fake_two", "= 1.1.0"]], @installed, "the locked version is installed"

    @installed.clear
    @bot.reload_config
    File.write(File.join(@plugins_dir, "fancy.rb"), plugin_using("gemdrop_fake_two", ">= 1.0") + "# changed\n", perm: 0o600)
    @bot.reload_config
    assert_equal "loaded", status("fancy")["state"]
    assert_empty @installed, "nothing to install the second time"
  end

  def test_failed_install_is_reported_and_the_bot_goes_on
    write_plugin("fancy", plugin_using("gemdrop_fake_three", "~> 9.0"))
    start(fake_installer(fail_with: "could not find a valid gem"))

    wait_for("fancy", "error")
    assert_match(/couldn't install its gems: gemdrop_fake_three \(~> 9.0\): could not find a valid gem/,
                 status("fancy")["error"])
  end

  def test_status_shows_installing_while_waiting
    gate = Queue.new
    slow = fake_installer
    write_plugin("fancy", plugin_using("gemdrop_fake_four", "~> 1.2"))
    start(lambda { |*args|
      gate.pop
      slow.call(*args)
    })

    assert_equal({ "state" => "installing", "gems" => ["gemdrop_fake_four (~> 1.2)"] }, status("fancy"))
    gate << :go
    wait_for("fancy", "loaded")
  end
end

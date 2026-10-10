require "test_helper"

# Several networks: config, per-network channels and the Supervisor.
class NetworksTest < Minitest::Test
  include StoreHelper

  CONFIG = <<~YAML.freeze
    nick: Gemdrop
    admins: [root]
    require_secure_users: false
    networks:
      IRCnet:
        server: irc.example.net
        network: IRCnet
        channels: ["#home"]
      EFnet:
        server: irc.example.org
        nick: OtherBot
        channels: ["#gunnit"]
  YAML

  # A connection that plays back server lines, for Supervisor#run.
  class ScriptedConnection < FakeConnection
    def initialize(lines)
      super()
      @script = lines.dup
    end

    def connect = nil
    def security = "test"
    def gets = @script.shift
  end

  def setup
    super
    @config_path = File.join(@tmpdir, "config.yml")
    write_config(CONFIG)
    install_plugins(File.join(@tmpdir, "plugins"), "chanserv") # channel commands
    @conns = {}
  end

  def write_config(yaml) = File.write(@config_path, yaml, perm: 0o600)

  def supervisor(factory: ->(net) { @conns[net["id"]] = FakeConnection.new })
    @supervisor = Gemdrop::Supervisor.new(Gemdrop::Config.load(@config_path), config_path: @config_path,
                                                                            store: @store, hasher: TEST_HASHER,
                                                                            connection_factory: factory,
                                                                            logger: Logger.new(nil))
  end

  def welcome(network, nick = "Gemdrop")
    bot = @supervisor.bot(network)
    bot.handle(":server 001 #{nick} :Welcome")
    bot.handle(":server 005 #{nick} NETWORK=#{network} :are supported")
    bot
  end

  def status = JSON.parse(File.read(File.join(@tmpdir, "data", "status.json")))

  # --- config ------------------------------------------------------------

  def test_networks_inherit_top_level_settings
    config = Gemdrop::Config.load(@config_path)
    ircnet, efnet = config["networks"]

    assert_equal %w[IRCnet EFnet], config["networks"].map { |net| net["id"] }
    assert_equal "Gemdrop", ircnet["nick"]
    assert_equal "OtherBot", efnet["nick"]
    assert_equal ["#gunnit"], efnet["channels"]
    assert_equal ["root"], efnet["admins"]
    assert_equal File.join(@tmpdir, "data/plugins/efnet"), efnet["plugin_data_dir"]
  end

  def test_single_server_config_is_one_network
    write_config("server: irc.example.net\nnetwork: IRCnet\n")
    assert_equal ["IRCnet"], Gemdrop::Config.load(@config_path)["networks"].map { |net| net["id"] }

    write_config("server: irc.example.net\n")
    assert_equal ["default"], Gemdrop::Config.load(@config_path)["networks"].map { |net| net["id"] }
  end

  def test_rejects_bad_network_configs
    {
      "server: x.example.net\nnetworks:\n  A:\n    server: a.example.net\n" => /top level/,
      "networks:\n  A:\n    server: a.example.net\n    admins: [x]\n" => /admins can't be set per network/,
      "networks:\n  A:\n    nick: Bot\n" => /networks: A: server is not set/,
      "networks:\n  A:\n    server: a.example.net\n  a:\n    server: b.example.net\n" => /more than once/,
      "networks:\n  \"bad name\":\n    server: a.example.net\n" => /network name/,
      "networks: {}\n" => /mapping of network names/
    }.each do |yaml, error|
      write_config(yaml)
      assert_raises(Gemdrop::ConfigError) { Gemdrop::Config.load(@config_path) }.then { |e| assert_match(error, e.message) }
    end
  end

  # --- channels ------------------------------------------------------------

  def test_channels_are_per_network
    Gemdrop::Accounts.new(@store, TEST_HASHER).register("alice", "password123")
    ircnet = Gemdrop::Channels.new(@store, network: "IRCnet")
    efnet = Gemdrop::Channels.new(@store, network: "EFnet")
    ircnet.register("#same", "alice")

    refute efnet.registered?("#same")
    efnet.register("#same", "alice")
    ircnet.drop("#same")
    assert efnet.registered?("#same")
    assert_equal [%w[EFnet #same]], Gemdrop::Channels.owned_anywhere(@store, "alice")
  end

  def test_old_channels_move_to_the_first_network
    @store.transaction do |data|
      data["channels"] = { "#old" => { "name" => "#old", "owner" => "alice", "access" => {} } }
    end
    supervisor

    refute(@store.read { |data| data.key?("channels") })
    assert Gemdrop::Channels.new(@store, network: "IRCnet").registered?("#old")
    refute Gemdrop::Channels.new(@store, network: "EFnet").registered?("#old")
  end

  # --- supervisor ------------------------------------------------------------

  def test_each_network_joins_its_own_channels
    supervisor
    Gemdrop::Channels.new(@store, network: "EFnet").tap do |efnet|
      Gemdrop::Accounts.new(@store, TEST_HASHER).register("alice", "password123")
      efnet.register("#registered", "alice")
    end
    welcome("IRCnet")
    welcome("EFnet", "OtherBot")

    assert_equal ["JOIN #home"], @conns["IRCnet"].lines.grep(/JOIN/)
    assert_equal ["JOIN #gunnit", "JOIN #registered"], @conns["EFnet"].lines.grep(/JOIN/)
  end

  def test_admin_account_works_on_every_network_and_channels_stay_apart
    Gemdrop::Accounts.new(@store, TEST_HASHER).register("root", "password123")
    Gemdrop::Accounts.new(@store, TEST_HASHER).register("alice", "password123")
    supervisor
    ircnet = welcome("IRCnet")
    efnet = welcome("EFnet", "OtherBot")

    efnet.handle(":root!r@root.host PRIVMSG OtherBot :CHANREGISTER #gunnit alice")
    assert_includes @conns["EFnet"].lines, "NOTICE root :You must IDENTIFY first."

    # Identifying is per network, with the same account.
    efnet.handle(":root!r@root.host PRIVMSG OtherBot :IDENTIFY password123")
    efnet.handle(":root!r@root.host PRIVMSG OtherBot :CHANREGISTER #gunnit alice")
    assert_includes @conns["EFnet"].lines, "NOTICE root :#gunnit registered with owner alice."

    ircnet.handle(":root!r@root.host PRIVMSG Gemdrop :IDENTIFY password123")
    ircnet.handle(":root!r@root.host PRIVMSG Gemdrop :ACCESS #gunnit LIST")
    assert_includes @conns["IRCnet"].lines, "NOTICE root :#gunnit is not registered."
    ircnet.handle(":root!r@root.host PRIVMSG Gemdrop :CHANREGISTER #gunnit alice")
    assert_includes @conns["IRCnet"].lines, "NOTICE root :#gunnit registered with owner alice."
  end

  def test_status_file_combines_networks
    supervisor
    welcome("IRCnet")
    assert_equal "partly connected", status["state"]
    assert_equal %w[connected starting], status["networks"].values_at("IRCnet", "EFnet").map { |n| n["state"] }

    welcome("EFnet", "OtherBot")
    assert_equal "connected", status["state"]
    assert_equal "OtherBot", status["networks"]["EFnet"]["nick"]
    assert_equal "EFnet", status["networks"]["EFnet"]["network"]
  end

  def test_reload_adds_and_removes_networks
    supervisor
    welcome("IRCnet")
    welcome("EFnet", "OtherBot")
    write_config(CONFIG.sub(/  EFnet:.*\z/m, "  Libera:\n    server: irc.libera.example\n"))

    assert @supervisor.reload_config
    assert_nil @supervisor.bot("EFnet")
    assert @conns["EFnet"].closed
    assert_includes @conns["EFnet"].lines, "QUIT :Leaving this network"
    refute @conns["IRCnet"].closed
    assert_equal "Libera", @supervisor.bot("libera").network_id
    refute_includes status["networks"].keys, "EFnet"
  end

  def test_reload_applies_each_networks_settings
    supervisor
    welcome("IRCnet").handle(":Gemdrop!b@host JOIN #home")
    welcome("EFnet", "OtherBot").handle(":OtherBot!b@host JOIN #gunnit")
    @conns.each_value(&:clear)
    write_config(CONFIG.sub('channels: ["#gunnit"]', 'channels: ["#gunnit", "#more"]'))

    assert @supervisor.reload_config
    assert_equal ["JOIN #more"], @conns["EFnet"].lines
    assert_empty @conns["IRCnet"].lines
  end

  def test_broken_reload_keeps_everything
    supervisor
    write_config(CONFIG.sub("server: irc.example.org", "nick: Bot"))

    refute @supervisor.reload_config
    assert @supervisor.bot("EFnet")
  end

  def test_run_raises_when_every_network_fails
    write_config(CONFIG.sub(/  EFnet:.*\z/m, ""))
    lines = [":server 001 Gemdrop :Welcome\r\n", ":server 005 Gemdrop NETWORK=Other :are supported\r\n"]
    supervisor(factory: ->(_net) { ScriptedConnection.new(lines) })

    error = assert_raises(Gemdrop::ConfigError) { @supervisor.run(handle_signals: false) }
    assert_match(/IRCnet: .*Other network, not IRCnet/, error.message)
  end

  def test_one_failing_network_leaves_the_others_running
    lines = {
      "IRCnet" => [":server 001 Gemdrop :Welcome\r\n", ":server 005 Gemdrop NETWORK=Other :are supported\r\n"],
      "EFnet" => [":server 001 OtherBot :Welcome\r\n"]
    }
    supervisor(factory: ->(net) { ScriptedConnection.new(lines[net["id"]]) })
    runner = Thread.new { @supervisor.run(handle_signals: false) }
    sleep 0.05 until @supervisor.instance_variable_get(:@errors).any?

    assert runner.alive?
    @supervisor.stop
    assert runner.join(5)
  end
end

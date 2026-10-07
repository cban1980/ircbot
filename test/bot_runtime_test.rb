require "test_helper"

# Config reload, reconnect/stop requests and the status file.
class BotRuntimeTest < Minitest::Test
  include StoreHelper

  BASE_CONFIG = <<~YAML.freeze
    server: irc.example.net
    nick: ModeBot
    channels: ["#home"]
    link_preview:
      enabled: false
  YAML

  def setup
    super
    @config_path = File.join(@tmpdir, "config.yml")
    File.write(@config_path, BASE_CONFIG, perm: 0o600)
    @conn = FakeConnection.new
    @bot = IRCBot::Bot.new(IRCBot::Config.load(@config_path), config_path: @config_path, connection: @conn,
                                                                store: @store, hasher: TEST_HASHER, logger: Logger.new(nil))
    @bot.handle(":server 001 ModeBot :Welcome")
    @bot.handle(":ModeBot!bot@host JOIN #home")
    @conn.clear
  end

  def edit_config(extra)
    File.write(@config_path, BASE_CONFIG + extra, perm: 0o600)
  end

  def status = JSON.parse(File.read(File.join(@tmpdir, "data", "status.json")))

  def test_reload_joins_new_and_parts_removed_channels
    File.write(@config_path, BASE_CONFIG.sub('["#home"]', '["#new"]'), perm: 0o600)

    assert @bot.reload_config
    assert_includes @conn.lines, "JOIN #new"
    assert_includes @conn.lines, "PART #home :No longer configured"
  end

  def test_reload_joins_channels_registered_from_the_command_line
    IRCBot::Accounts.new(@store, TEST_HASHER).register("alice", "password123")
    IRCBot::Channels.new(@store).register("#fromcli", "alice")

    @bot.reload_config
    assert_equal ["JOIN #fromcli"], @conn.lines
  end

  def test_reload_changes_nick_and_umodes_live
    File.write(@config_path, BASE_CONFIG.sub("nick: ModeBot", "nick: NewBot") + "umodes: \"+iw\"\n", perm: 0o600)

    @bot.reload_config
    assert_includes @conn.lines, "NICK NewBot"
    assert_includes @conn.lines, "MODE ModeBot +iw"
    refute @conn.closed
  end

  def test_connection_setting_change_reconnects
    edit_config("realname: Something else\n")

    @bot.reload_config
    assert_equal ["QUIT :Applying new connection settings"], @conn.lines
    assert @conn.closed
  end

  def test_broken_config_keeps_running_with_previous_settings
    File.write(@config_path, "server: irc.example.net\ntls: false\n", perm: 0o600)

    refute @bot.reload_config
    refute @conn.closed
    assert_empty @conn.lines

    File.write(@config_path, "server: [unclosed\n", perm: 0o600)
    refute @bot.reload_config
  end

  def test_data_file_changes_need_a_restart
    edit_config("data_file: elsewhere/ircbot.json\n")

    assert @bot.reload_config
    assert_equal File.join(@tmpdir, "data/ircbot.json"), @bot.instance_variable_get(:@config)["data_file"]
  end

  def test_admin_change_applies_without_reconnect
    edit_config("admins: [alice]\n")

    @bot.reload_config
    assert @bot.send(:admin?, "alice")
    refute @conn.closed
  end

  def test_stop_quits_and_closes
    @bot.stop("Bye")

    assert_equal ["QUIT :Bye"], @conn.lines
    assert @conn.closed
  end

  def test_status_file_tracks_state
    assert_equal "connected", status["state"]
    assert_equal "ModeBot", status["nick"]
    assert_equal ["#home"], status["channels"]
    assert_equal 0o600, File.stat(File.join(@tmpdir, "data", "status.json")).mode & 0o777

    @bot.handle(":ModeBot!bot@host PART #home")
    assert_empty status["channels"]
  end
end

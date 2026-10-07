require "test_helper"

class ConfigTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("ircbot-config")
    @path = File.join(@tmpdir, "config.yml")
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def load(yaml)
    File.write(@path, yaml)
    IRCBot::Config.load(@path)
  end

  def test_secure_defaults
    config = load("server: irc.example.net\n")

    assert config["tls"]
    assert config["tls_verify"]
    assert config["require_secure_users"]
    assert_equal "1.2", config["tls_min_version"]
    assert_equal File.join(@tmpdir, "secret/pepper.key"), config["pepper_file"]
  end

  def test_requires_server
    assert_raises(IRCBot::ConfigError) { load("nick: Bot\n") }
  end

  def test_refuses_plaintext_without_allow_insecure
    error = assert_raises(IRCBot::ConfigError) { load("server: irc.example.net\ntls: false\n") }
    assert_match(/unencrypted/, error.message)

    assert load("server: irc.example.net\ntls: false\nallow_insecure: true\n")
  end

  def test_refuses_unverified_tls_unless_pinned
    assert_raises(IRCBot::ConfigError) { load("server: irc.example.net\ntls_verify: false\n") }

    pinned = load("server: irc.example.net\ntls_verify: false\ntls_fingerprint: #{'AB:' * 31}AB\n")
    assert pinned["tls_fingerprint"]
  end

  def test_self_signed_settings
    config = load("server: irc.example.net\ntls_self_signed: true\n")

    assert config["tls_self_signed"]
    assert config["tls_verify"], "verification stays on; self-signed keys are trusted on first use"
    assert_equal File.join(@tmpdir, "data/known_servers"), config["tls_known_servers"]
    refute load("server: irc.example.net\n")["tls_self_signed"], "off by default"
    assert_raises(IRCBot::ConfigError) { load("server: irc.example.net\ntls_self_signed: \"yes please\"\n") }
  end

  def test_link_preview_message_type
    assert_equal "privmsg", load("server: irc.example.net\n")["link_preview"]["message_type"]
    assert_equal "notice", load("server: irc.example.net\nlink_preview: { message_type: NOTICE }\n")["link_preview"]["message_type"]
    assert_raises(IRCBot::ConfigError) { load("server: irc.example.net\nlink_preview: { message_type: shout }\n") }
  end

  def test_identity_settings
    config = load(<<~YAML)
      server: irc.example.net
      nick: Moder
      alt_nicks: [Moder_, "Mod[er]"]
      user: moder
      realname: Keeps the channel tidy
      umodes: "+iw"
    YAML

    assert_equal %w[Moder_ Mod[er]], config["alt_nicks"]
    assert_equal "+iw", config["umodes"]
  end

  def test_rejects_invalid_identity
    base = "server: irc.example.net\n"

    assert_raises(IRCBot::ConfigError) { load(base + "nick: 9lives\n") }
    assert_raises(IRCBot::ConfigError) { load(base + "alt_nicks: [\"bad nick\"]\n") }
    assert_raises(IRCBot::ConfigError) { load(base + "user: me@host\n") }
    assert_raises(IRCBot::ConfigError) { load(base + "realname: \"\"\n") }
    assert_raises(IRCBot::ConfigError) { load(base + "umodes: iw\n") }
    assert_raises(IRCBot::ConfigError) { load(base + "umodes: \"+io\"\n") }
    assert_equal "", load(base + "umodes: \"\"\n")["umodes"]
  end

  def test_rejects_bad_fingerprint_and_tls_version
    assert_raises(IRCBot::ConfigError) { load("server: irc.example.net\ntls_fingerprint: abc\n") }
    assert_raises(IRCBot::ConfigError) { load("server: irc.example.net\ntls_min_version: 1.0\n") }
    assert_equal "1.3", load("server: irc.example.net\ntls_min_version: 1.3\n")["tls_min_version"]
  end
end

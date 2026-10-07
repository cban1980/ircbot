require "test_helper"

class MessageTest < Minitest::Test
  def test_parses_prefix_command_and_trailing
    msg = IRCBot::Message.parse(":alice!al@example.org PRIVMSG #chan :hello there\r\n")

    assert_equal "alice", msg.nick
    assert_equal "al@example.org", msg.userhost
    assert_equal "PRIVMSG", msg.command
    assert_equal ["#chan", "hello there"], msg.params
  end

  def test_parses_tags
    msg = IRCBot::Message.parse("@account=alice;time=now :alice!a@h JOIN #chan")

    assert_equal({ "account" => "alice", "time" => "now" }, msg.tags)
    assert_equal ["#chan"], msg.params
  end

  def test_parses_server_message_without_prefix
    msg = IRCBot::Message.parse("PING :irc.example.org")

    assert_equal "PING", msg.command
    assert_equal ["irc.example.org"], msg.params
    assert_nil msg.nick
  end

  def test_casemap_treats_brackets_as_case_variants
    assert IRCBot::Casemap.eq?("Foo[Bar]", "foo{bar}")
  end
end

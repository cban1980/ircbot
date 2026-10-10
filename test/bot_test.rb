require "test_helper"

class BotTest < Minitest::Test
  include StoreHelper

  def setup
    super
    @now = 0
    build_bot("require_secure_users" => false)
  end

  def build_bot(overrides = {})
    @conn = FakeConnection.new
    # Channel services and CTCP answers are plugins: install the real ones.
    plugins_dir = install_plugins(File.join(@tmpdir, "plugins"), "chanserv", "ctcp")
    config = Gemdrop::Config::DEFAULTS.merge(
      "server" => "irc.example.net", "nick" => "Gemdrop", "admins" => ["root"], "channels" => ["#home"],
      "status_file" => File.join(@tmpdir, "status.json"), "plugins_dir" => plugins_dir
    ).merge(overrides)
    @bot = Gemdrop::Bot.new(config, connection: @conn, store: @store, hasher: TEST_HASHER,
                                   clock: -> { @now }, logger: Logger.new(nil))
    @bot.handle(":server 001 Gemdrop :Welcome")
    @bot.handle(":Gemdrop!bot@host JOIN #chan")
    @conn.clear
  end

  # Server replies to "WHOIS nick nick"; secure_numeric nil means plaintext.
  def whois_reply(nick, user: nick, host: "#{nick}.host", secure_numeric: "320")
    @bot.handle(":irc.example.net 311 Gemdrop #{nick} #{user} #{host} * :Real Name")
    case secure_numeric
    when "320" then @bot.handle(":irc.example.net 320 Gemdrop #{nick} :is a Secure Connection (SSL/TLS)")
    when "671" then @bot.handle(":irc.example.net 671 Gemdrop #{nick} :is using a secure connection")
    end
    @bot.handle(":irc.example.net 318 Gemdrop #{nick} :End of WHOIS list.")
  end

  def say(nick, text, host: "#{nick}@#{nick}.host")
    @bot.handle(":#{nick}!#{host} PRIVMSG Gemdrop :#{text}")
  end

  def join(nick, channel = "#chan", host: "#{nick}@#{nick}.host")
    @bot.handle(":#{nick}!#{host} JOIN #{channel}")
  end

  def notices_to(nick)
    @conn.lines.grep(/\ANOTICE #{nick} :/).map { |l| l.split(" :", 2).last }
  end

  # root registers #chan with alice as owner; bob has an account.
  # The admin "root" is created locally (as bin/gemdrop-account would),
  # because admin names can't be registered over IRC.
  def create_admin
    Gemdrop::Accounts.new(@store, TEST_HASHER).register("root", "password123")
    say("root", "IDENTIFY password123")
  end

  # root registers #chan with alice as owner; bob has an account.
  def setup_channel
    create_admin
    %w[alice bob].each { |n| say(n, "REGISTER password123") }
    say("root", "CHANREGISTER #chan alice")
    @conn.clear
  end

  def test_answers_ping
    @bot.handle("PING :abc")

    assert_equal ["PONG :abc"], @conn.lines
  end

  # --- bot identity ------------------------------------------------------------

  def connect_fresh(overrides = {})
    build_bot(overrides)
    @bot.send(:reset_state)
    @bot.send(:register_connection)
  end

  def test_joins_only_after_network_is_confirmed
    connect_fresh("network" => "IRCnet")
    @conn.clear
    @bot.handle(":server 001 Gemdrop :Welcome to the Internet Relay Network")
    refute(@conn.lines.any? { |l| l.start_with?("JOIN") })

    @bot.handle(":server 005 Gemdrop PREFIX=(ov)@+ NETWORK=IRCnet CASEMAPPING=rfc1459 :are supported by this server")
    assert_includes @conn.lines, "JOIN #home"
  end

  def test_wrong_network_quits_and_stops
    connect_fresh("network" => "IRCnet")
    @bot.handle(":server 001 Gemdrop :Welcome to the EFNet Internet Relay Chat Network Gemdrop")
    @conn.clear

    error = assert_raises(Gemdrop::ConfigError) do
      @bot.handle(":server 005 Gemdrop NETWORK=EFNet :are supported by this server")
    end
    assert_match(/EFNet network, not IRCnet/, error.message)
    assert_equal ["QUIT :Wrong network"], @conn.lines
  end

  def test_missing_network_name_stops_at_end_of_motd
    connect_fresh("network" => "IRCnet")
    @bot.handle(":server 001 Gemdrop :Welcome")
    @bot.handle(":server 005 Gemdrop PREFIX=(ov)@+ :are supported by this server")

    assert_raises(Gemdrop::ConfigError) { @bot.handle(":server 376 Gemdrop :End of MOTD command.") }
  end

  def test_registers_with_configured_identity
    connect_fresh("nick" => "Moder", "user" => "moder", "realname" => "Channel keeper")

    assert_equal ["NICK Moder", "USER moder 0 * :Channel keeper"], @conn.lines
  end

  def test_sets_configured_user_modes_after_welcome
    connect_fresh("umodes" => "+iw")
    @conn.clear
    @bot.handle(":server 001 Gemdrop :Welcome")

    assert_equal "MODE Gemdrop +iw", @conn.lines.first
  end

  def test_empty_umodes_sends_no_mode
    connect_fresh("umodes" => "")
    @conn.clear
    @bot.handle(":server 001 Gemdrop :Welcome")

    refute(@conn.lines.any? { |l| l.start_with?("MODE") })
  end

  def test_falls_back_through_alt_nicks_then_numbered
    connect_fresh("alt_nicks" => %w[Gemdrop2 MBot])
    @conn.clear

    @bot.handle(":server 433 * Gemdrop :Nickname is already in use")
    @bot.handle(":server 437 * Gemdrop2 :Nick/channel is temporarily unavailable")
    @bot.handle(":server 433 * MBot :Nickname is already in use")

    assert_equal "NICK Gemdrop2", @conn.lines[0]
    assert_equal "NICK MBot", @conn.lines[1]
    assert_match(/\ANICK Gemdro\d{3}\z/, @conn.lines[2])
  end

  def test_regains_primary_nick_when_holder_leaves
    connect_fresh("alt_nicks" => %w[Gemdrop2])
    @bot.handle(":server 433 * Gemdrop :Nickname is already in use")
    @bot.handle(":server 001 Gemdrop2 :Welcome")
    @conn.clear

    @bot.handle(":Gemdrop!x@y QUIT :bye")
    assert_equal ["NICK Gemdrop"], @conn.lines

    @bot.handle(":Gemdrop2!bot@host NICK :Gemdrop")
    @conn.clear
    @bot.handle("PING :abc")
    assert_equal ["PONG :abc"], @conn.lines, "no regain attempt once it has the nick"
  end

  def test_retries_primary_nick_on_ping
    connect_fresh("alt_nicks" => %w[Gemdrop2])
    @bot.handle(":server 433 * Gemdrop :Nickname is already in use")
    @bot.handle(":server 001 Gemdrop2 :Welcome")
    @conn.clear

    @bot.handle("PING :abc")
    @bot.handle(":server 433 Gemdrop2 Gemdrop :Nickname is already in use")

    assert_equal ["PONG :abc", "NICK Gemdrop"], @conn.lines
  end

  def test_checks_whether_primary_nick_is_free
    connect_fresh("alt_nicks" => %w[Gemdrop2])
    @bot.handle(":server 433 * Gemdrop :Nickname is already in use")
    @bot.handle(":server 001 Gemdrop2 :Welcome")
    @conn.clear

    @bot.send(:check_nick)
    assert_equal ["ISON Gemdrop"], @conn.lines
    @bot.handle(":server 303 Gemdrop2 :Gemdrop")
    assert_equal ["ISON Gemdrop"], @conn.lines, "still taken: no NICK"

    @bot.handle(":server 303 Gemdrop2 :")
    assert_equal "NICK Gemdrop", @conn.lines.last

    @bot.handle(":Gemdrop2!bot@host NICK :Gemdrop")
    @conn.clear
    @bot.send(:check_nick)
    assert_empty @conn.lines, "no checks once it has the nick"
  end

  def test_monitor_retakes_primary_nick_when_it_goes_offline
    connect_fresh("alt_nicks" => %w[Gemdrop2])
    @bot.handle(":server 433 * Gemdrop :Nickname is already in use")
    @bot.handle(":server 001 Gemdrop2 :Welcome")
    @bot.handle(":server 005 Gemdrop2 MONITOR=100 NETWORK=Example :are supported")
    @conn.clear

    @bot.handle(":server 376 Gemdrop2 :End of MOTD")
    assert_equal ["MONITOR + Gemdrop"], @conn.lines

    @bot.handle(":server 731 Gemdrop2 :Gemdrop")
    assert_equal "NICK Gemdrop", @conn.lines.last
  end

  def test_no_monitor_without_server_support
    connect_fresh
    @bot.handle(":server 001 Gemdrop :Welcome")
    @conn.clear
    @bot.handle(":server 376 Gemdrop :End of MOTD")

    refute(@conn.lines.any? { |l| l.start_with?("MONITOR") })
  end

  def test_joins_configured_and_registered_channels_on_welcome
    setup_channel
    @bot.send(:reset_state) # as after a reconnect
    @bot.handle(":server 001 Gemdrop :Welcome")

    assert_includes @conn.lines, "JOIN #home"
    assert_includes @conn.lines, "JOIN #chan"
  end

  def test_register_then_identify
    say("alice", "REGISTER password123")
    assert_match(/registered/, notices_to("alice").last)

    say("alice", "LOGOUT")
    say("alice", "IDENTIFY wrongpass")
    assert_match(/Invalid/, notices_to("alice").last)

    say("alice", "IDENTIFY password123")
    assert_match(/identified as alice/, notices_to("alice").last)
  end

  def test_session_not_usable_from_another_host
    setup_channel
    join("alice")
    @conn.clear

    say("alice", "UP #chan", host: "evil@elsewhere")

    assert_match(/IDENTIFY first/, notices_to("alice").last)
    refute(@conn.lines.any? { |l| l.start_with?("MODE") })
  end

  def test_only_admins_register_channels
    say("bob", "REGISTER password123")
    say("bob", "CHANREGISTER #other bob")

    assert_match(/Only bot admins/, notices_to("bob").last)
  end

  def test_auto_op_owner_on_join
    setup_channel
    join("alice")

    assert_includes @conn.lines, "MODE #chan +o alice"
  end

  def test_modes_applied_on_identify_for_channels_user_is_in
    setup_channel
    say("alice", "ACCESS #chan ADD bob voice")
    say("bob", "LOGOUT")
    join("bob")
    @conn.clear

    say("bob", "IDENTIFY password123")

    assert_includes @conn.lines, "MODE #chan +v bob"
  end

  def test_unidentified_user_gets_nothing_on_join
    setup_channel
    say("alice", "LOGOUT")
    @conn.clear
    join("alice")

    assert_empty @conn.lines
  end

  def test_access_add_respects_rank
    setup_channel
    say("alice", "ACCESS #chan ADD bob op")
    assert_match(/bob now has op/, notices_to("alice").last)

    say("bob", "ACCESS #chan ADD root op")
    assert_match(/below your own/, notices_to("bob").last)

    say("bob", "ACCESS #chan DEL alice")
    assert_match(/equal or higher/, notices_to("bob").last)
  end

  # --- hostmask auto-op (admin only) -----------------------------------------

  def test_admin_adds_mask_and_matching_user_gets_op_without_identifying
    setup_channel
    say("root", "ACCESS #chan ADDMASK *!*carol@home.example.net op")
    assert_match(/now gets op on #chan/, notices_to("root").last)
    @conn.clear

    join("carol", host: "~carol@home.example.net")
    assert_includes @conn.lines, "MODE #chan +o carol"
  end

  def test_mask_does_not_match_other_hosts_or_users
    setup_channel
    say("root", "ACCESS #chan ADDMASK *!*carol@home.example.net op")
    @conn.clear

    join("carol", host: "carol@elsewhere.example.net")
    join("mallory", host: "mallory@home.example.net")
    assert_empty @conn.lines.grep(/\AMODE/)
  end

  def test_only_admins_manage_masks
    setup_channel
    say("alice", "ACCESS #chan ADDMASK *!*alice@home.example.net op") # alice is the owner, not an admin

    assert_match(/Only bot admins/, notices_to("alice").last)
  end

  def test_masks_need_an_exact_host
    setup_channel
    %w[*!*@* *!*@*.se *!*carol@home.* *!*carol@localhost carol nick!user@].each do |mask|
      @now += 10 # stay under the command rate limit
      say("root", "ACCESS #chan ADDMASK #{mask} op")
      assert_match(/not a valid mask|full hostname/, notices_to("root").last, mask)
    end
    @now += 10
    say("root", "ACCESS #chan ADDMASK *!*carol@home.example.net owner")
    assert_match(/Unknown level/, notices_to("root").last)
  end

  def test_mask_and_account_give_the_higher_level
    setup_channel
    say("alice", "ACCESS #chan ADD bob voice")
    say("root", "ACCESS #chan ADDMASK bob!*@bob.host op")
    @conn.clear

    join("bob") # identified as bob (voice) and matching the op mask
    assert_equal ["MODE #chan +o bob"], @conn.lines.grep(/\AMODE/)
  end

  def test_delmask_and_list
    setup_channel
    say("root", "ACCESS #chan ADDMASK *!*carol@home.example.net voice")
    say("alice", "ACCESS #chan LIST")
    assert_includes notices_to("alice"), "#chan: mask *!*carol@home.example.net voice (added by root)"

    say("root", "ACCESS #chan DELMASK *!*carol@home.example.net")
    @conn.clear
    join("carol", host: "carol@home.example.net")
    assert_empty @conn.lines.grep(/\AMODE/)
  end

  def test_masks_only_apply_on_registered_channels
    setup_channel
    say("root", "ACCESS #other ADDMASK *!*carol@home.example.net op")

    assert_match(/not registered/, notices_to("root").last)
  end

  def test_access_list
    setup_channel
    say("alice", "ACCESS #chan ADD bob voice")
    @conn.clear
    say("alice", "ACCESS #chan LIST")

    assert_equal ["#chan: alice owner", "#chan: bob voice"], notices_to("alice")
  end

  def test_voice_user_cannot_op_others
    setup_channel
    say("alice", "ACCESS #chan ADD bob voice")
    join("alice")
    @conn.clear

    say("bob", "OP #chan alice")

    assert_match(/need op access/, notices_to("bob").last)
    refute(@conn.lines.any? { |l| l.start_with?("MODE") })
  end

  def test_op_can_voice_and_cannot_deop_owner
    setup_channel
    say("alice", "ACCESS #chan ADD bob op")
    join("alice")
    join("carol")
    @conn.clear

    say("bob", "VOICE #chan carol")
    assert_includes @conn.lines, "MODE #chan +v carol"

    say("bob", "DEOP #chan alice")
    assert_match(/equal or higher/, notices_to("bob").last)
  end

  def test_up_and_down
    setup_channel
    say("alice", "ACCESS #chan ADD bob voice")
    join("bob")
    @conn.clear

    say("bob", "UP #chan")
    say("bob", "DOWN #chan")

    assert_equal ["MODE #chan +v bob", "MODE #chan -v bob"], @conn.lines.grep(/\AMODE/)
  end

  def test_halfop_is_not_offered
    setup_channel
    say("alice", "ACCESS #chan ADD bob halfop")

    assert_match(/Unknown level/, notices_to("alice").last)
  end

  # --- TLS requirement for password commands ---------------------------------

  def test_secret_command_waits_for_whois_and_runs_on_tls
    build_bot
    say("alice", "REGISTER password123")

    assert_equal ["WHOIS alice alice"], @conn.lines
    whois_reply("alice")
    assert_match(/registered/, notices_to("alice").last)
  end

  def test_secret_command_refused_without_tls
    build_bot
    say("alice", "REGISTER password123")
    whois_reply("alice", secure_numeric: nil)

    assert_match(/not connected to IRC over TLS/, notices_to("alice").last)
    say("alice", "WHOAMI")
    assert_match(/not identified/, notices_to("alice").last)
  end

  def test_accepts_standard_671_numeric
    build_bot
    say("alice", "REGISTER password123")
    whois_reply("alice", secure_numeric: "671")

    assert_match(/registered/, notices_to("alice").last)
  end

  def test_unrelated_320_reply_does_not_count_as_tls
    build_bot
    say("alice", "REGISTER password123")
    @bot.handle(":irc.example.net 311 Gemdrop alice alice host * :Real")
    @bot.handle(":irc.example.net 320 Gemdrop alice :is identified to services")
    @bot.handle(":irc.example.net 318 Gemdrop alice :End of WHOIS list.")

    assert_match(/not connected to IRC over TLS/, notices_to("alice").last)
  end

  def test_whois_for_different_userhost_is_rejected
    build_bot
    say("alice", "REGISTER password123")
    whois_reply("alice", user: "someone", host: "elsewhere")

    assert_match(/not connected to IRC over TLS/, notices_to("alice").last)
  end

  def test_tls_result_is_cached_per_userhost
    build_bot
    say("alice", "REGISTER password123")
    whois_reply("alice")
    say("alice", "LOGOUT")
    @conn.clear

    say("alice", "IDENTIFY password123")

    assert_match(/identified as alice/, notices_to("alice").last)
    refute(@conn.lines.any? { |l| l.start_with?("WHOIS") })
  end

  def test_tls_cache_cleared_on_quit
    build_bot
    say("alice", "REGISTER password123")
    whois_reply("alice")
    @bot.handle(":alice!alice@alice.host QUIT :bye")
    @conn.clear

    say("alice", "IDENTIFY password123")

    assert_equal ["WHOIS alice alice"], @conn.lines
  end

  # --- brute-force limits ----------------------------------------------------

  def test_identify_locks_out_after_repeated_failures
    say("alice", "REGISTER password123")
    say("alice", "LOGOUT")
    5.times { say("alice", "IDENTIFY wrongpass1") }

    say("alice", "IDENTIFY password123")
    assert_match(/Too many failed attempts. Try again in 15 minutes/, notices_to("alice").last)

    @now += Gemdrop::Bot::LOGIN_WINDOW + 1
    say("alice", "IDENTIFY password123")
    assert_match(/identified as alice/, notices_to("alice").last)
  end

  def test_lockout_is_per_host
    say("alice", "REGISTER password123")
    say("alice", "LOGOUT")
    5.times { say("alice", "IDENTIFY wrongpass1", host: "evil@attacker") }

    say("alice", "IDENTIFY password123")
    assert_match(/identified as alice/, notices_to("alice").last)
  end

  def test_wrong_old_password_counts_as_failed_attempt
    say("alice", "REGISTER password123")
    5.times { say("alice", "PASSWORD wrongpass1 newsecret99") }

    say("alice", "PASSWORD password123 newsecret99")
    assert_match(/Too many failed attempts/, notices_to("alice").last)
  end

  def test_registration_limited_per_host
    %w[a1 a2 a3].each { |n| say(n, "REGISTER password123", host: "x@samehost") }
    say("a4", "REGISTER password123", host: "x@samehost")

    assert_match(/Too many registrations/, notices_to("a4").last)
  end

  def test_quit_ends_session
    setup_channel
    join("alice")
    @bot.handle(":alice!alice@alice.host QUIT :bye")
    @conn.clear

    join("alice")

    assert_empty @conn.lines
  end

  def test_nick_change_keeps_session_and_membership
    setup_channel
    join("alice")
    @bot.handle(":alice!alice@alice.host NICK :alice2")
    @conn.clear

    say("alice2", "DOWN #chan", host: "alice@alice.host")

    assert_includes @conn.lines, "MODE #chan -o alice2"
  end

  def test_names_reply_populates_roster
    setup_channel
    @bot.handle(":server 353 Gemdrop = #chan :@Gemdrop +alice carol")
    @conn.clear

    say("alice", "UP #chan")

    assert_includes @conn.lines, "MODE #chan +o alice"
  end

  def test_chandrop_by_owner
    setup_channel
    say("alice", "CHANDROP #chan")

    assert_includes @conn.lines, "PART #chan :Channel dropped"
    say("alice", "UP #chan")
    assert_match(/not registered/, notices_to("alice").last)
  end

  def test_unknown_command
    say("alice", "FROBNICATE")

    assert_match(/Unknown command/, notices_to("alice").last)
  end

  def test_password_in_channel_is_not_processed_but_warned_about
    @bot.handle(":alice!a@h PRIVMSG #chan :REGISTER password123")

    assert_equal 1, @conn.lines.size
    assert_match(/\ANOTICE alice :Careful: you sent that to #chan/, @conn.lines.first)
    refute_includes @conn.lines.first, "password123"
    say("alice", "IDENTIFY password123")
    assert_match(/Invalid/, notices_to("alice").last)
  end

  def test_warns_about_mistyped_msg_in_channel
    @bot.handle(":alice!a@h PRIVMSG #chan :msg Gemdrop IDENTIFY hunter22")

    assert_match(/Careful/, notices_to("alice").last)
  end

  def test_ordinary_channel_chat_is_ignored
    @bot.handle(":alice!a@h PRIVMSG #chan :Register now for the meetup on Friday")
    @bot.handle(":alice!a@h PRIVMSG #chan :hello")

    assert_empty @conn.lines
  end

  def test_replies_never_echo_passwords
    say("alice", "REGISTER password123")
    say("alice", "PASSWORD password123 newsecret99")
    say("alice", "LOGOUT")
    say("alice", "IDENTIFY wrongpass1")
    say("alice", "IDENTIFY alice newsecret99 extra")

    @conn.lines.each do |line|
      refute_match(/password123|newsecret99|wrongpass1/, line)
    end
  end

  def test_redacts_passwords_in_logs
    assert_equal ":a!b@c PRIVMSG Gemdrop :IDENTIFY [redacted]",
                 @bot.send(:redact, ":a!b@c PRIVMSG Gemdrop :IDENTIFY alice secret")
    assert_equal "PRIVMSG NickServ :IDENTIFY [redacted]",
                 @bot.send(:redact, "PRIVMSG NickServ :IDENTIFY hunter22")
    assert_equal "@time=x :a!b@c PRIVMSG #chan :msg Gemdrop PASSWORD [redacted]",
                 @bot.send(:redact, "@time=x :a!b@c PRIVMSG #chan :msg Gemdrop PASSWORD old new")
  end
end

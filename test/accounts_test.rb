require "test_helper"

class AccountsTest < Minitest::Test
  include StoreHelper

  def setup
    super
    @accounts = Gemdrop::Accounts.new(@store, TEST_HASHER)
  end

  def data_path = File.join(@tmpdir, "data.json")

  def test_register_and_authenticate_case_insensitively
    @accounts.register("Alice", "correct horse")

    assert_equal "Alice", @accounts.authenticate("alice", "correct horse")
    assert_nil @accounts.authenticate("alice", "wrong password")
    assert_nil @accounts.authenticate("nobody", "correct horse")
  end

  def test_rejects_duplicate_and_short_passwords
    @accounts.register("alice", "correct horse")

    assert_raises(Gemdrop::Error) { @accounts.register("ALICE", "another password") }
    assert_raises(Gemdrop::Error) { @accounts.register("bob", "short") }
  end

  def test_password_is_not_stored_in_plain_text
    @accounts.register("alice", "correct horse")

    stored = File.read(data_path)
    refute_includes stored, "correct horse"
    assert_match(/"scrypt\$4\$8\$1\$/, stored)
    assert_equal 0o600, File.stat(data_path).mode & 0o777
  end

  def test_store_creates_private_directory
    path = File.join(@tmpdir, "nested", "data.json")
    Gemdrop::Accounts.new(Gemdrop::Store.new(path), TEST_HASHER)

    assert_equal 0o700, File.stat(File.dirname(path)).mode & 0o777
  end

  def test_rejects_password_containing_account_name
    assert_raises(Gemdrop::Error) { @accounts.register("alice", "xxAlice123") }
  end

  def test_different_pepper_is_refused
    @accounts.register("alice", "correct horse")
    other = Gemdrop::PasswordHasher.new(pepper: "q" * 32, log_n: 4)

    assert_raises(Gemdrop::ConfigError) { Gemdrop::Accounts.new(Gemdrop::Store.new(data_path), other) }
  end

  def test_rehashes_when_cost_changes
    @accounts.register("alice", "correct horse")
    stronger = Gemdrop::PasswordHasher.new(pepper: TEST_PEPPER, log_n: 5)
    upgraded = Gemdrop::Accounts.new(Gemdrop::Store.new(data_path), stronger)

    assert_equal "alice", upgraded.authenticate("alice", "correct horse")
    assert_match(/"scrypt\$5\$/, File.read(data_path))
    assert_equal "alice", upgraded.authenticate("alice", "correct horse")
  end

  def test_set_password
    @accounts.register("alice", "correct horse")
    @accounts.set_password("alice", "battery staple")

    assert_equal "alice", @accounts.authenticate("alice", "battery staple")
    assert_nil @accounts.authenticate("alice", "correct horse")
    assert_raises(Gemdrop::Error) { @accounts.set_password("alice", "short") }
  end

  def test_session_is_bound_to_userhost
    @accounts.login("alice", "a@home", "alice")

    assert_equal "alice", @accounts.account_for("alice", "a@home")
    assert_nil @accounts.account_for("alice", "evil@elsewhere")
    assert_nil @accounts.account_for("alice", "a@home"), "mismatch should drop the session"
  end

  def test_session_follows_nick_change
    @accounts.login("alice", "a@home", "alice")
    @accounts.rename("alice", "alice_away")

    assert_nil @accounts.account_for("alice", "a@home")
    assert_equal "alice", @accounts.account_for("alice_away", "a@home")
  end

  def test_accounts_persist_across_reload
    @accounts.register("alice", "correct horse")
    reloaded = Gemdrop::Accounts.new(Gemdrop::Store.new(data_path), TEST_HASHER)

    assert_equal "alice", reloaded.authenticate("alice", "correct horse")
  end
end

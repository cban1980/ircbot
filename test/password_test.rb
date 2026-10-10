require "test_helper"

class PasswordHasherTest < Minitest::Test
  def test_verify
    stored = TEST_HASHER.hash("correct horse")

    assert TEST_HASHER.verify("correct horse", stored)
    refute TEST_HASHER.verify("wrong horse", stored)
  end

  def test_same_password_hashes_differently_each_time
    refute_equal TEST_HASHER.hash("correct horse"), TEST_HASHER.hash("correct horse")
  end

  def test_hash_is_useless_without_the_pepper
    stored = TEST_HASHER.hash("correct horse")
    other = Gemdrop::PasswordHasher.new(pepper: "q" * 32, log_n: 4)

    refute other.verify("correct horse", stored)
  end

  def test_rejects_malformed_hashes
    refute TEST_HASHER.verify("x", "")
    refute TEST_HASHER.verify("x", "scrypt$4$8$1$!!")
    refute TEST_HASHER.verify("x", "pbkdf2-sha256$1$abc$def")
  end

  def test_rejects_short_pepper
    assert_raises(ArgumentError) { Gemdrop::PasswordHasher.new(pepper: "short") }
  end
end

class PepperTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("gemdrop-pepper")
    @path = File.join(@tmpdir, "secret", "pepper.key")
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def test_generates_private_key_file_once
    first = Gemdrop::Pepper.load(path: @path, env: {})

    assert_equal 32, first.bytesize
    assert_equal 0o600, File.stat(@path).mode & 0o777
    assert_equal 0o700, File.stat(File.dirname(@path)).mode & 0o777
    assert_equal first, Gemdrop::Pepper.load(path: @path, env: {})
  end

  def test_env_takes_precedence
    hex = "ab" * 32

    assert_equal [hex].pack("H*"), Gemdrop::Pepper.load(path: @path, env: { "GEMDROP_PEPPER" => hex })
    refute File.exist?(@path)
  end

  def test_refuses_world_readable_key_file
    Gemdrop::Pepper.load(path: @path, env: {})
    File.chmod(0o644, @path)

    assert_raises(Gemdrop::ConfigError) { Gemdrop::Pepper.load(path: @path, env: {}) }
  end

  def test_refuses_short_pepper
    assert_raises(Gemdrop::ConfigError) { Gemdrop::Pepper.load(path: @path, env: { "GEMDROP_PEPPER" => "abcd" }) }
  end
end

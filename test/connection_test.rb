require "test_helper"

# Real TLS handshakes against a local server with a throwaway self-signed cert.
class ConnectionTest < Minitest::Test
  def setup
    @key = OpenSSL::PKey::EC.generate("prime256v1")
    @cert = self_signed_cert(@key, "localhost")
    @tcp = TCPServer.new("127.0.0.1", 0)
    @port = @tcp.addr[1]
    @dir = Dir.mktmpdir("rubicon-tls")
    @known_path = File.join(@dir, "known_servers")
  end

  def teardown
    @tcp.close
    @server_thread&.kill
    FileUtils.remove_entry(@dir)
  end

  def self_signed_cert(key, name)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=#{name}")
    cert.public_key = key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 3600
    ext = OpenSSL::X509::ExtensionFactory.new(cert, cert)
    cert.add_extension(ext.create_extension("subjectAltName", "DNS:#{name}"))
    cert.sign(key, OpenSSL::Digest.new("SHA256"))
    cert
  end

  # Accepts TLS clients and sends each a line.
  def start_server(max_version: nil, cert: @cert, key: @key)
    context = OpenSSL::SSL::SSLContext.new
    context.cert = cert
    context.key = key
    context.max_version = max_version if max_version
    server = OpenSSL::SSL::SSLServer.new(@tcp, context)
    @server_thread = Thread.new do
      loop do
        client = server.accept
        client.write(":server NOTICE * :hello\r\n")
        client.close
      rescue OpenSSL::SSL::SSLError, SystemCallError
        next
      end
    rescue IOError
      nil
    end
  end

  def tofu_connection
    connection(known_servers: Rubicon::KnownServers.new(@known_path))
  end

  def connection(**options)
    Rubicon::Connection.new(host: "localhost", port: @port, **options)
  end

  def pin = Rubicon::Connection.spki_fingerprint(@cert)

  def test_rejects_self_signed_certificate_by_default
    start_server
    error = assert_raises(OpenSSL::SSL::SSLError) { connection.connect }
    assert_match(/certificate verify failed/, error.message)
  end

  def test_pinned_key_allows_self_signed_certificate
    start_server
    conn = connection(verify: false, fingerprint: pin.scan(/../).join(":").upcase)
    conn.connect

    assert_match(/hello/, conn.gets)
    assert_match(/TLSv1\.[23], .*certificate NOT verified, key pinned/, conn.security)
  ensure
    conn&.close
  end

  def test_wrong_pin_is_rejected
    start_server
    error = assert_raises(OpenSSL::SSL::SSLError) { connection(verify: false, fingerprint: "00" * 32).connect }
    assert_match(/does not match tls_fingerprint/, error.message)
  end

  # --- self-signed certificates, trusted on first use ------------------------

  def test_self_signed_trusted_on_first_use_then_remembered
    start_server
    first = tofu_connection
    first.connect
    assert first.first_use?
    assert_match(/self-signed certificate, NEW key #{pin} trusted on first use/, first.security)
    assert_match(/hello/, first.gets)
    first.close

    second = tofu_connection
    second.connect
    refute second.first_use?
    assert_match(/key matches the one trusted on first use/, second.security)
    second.close

    assert_equal "localhost:#{@port} #{pin}\n", File.read(@known_path)
    assert_equal 0o600, File.stat(@known_path).mode & 0o777
  end

  def test_changed_key_is_refused
    File.write(@known_path, "localhost:#{@port} #{'00' * 32}\n", perm: 0o600)
    start_server

    error = assert_raises(OpenSSL::SSL::SSLError) { tofu_connection.connect }
    assert_match(/CHANGED.*man-in-the-middle/, error.message)
  end

  def test_self_signed_with_other_hostname_is_trusted_on_first_use
    other_key = OpenSSL::PKey::EC.generate("prime256v1")
    start_server(cert: self_signed_cert(other_key, "other.example"), key: other_key)
    conn = tofu_connection
    conn.connect

    assert conn.first_use?
  ensure
    conn&.close
  end

  def test_concurrent_first_use_records_every_server
    known = Rubicon::KnownServers.new(@known_path)
    threads = (1..8).map { |i| Thread.new { known.check!("server#{i}:6697", format("%064x", i)) } }

    assert_equal [:new] * 8, threads.map(&:value)
    assert_equal 8, known.entries.size
  end

  def test_known_servers_file_must_be_private
    File.write(@known_path, "localhost:#{@port} #{pin}\n", perm: 0o644)
    start_server

    assert_raises(Rubicon::ConfigError) { tofu_connection.connect }
  end

  def test_minimum_tls_version_is_enforced
    start_server(max_version: OpenSSL::SSL::TLS1_2_VERSION)

    assert_raises(OpenSSL::SSL::SSLError) do
      connection(verify: false, fingerprint: pin, min_version: "1.3").connect
    end
  end

  def test_old_tls_versions_are_refused
    start_server(max_version: OpenSSL::SSL::TLS1_1_VERSION)

    assert_raises(OpenSSL::SSL::SSLError, SystemCallError) do
      connection(verify: false, fingerprint: pin).connect
    end
  end
end

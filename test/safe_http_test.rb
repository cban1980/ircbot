require "test_helper"

class SafeHttpTest < Minitest::Test
  # A tiny HTTP server whose routes write raw responses to the socket.
  class TestServer
    attr_reader :port, :requests

    def initialize(routes)
      @routes = routes
      @requests = []
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @thread = Thread.new { loop { handle(@server.accept) } }
    end

    def handle(client)
      request_line = client.gets.to_s
      headers = []
      while (line = client.gets) && line != "\r\n"
        headers << line.chomp
      end
      @requests << [request_line.split[1], headers]
      route = @routes.fetch(request_line.split[1], ->(c) { c.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n") })
      route.call(client)
    rescue IOError, SystemCallError
      nil
    ensure
      client&.close
    end

    def stop
      @thread.kill
      @server.close
    end
  end

  def respond(status, headers, body = "")
    lambda do |client|
      head = headers.map { |k, v| "#{k}: #{v}\r\n" }.join
      client.write("HTTP/1.1 #{status}\r\n#{head}Connection: close\r\n\r\n#{body}")
    end
  end

  # Headers, then body data forever (until the client hangs up).
  def endless(content_type)
    lambda do |client|
      client.write("HTTP/1.1 200 OK\r\nContent-Type: #{content_type}\r\nContent-Length: 999999999\r\n\r\n")
      loop { client.write("x" * 4096) }
    end
  end

  def setup
    @server = TestServer.new(
      "/title" => respond("200 OK", { "Content-Type" => "text/html; charset=utf-8" }, "<title>Hi</title>"),
      "/endless" => endless("text/html"),
      "/image" => endless("image/png"),
      "/to-title" => respond("302 Found", { "Location" => "/title" }),
      "/to-internal" => ->(c) { respond("302 Found", { "Location" => "http://internal.test:#{@server.port}/title" }).call(c) },
      "/to-other" => ->(c) { respond("302 Found", { "Location" => "http://other.test:#{@server.port}/title" }).call(c) },
      "/loop" => respond("302 Found", { "Location" => "/loop" })
    )
    dns = { "public.test" => ["127.0.0.1"], "other.test" => ["127.0.0.1"], "internal.test" => ["10.0.0.1"] }
    @http = Gemdrop::SafeHttp.new(
      user_agent: "test-agent",
      resolver: ->(host) { dns.fetch(host) },
      blocked_ranges: [IPAddr.new("10.0.0.0/8")], # let the local test server through
      ports: { "http" => @server.port },
      max_bytes: 1024
    )
  end

  def teardown
    @server.stop
  end

  def url(path) = "http://public.test:#{@server.port}#{path}"

  def test_fetches_html_with_safe_request_headers
    response = @http.get(url("/title"))

    assert_equal 200, response.status
    assert_equal "text/html", response.content_type
    assert_equal "<title>Hi</title>", response.body
    _path, headers = @server.requests.last
    assert_includes headers, "User-Agent: test-agent"
    assert_includes headers, "Accept-Encoding: identity"
  end

  def test_stops_reading_at_byte_cap
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    response = @http.get(url("/endless"))

    assert_equal 1024, response.body.bytesize
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 3
  end

  def test_non_html_returns_headers_without_reading_body
    response = @http.get(url("/image"))

    assert_equal "image/png", response.content_type
    assert_equal 999_999_999, response.content_length
    assert_nil response.body
  end

  def test_follows_redirects
    response = @http.get(url("/to-title"))

    assert_equal "<title>Hi</title>", response.body
    assert_equal url("/title"), response.url
  end

  def test_extra_headers_only_go_to_the_same_origin
    @http.get(url("/to-title"), headers: { "Authorization" => "Bearer T" })
    assert(@server.requests.all? { |_path, headers| headers.include?("Authorization: Bearer T") },
           "same host, scheme and port: sent on every hop")

    @server.requests.clear
    @http.get(url("/to-other"), headers: { "Authorization" => "Bearer T" })
    (first, first_headers), (second, second_headers) = @server.requests
    assert_equal ["/to-other", "/title"], [first, second]
    assert_includes first_headers, "Authorization: Bearer T"
    refute(second_headers.any? { |h| h.start_with?("Authorization") }, "never to another host")

    https = URI("https://api.example.com/x")
    refute @http.send(:same_origin?, URI("http://api.example.com/x"), https), "never over http after https"
    refute @http.send(:same_origin?, URI("https://api.example.com:8443/x"), https)
    assert @http.send(:same_origin?, URI("https://API.example.com/y"), https)
  end

  def test_reserved_headers_are_refused
    assert_raises(ArgumentError) { @http.get(url("/title"), headers: { "Host" => "evil.test" }) }
    assert_raises(ArgumentError) { @http.get(url("/title"), headers: { "X-A" => "1\r\nX-B: 2" }) }
  end

  def test_redirect_to_internal_address_is_refused
    error = assert_raises(Gemdrop::SafeHttp::Refused) { @http.get(url("/to-internal")) }
    assert_match(/non-public/, error.message)
  end

  def test_redirect_loop_is_refused
    assert_raises(Gemdrop::SafeHttp::Refused) { @http.get(url("/loop")) }
  end
end

# Address and URL checks with the real (default) blocklist.
class SafeHttpPolicyTest < Minitest::Test
  def http_resolving_to(*addresses)
    Gemdrop::SafeHttp.new(user_agent: "t", resolver: ->(_host) { addresses })
  end

  def test_refuses_non_public_addresses
    %w[127.0.0.1 10.1.2.3 172.16.0.1 192.168.1.1 169.254.169.254 100.64.0.1 0.0.0.0 224.0.0.1].each do |address|
      error = assert_raises(Gemdrop::SafeHttp::Refused, address) { http_resolving_to(address).vetted_address("x.test") }
      assert_match(/non-public/, error.message)
    end
  end

  def test_allows_public_addresses
    assert_equal "93.184.216.34", http_resolving_to("93.184.216.34").vetted_address("x.test")
  end

  def test_ignores_ipv6_results
    assert_equal "93.184.216.34", http_resolving_to("::1", "2606:2800:220:1::1", "93.184.216.34").vetted_address("x.test")

    error = assert_raises(Gemdrop::SafeHttp::Refused) { http_resolving_to("2606:2800:220:1::1").vetted_address("x.test") }
    assert_match(/no IPv4 address/, error.message)
  end

  def test_refuses_ipv6_literal_urls
    http = http_resolving_to("93.184.216.34")

    %w[http://[::1]/ http://[2606:2800:220:1::1]/ https://[::ffff:127.0.0.1]/].each do |url|
      assert_raises(Gemdrop::SafeHttp::Refused, url) { http.check_uri(url) }
    end
  end

  def test_refuses_if_any_resolved_address_is_internal
    assert_raises(Gemdrop::SafeHttp::Refused) { http_resolving_to("93.184.216.34", "127.0.0.1").vetted_address("x.test") }
  end

  def test_refuses_unsafe_urls
    http = http_resolving_to("93.184.216.34")

    ["ftp://example.com/", "file:///etc/passwd", "http://user:pw@example.com/",
     "http://example.com:8080/", "https://example.com:22/", "http:///nohost", "http://exa mple.com/"].each do |url|
      assert_raises(Gemdrop::SafeHttp::Refused, url) { http.check_uri(url) }
    end
    assert http.check_uri("https://example.com/path?q=1")
  end
end

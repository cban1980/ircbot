require "net/http"
require "ipaddr"
require "socket"
require "timeout"

module IRCBot
  # HTTP GET for untrusted, user-supplied URLs.
  #
  # Guards against server-side request forgery and resource exhaustion:
  # - only http/https on their default ports, no credentials in the URL
  # - IPv4 only: IPv6 results are ignored and IPv6 literals refused
  # - every IPv4 address the host resolves to must be public; the connection
  #   is pinned to the vetted address so DNS rebinding cannot swap it
  # - redirects are followed by hand and re-checked at every hop
  # - proxies from the environment are ignored, compression is refused
  # - tight per-operation timeouts, an overall deadline, and a byte cap; the
  #   connection is aborted rather than drained once enough has been read
  class SafeHttp
    class Refused < StandardError; end

    Response = Data.define(:url, :status, :content_type, :content_length, :body)

    MAX_REDIRECTS = 3
    MAX_URL_LENGTH = 2_048
    MAX_BYTES = 256 * 1024
    IO_TIMEOUT = 5
    DEADLINE = 10

    DEFAULT_PORTS = { "http" => 80, "https" => 443 }.freeze

    # Loopback, private, link-local, CGNAT, multicast, documentation,
    # benchmarking and reserved IPv4 ranges.
    BLOCKED_RANGES = %w[
      0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12
      192.0.0.0/24 192.0.2.0/24 192.88.99.0/24 192.168.0.0/16 198.18.0.0/15
      198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4
    ].map { |range| IPAddr.new(range) }.freeze

    # Signals that we have what we need; aborts net/http without reading on.
    class Done < StandardError; end
    private_constant :Done

    def initialize(user_agent:, resolver: nil, blocked_ranges: BLOCKED_RANGES, ports: DEFAULT_PORTS,
                   max_bytes: MAX_BYTES)
      @user_agent = user_agent
      @resolver = resolver || method(:resolve)
      @blocked_ranges = blocked_ranges
      @ports = ports
      @max_bytes = max_bytes
    end

    # Request headers callers may not set: the client sets or guards them.
    RESERVED_HEADERS = %w[host accept accept-encoding user-agent content-length connection transfer-encoding].freeze

    # Fetches url. The body is only read when the content type matches
    # body_types; otherwise only status and headers are returned. headers
    # (e.g. an API token) are sent only to the URL's own host, never to a
    # host a redirect leads to.
    def get(url, body_types: %r{\A(?:text/html|application/xhtml\+xml)\z}, accept: "text/html", headers: {})
      deadline = now + DEADLINE
      uri = check_uri(url)
      headers = check_headers(headers)
      origin = uri.hostname
      Timeout.timeout(DEADLINE + IO_TIMEOUT, Refused, "fetch took too long") do
        (MAX_REDIRECTS + 1).times do
          extra = uri.hostname == origin ? headers : {}
          response, location = fetch_once(uri, body_types, accept, deadline, extra)
          return response unless location

          uri = check_uri(URI.join(uri.to_s, location).to_s)
        end
      end
      raise Refused, "too many redirects"
    end

    # Raises Refused unless the URI is an allowed target; returns it parsed.
    def check_uri(url)
      raise Refused, "URL too long" if url.length > MAX_URL_LENGTH

      uri = URI.parse(url)
      raise Refused, "unsupported scheme" unless uri.is_a?(URI::HTTP) && @ports.key?(uri.scheme)
      raise Refused, "missing host" if uri.hostname.to_s.empty?
      raise Refused, "IPv6 addresses are not fetched" if uri.host.start_with?("[")
      raise Refused, "credentials in URL" if uri.userinfo
      raise Refused, "non-standard port" unless uri.port == @ports[uri.scheme]

      uri
    rescue URI::Error => e
      raise Refused, "invalid URL: #{e.message}"
    end

    # The first resolved IPv4 address, after checking that all IPv4 results
    # are public. IPv6 results are ignored.
    def vetted_address(host)
      addresses = @resolver.call(host).map { |address| IPAddr.new(address) }.select(&:ipv4?)
      raise Refused, "#{host} has no IPv4 address" if addresses.empty?
      raise Refused, "#{host} resolves to a non-public address" if addresses.any? { |ip| blocked?(ip) }

      addresses.first.to_s
    end

    private

    def check_headers(headers)
      headers.to_h do |name, value|
        name = name.to_s
        value = value.to_s
        raise ArgumentError, "invalid header name #{name.inspect}" unless name.match?(/\A[A-Za-z0-9-]{1,64}\z/)
        raise ArgumentError, "header #{name} can't be set" if RESERVED_HEADERS.include?(name.downcase)
        raise ArgumentError, "invalid value for header #{name}" if value.match?(/[\r\n\0]/) || value.bytesize > 1024

        [name, value]
      end
    end

    def fetch_once(uri, body_types, accept, deadline, headers = {})
      http = Net::HTTP.new(uri.hostname, uri.port, nil) # nil: never use a proxy from ENV
      http.ipaddr = vetted_address(uri.hostname)
      http.use_ssl = uri.scheme == "https"
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.min_version = OpenSSL::SSL::TLS1_2_VERSION
      http.ciphers = Connection::DEFAULT_CIPHERS
      http.open_timeout = http.read_timeout = http.ssl_timeout = http.write_timeout = IO_TIMEOUT
      http.max_retries = 0

      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = @user_agent
      request["Accept"] = accept
      request["Accept-Encoding"] = "identity"
      headers.each { |name, value| request[name] = value }

      response = location = nil
      body = String.new(encoding: Encoding::BINARY)
      begin
        http.start do
          http.request(request) do |res|
            if res.is_a?(Net::HTTPRedirection) && res["location"]
              location = res["location"]
            else
              type = res["content-type"].to_s.split(";").first.to_s.strip.downcase
              read_capped(res, body, deadline) if res.is_a?(Net::HTTPSuccess) && type.match?(body_types)
              response = build_response(uri, res, type, body)
            end
            raise Done
          end
        end
      rescue Done
        nil
      end
      [response, location]
    end

    def read_capped(res, body, deadline)
      res.read_body do |chunk|
        body << chunk.byteslice(0, @max_bytes - body.bytesize)
        break if body.bytesize >= @max_bytes
        raise Refused, "fetch took too long" if now > deadline
      end
    end

    def build_response(uri, res, type, body)
      length = res["content-length"]
      Response.new(
        url: uri.to_s,
        status: res.code.to_i,
        content_type: type.empty? ? nil : type,
        content_length: length&.match?(/\A\d+\z/) ? length.to_i : nil,
        body: body.empty? ? nil : body
      )
    end

    def blocked?(ip)
      @blocked_ranges.any? { |range| range.include?(ip) }
    end

    def resolve(host)
      Addrinfo.getaddrinfo(host, nil, :INET, :STREAM, timeout: IO_TIMEOUT).map(&:ip_address).uniq
    rescue SocketError => e
      raise Refused, "cannot resolve #{host}: #{e.message}"
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end

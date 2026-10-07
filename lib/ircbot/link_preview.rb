require "json"
require "cgi"
require "uri"

module IRCBot
  # Turns a URL posted in a channel into a one-line description.
  #
  # YouTube videos are described from YouTube's own APIs (title, channel and,
  # with an API key, duration and views). Web pages get their <title>; other
  # content gets its type and size from the response headers. All text from
  # remote sites is sanitized before it is sent to IRC.
  class LinkPreview
    URL = %r{\bhttps?://[^<>"\x00-\x20\x7f]+}i
    YOUTUBE_HOSTS = %w[
      youtube.com www.youtube.com m.youtube.com music.youtube.com
      youtu.be youtube-nocookie.com www.youtube-nocookie.com
    ].freeze
    VIDEO_ID = /\A[A-Za-z0-9_-]{11}\z/
    JSON_TYPES = %r{\Aapplication/json\z}
    HTML_TYPES = %r{\A(?:text/html|application/xhtml\+xml)\z}
    MAX_TEXT = 250

    # IRC formatting codes, other control characters, and bidirectional
    # overrides that could disguise text.
    UNSAFE_CHARS = /[\x00-\x1f\x7f\u0080-\u009f‎‏‪-‮⁦-⁩]/

    FETCH_ERRORS = [
      SafeHttp::Refused, Timeout::Error, IOError, SystemCallError, SocketError,
      OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError, JSON::ParserError, URI::Error
    ].freeze

    def self.extract_urls(text, limit:)
      text.scan(URL).map { |url| trim_trailing(url) }.uniq.first(limit)
    end

    # Drops sentence punctuation after a URL, and a closing parenthesis
    # unless the URL itself opened one (e.g. Wikipedia links).
    def self.trim_trailing(url)
      url = url.sub(/[.,;:!?'"]+\z/, "")
      url = url.chomp(")") while url.end_with?(")") && url.count(")") > url.count("(")
      url
    end

    def self.youtube_id(uri)
      host = uri.host.to_s.downcase
      return nil unless YOUTUBE_HOSTS.include?(host)

      id =
        if host == "youtu.be"
          uri.path.to_s.split("/")[1]
        elsif uri.path == "/watch"
          URI.decode_www_form(uri.query.to_s).assoc("v")&.last
        else
          uri.path.to_s[%r{\A/(?:shorts|live|embed|v)/([^/]+)}, 1]
        end
      id if id&.match?(VIDEO_ID)
    rescue ArgumentError
      nil
    end

    def self.sanitize(text)
      clean = text.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
                  .gsub(UNSAFE_CHARS, " ").gsub(/[[:space:]]+/, " ").strip
      clean.length > MAX_TEXT ? "#{clean[0, MAX_TEXT - 1].rstrip}…" : clean
    end

    def initialize(http:, youtube_api_key: nil, logger: Logger.new(nil))
      @http = http
      @youtube_api_key = youtube_api_key
      @log = logger
    end

    # A preview line for the URL, or nil if there is nothing worth saying.
    def preview(url)
      uri = URI.parse(url)
      id = self.class.youtube_id(uri)
      id ? youtube(id) : page(uri)
    rescue *FETCH_ERRORS => e
      @log.debug("No preview for #{url}: #{e.class}: #{e.message}")
      nil
    end

    private

    # --- YouTube -----------------------------------------------------------

    def youtube(id)
      details = @youtube_api_key ? youtube_api(id) : youtube_oembed(id)
      return nil unless details && !details[:title].to_s.strip.empty?

      parts = [details[:title], details[:channel], details[:duration], details[:views]]
      line("YouTube", parts.compact.map { |part| self.class.sanitize(part) }.reject(&:empty?).join(" · "))
    end

    # Without an API key: title and channel from the public oEmbed endpoint.
    def youtube_oembed(id)
      query = URI.encode_www_form(url: "https://www.youtube.com/watch?v=#{id}", format: "json")
      data = fetch_json("https://www.youtube.com/oembed?#{query}") or return nil

      { title: data["title"], channel: data["author_name"] }
    end

    # With an API key: also duration, live status and view count.
    def youtube_api(id)
      query = URI.encode_www_form(part: "snippet,contentDetails,statistics", id: id, key: @youtube_api_key)
      data = fetch_json("https://www.googleapis.com/youtube/v3/videos?#{query}") or return nil
      video = data["items"]&.first or return nil

      snippet = video["snippet"] || {}
      live = snippet["liveBroadcastContent"] == "live"
      {
        title: snippet["title"],
        channel: snippet["channelTitle"],
        duration: live ? "LIVE" : format_duration(video.dig("contentDetails", "duration")),
        views: (count = video.dig("statistics", "viewCount")) && "#{compact_number(count.to_i)} views"
      }
    end

    def fetch_json(url)
      response = @http.get(url, body_types: JSON_TYPES, accept: "application/json")
      return nil unless response.status == 200 && response.body

      JSON.parse(response.body.force_encoding(Encoding::UTF_8))
    end

    # ISO 8601 duration ("PT1H2M3S") as "1:02:03"; nil for zero or unknown.
    def format_duration(iso)
      match = iso.to_s.match(/\AP(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?\z/) or return nil
      days, hours, minutes, seconds = match.captures.map(&:to_i)
      total = (((days * 24) + hours) * 60 + minutes) * 60 + seconds
      return nil if total.zero?

      h, rest = total.divmod(3600)
      m, s = rest.divmod(60)
      h.positive? ? format("%d:%02d:%02d", h, m, s) : format("%d:%02d", m, s)
    end

    def compact_number(n)
      return n.to_s if n < 1_000

      value, unit = [[1e9, "B"], [1e6, "M"], [1e3, "K"]].find { |size, _| n >= size }
      "#{format('%.1f', n / value).sub(/\.0\z/, '')}#{unit}"
    end

    # --- other links ---------------------------------------------------------

    def page(uri)
      response = @http.get(uri.to_s, body_types: HTML_TYPES)
      return nil unless (200..299).cover?(response.status)

      host = URI.parse(response.url).hostname.to_s.downcase.delete_prefix("www.")
      if response.body
        title = html_title(response.body)
        title && line(host, title)
      elsif response.content_type
        info = [response.content_type, response.content_length && human_size(response.content_length)]
        line(host, info.compact.join(", "))
      end
    end

    def html_title(body)
      html = decode(body)
      raw = html[%r{<title[^>]*>(.*?)</title>}im, 1] ||
            html[/<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']*)/i, 1] ||
            html[/<meta[^>]+content=["']([^"']*)["'][^>]+property=["']og:title["']/i, 1]
      return nil unless raw

      title = self.class.sanitize(CGI.unescapeHTML(raw.gsub("&nbsp;", " ")))
      title.empty? ? nil : title
    end

    # Decodes the body using the charset from <meta>, falling back to UTF-8.
    def decode(body)
      charset = body[/<meta[^>]+charset=["']?([\w-]+)/i, 1]
      encoding = charset ? Encoding.find(charset) : Encoding::UTF_8
      body.dup.force_encoding(encoding).encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
    rescue ArgumentError, Encoding::ConverterNotFoundError
      body.dup.force_encoding(Encoding::UTF_8).scrub("")
    end

    def human_size(bytes)
      units = %w[B KB MB GB TB]
      exp = bytes.zero? ? 0 : [(Math.log(bytes) / Math.log(1024)).floor, units.size - 1].min
      exp.zero? ? "#{bytes} B" : format("%.1f %s", bytes.to_f / (1024**exp), units[exp])
    end

    def line(label, text)
      text = self.class.sanitize(text)
      text.empty? ? nil : "[#{self.class.sanitize(label)}] #{text}"
    end
  end
end

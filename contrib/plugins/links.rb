# Link previews: when someone posts a link, the bot says what it is.
#
#   [YouTube] Me at the zoo · jawed · 0:19 · 350M views
#   [GitHub] rails/rails: Ruby on Rails · ★56K · Ruby
#   [Wikipedia] Ruby (programming language): Ruby is an interpreted, ...
#   [example.com] Example Domain
#   [cdn.example.com] image/png, 1.2 MB
#
# Install:   bin/gemdrop-docker plugin install contrib/plugins/links.rb
# Settings:  under "plugins: links:" in config.yml; all are optional and
#            listed with their defaults in docs/links.md.
# Commands:  TITLE <url> previews a link on request; LINKS [count] lists
#            the links recently posted in a channel.
#
# Sites with their own previews: YouTube (videos, Shorts, live, playlists;
# duration and views with youtube_api_key), Vimeo, GitHub (repositories,
# issues, pull requests, users), Wikipedia, Spotify, SoundCloud and Reddit.
# Other pages show their title (and optionally description); other files
# their type and size. Everything is fetched through the bot's guarded HTTP
# client: public addresses only, small size and time limits.
require "cgi"
require "json"
require "uri"

class Links < Gemdrop::Plugin
  description "Previews links: page titles, YouTube, GitHub, Wikipedia and more"

  SITES = %w[youtube vimeo github wikipedia spotify soundcloud reddit].freeze

  # {field} is replaced by the field; {before|field|after} adds the text
  # around it only when the field has a value.
  FORMATS = {
    "page" => "[{site}] {title}{ — |description|}",
    "file" => "[{site}] {type}{, |size|}",
    "youtube" => "[YouTube] {title}{ · |channel|}{ · |duration|}{ · |views| views}",
    "youtube_playlist" => "[YouTube playlist] {title}{ · |channel|}",
    "vimeo" => "[Vimeo] {title}{ · |author|}{ · |duration|}",
    "github_repo" => "[GitHub] {name}{: |description|}{ · ★|stars|}{ · |language|}",
    "github_issue" => '[GitHub] {repo}{ |kind| }#{number}: {title}{ · |state|}{ · by |author|}',
    "github_user" => "[GitHub] {name}{ (|login|)}{ · |bio|}{ · |repos| repos}",
    "wikipedia" => "[Wikipedia] {title}{: |extract|}",
    "spotify" => "[Spotify] {title}{ · |author|}",
    "soundcloud" => "[SoundCloud] {title}{ · |author|}",
    "reddit" => "[Reddit] {title}{ · |author|}"
  }.freeze

  setting "message_type", default: "privmsg", values: %w[privmsg notice], channel: true
  setting "only_channels", default: [], type: :list, channel: true
  setting "ignore_channels", default: [], type: :list, channel: true
  setting "ignore_nicks", default: [], type: :list, channel: true
  setting "ignore_masks", default: [], type: :list, channel: true
  setting "only_domains", default: [], type: :list, channel: true
  setting "ignore_domains", default: [], type: :list, channel: true
  setting "ignore_prefixes", default: [], type: :list, channel: true
  setting "skip_word", default: "nopreview", type: :string, channel: true
  setting "private_messages", default: false, type: :boolean, channel: true
  setting "actions", default: true, type: :boolean, channel: true
  setting "sites", default: SITES, type: :list, channel: true
  setting "pages", default: true, type: :boolean, channel: true
  setting "files", default: true, type: :boolean, channel: true
  setting "title_source", default: "title", values: %w[title og], channel: true
  setting "show_description", default: false, type: :boolean, channel: true
  setting "skip_title_in_url", default: false, type: :boolean, channel: true
  setting "bold", default: false, type: :boolean, channel: true
  setting "title_length", default: 200, type: :integer, min: 20, max: 400, channel: true
  setting "description_length", default: 150, type: :integer, min: 20, max: 400, channel: true
  setting "max_length", default: 350, type: :integer, min: 40, max: 400, channel: true
  setting "max_urls", default: 3, type: :integer, min: 1, max: 10, channel: true
  setting "per_channel_per_minute", default: 6, type: :integer, min: 1, channel: true
  setting "per_user_per_minute", default: 3, type: :integer, min: 1, channel: true
  setting "repeat_minutes", default: 10, type: :integer, min: 0, channel: true
  setting "cache_minutes", default: 30, type: :integer, min: 0
  setting "history_size", default: 25, type: :integer, min: 0, max: 500
  setting "formats", default: {}, type: :hash, channel: true
  setting "youtube_api_key", type: :string
  setting "github_token", type: :string

  URL = %r{\bhttps?://[^<>"\x00-\x20\x7f]+}i
  YOUTUBE_HOSTS = %w[
    youtube.com www.youtube.com m.youtube.com music.youtube.com
    youtu.be youtube-nocookie.com www.youtube-nocookie.com
  ].freeze
  VIDEO_ID = /\A[A-Za-z0-9_-]{11}\z/
  PLAYLIST_ID = /\A[A-Za-z0-9_-]{10,64}\z/
  GITHUB_RESERVED = %w[
    about apps collections enterprise explore features issues login marketplace new notifications orgs
    pricing pulls search settings site sponsors topics trending
  ].freeze
  HTML_TYPES = %r{\A(?:text/html|application/xhtml\+xml)\z}
  CACHE_SIZE = 500
  NO_PREVIEW = :none # a site handler matched but has nothing to say

  def setup
    unknown_sites = settings["sites"] - SITES
    raise Gemdrop::Error, "unknown sites: #{unknown_sites.join(', ')} (known: #{SITES.join(', ')})" if unknown_sites.any?

    unknown_formats = settings["formats"].keys - FORMATS.keys
    raise Gemdrop::Error, "unknown formats: #{unknown_formats.join(', ')} (known: #{FORMATS.keys.join(', ')})" if unknown_formats.any?

    @lock = Mutex.new # cache and history; previews finish on worker threads
    @cache = {}
    @limiters = {}
    @history = data["history"] || {}
    @dirty = false
    every(300) { save }
  end

  def teardown = save

  on(:message) { |event| consider(event, event.channel) }
  on(:action) { |event| consider(event, event.channel) if event.channel ? settings_for(event.channel)["actions"] : false }

  on(:private_message) do |event|
    next unless settings["private_messages"]
    next if command_word?(event.text)

    consider(event, nil)
  end

  # A help page made when asked: what is previewed with the current settings.
  help_topic("links", summary: "what gets previewed here") do
    parts = ["I preview #{settings['sites'].join(', ')}"]
    parts << "web page titles" if settings["pages"]
    parts << "file types and sizes" if settings["files"]
    text = "#{parts.join(', ')}; at most #{settings['max_urls']} links per message."
    text += "\nAdd \"#{settings['skip_word']}\" to a message to skip its links." unless settings["skip_word"].empty?
    text + "\nTITLE <url> previews one on request; LINKS lists recent links in a channel."
  end

  command "TITLE", usage: "TITLE <url>", help: "preview a link", aliases: %w[PREVIEW], cooldown: 5 do |ctx, args|
    url = extract_urls(args.join(" ")).first or ctx.usage!
    opts = settings_for(ctx.channel)
    queued = background do
      line = preview_line(url, opts)
      line ? ctx.reply(line) : ctx.reply_privately("No preview for #{url}.")
    end
    raise Gemdrop::Error, "Too busy right now; try again in a moment." unless queued
  end

  command "LINKS", usage: "LINKS [#chan] [count]", help: "links recently posted in a channel", cooldown: 10 do |ctx, args|
    channel = ctx.channel
    channel = args.shift if channel.nil? && args.first.to_s.match?(Gemdrop::Channels::NAME)
    ctx.usage! unless channel
    raise Gemdrop::Error, "You're not on #{channel}." unless ctx.channel || user(channel, ctx.nick)

    count = (args.first || 5).to_i.clamp(1, 10)
    entries = @lock.synchronize { (@history[key(channel)] || []).last(count).reverse.map(&:dup) }
    next ctx.reply_privately("No links posted in #{channel} yet.") if entries.empty?

    entries.each do |entry|
      title = entry["title"] ? " — #{entry['title']}" : ""
      ctx.reply_privately("#{ago(entry['at'])} ago, #{entry['nick']}: #{entry['url']}#{title}")
    end
  end

  # --- deciding what to preview ----------------------------------------------------

  def extract_urls(text) = text.to_s.scan(URL).map { |url| trim_trailing(url) }.uniq

  private

  def consider(event, channel)
    opts = settings_for(channel)
    return if event.nick.nil? || Gemdrop::Casemap.eq?(event.nick, bot_nick)
    return if channel && !channel_wanted?(channel, opts)
    return if ignored_user?(event, opts)

    text = event.text.to_s
    return if opts["ignore_prefixes"].any? { |prefix| !prefix.to_s.empty? && text.start_with?(prefix.to_s) }
    return if !opts["skip_word"].empty? && text.downcase.include?(opts["skip_word"].downcase)

    target = channel || event.nick
    urls = extract_urls(text).select { |url| domain_wanted?(url, opts) }.first(opts["max_urls"])
    urls.each do |url|
      remember(channel, event.nick, url) if channel
      next unless fresh?(target, url, opts)
      break unless within_limits?(target, event.userhost, opts)

      queue_preview(url, target, channel, event.nick, opts)
    end
  end

  def queue_preview(url, target, channel, nick, opts)
    queued = background do
      line = preview_line(url, opts)
      next unless line

      send_preview(target, line, opts)
      record_title(channel, url, line) if channel
      publish("link", { "url" => url, "nick" => nick, "channel" => channel, "network" => network, "preview" => line })
    end
    log.warn("Preview queue full; skipped #{url}") unless queued
  end

  def send_preview(target, line, opts)
    opts["message_type"] == "notice" ? notice(target, line) : say(target, line)
  end

  def channel_wanted?(channel, opts)
    return false if opts["ignore_channels"].any? { |c| Gemdrop::Casemap.eq?(c, channel) }

    opts["only_channels"].empty? || opts["only_channels"].any? { |c| Gemdrop::Casemap.eq?(c, channel) }
  end

  def ignored_user?(event, opts)
    opts["ignore_nicks"].any? { |nick| Gemdrop::Casemap.eq?(nick, event.nick) } ||
      (event.userhost && opts["ignore_masks"].any? { |mask| Gemdrop::Channels.mask_match?(mask, event.prefix) })
  end

  def domain_wanted?(url, opts)
    host = URI.parse(url).hostname.to_s.downcase
    return false if opts["ignore_domains"].any? { |domain| domain_match?(host, domain) }

    opts["only_domains"].empty? || opts["only_domains"].any? { |domain| domain_match?(host, domain) }
  rescue URI::Error
    false
  end

  def domain_match?(host, domain)
    domain = domain.to_s.downcase.delete_prefix(".")
    host == domain || host.end_with?(".#{domain}")
  end

  # The same link isn't previewed again in a channel for repeat_minutes.
  def fresh?(target, url, opts)
    window = opts["repeat_minutes"] * 60
    return true if window.zero?

    seen_key = "#{key(target)} #{url}"
    return false if limiter(window).blocked_for(seen_key, limit: 1)

    limiter(window).hit(seen_key)
    true
  end

  def within_limits?(target, userhost, opts)
    chan_key = "chan:#{key(target)}"
    host_key = "host:#{userhost.to_s.split('@', 2).last.to_s.downcase}"
    return false if limiter(60).blocked_for(chan_key, limit: opts["per_channel_per_minute"])
    return false if limiter(60).blocked_for(host_key, limit: opts["per_user_per_minute"])

    [chan_key, host_key].each { |limit_key| limiter(60).hit(limit_key) }
    true
  end

  def limiter(window) = (@limiters[window] ||= Gemdrop::RateLimiter.new(window: window, clock: -> { now }))

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def command_word?(text)
    word = text.to_s.strip.split.first.to_s.upcase
    Gemdrop::Bot::COMMANDS.key?(word) || self.class.commands.key?(word)
  end

  # Drops sentence punctuation after a URL, and a closing parenthesis
  # unless the URL itself opened one (e.g. Wikipedia links).
  def trim_trailing(url)
    url = url.sub(/[.,;:!?'"]+\z/, "")
    url = url.chomp(")") while url.end_with?(")") && url.count(")") > url.count("(")
    url
  end

  # --- turning a URL into a line (on a worker thread) ---------------------------------

  def preview_line(url, opts)
    info = cached([url, *opts.values_at(*FETCH_SETTINGS)]) { fetch_info(url, opts) }
    info && render(info, opts)
  end

  # Settings that change what is fetched; channels that agree on them
  # share cached previews (formats are applied afterwards).
  FETCH_SETTINGS = %w[sites pages files title_source skip_title_in_url].freeze

  # Previews are cached as their fields, so channels with different
  # formats share one fetch.
  def cached(url)
    ttl = settings["cache_minutes"] * 60
    return yield if ttl.zero?

    hit = @lock.synchronize { @cache[url] }
    return hit[0] if hit && hit[1] > now

    info = yield
    @lock.synchronize do
      @cache.delete(url)
      @cache[url] = [info, now + ttl]
      @cache.delete(@cache.keys.first) while @cache.size > CACHE_SIZE
    end
    info
  end

  # [format name, fields] or nil.
  def fetch_info(url, opts)
    uri = URI.parse(url)
    info = site_info(uri, opts)
    return nil if info == NO_PREVIEW

    info || page_info(uri, opts)
  rescue Gemdrop::Error, URI::Error, JSON::ParserError, ArgumentError => e
    log.debug("No preview for #{url}: #{e.message}")
    nil
  end

  def site_info(uri, opts)
    host = uri.hostname.to_s.downcase
    sites = opts["sites"]
    if sites.include?("youtube") && YOUTUBE_HOSTS.include?(host) then youtube(uri)
    elsif sites.include?("vimeo") && host.match?(/\A(?:www\.|player\.)?vimeo\.com\z/) then vimeo(uri)
    elsif sites.include?("github") && host.match?(/\A(?:www\.)?github\.com\z/) then github(uri)
    elsif sites.include?("wikipedia") && host.match?(/\A[a-z-]{2,12}(?:\.m)?\.wikipedia\.org\z/) then wikipedia(uri)
    elsif sites.include?("spotify") && host == "open.spotify.com"
      oembed("spotify", "https://open.spotify.com/oembed?url=#{escape(uri.to_s)}")
    elsif sites.include?("soundcloud") && host.match?(/\A(?:www\.|m\.)?soundcloud\.com\z/)
      oembed("soundcloud", "https://soundcloud.com/oembed?format=json&url=#{escape(uri.to_s)}")
    elsif sites.include?("reddit") && host.match?(/\A(?:(?:www|old|new|np)\.)?reddit\.com\z|\Aredd\.it\z/)
      oembed("reddit", "https://www.reddit.com/oembed?url=#{escape(uri.to_s)}")
    end
  end

  # --- YouTube ---------------------------------------------------------------------------

  def youtube(uri)
    if (id = youtube_id(uri))
      youtube_api_key ? youtube_api(id) : youtube_oembed("https://www.youtube.com/watch?v=#{id}", "youtube")
    elsif uri.path == "/playlist" && (list = query_param(uri, "list"))&.match?(PLAYLIST_ID)
      youtube_oembed("https://www.youtube.com/playlist?list=#{list}", "youtube_playlist")
    else
      NO_PREVIEW # YouTube pages themselves are never scraped
    end
  end

  def youtube_id(uri)
    host = uri.hostname.to_s.downcase
    return nil unless YOUTUBE_HOSTS.include?(host)

    id =
      if host == "youtu.be"
        uri.path.to_s.split("/")[1]
      elsif uri.path == "/watch"
        query_param(uri, "v")
      else
        uri.path.to_s[%r{\A/(?:shorts|live|embed|v)/([^/]+)}, 1]
      end
    id if id&.match?(VIDEO_ID)
  end

  def youtube_oembed(url, format)
    data = json_or_nil("https://www.youtube.com/oembed?#{URI.encode_www_form(url: url, format: 'json')}")
    return NO_PREVIEW unless data && !data["title"].to_s.strip.empty?

    [format, { "title" => data["title"], "channel" => data["author_name"] }]
  end

  # With an API key: also duration (or LIVE), views, likes and the date.
  def youtube_api(id)
    query = URI.encode_www_form(part: "snippet,contentDetails,statistics", id: id, key: youtube_api_key)
    video = json_or_nil("https://www.googleapis.com/youtube/v3/videos?#{query}")&.dig("items", 0)
    return NO_PREVIEW unless video && !video.dig("snippet", "title").to_s.strip.empty?

    snippet = video["snippet"]
    live = snippet["liveBroadcastContent"] == "live"
    stats = video["statistics"] || {}
    ["youtube", {
      "title" => snippet["title"],
      "channel" => snippet["channelTitle"],
      "duration" => live ? "LIVE" : iso_duration(video.dig("contentDetails", "duration")),
      "views" => stats["viewCount"] && compact_number(stats["viewCount"].to_i),
      "likes" => stats["likeCount"] && compact_number(stats["likeCount"].to_i),
      "date" => snippet["publishedAt"].to_s[0, 10]
    }]
  end

  def youtube_api_key = settings["youtube_api_key"] || ENV.fetch("GEMDROP_YOUTUBE_API_KEY", nil)

  # --- other sites -------------------------------------------------------------------------

  def vimeo(uri)
    return nil unless uri.path.to_s.match?(%r{/\d+(?:/|\z)})

    data = json_or_nil("https://vimeo.com/api/oembed.json?url=#{escape(uri.to_s)}")
    return NO_PREVIEW unless data && data["title"]

    ["vimeo", { "title" => data["title"], "author" => data["author_name"],
                "duration" => data["duration"] && clock(data["duration"].to_i) }]
  end

  def github(uri)
    owner, repo, kind, number = uri.path.to_s.split("/").reject(&:empty?)
    return nil if owner.nil? || GITHUB_RESERVED.include?(owner.downcase)
    return nil unless owner.match?(/\A[\w.-]+\z/) && (repo.nil? || repo.match?(/\A[\w.-]+\z/))

    headers = settings["github_token"] ? { "Authorization" => "Bearer #{settings['github_token']}" } : {}
    if repo.nil?
      data = json_or_nil("https://api.github.com/users/#{owner}", headers) or return nil
      ["github_user", { "name" => data["name"] || data["login"], "login" => (data["login"] if data["name"]),
                        "bio" => data["bio"], "repos" => data["public_repos"]&.to_s }]
    elsif %w[issues pull].include?(kind) && number.to_s.match?(/\A\d+\z/)
      data = json_or_nil("https://api.github.com/repos/#{owner}/#{repo}/issues/#{number}", headers) or return nil
      state = data["pull_request"]&.dig("merged_at") ? "merged" : data["state"]
      ["github_issue", { "repo" => "#{owner}/#{repo}", "kind" => data["pull_request"] ? "PR" : "issue",
                         "number" => number, "title" => data["title"], "state" => state,
                         "author" => data.dig("user", "login") }]
    elsif kind.nil? || %w[tree blob].include?(kind)
      data = json_or_nil("https://api.github.com/repos/#{owner}/#{repo}", headers) or return nil
      ["github_repo", { "name" => data["full_name"], "description" => data["description"],
                        "stars" => data["stargazers_count"] && compact_number(data["stargazers_count"]),
                        "language" => data["language"], "forks" => data["forks_count"]&.to_s }]
    end
  end

  def wikipedia(uri)
    title = uri.path.to_s[%r{\A/wiki/(.+)\z}, 1] or return nil
    lang = uri.hostname.to_s.downcase.split(".").first
    data = json_or_nil("https://#{lang}.wikipedia.org/api/rest_v1/page/summary/#{title.gsub('/', '%2F')}")
    return NO_PREVIEW unless data && data["title"]

    ["wikipedia", { "title" => data["title"], "description" => data["description"],
                    "extract" => data["extract"] }]
  end

  def oembed(format, url)
    data = json_or_nil(url)
    return NO_PREVIEW unless data && !data["title"].to_s.strip.empty?

    [format, { "title" => data["title"], "author" => data["author_name"] }]
  end

  # --- web pages and files ------------------------------------------------------------------

  def page_info(uri, opts)
    response = http_get(uri.to_s, accept: "text/html,application/xhtml+xml;q=0.9,*/*;q=0.5", types: HTML_TYPES)
    return nil unless (200..299).cover?(response.status)

    site = URI.parse(response.url).hostname.to_s.downcase.delete_prefix("www.")
    if response.body
      return nil unless opts["pages"]

      html = decode(response.body)
      title = page_title(html, opts) or return nil
      return nil if opts["skip_title_in_url"] && title_in_url?(title, response.url)

      ["page", { "site" => site, "title" => title, "site_name" => meta(html, "og:site_name"),
                 "description" => meta(html, "og:description") || meta(html, "description") }]
    elsif response.content_type && opts["files"]
      ["file", { "site" => site, "type" => response.content_type,
                 "size" => response.content_length && human_size(response.content_length) }]
    end
  end

  def page_title(html, opts)
    tag = html[%r{<title[^>]*>(.*?)</title>}im, 1]
    og = meta(html, "og:title")
    title = opts["title_source"] == "og" ? og || tag : tag || og
    title = title && unescape(title)
    title.nil? || title.strip.empty? ? nil : title
  end

  def meta(html, name)
    pattern = Regexp.escape(name)
    raw = html[/<meta[^>]+(?:property|name)=["']#{pattern}["'][^>]+content=["']([^"']*)/i, 1] ||
          html[/<meta[^>]+content=["']([^"']*)["'][^>]+(?:property|name)=["']#{pattern}["']/i, 1]
    raw && !raw.strip.empty? ? unescape(raw) : nil
  end

  # True if the title's words are all in the URL already (e.g. a slug).
  def title_in_url?(title, url)
    words = title.downcase.scan(/[[:alnum:]]{3,}/)
    words.any? && words.all? { |word| url.downcase.include?(word) }
  end

  # Decodes the body using the charset from <meta>, falling back to UTF-8.
  def decode(body)
    charset = body[/<meta[^>]+charset=["']?([\w-]+)/i, 1]
    encoding = charset ? Encoding.find(charset) : Encoding::UTF_8
    body.dup.force_encoding(encoding).encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
  rescue ArgumentError, Encoding::ConverterNotFoundError
    body.dup.force_encoding(Encoding::UTF_8).scrub("")
  end

  def unescape(text) = CGI.unescapeHTML(text.gsub("&nbsp;", " "))

  # --- formatting -------------------------------------------------------------------------------

  def render(info, opts)
    format_name, fields = info
    fields = fields.except("description") if format_name == "page" && !opts["show_description"]
    template = opts["formats"][format_name] || FORMATS.fetch(format_name)
    limits = { "title" => opts["title_length"], "description" => opts["description_length"],
               "extract" => opts["description_length"], "bio" => opts["description_length"] }
    line = template.to_s.gsub(/[\r\n]/, " ").gsub(/\{(?:([^{}|]*)\|)?(\w+)(?:\|([^{}|]*))?\}/) do
      before, name, after = Regexp.last_match.captures
      value = clean(fields[name], limits.fetch(name, opts["title_length"]))
      next "" if value.empty?

      value = "\x02#{value}\x02" if opts["bold"] && name == "title"
      "#{before}#{value}#{after}"
    end
    line = line.strip
    return nil if line.empty? || fields.values.compact.all? { |v| v.to_s.strip.empty? }

    line.length > opts["max_length"] ? "#{line[0, opts['max_length'] - 1].rstrip}…" : line
  end

  # Text from other sites: no IRC formatting, control or direction
  # characters, one line, at most max characters.
  def clean(text, max)
    clean = text.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
                .gsub(Gemdrop::Bot::UNSAFE_CHARS, " ").gsub(/[[:space:]]+/, " ").strip
    clean.length > max ? "#{clean[0, max - 1].rstrip}…" : clean
  end

  # ISO 8601 duration ("PT1H2M3S") as "1:02:03"; nil for zero or unknown.
  def iso_duration(iso)
    match = iso.to_s.match(/\AP(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?\z/) or return nil
    days, hours, minutes, seconds = match.captures.map(&:to_i)
    clock((((days * 24) + hours) * 60 + minutes) * 60 + seconds)
  end

  def clock(total)
    return nil unless total.positive?

    h, rest = total.divmod(3600)
    m, s = rest.divmod(60)
    h.positive? ? format("%d:%02d:%02d", h, m, s) : format("%d:%02d", m, s)
  end

  def compact_number(n)
    return n.to_s if n < 1_000

    value, unit = [[1e9, "B"], [1e6, "M"], [1e3, "K"]].find { |size, _| n >= size }
    "#{format('%.1f', n / value).sub(/\.0\z/, '')}#{unit}"
  end

  def human_size(bytes)
    units = %w[B KB MB GB TB]
    exp = bytes.zero? ? 0 : [(Math.log(bytes) / Math.log(1024)).floor, units.size - 1].min
    exp.zero? ? "#{bytes} B" : format("%.1f %s", bytes.to_f / (1024**exp), units[exp])
  end

  def ago(time)
    seconds = Time.now.to_i - time.to_i
    [[86_400, "d"], [3600, "h"], [60, "m"]].each { |size, unit| return "#{seconds / size}#{unit}" if seconds >= size }
    "#{seconds}s"
  end

  # --- history ----------------------------------------------------------------------------------

  def remember(channel, nick, url)
    size = settings["history_size"]
    return if size.zero?

    @lock.synchronize do
      list = (@history[key(channel)] ||= [])
      list << { "url" => url, "nick" => nick, "at" => Time.now.to_i }
      list.shift while list.size > size
      @dirty = true
    end
  end

  def record_title(channel, url, line)
    @lock.synchronize do
      entry = (@history[key(channel)] || []).reverse.find { |e| e["url"] == url } or next
      entry["title"] = line.delete("\x02")
      @dirty = true
    end
  end

  def save
    history = @lock.synchronize do
      next nil unless @dirty

      @dirty = false
      @history.transform_values { |list| list.map(&:dup) }
    end
    data["history"] = history if history
  end

  # --- helpers ---------------------------------------------------------------------------------

  def json_or_nil(url, headers = {})
    http_json(url, headers: headers)
  rescue Gemdrop::Error => e
    log.debug("#{url}: #{e.message}")
    nil
  end

  def query_param(uri, name) = URI.decode_www_form(uri.query.to_s).assoc(name)&.last

  def escape(text) = URI.encode_www_form_component(text)

  def key(name) = Gemdrop::Casemap.downcase(name)
end

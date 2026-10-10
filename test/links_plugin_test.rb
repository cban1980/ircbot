require "test_helper"

# The links plugin (contrib/plugins/links.rb): finding links, the site
# previews, page titles, formatting, limits and settings.
class LinksPluginTest < Minitest::Test
  include StoreHelper

  Response = Gemdrop::SafeHttp::Response

  # Returns canned responses by URL prefix and records what was fetched.
  class FakeHttp
    attr_reader :fetched, :headers

    def initialize = (@routes = {}) && (@fetched = []) && (@headers = [])

    def route(prefix, response) = @routes[prefix] = response

    def get(url, headers: {}, **)
      @fetched << url
      @headers << headers
      _prefix, response = @routes.find { |prefix, _| url.start_with?(prefix) }
      raise Gemdrop::SafeHttp::Refused, "no route" unless response

      response
    end
  end

  def setup
    super
    @plugins_dir = File.join(@tmpdir, "plugins")
    Dir.mkdir(@plugins_dir, 0o700)
    File.write(File.join(@plugins_dir, "links.rb"),
               File.read(File.expand_path("../contrib/plugins/links.rb", __dir__)), perm: 0o600)
    @http = FakeHttp.new
  end

  def start(settings = "")
    path = File.join(@tmpdir, "config.yml")
    File.write(path, <<~YAML + settings.gsub(/^/, "    "), perm: 0o600)
      server: irc.example.net
      nick: Gemdrop
      channels: ["#chan"]
      require_secure_users: false
      plugins:
        links:
    YAML
    @conn = FakeConnection.new
    @bot = Gemdrop::Bot.new(Gemdrop::Config.load(path), connection: @conn, store: @store, hasher: TEST_HASHER,
                                                       http: @http, plugin_pool: InlinePool.new, logger: Logger.new(nil))
    @bot.handle(":server 001 Gemdrop :Welcome")
    @bot.handle(":Gemdrop!bot@host JOIN #chan")
    @conn.clear
    plugin
  end

  def plugin = @bot.send(:plugin_manager).plugin("links")
  def status = @bot.send(:plugin_manager).status["links"]

  def chat(nick, text, channel: "#chan", host: "#{nick}@#{nick}.host")
    @bot.handle(":#{nick}!#{host} PRIVMSG #{channel} :#{text}")
  end

  def html(url, body, status: 200)
    Response.new(url: url, status: status, content_type: "text/html", content_length: nil, body: body.b)
  end

  # json("title" => "x") or json({...}, status: 404)
  def json(body = nil, status: 200, **fields)
    Response.new(url: "x", status: status, content_type: "application/json", content_length: nil,
                 body: JSON.generate(body || fields))
  end

  def page(url = "https://example.com/", title = "Example Domain")
    @http.route(url, html(url, "<html><head><title>#{title}</title></head></html>"))
  end

  # The line the plugin would post for a URL (fetching through FakeHttp).
  # Runs as a background job would; http_get refuses to run elsewhere.
  def preview(url)
    Thread.current[:gemdrop_background] = true
    plugin.send(:preview_line, url, plugin.settings).tap { plugin.instance_variable_get(:@cache).clear }
  ensure
    Thread.current[:gemdrop_background] = nil
  end

  # --- finding links ------------------------------------------------------------------

  def test_extracts_urls_and_trims_punctuation
    start
    urls = plugin.extract_urls("see https://example.com/a. and (https://en.wikipedia.org/wiki/Foo_(bar)), " \
                               "https://example.com/b?x=1! twice https://example.com/a")
    assert_equal %w[https://example.com/a https://en.wikipedia.org/wiki/Foo_(bar) https://example.com/b?x=1], urls
  end

  def test_previews_links_in_channels
    start
    page
    chat("alice", "look https://example.com/!")
    assert_equal ["PRIVMSG #chan :[example.com] Example Domain"], @conn.lines
  end

  def test_notice_and_bold_and_custom_format
    start(%(message_type: notice\nbold: true\nformats:\n  page: "{title} ({site})"\n))
    page
    chat("alice", "https://example.com/")
    assert_equal ["NOTICE #chan :\x02Example Domain\x02 (example.com)"], @conn.lines
  end

  def test_ignores_own_messages_private_messages_and_skip_word
    start
    page
    chat("Gemdrop", "https://example.com/", host: "bot@host")
    @bot.handle(":alice!a@a.host PRIVMSG Gemdrop :https://example.com/")
    chat("alice", "https://example.com/ nopreview")
    assert_empty @http.fetched
  end

  def test_private_messages_when_enabled
    start("private_messages: true\ncache_minutes: 0\n")
    page
    @bot.handle(":alice!a@a.host PRIVMSG Gemdrop :https://example.com/")
    @bot.handle(":alice!a@a.host PRIVMSG Gemdrop :TITLE https://example.com/other")
    assert_equal ["PRIVMSG alice :[example.com] Example Domain"], @conn.lines.grep(/Example/).first(1)
    assert_equal 1, @http.fetched.count("https://example.com/other"), "TITLE is a command, not also a link to preview"
  end

  def test_actions_and_their_setting
    start
    page
    chat("alice", "\x01ACTION likes https://example.com/\x01")
    assert_equal ["PRIVMSG #chan :[example.com] Example Domain"], @conn.lines

    start("actions: false\n")
    chat("alice", "\x01ACTION likes https://example.com/\x01")
    assert_empty @conn.lines
  end

  # --- limits -------------------------------------------------------------------------

  def test_at_most_max_urls_per_message
    start
    (1..5).each { |i| page("https://example.com/#{i}") }
    chat("alice", (1..5).map { |i| "https://example.com/#{i}" }.join(" "))
    assert_equal 3, @conn.lines.size
  end

  def test_same_link_not_repeated_within_repeat_minutes
    start
    page
    clock = 0
    plugin.define_singleton_method(:now) { clock }
    chat("alice", "https://example.com/")
    chat("bob", "https://example.com/")
    assert_equal 1, @conn.lines.size

    chat("bob", "https://example.com/", channel: "#other")
    assert_equal 2, @conn.lines.size, "other channels get their own preview"

    clock += 601
    chat("bob", "https://example.com/")
    assert_equal 3, @conn.lines.size
  end

  def test_per_user_and_per_channel_limits
    start("repeat_minutes: 0\ncache_minutes: 0\n")
    page("https://example.com/")
    clock = 0
    plugin.define_singleton_method(:now) { clock }
    5.times { chat("alice", "https://example.com/") }
    assert_equal 3, @conn.lines.size

    %w[b c d e].each { |n| chat(n, "https://example.com/", host: "#{n}@#{n}.example") }
    assert_equal 6, @conn.lines.size

    clock += 61
    chat("bob", "https://example.com/", host: "bob@bob.example")
    assert_equal 7, @conn.lines.size
  end

  def test_cache_saves_fetches
    start("repeat_minutes: 0\n")
    page
    chat("alice", "https://example.com/")
    chat("bob", "https://example.com/", channel: "#other")
    assert_equal 1, @http.fetched.size
    assert_equal 2, @conn.lines.size
  end

  # --- filters and per-channel settings -----------------------------------------------------

  def test_channel_nick_mask_domain_and_prefix_filters
    start(<<~YAML)
      only_channels: ["#chan", "#other"]
      ignore_channels: ["#other"]
      ignore_nicks: [OtherBot]
      ignore_masks: ["*!*@spam.example"]
      ignore_domains: [ads.example.com]
      ignore_prefixes: ["!"]
    YAML
    page("https://ads.example.com/")
    page("https://example.com/")
    chat("otherbot", "https://example.com/")
    chat("mallory", "https://example.com/", host: "m@spam.example")
    chat("alice", "https://example.com/", channel: "#elsewhere")
    chat("alice", "https://example.com/", channel: "#other")
    chat("alice", "!cmd https://example.com/")
    chat("alice", "https://ads.example.com/")
    assert_empty @http.fetched

    chat("alice", "https://example.com/")
    assert_equal 1, @conn.lines.size
  end

  def test_only_domains
    start("only_domains: [example.org]\n")
    page("https://example.com/")
    page("https://www.example.org/", "Org")
    chat("alice", "https://example.com/ https://www.example.org/")
    assert_equal ["PRIVMSG #chan :[example.org] Org"], @conn.lines
  end

  def test_channel_settings_override
    start(%(channel_settings:\n  "#quiet":\n    message_type: notice\n    show_description: true\n))
    @http.route("https://example.com/", html("https://example.com/",
                                             %(<title>T</title><meta name="description" content="About it">)))
    @bot.handle(":Gemdrop!bot@host JOIN #quiet")
    @conn.clear
    chat("alice", "https://example.com/")
    chat("alice", "https://example.com/", channel: "#quiet")
    assert_equal ["PRIVMSG #chan :[example.com] T", "NOTICE #quiet :[example.com] T — About it"], @conn.lines
  end

  def test_bad_settings_stop_loading
    start("sites: [youtube, myspace]\n")
    assert_match(/unknown sites: myspace/, status["error"])

    start(%(channel_settings:\n  "#c":\n    youtube_api_key: x\n))
    assert_match(/can't be set per channel/, status["error"])

    start(%(channel_settings:\n  "#c":\n    max_urls: 50\n))
    assert_match(/max_urls must be at most 10/, status["error"])

    start("formats:\n  tiktok: x\n")
    assert_match(/unknown formats: tiktok/, status["error"])
  end

  # --- YouTube ---------------------------------------------------------------------------------

  def test_recognizes_youtube_url_forms
    start
    %w[
      https://www.youtube.com/watch?v=dQw4w9WgXcQ https://youtu.be/dQw4w9WgXcQ?t=10
      https://m.youtube.com/watch?feature=share&v=dQw4w9WgXcQ https://www.youtube.com/shorts/dQw4w9WgXcQ
      https://www.youtube.com/live/dQw4w9WgXcQ https://music.youtube.com/watch?v=dQw4w9WgXcQ
      https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ
    ].each { |url| assert_equal "dQw4w9WgXcQ", plugin.send(:youtube_id, URI.parse(url)), url }
    %w[https://www.youtube.com/watch?v=short https://youtube.com.evil.example/watch?v=dQw4w9WgXcQ
       https://www.youtube.com/@channel].each { |url| assert_nil plugin.send(:youtube_id, URI.parse(url)), url }
  end

  def test_youtube_via_oembed_without_api_key
    start
    @http.route("https://www.youtube.com/oembed", json("title" => "Me at the zoo", "author_name" => "jawed"))
    assert_equal "[YouTube] Me at the zoo · jawed", preview("https://youtu.be/dQw4w9WgXcQ")
    assert_includes @http.fetched.last, CGI.escape("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
  end

  def test_youtube_via_data_api_with_duration_and_views
    start("youtube_api_key: KEY\n")
    @http.route("https://www.googleapis.com/", json("items" => [{
      "snippet" => { "title" => "Big Talk", "channelTitle" => "Conf", "publishedAt" => "2024-05-01T10:00:00Z" },
      "contentDetails" => { "duration" => "PT1H2M3S" }, "statistics" => { "viewCount" => "1234567" }
    }]))
    assert_equal "[YouTube] Big Talk · Conf · 1:02:03 · 1.2M views", preview("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    assert_includes @http.fetched.last, "key=KEY"
  end

  def test_youtube_live_short_playlist_and_custom_format
    start(%(youtube_api_key: KEY\nformats:\n  youtube: "{title} [{duration}]{ · |date|}"\n))
    live = { "snippet" => { "title" => "Stream", "liveBroadcastContent" => "live", "publishedAt" => "2024-05-01T00:00:00Z" } }
    @http.route("https://www.googleapis.com/", json("items" => [live]))
    assert_equal "Stream [LIVE] · 2024-05-01", preview("https://youtu.be/dQw4w9WgXcQ")

    start
    @http.route("https://www.youtube.com/oembed", json("title" => "Mix", "author_name" => "DJ"))
    assert_equal "[YouTube playlist] Mix · DJ", preview("https://www.youtube.com/playlist?list=PL1234567890abcdef")
  end

  def test_unavailable_youtube_video_and_youtube_pages_give_nothing
    start
    @http.route("https://www.youtube.com/oembed", json({}, status: 404))
    assert_nil preview("https://youtu.be/dQw4w9WgXcQ")
    assert_nil preview("https://www.youtube.com/@somechannel")
    refute(@http.fetched.any? { |url| url.include?("@somechannel") }, "YouTube pages are never scraped")
  end

  # --- other sites --------------------------------------------------------------------------------

  def test_github_repo_issue_pr_and_user
    start("github_token: TOKEN\n")
    @http.route("https://api.github.com/repos/rails/rails/issues/42",
                json("title" => "Fix it", "state" => "closed", "user" => { "login" => "dhh" },
                     "pull_request" => { "merged_at" => "2024-01-01" }))
    @http.route("https://api.github.com/repos/rails/rails",
                json("full_name" => "rails/rails", "description" => "Ruby on Rails", "stargazers_count" => 56_123,
                     "language" => "Ruby"))
    @http.route("https://api.github.com/users/matz", json("login" => "matz", "name" => "Yukihiro Matsumoto",
                                                          "bio" => nil, "public_repos" => 9))

    assert_equal "[GitHub] rails/rails: Ruby on Rails · ★56.1K · Ruby", preview("https://github.com/rails/rails")
    assert_equal "[GitHub] rails/rails PR #42: Fix it · merged · by dhh", preview("https://github.com/rails/rails/pull/42")
    assert_equal "[GitHub] Yukihiro Matsumoto (matz) · 9 repos", preview("https://github.com/matz")
    assert_equal({ "Authorization" => "Bearer TOKEN" }, @http.headers.last)
  end

  def test_wikipedia_vimeo_and_oembed_sites
    start
    @http.route("https://en.wikipedia.org/api/rest_v1/page/summary/Ruby_(programming_language)",
                json("title" => "Ruby (programming language)", "extract" => "Ruby is an interpreted language."))
    @http.route("https://vimeo.com/api/oembed.json", json("title" => "Film", "author_name" => "Maker", "duration" => 125))
    @http.route("https://open.spotify.com/oembed", json("title" => "Song"))
    @http.route("https://soundcloud.com/oembed", json("title" => "Track", "author_name" => "Artist"))

    assert_equal "[Wikipedia] Ruby (programming language): Ruby is an interpreted language.",
                 preview("https://en.m.wikipedia.org/wiki/Ruby_(programming_language)")
    assert_equal "[Vimeo] Film · Maker · 2:05", preview("https://vimeo.com/123456")
    assert_equal "[Spotify] Song", preview("https://open.spotify.com/track/abc")
    assert_equal "[SoundCloud] Track · Artist", preview("https://soundcloud.com/artist/track")
  end

  def test_sites_can_be_turned_off
    start("sites: [youtube]\n")
    page("https://github.com/rails/rails", "GitHub - rails/rails")
    assert_equal "[github.com] GitHub - rails/rails", preview("https://github.com/rails/rails")
  end

  # --- pages and files ----------------------------------------------------------------------------

  def test_page_title_with_entities
    start
    page("https://www.example.com/a", "Tom &amp; Jerry&nbsp;&#8211; &quot;Show&quot;")
    assert_equal "[example.com] Tom & Jerry – \"Show\"", preview("https://www.example.com/a")
  end

  def test_falls_back_to_og_title_uses_meta_charset_and_title_source
    start
    body = %(<meta charset="iso-8859-1"><meta property="og:title" content="Caf\xE9">).b
    @http.route("https://example.com/", html("https://example.com/", body))
    assert_equal "[example.com] Café", preview("https://example.com/")

    start("title_source: og\n")
    @http.route("https://example.com/", html("https://example.com/", %(<title>Tag</title><meta property="og:title" content="OG">)))
    assert_equal "[example.com] OG", preview("https://example.com/")
  end

  def test_strips_irc_control_and_bidi_characters
    start
    page("https://example.com/", "Hi\x03" + "4red\x02 ‮evil")
    assert_equal "[example.com] Hi 4red evil", preview("https://example.com/")
  end

  def test_truncates_long_titles_and_lines
    start("title_length: 50\n")
    page("https://example.com/", "a" * 1000)
    line = preview("https://example.com/")
    assert_equal "[example.com] #{'a' * 49}…", line
  end

  def test_skip_title_in_url
    start("skip_title_in_url: true\n")
    page("https://blog.example.com/great-news-today", "Great News Today")
    assert_nil preview("https://blog.example.com/great-news-today")
  end

  def test_non_html_shows_type_and_size_unless_files_are_off
    start
    file = Response.new(url: "https://cdn.example.com/x.png", status: 200, content_type: "image/png",
                        content_length: 1_234_567, body: nil)
    @http.route("https://cdn", file)
    assert_equal "[cdn.example.com] image/png, 1.2 MB", preview("https://cdn.example.com/x.png")

    start("files: false\n")
    @http.route("https://cdn", file)
    assert_nil preview("https://cdn.example.com/x.png")
  end

  def test_error_pages_and_refused_fetches_give_nothing
    start
    @http.route("https://example.com/", html("https://example.com/", "<title>Nope</title>", status: 404))
    assert_nil preview("https://example.com/")
    assert_nil preview("http://10.0.0.1/")
  end

  # --- commands, history and other plugins ---------------------------------------------------

  def test_title_command
    start
    page
    @bot.handle(":alice!a@a.host PRIVMSG Gemdrop :TITLE https://example.com/")
    @bot.handle(":bob!b@b.host PRIVMSG Gemdrop :PREVIEW nothing here")
    assert_equal ["NOTICE alice :[example.com] Example Domain", "NOTICE bob :Usage: TITLE <url>"], @conn.lines
  end

  def test_links_command_lists_recent_links_with_titles
    start
    page
    chat("alice", "https://example.com/")
    chat("bob", "https://unknown.example/page")
    @bot.handle(":carol!c@c.host JOIN #chan")
    @conn.clear

    @bot.handle(":carol!c@c.host PRIVMSG Gemdrop :LINKS #chan 5")
    notices = @conn.lines.grep(/\ANOTICE carol/)
    assert_match(%r{\ANOTICE carol :\d+s ago, bob: https://unknown.example/page\z}, notices[0])
    assert_match(/alice: https:\/\/example.com\/ — \[example.com\] Example Domain\z/, notices[1])

    @bot.handle(":mallory!m@m.host PRIVMSG Gemdrop :LINKS #secret")
    assert_equal ["NOTICE mallory :You're not on #secret."], @conn.lines.grep(/\ANOTICE mallory/)
  end

  def test_history_is_saved
    start
    page
    chat("alice", "https://example.com/")
    @bot.send(:plugin_manager).unload_all
    saved = JSON.parse(File.read(File.join(@tmpdir, "data/plugins/links.json")))
    assert_equal "https://example.com/", saved.dig("history", "#chan", 0, "url")
  end

  def test_publishes_previews_to_other_plugins
    File.write(File.join(@plugins_dir, "listener.rb"), <<~RUBY, perm: 0o600)
      class Listener < Gemdrop::Plugin
        attr_reader :got
        listen("link") { |payload, _info| (@got ||= []) << payload }
      end
    RUBY
    start
    page
    chat("alice", "https://example.com/")
    got = @bot.send(:plugin_manager).plugin("listener").got
    assert_equal [["https://example.com/", "alice", "#chan", "[example.com] Example Domain"]],
                 got.map { |p| p.values_at("url", "nick", "channel", "preview") }
  end
end

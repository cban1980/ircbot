require "test_helper"

class LinkPreviewTest < Minitest::Test
  Response = IRCBot::SafeHttp::Response

  # Returns canned responses by URL prefix and records what was fetched.
  class FakeHttp
    attr_reader :fetched

    def initialize(responses)
      @responses = responses
      @fetched = []
    end

    def get(url, **)
      @fetched << url
      _prefix, response = @responses.find { |prefix, _| url.start_with?(prefix) }
      raise IRCBot::SafeHttp::Refused, "no route" unless response

      response
    end
  end

  def html(url, body, status: 200)
    Response.new(url: url, status: status, content_type: "text/html", content_length: nil, body: body.b)
  end

  def json(body)
    Response.new(url: "x", status: 200, content_type: "application/json", content_length: nil, body: JSON.generate(body))
  end

  # Routes can be passed as a hash or as trailing "prefix" => response pairs.
  def preview(url, responses = {}, youtube_api_key: nil, **routes)
    @http = FakeHttp.new(responses.merge(routes))
    IRCBot::LinkPreview.new(http: @http, youtube_api_key: youtube_api_key).preview(url)
  end

  # --- URL handling ------------------------------------------------------------

  def test_extracts_urls_and_trims_punctuation
    text = "see https://example.com/a, and (https://en.wikipedia.org/wiki/Ruby_(language)) and http://x.org/b."

    assert_equal ["https://example.com/a", "https://en.wikipedia.org/wiki/Ruby_(language)", "http://x.org/b"],
                 IRCBot::LinkPreview.extract_urls(text, limit: 5)
    assert_equal 1, IRCBot::LinkPreview.extract_urls(text, limit: 1).size
  end

  def test_recognizes_youtube_url_forms
    id = "dQw4w9WgXcQ"
    %W[
      https://www.youtube.com/watch?v=#{id}
      https://youtube.com/watch?feature=share&v=#{id}
      https://m.youtube.com/watch?v=#{id}&t=42
      https://music.youtube.com/watch?v=#{id}
      https://youtu.be/#{id}?si=abc
      https://www.youtube.com/shorts/#{id}
      https://www.youtube.com/live/#{id}
      https://www.youtube-nocookie.com/embed/#{id}
    ].each do |url|
      assert_equal id, IRCBot::LinkPreview.youtube_id(URI.parse(url)), url
    end
  end

  def test_rejects_non_video_youtube_and_lookalike_urls
    %w[
      https://www.youtube.com/
      https://www.youtube.com/watch?v=short
      https://www.youtube.com/@somechannel
      https://youtube.com.evil.test/watch?v=dQw4w9WgXcQ
      https://notyoutube.com/watch?v=dQw4w9WgXcQ
    ].each do |url|
      assert_nil IRCBot::LinkPreview.youtube_id(URI.parse(url)), url
    end
  end

  # --- YouTube -------------------------------------------------------------------

  def test_youtube_via_oembed_without_api_key
    line = preview("https://youtu.be/dQw4w9WgXcQ",
                   "https://www.youtube.com/oembed?" => json("title" => "Never Gonna Give You Up",
                                                             "author_name" => "Rick Astley"))

    assert_equal "[YouTube] Never Gonna Give You Up · Rick Astley", line
    assert_includes @http.fetched.first, "url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3DdQw4w9WgXcQ"
  end

  def test_youtube_via_data_api_with_duration_and_views
    video = {
      "snippet" => { "title" => "Big Talk", "channelTitle" => "Conf", "liveBroadcastContent" => "none" },
      "contentDetails" => { "duration" => "PT1H2M3S" },
      "statistics" => { "viewCount" => "1234567" }
    }
    line = preview("https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                   { "https://www.googleapis.com/youtube/v3/videos?" => json("items" => [video]) },
                   youtube_api_key: "KEY")

    assert_equal "[YouTube] Big Talk · Conf · 1:02:03 · 1.2M views", line
    assert_includes @http.fetched.first, "key=KEY"
  end

  def test_youtube_live_and_short_durations
    live = { "snippet" => { "title" => "Stream", "channelTitle" => "C", "liveBroadcastContent" => "live" },
             "contentDetails" => { "duration" => "P0D" }, "statistics" => { "viewCount" => "999" } }
    short = { "snippet" => { "title" => "Clip", "channelTitle" => "C" },
              "contentDetails" => { "duration" => "PT45S" }, "statistics" => {} }

    assert_equal "[YouTube] Stream · C · LIVE · 999 views",
                 preview("https://youtu.be/dQw4w9WgXcQ", { "https://www.googleapis.com/" => json("items" => [live]) },
                         youtube_api_key: "K")
    assert_equal "[YouTube] Clip · C · 0:45",
                 preview("https://youtu.be/dQw4w9WgXcQ", { "https://www.googleapis.com/" => json("items" => [short]) },
                         youtube_api_key: "K")
  end

  def test_unavailable_youtube_video_gives_nothing
    assert_nil preview("https://youtu.be/dQw4w9WgXcQ",
                       "https://www.youtube.com/oembed?" => Response.new(url: "x", status: 404, content_type: nil,
                                                                         content_length: nil, body: nil))
    assert_nil preview("https://youtu.be/dQw4w9WgXcQ", { "https://www.googleapis.com/" => json("items" => []) },
                       youtube_api_key: "K")
  end

  # --- other pages ---------------------------------------------------------------

  def test_page_title_with_entities
    line = preview("https://www.example.com/a",
                   "https://www.example.com/" => html("https://www.example.com/a",
                                                      "<html><head><title>\n  Tom &amp; Jerry&#39;s &nbsp;Page </title>"))

    assert_equal "[example.com] Tom & Jerry's Page", line
  end

  def test_falls_back_to_og_title_and_uses_meta_charset
    body = "<meta charset=\"iso-8859-1\"><meta property=\"og:title\" content=\"Caf\xE9\">".b
    line = preview("https://example.com/", "https://example.com/" => html("https://example.com/", body))

    assert_equal "[example.com] Café", line
  end

  def test_strips_irc_control_and_bidi_characters
    body = "<title>\x02Bold\x0F \x034,5colour\x03 ‮gnirts‬\r\nPRIVMSG #x :pwned</title>"
    line = preview("https://example.com/", "https://example.com/" => html("https://example.com/", body))

    refute_match(/[\x00-\x1f‪-‮]/, line)
    assert_equal "[example.com] Bold 4,5colour gnirts PRIVMSG #x :pwned", line
  end

  def test_truncates_long_titles
    line = preview("https://example.com/", "https://example.com/" => html("https://example.com/", "<title>#{'a' * 1000}</title>"))

    assert_operator line.length, :<=, 270
    assert line.end_with?("…")
  end

  def test_non_html_shows_type_and_size
    file = Response.new(url: "https://cdn.example.com/x.png", status: 200, content_type: "image/png",
                        content_length: 1_258_291, body: nil)

    assert_equal "[cdn.example.com] image/png, 1.2 MB", preview("https://cdn.example.com/x.png", "https://cdn" => file)
  end

  def test_error_pages_and_refused_fetches_give_nothing
    assert_nil preview("https://example.com/", "https://example.com/" => html("https://example.com/", "<title>Nope</title>", status: 404))
    assert_nil preview("http://10.0.0.1/", {})
  end
end

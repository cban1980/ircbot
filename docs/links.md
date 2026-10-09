# Link previews (the `links` plugin)

When someone posts a link, the bot says what it is:

```
[YouTube] Me at the zoo · jawed
[YouTube] Big Talk · Conf · 1:02:03 · 1.2M views        (with youtube_api_key)
[GitHub] rails/rails: Ruby on Rails · ★56.1K · Ruby
[GitHub] rails/rails PR #42: Fix it · merged · by dhh
[Wikipedia] Ruby (programming language): Ruby is an interpreted, high-level...
[Vimeo] Film · Maker · 2:05
[example.com] Example Domain
[cdn.example.com] image/png, 1.2 MB
```

Link previews are a plugin, [contrib/plugins/links.rb](../contrib/plugins/links.rb),
so they can be configured in detail, changed or left out.

## Installing

```sh
bin/ircbot-docker plugin install contrib/plugins/links.rb
```

New instances made with `ircbot-docker init` get it automatically. To
turn previews off, remove it (`ircbot-docker plugin remove links`) or set
`enabled: false` under `plugins: links:`.

## What it previews

| Links | Shows | Source |
| --- | --- | --- |
| YouTube videos, Shorts, live streams (`youtube.com/watch`, `youtu.be`, `/shorts/`, `/live/`, `/embed/`, music and mobile hosts) | title, channel; with `youtube_api_key` also duration (or LIVE) and views | YouTube oEmbed, or the YouTube Data API v3 |
| YouTube playlists | title, channel | YouTube oEmbed |
| Vimeo videos | title, author, duration | Vimeo oEmbed |
| GitHub repositories | name, description, stars, language | GitHub API |
| GitHub issues and pull requests | number, title, state (open/closed/merged), author | GitHub API |
| GitHub users and organizations | name, login, bio, public repos | GitHub API |
| Wikipedia articles (any language, mobile too) | title and the article's summary | Wikipedia REST API |
| Spotify, SoundCloud, Reddit | title (and author) | their oEmbed endpoints |
| Other web pages | the page title (`<title>` or `og:title`), optionally the description | the page |
| Other files | content type and size | the response headers |

YouTube pages other than videos and playlists (channels, search) are
never scraped, and give no preview. Each site can be turned off with
`sites:`; its links are then treated as ordinary pages.

## Settings

All optional, under `plugins: links:` in `config.yml`. A wrong value
stops the plugin from loading, with the reason in `ircbot-docker plugin
list`.

```yaml
plugins:
  links:
    message_type: notice
    ignore_nicks: [OtherBot]
    youtube_api_key: "..."        # then: chmod 600 config.yml
    channel_settings:
      "#busy":
        per_channel_per_minute: 2
```

### Where and from whom

| Setting | Default | Meaning |
| --- | --- | --- |
| `only_channels` | `[]` | Preview only in these channels (empty: all) |
| `ignore_channels` | `[]` | Never preview in these channels |
| `ignore_nicks` | `[]` | Never preview links from these nicks, e.g. other bots |
| `ignore_masks` | `[]` | Never preview links from users matching these `nick!user@host` masks (`*` and `?` allowed) |
| `only_domains` | `[]` | Preview only links to these domains and their subdomains (empty: all) |
| `ignore_domains` | `[]` | Never preview links to these domains and their subdomains |
| `ignore_prefixes` | `[]` | Skip messages starting with one of these, e.g. `["!"]` for other bots' commands |
| `skip_word` | `"nopreview"` | Skip messages containing this word; `""` turns it off |
| `actions` | `true` | Also preview links in `/me` actions |
| `private_messages` | `false` | Also preview links sent to the bot by private message (answered privately) |

### What to show

| Setting | Default | Meaning |
| --- | --- | --- |
| `sites` | all | Sites with their own previews: `youtube vimeo github wikipedia spotify soundcloud reddit` |
| `pages` | `true` | Preview ordinary web pages |
| `files` | `true` | Preview other files (type and size) |
| `title_source` | `title` | `title`: the page's `<title>`, falling back to `og:title`; `og`: the other way round |
| `show_description` | `false` | Add the page's description (`og:description` or `<meta name="description">`) |
| `skip_title_in_url` | `false` | No preview when every word of the title is already in the URL (e.g. blog slugs) |
| `bold` | `false` | Show titles in bold |
| `title_length` | `200` | Longest title, in characters (20-400) |
| `description_length` | `150` | Longest description, Wikipedia summary or GitHub bio (20-400) |
| `max_length` | `350` | Longest preview line (40-400) |
| `message_type` | `privmsg` | `privmsg`: a normal message; `notice`: a notice, which other bots by convention never answer |
| `formats` | built-in | Your own line formats, see below |

### Limits

| Setting | Default | Meaning |
| --- | --- | --- |
| `max_urls` | `3` | Links looked at per message (1-10) |
| `per_channel_per_minute` | `6` | Previews per channel per minute |
| `per_user_per_minute` | `3` | Previews per user (host) per minute |
| `repeat_minutes` | `10` | The same link isn't previewed again in a channel for this long (0: always) |
| `cache_minutes` | `30` | Fetched previews are reused for this long (0: no cache); at most 500 links |
| `history_size` | `25` | Links remembered per channel for `LINKS` (0: none) |

### Keys

| Setting | Meaning |
| --- | --- |
| `youtube_api_key` | A YouTube Data API v3 key: adds duration, LIVE and view counts. The `IRCBOT_YOUTUBE_API_KEY` environment variable works too |
| `github_token` | A GitHub token: raises GitHub's limit of 60 lookups per hour. It is only ever sent to api.github.com |

A key in `config.yml` means the file must be private (`chmod 600`); the
bot refuses to start otherwise.

### Per channel

`channel_settings` overrides any of the settings above for one channel,
except `channel_settings`, the keys, `cache_minutes` and `history_size`:

```yaml
plugins:
  links:
    channel_settings:
      "#linux.se":
        show_description: true
        bold: true
      "#gunnit":
        message_type: notice
        sites: [youtube]
```

With several networks, `network_settings` (see the
[plugin docs](plugins.md#settings-and-configuration)) does the same per
network, and `networks:` limits the plugin to some networks.

### Formats

Each kind of preview has a format. `{field}` is replaced by the field;
`{before|field|after}` adds the text around the field only when it has a
value. Override any of them under `formats:`:

```yaml
plugins:
  links:
    formats:
      page: "↳ {title}{ (|site|)}"
      youtube: "▶ {title}{ by |channel|}{ [|duration|]}{ · |views| views}{ · |date|}"
```

| Format | Default | Fields |
| --- | --- | --- |
| `page` | `[{site}] {title}{ — \|description\|}` | `site title description site_name` |
| `file` | `[{site}] {type}{, \|size\|}` | `site type size` |
| `youtube` | `[YouTube] {title}{ · \|channel\|}{ · \|duration\|}{ · \|views\| views}` | `title channel`; with an API key also `duration views likes date` |
| `youtube_playlist` | `[YouTube playlist] {title}{ · \|channel\|}` | `title channel` |
| `vimeo` | `[Vimeo] {title}{ · \|author\|}{ · \|duration\|}` | `title author duration` |
| `github_repo` | `[GitHub] {name}{: \|description\|}{ · ★\|stars\|}{ · \|language\|}` | `name description stars language forks` |
| `github_issue` | `[GitHub] {repo}{ \|kind\| }#{number}: {title}{ · \|state\|}{ · by \|author\|}` | `repo kind (issue/PR) number title state author` |
| `github_user` | `[GitHub] {name}{ (\|login\|)}{ · \|bio\|}{ · \|repos\| repos}` | `name login bio repos` |
| `wikipedia` | `[Wikipedia] {title}{: \|extract\|}` | `title description extract` |
| `spotify`, `soundcloud`, `reddit` | `[Spotify] {title}{ · \|author\|}` (and so on) | `title author` |

All text from other sites has IRC formatting, control characters and
Unicode direction overrides removed, and is cut to the length limits,
before it is sent.

## Commands

| Command | |
| --- | --- |
| `TITLE <url>` (or `PREVIEW`) | Previews a link on request, also links the automatic previews skip. Once per 5 seconds per user |
| `LINKS [count]` in a channel, `LINKS #chan [count]` by private message | The last links posted in the channel (default 5, at most 10), with their previews, sent to you as notices. Only for users on the channel |

Like all plugin commands, these work by private message (`/msg ModeBot
TITLE ...`); set `prefix: "!"` to also use `!title` and `!links` in
channels.

## For other plugins

Every preview is published as the `link` topic, so other plugins can use
them:

```ruby
listen "link" do |payload, _info|
  # payload: { "url", "nick", "channel", "network", "preview" }
end
```

## Privacy and safety

Fetching a link shows the bot's IP address to that site (and to YouTube,
GitHub or Wikipedia for their links). The fetches go through the bot's
guarded HTTP client: only http and https on standard ports, only public
IPv4 addresses (never localhost or private networks, checked again at
every redirect), at most 3 redirects, 256 KB and 10 seconds. See
[Fetching user-posted links](../README.md#fetching-user-posted-links).

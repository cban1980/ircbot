# ircbot

A Ruby IRC bot for IRCnet that handles user registration and channel
access (op/voice). It uses only the Ruby standard library; minitest and
rake are needed for tests.

## Running

```sh
cp config.example.yml config.yml   # set server, nick, admins, channels
bin/ircbot                         # or: bin/ircbot path/to/config.yml
IRCBOT_LOG_LEVEL=debug bin/ircbot  # log raw traffic (passwords are redacted)
```

The bot's identity is set in `config.yml`: `nick` plus fallback
`alt_nicks`, `user` (ident), `realname` and `umodes` (its own user
modes, `+i` by default). If its nick is taken it uses an alternative and
retries the primary nick on every server PING and whenever the holder
quits or changes nick.

IRCnet has no services, so nobody can register channels or op the bot
for you. Op the bot by hand in each channel; it keeps auto-opping
registered users from there. If the bot loses op (netsplit, kick), an op
has to give it back.

**First start:** the names in `admins` are bot accounts. Connect with that
nick over TLS and `/msg ModeBot REGISTER <password>` straight away so
nobody else claims it.

## Commands

All commands are sent by private message (`/msg ModeBot ...`); replies are notices.

| Command | Who |
| --- | --- |
| `REGISTER <password>` | anyone on TLS; registers the current nick |
| `IDENTIFY [account] <password>`, `PASSWORD <old> <new>` | anyone on TLS |
| `LOGOUT`, `WHOAMI` | anyone |
| `CHANREGISTER <#chan> <owner>` | bot admins |
| `CHANDROP <#chan>` | channel owner |
| `ACCESS <#chan> LIST` / `ADD <account> <voice\|op>` / `DEL <account>` | op and above |
| `ACCESS <#chan> ADDMASK <nick!user@host> <voice\|op>` / `DELMASK <mask>` | bot admins |

**Masks** give voice/op on join to anyone matching `nick!user@host`,
without identifying. Nick and user may use `*`/`?`; the host must be an
exact hostname or IP (e.g. `*!*user@host.example.net`), so a mask can't
cover a whole network. Anyone else connecting from that host and matching
the mask gets the mode too.
| `UP <#chan>` / `DOWN <#chan>` | voice and above |
| `OP`, `DEOP`, `VOICE`, `DEVOICE <#chan> [nick]` | op and above |

Levels rank `voice < op < owner`. Users can only grant levels below their
own and cannot change or deop users of equal or higher rank. Bot admins
count as owner on every registered channel. Identified users get their
mode automatically when they join, or when they identify while already in
the channel.

## Running in Docker

`bin/ircbot-docker` builds a Debian trixie image (Ruby 3.3, no gems) and
runs the bot in a hardened container. All settings and state live in one
host folder, `instance/` by default (`IRCBOT_DIR=/path` to change),
mounted at `/bot` and editable on the host:

```sh
bin/ircbot-docker init                        # create instance/ (copies existing config/data/secret)
bin/ircbot-docker edit                        # edit config.yml; checks it and reloads the bot
bin/ircbot-docker account register <nick>     # password prompt, hidden
bin/ircbot-docker start                       # --debug, --foreground, --rebuild, ...
bin/ircbot-docker status                      # container, health, server, nick, channels
bin/ircbot-docker logs -f
bin/ircbot-docker reload                      # apply config.yml/data changes live
bin/ircbot-docker reconnect                   # new IRC connection
bin/ircbot-docker channel register '#chan' <owner>   # the bot joins right away
bin/ircbot-docker restart                     # checks the config first
bin/ircbot-docker update                      # rebuild on a fresh base image, restart
bin/ircbot-docker test                        # run the test suite on trixie
bin/ircbot-docker --help                      # everything else
```

**Live reload** (`reload`, `edit`, `channel register|drop`): the bot
re-reads `config.yml` on SIGHUP. Admins, channels (joined/parted),
nick, user modes, link previews and limits apply immediately; changes to
server, TLS, network, user or realname make it reconnect. An invalid
config is refused and the bot keeps running with the old one (the script
also checks before sending). `data_file`, `pepper_file` and
`status_file` need a `restart`. Account changes never need a reload.

**Moving to another server:** `bin/ircbot-docker backup` writes one
archive with `config.yml`, `data/` and `secret/` (keep it private: it
holds the pepper and password hashes). On the new server, with this repo
and Docker installed: `bin/ircbot-docker restore FILE && bin/ircbot-docker
start`. IRCnet admits clients by IP, so check that its server accepts the
new machine.

The container runs as your user (files stay yours), with a read-only
filesystem, no capabilities, `no-new-privileges`, memory and process
limits, log rotation, a health check (connected, with server activity in
the last 10 minutes) and `--restart unless-stopped`. Config, data and
secrets are excluded from the image (`.dockerignore`).

## Link previews

When someone posts a link in a channel, the bot replies in the channel:

```
[YouTube] Me at the zoo · jawed
[YouTube] Big Talk · Conf · 1:02:03 · 1.2M views     (with youtube_api_key)
[example.com] Example Domain
[ruby-lang.org] image/png, 5.2 KB
```

- **YouTube** (`youtube.com/watch`, `youtu.be`, `/shorts/`, `/live/`,
  `/embed/`, music and mobile hosts) uses YouTube's oEmbed endpoint, or
  the Data API v3 when `youtube_api_key` is set, which adds duration (or
  LIVE) and view count. YouTube pages themselves are never scraped.
- **Web pages** show their `<title>` (or `og:title`); **other files** show
  the content type and size from the response headers.
- At most 3 links per message, 6 previews per channel and 3 per host per
  minute, and the same link isn't repeated in a channel within 10
  minutes. Fetches run on 2 background threads, so a slow site never
  stalls the bot.
- Previews are normal channel messages. Set `message_type: notice` to
  send notices instead, which other bots by convention never answer; with
  messages, put other link bots in `ignore_nicks` so two bots can't keep
  previewing each other.
- Configure under `link_preview:` (`enabled`, `message_type`, `channels`,
  `ignore_nicks`, `youtube_api_key`).

## Security

### Transport

- **Bot to server:** TLS only, verified against the system CA store with
  hostname checking, TLS 1.2 minimum (`tls_min_version: "1.3"` to raise it).
  The negotiated version and cipher are logged on connect.
- **Key pinning:** `tls_fingerprint` pins the server's public key. Use it
  when the server has a self-signed certificate, or to detect a
  certificate swap even by a trusted CA.
- **Self-signed certificates** (common on IRCnet): with
  `tls_self_signed: true` the server is trusted on first use, like SSH.
  OpenSSL still verifies as usual; if that fails, the server's key is
  recorded in `data/known_servers` the first time (logged as a warning)
  and must match on every later connection. A changed key is refused as a
  possible man-in-the-middle; delete the server's line to accept a
  legitimate new key.
- The bot **refuses to start** with plaintext or unverified, unpinned TLS
  unless `allow_insecure: true` is set.
- **Users to server:** with `require_secure_users` (default), `REGISTER`,
  `IDENTIFY` and `PASSWORD` are only processed once a `WHOIS nick nick`
  (answered by the user's own server) confirms their connection uses TLS.
  The WHOIS user@host must also match the sender. IRCnet reports this as
  numeric 320 "is a Secure Connection (SSL/TLS)" from ircd 2.11.3 on;
  671 is accepted for other networks. If a user's server doesn't report
  TLS, they can't use password commands.

### Passwords

- Never stored or logged in readable form: HMAC'd with a secret
  **pepper**, then hashed with **scrypt** (64 MiB, ~150 ms per attempt)
  and a random salt.
- The pepper lives in `secret/pepper.key` (created on first start, mode
  0600) or `IRCBOT_PEPPER`, never in the data file. A stolen
  `data/ircbot.json` alone cannot be cracked offline. **Back the pepper up
  separately: without it no one can log in.** The bot refuses to start if
  the pepper file is accessible by others or doesn't match the data file.
- **Brute force:** wrong passwords (`IDENTIFY`, or the old password in
  `PASSWORD`) are limited to 5 per account+host, 10 per host and 25 per
  account in 15 minutes. Registrations are limited to 3 per host per hour.
- Raising the scrypt cost later upgrades each hash on the user's next login.
- If someone types a password command into a channel by mistake, the bot
  ignores it and privately tells them to change that password.
- Passwords need 8+ characters and must not contain the account name.

### Fetching user-posted links

The URLs are attacker-controlled, so the fetcher (`SafeHttp`) is strict:

- Only `http`/`https` on ports 80/443; no `user:pass@` URLs.
- **IPv4 only:** IPv6 DNS results are ignored and IPv6 literal URLs are
  refused; IPv6-only sites get no preview.
- **No internal targets:** every IPv4 address a host resolves to must be
  public. Loopback, private, link-local (including cloud metadata
  169.254.169.254), CGNAT, multicast and reserved ranges are refused. The
  connection is pinned to the vetted IP, so DNS rebinding can't redirect it.
- Redirects (max 3) are re-checked at every hop.
- Proxy environment variables are ignored; compressed responses are
  refused (no decompression bombs).
- 5 s per network operation, 10 s overall, at most 256 KB read. Bodies are
  only read for HTML/JSON; for anything else just the headers.
- TLS 1.2+ with certificate verification for HTTPS links.
- Remote text is stripped of IRC formatting/control codes, line breaks and
  Unicode direction overrides, and truncated, before it reaches IRC.

Fetching a link reveals the bot's IP address to that site (and to
YouTube/Google for videos).

### What it can't control

IRC has no masked input, and a private message is relayed in readable
form by every server it passes through. TLS protects each hop, not the
servers themselves. Treat IRCnet server operators as able to see it.

## Notes

- A login is bound to nick + user@host and ends on QUIT, so another client
  taking the nick does not inherit it.
- Data lives in `data/ircbot.json` (written atomically, mode 0600, in a
  0700 directory). Rate-limit counters are in memory and reset on restart.
- Only `#` and `&` channels can be registered; IRCnet `!` channels and
  modeless `+` channels are not supported.

## Tests

```sh
rake test
```

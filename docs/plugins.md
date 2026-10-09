# Writing plugins

Plugins add features to the bot without changing its core: commands,
reactions to IRC events, channel moderation, logging, relays between
networks, web lookups and more. Each plugin is one Ruby file in the
instance's `plugins/` folder (`instance/plugins/` with Docker). The bot
loads, reloads and unloads plugins while it stays connected.

This page is the complete API reference. The [README](../README.md#plugins)
covers installing and configuring plugins, and
[contrib/plugins/](../contrib/plugins/) has working examples:

| Example | Shows |
| --- | --- |
| [dice.rb](../contrib/plugins/dice.rb) | commands, settings |
| [ops.rb](../contrib/plugins/ops.rb) | command levels and aliases, kick/ban/topic |
| [chanlog.rb](../contrib/plugins/chanlog.rb) | logging every event and the bot's own lines to files |
| [relay.rb](../contrib/plugins/relay.rb) | relaying chat between channels on different networks |
| [links.rb](../contrib/plugins/links.rb) | link previews: background HTTP, caching, per-channel settings, publishing ([its docs](links.md)) |

## Contents

- [A first plugin](#a-first-plugin)
- [How plugins run](#how-plugins-run)
- [Declarations](#declarations): description, settings, commands, events, CTCP, listeners
- [Commands](#commands)
- [Events](#events)
- [Sending to IRC](#sending-to-irc)
- [Channel state](#channel-state)
- [Accounts and access](#accounts-and-access)
- [The network and the server](#the-network-and-the-server)
- [Other networks](#other-networks)
- [Settings and configuration](#settings-and-configuration)
- [Storage](#storage)
- [Timers and background work](#timers-and-background-work)
- [HTTP](#http)
- [Plugins working together](#plugins-working-together)
- [Logging and errors](#logging-and-errors)
- [CTCP](#ctcp)
- [Security](#security)
- [Reference: types](#reference-types)

## A first plugin

`plugins/hello.rb`:

```ruby
class Hello < IRCBot::Plugin
  description "Greets people"
  setting "greeting", default: "Hello", type: :string

  command "HELLO", usage: "HELLO [name]", help: "say hello" do |ctx, args|
    ctx.reply("#{settings['greeting']}, #{args.first || ctx.nick}!")
  end

  on :join do |event|
    next if event.nick == bot_nick
    next unless rate_limit("greet:#{event.channel}", limit: 3, per: 60)

    notice(event.nick, "#{settings['greeting']}, welcome to #{event.channel}!")
  end
end
```

Install it and try it:

```sh
bin/ircbot-docker plugin install hello.rb   # or copy it into instance/plugins/ and reload
/msg ModeBot HELLO
```

To also accept `!hello` in channels, set a prefix in `config.yml` and reload:

```yaml
plugins:
  hello:
    prefix: "!"
    greeting: "Hi"
```

## How plugins run

- **One class per file**, at the top level, inheriting from
  `IRCBot::Plugin`. The file name (lowercase letters, digits, `_`) is the
  plugin's name, used in `config.yml`, `PLUGIN` commands and logs.
- **Loading** evaluates the file in a fresh module, so a reload replaces
  the old code completely. If a changed file fails to load, the old
  version keeps running and the error shows in `plugin list` and
  `PLUGIN LIST`.
- **One instance per network.** With several networks, each network runs
  its own instance of every plugin with its own state. Use
  [`primary?`](#the-network-and-the-server) for work that should happen
  once, [`shared`](#plugins-working-together) for state common to all
  instances, and [`on_network`](#other-networks) to act on another network.
- **One thing at a time.** Commands, event hooks, timers and listeners run
  one at a time with the rest of that network's IRC handling, with the
  plugin as `self`. While a hook runs, nothing else on that network
  happens, so hooks must be quick. Anything that waits (HTTP, files that
  may be slow, sleeping) belongs in [`background`](#timers-and-background-work).
- **Lifecycle.** `setup` runs after loading, `teardown` before unloading
  (also on reload and shutdown). Timers stop and channels the plugin joined
  are left when it is unloaded.
- **Failures are contained.** An exception in a hook, timer, listener or
  background job is logged and the bot goes on. In a command, an
  `IRCBot::Error` sends its message to the user; any other exception is
  logged and the user is told the command failed.
- **Only the standard library** is available; the Docker image has no
  gems.

## Declarations

Class-level methods, written in the class body.

| Declaration | Purpose |
| --- | --- |
| `description "text"` | Shown in `PLUGIN LIST` and `plugin list` |
| `setting "name", default:, type:, values:, min:, max:, desc:` | A checked setting ([Settings](#settings-and-configuration)) |
| `defaults "name" => value, ...` | Plain default settings, without checks |
| `command "NAME", ...  { \|ctx, args\| }` | A command ([Commands](#commands)) |
| `on :event { \|event\| }` | An event hook ([Events](#events)); several per event are fine |
| `ctcp_handler "NAME" { \|event\| "reply" }` | Answers a CTCP request ([CTCP](#ctcp)) |
| `listen "topic" { \|payload, info\| }` | Receives messages from other plugins ([Plugins working together](#plugins-working-together)) |

Instance methods `setup` and `teardown` can be overridden. Any other
methods you define are your own helpers.

## Commands

```ruby
command "KICK", usage: "KICK [#chan] <nick> [reason]", help: "kick someone",
                aliases: %w[K], level: "op", where: :any, cooldown: 5 do |ctx, args|
  ...
end
```

| Option | Default | Meaning |
| --- | --- | --- |
| `usage:` | the name | Shown by `ctx.usage!` and `HELP` |
| `help:` | none | One-line description for `HELP` |
| `aliases:` | `[]` | Other names for the same command |
| `admin:` | `false` | Only bot admins (implies `identified:`) |
| `identified:` | `false` | Only users identified to a bot account |
| `level:` | none | `"voice"`, `"op"` or `"owner"`: access needed on the channel (implies `identified:`). In a channel it's that channel; by private message the first argument must be the channel, and it is taken off `args` |
| `where:` | `:any` | `:channel` or `:private` to allow only one of them |
| `cooldown:` | none | Seconds before the same host may use the command again |

Command names are 1 to 32 characters, `A-Z`, digits, `_` and `-`. Names of
built-in commands (`HELP`, `REGISTER`, `OP`, `PLUGIN`, ...) and of other
loaded plugins' commands are refused at load time.

Where commands work is set per plugin in `config.yml`. By default they
work by private message (`/msg ModeBot ROLL`). A `prefix` such as `"!"`
also enables them in channels (`!roll`), `private: false` turns off the
private form, and `channels:` limits the channel form to some channels.

### The command context (`ctx`)

| Method | Returns |
| --- | --- |
| `ctx.nick`, `ctx.userhost` | Who sent it |
| `ctx.channel` | The channel it was said in, or nil by private message |
| `ctx.channel?` | True in a channel |
| `ctx.target_channel` | The channel the command acts on: `ctx.channel`, or for `level:` commands by private message the channel argument |
| `ctx.args`, `ctx.text` | The arguments, as a list and as one string |
| `ctx.command` | The `Plugin::Command` (name, usage, aliases, ...) |
| `ctx.network` | The network name |
| `ctx.account` | The user's bot account, or nil if not identified |
| `ctx.admin?` | True for bot admins |
| `ctx.access_level(channel = target_channel)` | `"voice"`, `"op"`, `"owner"` or nil |
| `ctx.reply(text)` | Answers in the channel, or by notice for a private message |
| `ctx.reply_privately(text)` | Answers by notice |
| `ctx.reply_action(text)` | `/me` in the channel or to the user |
| `ctx.usage!` | Stops with "Usage: ..." sent to the user |

Stop a command with a message to the user with
`raise IRCBot::Error, "text"`. Plugin commands share the bot's command
rate limits, so a user can't flood through them.

## Events

```ruby
on :message do |event|
  say(event.channel, "Hi #{event.nick}") if event.text.match?(/\Ahello\b/i)
end
```

Hooks run after the bot itself has handled the line, so channel state is
already updated (on `:join` the new user is in `users(channel)`; on
`:quit` they are gone).

| Event | When | Fields set |
| --- | --- | --- |
| `:connected` | Registered with the server (001) | `message` |
| `:disconnected` | The connection ended | (none) |
| `:message` | Text in a channel (not actions or CTCP) | `nick userhost channel text` |
| `:action` | `/me`, in a channel or to the bot | `nick userhost channel target text` |
| `:private_message` | Text sent to the bot, commands included | `nick userhost target text` |
| `:notice` | A notice in a channel or to the bot | `nick userhost channel target text` |
| `:ctcp` | A CTCP request, after it was answered | `nick userhost channel target ctcp text` |
| `:ctcp_reply` | A CTCP answer sent to the bot | `nick userhost target ctcp text` |
| `:join` | Someone (or the bot) joined | `nick userhost channel` |
| `:part` | Someone (or the bot) left | `nick userhost channel text` (reason) |
| `:kick` | Someone was kicked | `nick` (kicked), `channel text`; `message.nick` kicked them |
| `:quit` | Someone quit | `nick userhost text` |
| `:nick` | Someone changed nick | `nick userhost new_nick` |
| `:mode` | Channel modes changed | `nick userhost channel modes` (list of `ModeChange`) |
| `:topic` | The topic changed | `nick userhost channel text` |
| `:invite` | Someone invited the bot | `nick userhost target channel` |
| `:identified` | A user identified or registered | `nick userhost account` |
| `:logout` | A user logged out | `nick userhost account` |
| `:outgoing` | The bot sent a line | `text` (the line), `message` |
| `:line` | Any line was received | `message` |

Every event also has `type`, `network` and `message` (the parsed line,
see [types](#reference-types)), plus `event.channel?` and `event.prefix`
(`nick!user@host`).

- Text carrying a password command (`REGISTER`, `IDENTIFY`, `PASSWORD`) is
  never shown to plugins, in any event.
- Server notices have no `nick`.
- In `:outgoing` hooks, lines you send are not reported again, so a hook
  can't loop. A bot-side line that would carry a password is redacted.
- `:line` is for numerics and anything else not covered:
  `on(:line) { |e| handle_whois(e.message) if e.message.command == "311" }`.

## Sending to IRC

All of these check their arguments: targets must be single words, and
text is cut to one line of at most 400 bytes with line breaks removed. So
text from users can't inject protocol lines. They return `true` when sent
and `false` when not (disconnected, or the plugin was unloaded). Invalid
arguments raise `ArgumentError`.

| Method | Sends |
| --- | --- |
| `say(target, text)` | `PRIVMSG`; text is split on line breaks, at most 10 lines |
| `notice(target, text)` | `NOTICE`, the same way |
| `action(target, text)` | `/me` |
| `ctcp(target, command, text = nil)` | A CTCP request, e.g. `ctcp("alice", "VERSION")` |
| `ctcp_reply(nick, command, text = nil)` | A CTCP answer (notice) |
| `join(channel, key = nil)` | Joins, and rejoins after reconnects and config reloads until `part` or unload |
| `part(channel, reason = nil)` | Leaves a channel this plugin joined. Configured and registered channels raise `ArgumentError` |
| `mode(channel, modes, *params)` | `mode("#c", "+nt")`, `mode("#c", "+l", 50)` |
| `op / deop / voice / devoice(channel, *nicks)` | Status modes for any number of nicks, batched to the server's `MODES` limit |
| `ban / unban(channel, *masks)` | Ban list changes, batched the same way |
| `kick(channel, nick, reason = nil)` | |
| `kickban(channel, nick, reason = nil)` | Bans `ban_mask(nick)`, then kicks. Raises `IRCBot::Error` if the nick's host is unknown |
| `ban_mask(nick)` | `"*!*user@host"` for a nick sharing a channel with the bot (a leading `~` is dropped), or nil |
| `set_topic(channel, text)` | |
| `invite(nick, channel)` | |
| `raw(line)` | Any other single line, e.g. `raw("WHOIS alice")` |

`raw` refuses `PASS USER NICK QUIT OPER SERVICE SQUIT KILL DIE RESTART CAP
AUTHENTICATE`: the bot manages its connection and nick itself. The server
also throttles everything the bot sends, so a burst is queued, not
dropped.

The bot only has the powers it has on IRC: moderation needs it to be a
channel operator (`op?(channel)`). On IRCnet nobody can op it except by
hand.

## Channel state

Updated from what the server sends (NAMES, JOIN, PART, KICK, QUIT, NICK,
MODE, TOPIC and the replies the bot asks for when it joins).

| Method | Returns |
| --- | --- |
| `bot_nick` | The bot's current nick |
| `channels` | Channels the bot is in |
| `in_channel?(channel)` | |
| `users(channel)` | `Roster::Member`s: `nick`, `userhost` (or nil), `modes`, `op?`, `voice?`, `halfop?` |
| `user(channel, nick)` | One `Member`, or nil if not on the channel |
| `op?(channel, nick = bot_nick)`, `voice?(...)` | Status in the channel (by default the bot's own) |
| `topic(channel)` | `Roster::Topic` (`text`, `by`, `at` as Unix time), or nil |
| `channel_modes(channel)` | `{ "n" => true, "t" => true, "k" => "key", "l" => "50" }` |
| `userhost_of(nick)` | `user@host` of a nick in any of the bot's channels, or nil |

A `userhost` is known for users who joined while the bot was there or
have sent anything since; for others it is nil until they do.

## Accounts and access

Accounts are the bot's own (`REGISTER`/`IDENTIFY`), shared by all
networks; logins and channel access are per network.

| Method | Returns |
| --- | --- |
| `account_for(nick, userhost = nil)` | The account the nick is identified as, or nil. With `userhost` the login must be from that `user@host` (safer; `ctx.account` does this) |
| `admin?(account)` | True for bot admins |
| `admins` | The admin account names |
| `access_level(channel, account)` | `"voice"`, `"op"`, `"owner"` or nil. Admins are owner everywhere |
| `account_name(name)` | The account name as registered, or nil |
| `account_exists?(name)` | |
| `identified_users` | `{ nick => account }` on this network |
| `registered_channels` | Channels registered on this network |
| `channel_registered?(channel)` | |
| `channel_access(channel)` | `[[account, level], ...]`, the owner first |
| `channel_owner(channel)` | The owner's account, or nil |

Rank levels with `IRCBot::Channels.rank(level)` (voice 1, op 2, owner 3,
nil 0).

## The network and the server

| Method | Returns |
| --- | --- |
| `network` | This network's name from `config.yml` (`"IRCnet"`; `"default"` for a single-server config without `network:`) |
| `network_name` | The name the server reports (`ISUPPORT NETWORK`), or nil |
| `networks` | All networks the bot is on, in config order |
| `primary?` | True on the first network only. Use it for things that must happen once per bot, such as starting a web listener |
| `connected?` | True while registered with the server |
| `server` | The server's host name from the config |
| `isupport` | The server's ISUPPORT tokens: `{ "PREFIX" => "(ov)@+", "CHANMODES" => "beI,k,l,imnpst", "MONITOR" => "100", ... }` (true for tokens without a value) |
| `bot_config` | The bot's settings for this network, without secrets or file paths: `nick alt_nicks user realname umodes server port tls network channels admins ctcp id` |

## Other networks

`on_network(name)` returns a `Plugin::Remote` for another network the bot
is on (nil if there is none). It has the [sending methods](#sending-to-irc)
except `kickban` and `ban_mask`, plus `network`, `connected?`, `nick` and
`channels`.

```ruby
on :message do |event|
  next unless network == "IRCnet" && event.channel == "#linux.se"

  on_network("EFnet")&.say("#gunnit", "<#{event.nick}> #{event.text}")
end
```

Actions on another network are queued and run on that network's own turn,
in order, right after. They return true once queued (false while that
network is disconnected), and problems there are logged rather than
raised. Joins and parts made this way belong to your plugin on that
network, as if that network's instance had made them.

See [relay.rb](../contrib/plugins/relay.rb) for a complete relay.

## Settings and configuration

A plugin's settings come from its section in `config.yml`, on top of its
defaults:

```yaml
plugins:
  hello:
    prefix: "!"          # the bot's options for every plugin, see below
    greeting: "Hi"       # the plugin's own settings
```

`settings` is a hash of the plugin's own settings (string keys). Changing
a plugin's section and reloading reloads the plugin.

Declare settings with `setting` to get defaults and checks. A value that
fails a check stops the plugin from loading; the message (e.g. `setting
count must be at most 10 (got 50)`) shows in `plugin list`.

```ruby
setting "count", default: 3, type: :integer, min: 1, max: 10
setting "mode", default: "fast", values: %w[fast slow]
setting "home", type: :channel                      # optional: no default
```

| Type | Accepts |
| --- | --- |
| `:string` | Text |
| `:integer` | Whole numbers |
| `:number` | Any number |
| `:boolean` | `true` / `false` |
| `:list` | A YAML list |
| `:hash` | A YAML mapping |
| `:channel` | A valid channel name |
| `:nick` | A valid nick |

`min`/`max` limit numbers, or the length of text and lists. `values`
lists the allowed values.

The bot's own options for every plugin (not passed to the plugin):

| Option | Default | Meaning |
| --- | --- | --- |
| `enabled` | `true` | `false` to not load it |
| `private` | `true` | Commands by private message |
| `prefix` | none | E.g. `"!"` (quoted): commands in channels too |
| `channels` | all | Limit channel commands to these channels |
| `networks` | all | Load only on these networks |
| `network_settings` | none | Per-network overrides of any of the above or of the plugin's settings |

```yaml
plugins:
  ops:
    prefix: "!"
    networks: [IRCnet, EFnet]
    network_settings:
      EFnet:
        prefix: "@"
        default_reason: "Bye"
```

Don't use the names above for your own settings. To read the bot's
configuration, use [`bot_config`](#the-network-and-the-server).

## Storage

| Method | Purpose |
| --- | --- |
| `data` | The plugin's JSON file: `data/plugins/<name>.json`, or `data/plugins/<network>/<name>.json` with several networks |
| `data["key"]`, `data["key"] = value`, `data.delete("key")` | Read, write, delete; values must be JSON (hashes, lists, strings, numbers, true/false/nil) |
| `data.to_h` | A copy of everything |
| `data.update { \|hash\| ... }` | Several changes in one atomic write |
| `data_dir` | A private folder for the plugin's own files (logs, caches): `data/plugins/[<network>/]<name>/` |

Reads return copies, so change data through `[]=`/`update`. Writes are
atomic (a crash never leaves a half-written file) but not free; for data
that changes on every line, keep it in memory and save it on a timer and
in `teardown`.

## Timers and background work

| Method | Purpose |
| --- | --- |
| `every(seconds) { ... }` | Repeats (at least 1 second apart); returns the timer |
| `after(seconds) { ... }` | Runs once |
| `cancel(timer)` | Stops a timer early |
| `background { ... }` | Runs on a worker thread; returns false if the queue (50 jobs) is full |
| `rate_limit(key, limit:, per:)` | Counts one use of `key`; false once it was used `limit` times in `per` seconds |

Timer blocks run like hooks: one at a time with the IRC handling. All
timers stop when the plugin is unloaded (at most 20 per plugin).

`background` blocks run outside the IRC handling, two at a time, so they
can wait. Everything in the API is safe to call from them; send results
with `say`/`notice` as usual. Long-lived threads of your own (a server
socket) should be started in `setup`, only on `primary?` if they must be
unique, and stopped in `teardown`.

## HTTP

Inside `background` only (they wait for the network):

| Method | Returns |
| --- | --- |
| `http_get(url, accept: "*/*", types: /text|json|xml/)` | `SafeHttp::Response`: `url` (after redirects), `status`, `content_type`, `content_length`, `body` (read only for matching `types`) |
| `http_json(url)` | Parsed JSON; raises `IRCBot::Error` unless the answer is a 200 with JSON |

Requests go through the bot's guarded client: only http
and https on standard ports, only public IPv4 addresses (no localhost or
private networks, checked again at every redirect), at most 3 redirects,
256 KiB and 10 seconds. A refused or failed request raises
`IRCBot::Error` with the reason.

```ruby
command "WEATHER", usage: "WEATHER <city>" do |ctx, args|
  ctx.usage! if args.empty?
  background do
    data = http_json("https://wttr.in/#{URI.encode_www_form_component(ctx.text)}?format=j1")
    ctx.reply("#{ctx.text}: #{data.dig('current_condition', 0, 'temp_C')}°C")
  rescue IRCBot::Error => e
    ctx.reply_privately(e.message)
  end
end
```

## Plugins working together

| Method | Purpose |
| --- | --- |
| `publish(topic, payload = nil, everywhere: false)` | Sends `payload` to other plugins' `listen` blocks for the topic, on this network right away; with `everywhere: true` also on the other networks, on their turn. Returns how many listeners on this network got it |
| `listen "topic" { \|payload, info\| }` | `info` is `{ plugin:, network: }` of the sender. A plugin doesn't get its own messages on its own network |
| `plugin(name)` | Another loaded plugin on this network, to call its methods directly, or nil |
| `shared` | A `Plugin::Shared` common to this plugin's instances on every network: `shared["k"]`, `shared["k"] = v`, `shared.delete("k")`, `shared.to_h`, `shared.synchronize { \|hash\| ... }`. Kept across reloads until the bot restarts; not saved to disk |

Payloads are passed as they are, not copied: don't change them in a
listener.

## Logging and errors

`log` is the plugin's logger (`log.info`, `log.warn`, `log.error`,
`log.debug`). Its lines are marked with the network and plugin, like
`[EFnet/chanlog]`, and go to the bot's log (`ircbot-docker logs`).

- `raise IRCBot::Error, "text"` in a command sends the text to the user.
- `usage!(text)` raises with "Usage: text"; in commands prefer `ctx.usage!`.
- Other exceptions in commands, hooks, timers, listeners and background
  jobs are logged with the first line of the backtrace and never stop the
  bot.
- An exception in `setup` stops the plugin from loading (the previous
  version, if any, keeps running).

## CTCP

The bot answers `VERSION`, `PING`, `TIME` and `CLIENTINFO` itself. The
VERSION text and whether the bot answers at all are set in `config.yml`:

```yaml
ctcp:
  enabled: true
  version: "Linuks, a Ruby IRC bot"
```

Plugins answer other CTCP commands, or replace the built-in answers, with
`ctcp_handler`. The block returns the reply text, or nil for no reply.
Plugin commands show up in `CLIENTINFO`. Each CTCP command can have one
handler across the loaded plugins.

```ruby
ctcp_handler "FINGER" do |event|
  "#{bot_nick} is a bot; ask #{admins.first} about it"
end
```

All CTCP requests, answered or not, also reach `on :ctcp` hooks, and
answers to the bot's own requests reach `on :ctcp_reply`. CTCP answers
share the command rate limits. Send requests with `ctcp(target,
"VERSION")`; `ACTION` (`/me`) is the separate `:action` event and
`action` method.

## Security

**Plugins are trusted code.** They run inside the bot with its full
privileges, including the password pepper and hashes, so only install
plugins you have read. The API keeps well-meaning plugins from causing
damage by accident (checked output, no raw protocol injection, contained
failures, guarded HTTP); it does not sandbox hostile code.

- The bot refuses to load plugins from a folder or file that other users
  can write to; `plugin install` copies files in with private permissions.
- Prefer `ctx.account` or `account_for(nick, userhost)` over
  `account_for(nick)`: the userhost check makes sure the login belongs to
  the user who sent the line.
- Hostmask-based decisions are only as good as the host: hosts without
  cloaks or identd can be shared.
- Don't store secrets in `data`; settings with API keys belong in
  `config.yml`, which must then be private (`chmod 600`).

## Reference: types

**`IRCBot::Message`**, the parsed line in `event.message`: `tags` (IRCv3
tags hash), `prefix` (`nick!user@host` or a server name), `command`
(upper case, e.g. `"PRIVMSG"`, `"311"`), `params` (list; the last one is
the trailing text), `nick`, `userhost`.

**`IRCBot::ModeChange`**, in `event.modes`: `set` (true for `+`), `mode`
(the letter), `param` (or nil); `to_s` gives `"+o alice"`.

**`IRCBot::Roster::Member`**: `nick`, `userhost` (or nil), `modes` (status
letters, e.g. `["o"]`), `op?`, `voice?`, `halfop?`.

**`IRCBot::Roster::Topic`**: `text`, `by` (nick or nick!user@host, or
nil), `at` (Unix time, or nil).

**`IRCBot::SafeHttp::Response`**: `url`, `status`, `content_type`,
`content_length`, `body`.

**`IRCBot::Plugin::Event`**: `type network nick userhost channel target
text new_nick modes ctcp account message`, `channel?`, `prefix`; fields
an event doesn't use are nil.

**`IRCBot::Plugin::Command`**: `name usage help admin identified aliases
where level cooldown`.

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
| [eventlog.rb](../contrib/plugins/eventlog.rb) | a structured JSON Lines log with a query API for other plugins ([its docs](eventlog.md)) |
| [help.rb](../contrib/plugins/help.rb) | the `HELP` command, built from the help catalog: every command and help page |
| [chanserv.rb](../contrib/plugins/chanserv.rb) | channel services: access lists, op/voice commands, automatic modes, help topics and groups |
| [ctcp.rb](../contrib/plugins/ctcp.rb) | the standard CTCP answers |
| [ai.rb](../contrib/plugins/ai.rb) | conversations through any AI backend: JSON APIs, secret files, locked settings ([its docs](ai.md)) |

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
- [Private conversations](#private-conversations)
- [Capabilities](#capabilities)
- [Gems](#gems)
- [Logging and errors](#logging-and-errors)
- [CTCP](#ctcp)
- [Security](#security)
- [Reference: types](#reference-types)

## A first plugin

`plugins/hello.rb`:

```ruby
class Hello < Gemdrop::Plugin
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
bin/gemdrop-docker plugin install hello.rb   # or copy it into instance/plugins/ and reload
/msg Gemdrop HELLO
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
  `Gemdrop::Plugin`. The file name (lowercase letters, digits, `_`) is the
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
- **One thing at a time per plugin, in parallel with everything else.**
  Commands, event hooks, timers, listeners and CTCP handlers run in the
  plugin's own queue, with the plugin as `self`: one at a time and in
  order (events arrive in the order they happened), so a plugin's own
  state needs no locking. Different plugins, and the bot itself, run in
  parallel, so a slow plugin only delays itself. Still, while a hook
  runs, that plugin's next events wait, so anything that waits (HTTP,
  slow files, sleeping) belongs in [`background`](#timers-and-background-work).
- **Events arrive slightly after the fact.** A hook runs just after the
  bot handled the line, so channel state (`users`, `topic` ...) may
  already include later changes. Use the event's own fields for what
  happened.
- **Shared things need care.** `background` jobs run alongside the
  plugin's queue, and calling another plugin's methods directly
  (`plugin(name)`) runs them in your thread, outside its queue; protect
  state those touch with a `Mutex`, or use `publish`/`listen` instead.
- **Lifecycle.** `setup` runs after loading, `teardown` before unloading
  (also on reload and shutdown). Timers stop and channels the plugin joined
  are left when it is unloaded.
- **Failures are contained.** An exception in a hook, timer, listener or
  background job is logged and the bot goes on. In a command, an
  `Gemdrop::Error` sends its message to the user; any other exception is
  logged and the user is told the command failed.
- **Gems** a plugin needs are declared with
  [`requires_gem`](#gems); the bot installs them itself. The standard
  library and the gems bundled with Ruby are always there.

## Declarations

Class-level methods, written in the class body.

| Declaration | Purpose |
| --- | --- |
| `description "text"` | Shown in `PLUGIN LIST` and `plugin list` |
| `setting "name", default:, type:, values:, min:, max:, desc:` | A checked setting ([Settings](#settings-and-configuration)) |
| `defaults "name" => value, ...` | Plain default settings, without checks |
| `command "NAME", ...  { \|ctx, args\| }` | A command ([Commands](#commands)) |
| `help_topic "name", "text", summary:` | A help page for `HELP name`, fixed or made when asked ([Help](#help)) |
| `help_group "Name"` | The heading for the plugin's commands in `LIST` ([Help](#help)) |
| `on :event { \|event\| }` | An event hook ([Events](#events)); several per event are fine |
| `ctcp_handler "NAME" { \|event\| "reply" }` | Answers a CTCP request ([CTCP](#ctcp)) |
| `private_text { \|ctx, words\| }` | Gets private messages that aren't commands, a conversation ([Private conversations](#private-conversations)) |
| `wants_cap "name", ...` | IRCv3 capabilities the plugin needs ([Capabilities](#capabilities)) |
| `listen "topic" { \|payload, info\| }` | Receives messages from other plugins ([Plugins working together](#plugins-working-together)) |
| `requires_gem "name", "~> 1.2"` | A gem the plugin needs ([Gems](#gems)) |

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
| `details:` | none | More text for `HELP <command>`; line breaks start new lines |
| `access:` | from the options below | Who `HELP` says may use it (`anyone identified voice op owner admin`), for commands that check access themselves; `"admin"` also hides it from non-admins in `HELP` |
| `aliases:` | `[]` | Other names for the same command |
| `admin:` | `false` | Only bot admins (implies `identified:`) |
| `identified:` | `false` | Only users identified to a bot account |
| `level:` | none | `"voice"`, `"op"` or `"owner"`: access needed on the channel (implies `identified:`). In a channel it's that channel; by private message the first argument must be the channel, and it is taken off `args` |
| `where:` | `:any` | `:channel` or `:private` to allow only one of them |
| `cooldown:` | none | Seconds before the same host may use the command again |

Command names are 1 to 32 characters, `A-Z`, digits, `_` and `-`. Names of
built-in commands (`REGISTER`, `IDENTIFY`, `PLUGIN`, ...) and of other
loaded plugins' commands are refused at load time.

Where commands work is set per plugin in `config.yml`. By default they
work by private message (`/msg Gemdrop ROLL`). A `prefix` such as `"!"`
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
`raise Gemdrop::Error, "text"`. Plugin commands share the bot's command
rate limits, so a user can't flood through them.

### Help

The `help` plugin ([help.rb](../contrib/plugins/help.rb)) answers `HELP`,
`LIST` and `MORE` from what plugins declare, so a plugin hooks into help
without any help code of its own:

| Declaration | Shows up as |
| --- | --- |
| `usage:` and `help:` on a command | its one-line answer in `HELP <command>` and its entry in `LIST` |
| `details:` on a command | more lines after that (line breaks start new lines; long answers continue with `MORE`) |
| `help_topic "name", "text", summary: "one line"` | a help page for `HELP name` (or `HELP topic name`), listed by `HELP` and `HELP plugin <name>` |
| `help_topic("name", summary: "...") { ... }` | a page made when someone asks: the block runs with the plugin as `self` and returns the text, so it can describe current settings or state |
| `help_group "Fun"` | lists the plugin's commands under that heading in `LIST` instead of the plugin's name; plugins with the same group share it |

`%<nick>s` in page text becomes the bot's nick. Aliases, who may use a
command (from `admin:`, `identified:` and `level:`) and where it works
(by `/msg`, with the plugin's channel prefix) are added automatically,
and admin-only commands are only shown to admins.

```ruby
help_group "Games"
help_topic "dice", "Write dice as NdM, e.g. 2d6.\nAsk %<nick>s for ROLL 2d6.", summary: "dice notation"
help_topic("limits", summary: "current limits") { "Up to #{settings['max_dice']} dice." }
command "ROLL", usage: "ROLL [NdM]", help: "roll dice", details: "Default 1d6.\nAt most 10 dice." do |ctx, args|
  ...
end
```

To build your own help (or anything else that lists commands),
`help_catalog` returns everything as data: `catalog.commands` (the core's
and every loaded plugin's, as `Gemdrop::HelpCatalog::Command`: `name
source group usage help details aliases access private prefix`),
`catalog.topics` (each with `name source summary` and `content`, the
page text, made then for live pages) and `catalog.plugins`, with lookups
`catalog.command(word)` (names and aliases), `catalog.topic(word)` and
`catalog.plugin(word)`.
`access` is one of `anyone identified voice op owner admin`. The bot
itself has no `HELP` command, so a plugin can provide its own instead of
`help.rb`.

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
| `:log` | The bot wrote a log record | `level` (debug/info/warn/error/fatal), `source` (`"IRCnet"`, `"IRCnet/links"` ...), `text` |

Every event also has `type`, `network`, `at` (when it happened, a UTC
`Time`; hooks run a moment later) and `message` (the parsed line, see
[types](#reference-types)), plus `event.channel?` and `event.prefix`
(`nick!user@host`).

A plugin that only needs some events of a type it hooks can say so with
`wants_event?(type)`; events it returns false for aren't queued for it at
all, which matters for busy events like `:line`:

```ruby
def wants_event?(type) = type != :line || settings["raw"]
```

If a plugin falls so far behind that its queue (5,000 waiting jobs)
overflows, new events and commands for it are dropped. When there's room
again, its `events_dropped(count)` runs first, in order, so it knows
exactly where it missed something; by default it logs a warning.

`:log` events carry the bot's log as it is written (at the bot's log
level, already redacted); records about one network go to that
network's plugins, the rest to the first network's. What a plugin logs
from a `:log` hook isn't reported again, so it can't loop. The
[eventlog](eventlog.md) plugin turns all of this into a parseable log.

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
| `kickban(channel, nick, reason = nil)` | Bans `ban_mask(nick)`, then kicks. Raises `Gemdrop::Error` if the nick's host is unknown |
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
| `registry` | The network's `Gemdrop::Channels`, to change registrations, access lists and masks (see [chanserv.rb](../contrib/plugins/chanserv.rb)); changes are saved at once |
| `sync_channels(part_reason: ...)` | Joins newly registered channels and parts dropped ones that aren't in the config |

Rank levels with `Gemdrop::Channels.rank(level)` (voice 1, op 2, owner 3,
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
| `bot_config` | The bot's settings for this network, without secrets or file paths: `nick alt_nicks user realname umodes server port tls network channels admins id` |

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

Don't use the names above for your own settings.

`setting "name", ..., locked: true` makes a setting config.yml-only:
`PLUGIN SET` refuses it, and a value saved for it anyway is ignored when
the plugin loads. Use it for settings that decide where secrets go (an
API's address and key), so a stolen admin login can't redirect them.

Setting names with `key`, `token`, `secret` or `password` as a part
(`api_key`, `access_token`, not `max_tokens` or `api_key_file`) are
treated as secrets, also inside mappings: `PLUGIN SETTINGS` shows them
as `(hidden)`, `PLUGIN SET` lines that contain one are redacted in logs,
and the bot insists that `config.yml` is private if it holds one. To read the bot's
configuration, use [`bot_config`](#the-network-and-the-server).

Admins can also change settings while the bot runs, per network, with
`PLUGIN SET <plugin> <setting> <value>` on IRC or `gemdrop-docker plugin
[-n NETWORK] set ...` (see the [README](../README.md#plugins)). Saved
values override `config.yml`, survive restarts, and reload the plugin.
They go through the same checks: a value that fails a `setting` check,
or makes `setup` raise, is refused and the plugin keeps its previous
settings. So validating settings in `setup` (raise `Gemdrop::Error`)
protects runtime changes too.

### Per channel

Settings declared with `channel: true` can also be set per channel, in
`channel_settings` (the bot adds and checks it for you):

```ruby
setting "language", default: "", type: :string, channel: true
setting "greeting", default: "Hi", type: :string, channel: true
```

```yaml
plugins:
  hello:
    language: English
    channel_settings:
      "#linux.se": { language: Swedish, greeting: "Hej" }
```

A key that isn't a channel is a network's name, holding that network's
channels; a plain `"#chan"` applies on every network:

```yaml
    channel_settings:
      "#gunnit": { greeting: "Yo" }               # every network
      IRCnet:
        "#linux.se": { language: Swedish }        # IRCnet's #linux.se only
```

`settings_for(channel)` returns the settings for a channel on the
plugin's network: `settings`, then the plain entry, then this network's
entry (just `settings` for nil or a channel without any). Every override
must be a `channel: true` setting and pass that setting's checks;
anything else stops the plugin from loading with the reason. Admins set
one channel's value live with `PLUGIN SET hello #linux.se language
Finnish` (and `PLUGIN UNSET hello #linux.se language`), saved for the
network it was sent on and merged with `config.yml`'s entries. A locked
setting can't be per channel.

## Storage

| Method | Purpose |
| --- | --- |
| `data` | The plugin's JSON file: `data/plugins/<name>.json`, or `data/plugins/<network>/<name>.json` with several networks |
| `data["key"]`, `data["key"] = value`, `data.delete("key")` | Read, write, delete; values must be JSON (hashes, lists, strings, numbers, true/false/nil) |
| `data.to_h` | A copy of everything |
| `data.update { \|hash\| ... }` | Several changes in one atomic write |
| `data_dir` | A private folder for the plugin's own files (logs, caches): `data/plugins/[<network>/]<name>/` |

`<network>` is the network's name in lower case (`ircnet`, `efnet`).

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

Timer blocks run like hooks, in the plugin's queue. All
timers stop when the plugin is unloaded (at most 20 per plugin).

`background` blocks run outside the plugin's queue, two at a time, so they
can wait. Everything in the API is safe to call from them; send results
with `say`/`notice` as usual. Long-lived threads of your own (a server
socket) should be started in `setup`, only on `primary?` if they must be
unique, and stopped in `teardown`.

## HTTP

Inside `background` only (they wait for the network):

| Method | Returns |
| --- | --- |
| `http_get(url, accept: "*/*", types: /text|json|xml/)` | `SafeHttp::Response`: `url` (after redirects), `status`, `content_type`, `content_length`, `body` (read only for matching `types`) |
| `http_json(url)` | Parsed JSON; raises `Gemdrop::Error` unless the answer is a 200 with JSON |
| `http_request(method, url, json: / form: / body:, content_type:, accept:, headers:, timeout:, max_bytes:, local:)` | Any request to an API: `:get :post :put :patch :delete :head`, with a JSON (`json:`), URL-encoded (`form:`) or raw (`body:` + `content_type:`) body; the rules of `http_post_json`. Returns the `SafeHttp::Response` whatever its status |
| `http_post_json(url, body, headers: {}, timeout: 60, max_bytes: 1 MiB, local: false)` | POSTs `body` (a Hash) as JSON to an API. Returns the `SafeHttp::Response` whatever its status, with the body as text, so error answers can be read (parse it yourself) |

Requests go through the bot's guarded client: only http
and https on standard ports, only public IPv4 addresses (no localhost or
private networks, checked again at every redirect), at most 3 redirects,
256 KiB and 10 seconds. A refused or failed request raises
`Gemdrop::Error` with the reason.

`http_post_json` follows no redirects at all (a 3xx is returned, so
credentials in its headers go nowhere else), and its `timeout` (1 to 600
seconds) bounds the whole request. `local: true` also lets it reach
localhost, private networks and any port, for services on the bot's own
machine such as a local model server: use it only for addresses from
`config.yml`, never for one a user gave. See [ai.rb](../contrib/plugins/ai.rb).

API keys belong in files, not in settings: `secret_file(name)` reads
one from the bot's secret folder (`secret/` in an instance, next to the
pepper). `name` is a plain file name; the file must be private to the
bot's user (`chmod 600`); it returns the content without surrounding
whitespace, or raises `Gemdrop::Error` saying what is wrong. Read it
when you need it, so a changed key works without a reload.

```ruby
command "WEATHER", usage: "WEATHER <city>" do |ctx, args|
  ctx.usage! if args.empty?
  background do
    data = http_json("https://wttr.in/#{URI.encode_www_form_component(ctx.text)}?format=j1")
    ctx.reply("#{ctx.text}: #{data.dig('current_condition', 0, 'temp_C')}°C")
  rescue Gemdrop::Error => e
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

## Private conversations

Private messages that aren't a command normally get "Unknown command."
One plugin can take them instead, as a conversation:

```ruby
private_text do |ctx, words|
  ctx.reply_privately("You said #{words.size} words: #{ctx.text}")
end
```

The block runs like a command (in the plugin's queue, with a `ctx`).
Only one loaded plugin can have it; a second one fails to load. Text
whose first word is a password command with a typo or two ("identfy
secret") never reaches it, so a mistyped password stays with the bot.
[ai.rb](../contrib/plugins/ai.rb) uses this for private chats.

## Capabilities

IRCv3 capabilities (`account-notify`, `server-time`, `away-notify`,
`message-tags` ...) are negotiated by the bot for the plugins that want
them:

```ruby
wants_cap "account-notify", "server-time"

on :line do |event|
  next unless cap?("server-time")

  sent_at = event.message.tags["time"]
end
```

The bot asks for them when it registers, or as soon as the plugin is
loaded on a connection that is already up, so no reconnect is needed.
`caps` lists the enabled ones and `cap?(name)` checks one. A server that
doesn't offer a capability (or doesn't do CAP at all, like IRCnet's)
simply never enables it; with no plugin wanting any, the bot doesn't use
CAP. Message tags are in `event.message.tags`; replies to capabilities
such as `account-notify` (`ACCOUNT`) arrive as `:line` events.

## Gems

A plugin can use any gem from rubygems.org. Declare it at the top of the
class:

```ruby
class Feeds < Gemdrop::Plugin
  requires_gem "nokogiri", "~> 1.16"            # activated and required here
  requires_gem "feedjira", "~> 3.2", require: false

  def setup
    require "feedjira"                           # fine after requires_gem
  end
end
```

Before loading the plugin, the bot reads its `requires_gem` lines (without
running the file) and checks which gems are missing. Missing ones are
downloaded in the background into the instance's `gems/` folder (the
`gems_dir` setting, next to `config.yml`), and the plugin loads by
itself when they are in; meanwhile `plugin list` shows it as
`installing`. The bot keeps running normally during the download, and a
version of the plugin that is already loaded keeps working until then.

- **Versions:** each requirement is any RubyGems requirement
  (`"~> 1.16"`, `">= 2.0", "< 3"`). The exact versions installed are
  recorded in `gems.lock` next to the folder; later installs (another
  plugin, a new server) use the locked version if it fits, so the bot
  keeps running what you tested. Delete a line to allow an upgrade.
- **Shared:** gems are installed once for all networks and all plugins.
  Two plugins needing incompatible versions of the same gem can't both
  load; the second gets a clear error.
- **Dependencies** come along automatically. Gems Ruby already ships
  (json, racc, rexml, csv, net-smtp, webrick, ...) are used rather than
  downloaded again.
- **Native extensions:** the image has no compiler. Most popular gems
  with C code (nokogiri, sqlite3, ffi, google-protobuf, ...) ship
  precompiled for Linux and install fine; gems that would have to be
  compiled (e.g. bcrypt) fail with a message saying so, and the plugin
  isn't loaded.
- **Failures** (no network, no such gem or version) are logged and shown
  in `plugin list`; the next reload or `PLUGIN LOAD` tries again.
- **Backups** include `gems.lock`, not the gems: after a restore, the bot
  downloads the same versions again when it starts.
- Gems run with the bot's privileges like plugins do, and are fetched
  from rubygems.org over HTTPS by RubyGems itself (not the guarded
  client, which is for user-posted links).

## Logging and errors

`log` is the plugin's logger (`log.info`, `log.warn`, `log.error`,
`log.debug`). Its lines are marked with the network and plugin, like
`[EFnet/chanlog]`, and go to the bot's log (`gemdrop-docker logs`).

- `raise Gemdrop::Error, "text"` in a command sends the text to the user.
- `usage!(text)` raises with "Usage: text"; in commands prefer `ctx.usage!`.
- Other exceptions in commands, hooks, timers, listeners and background
  jobs are logged with the first line of the backtrace and never stop the
  bot.
- An exception in `setup` stops the plugin from loading (the previous
  version, if any, keeps running).

## CTCP

The bot itself answers no CTCP; plugins do, with `ctcp_handler`. The
standard `VERSION`, `PING`, `TIME` and `CLIENTINFO` come from the `ctcp`
plugin ([ctcp.rb](../contrib/plugins/ctcp.rb)), whose `CLIENTINFO` lists
every CTCP command answered (`ctcp_commands`). The block returns the
reply text, or nil for no reply. Each CTCP command can have one handler
across the loaded plugins, so to answer `VERSION` differently, set the
`ctcp` plugin's `version` or leave it out of its `answer` list.

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

**`Gemdrop::Message`**, the parsed line in `event.message`: `tags` (IRCv3
tags hash), `prefix` (`nick!user@host` or a server name), `command`
(upper case, e.g. `"PRIVMSG"`, `"311"`), `params` (list; the last one is
the trailing text), `nick`, `userhost`.

**`Gemdrop::ModeChange`**, in `event.modes`: `set` (true for `+`), `mode`
(the letter), `param` (or nil); `to_s` gives `"+o alice"`.

**`Gemdrop::Roster::Member`**: `nick`, `userhost` (or nil), `modes` (status
letters, e.g. `["o"]`), `op?`, `voice?`, `halfop?`.

**`Gemdrop::Roster::Topic`**: `text`, `by` (nick or nick!user@host, or
nil), `at` (Unix time, or nil).

**`Gemdrop::SafeHttp::Response`**: `url`, `status`, `content_type`,
`content_length`, `body`.

**`Gemdrop::Plugin::Event`**: `type network nick userhost channel target
text new_nick modes ctcp account message at level source`, `channel?`,
`prefix`; fields an event doesn't use are nil.

**`Gemdrop::Plugin::Command`**: `name usage help admin identified aliases
where level cooldown`.

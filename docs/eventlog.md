# Event log (the `eventlog` plugin)

A structured, machine-readable record of what the bot sees and does:
channel events, what the bot itself sends, and the bot's own log. It is
a plugin, [contrib/plugins/eventlog.rb](../contrib/plugins/eventlog.rb),
written so that other plugins (and any other program) can parse it
reliably.

```sh
bin/gemdrop-docker plugin install contrib/plugins/eventlog.rb
```

## Files

One file per network and day (UTC), in JSON Lines format: one JSON
object per line, nothing else. The folder uses the network's name in
lower case (`IRCnet` → `ircnet`).

```
instance/data/plugins/<network>/eventlog/2026-10-10.jsonl
instance/data/plugins/<network>/eventlog/2026-10-07.jsonl.gz   (older days, compressed)
```

(With a single-server config without `networks:`, the folder is
`instance/data/plugins/eventlog/`.)

- Each record is written with a single append, so a crash can at most cut
  the last line short. Readers should skip lines that don't parse, as
  `records` does.
- Files are private (mode 0600). Days older than `compress_after_days`
  are gzipped; days older than `keep_days` are deleted.
- If a record can't be written (disk full, permissions), the bot keeps
  running: lost records are counted and reported in the bot's log at most
  every 5 minutes, and recovery is logged too.

## Records (schema version 1)

Every record has:

| Field | |
| --- | --- |
| `v` | Schema version, `1`. Fields may be added within a version; none are removed or change meaning |
| `ts` | When it happened: ISO 8601 UTC with milliseconds, `"2026-10-10T12:00:01.234Z"` |
| `network` | The network's name from `config.yml` |
| `type` | What happened (below) |

Fields that don't apply to a record are left out (never `null`).

| `type` | Fields | |
| --- | --- | --- |
| `message` | `channel nick userhost text` | Channel message |
| `action` | `channel nick userhost text` | `/me` (`channel` missing when sent to the bot) |
| `notice` | `channel` or `target`, `nick userhost text` | |
| `private_message` | `target nick userhost text` | Only with `private_messages: true` |
| `ctcp`, `ctcp_reply` | `ctcp target nick userhost text` | Private ones only with `private_messages: true` |
| `join`, `part` | `channel nick userhost`, `text` (part reason) | Includes the bot's own |
| `kick` | `channel nick` (kicked) `by text` (reason) | |
| `quit` | `nick userhost text` | |
| `nick` | `nick userhost new_nick` | |
| `mode` | `channel nick` (who) `modes` (`["+o alice", "-v bob"]`) | Channel modes |
| `topic` | `channel nick text` | |
| `invite` | `channel target nick userhost` | |
| `identified`, `logout` | `nick userhost account` | Users logging in to bot accounts |
| `connected`, `disconnected` | | The bot's connection |
| `outgoing` | `nick` (the bot) `command target channel text` | What the bot sends; by default PRIVMSG, NOTICE, MODE, KICK, TOPIC, JOIN, PART, INVITE |
| `log` | `level source text` | The bot's own log: `level` is debug/info/warn/error/fatal, `source` is where it came from (`"IRCnet"`, `"IRCnet/links"`, `"gems"`) |
| `line` | `raw` | Every line received (off by default) |
| `gap` | `lost` | Events were missed here: the plugin fell so far behind that `lost` events had to be dropped (only in extreme floods; it is also in the bot's log) |

`userhost` is left out with `hide_hosts: true`. Text is valid UTF-8 and at
most `max_text` characters. Lines carrying passwords (`IDENTIFY`,
`REGISTER`, `PASSWORD`, `PLUGIN SET` of keys) are never logged.

Example:

```json
{"v":1,"ts":"2026-10-10T12:00:01.234Z","network":"IRCnet","type":"message","channel":"#linux.se","nick":"alice","userhost":"alice@example.net","text":"hello"}
{"v":1,"ts":"2026-10-10T12:00:05.012Z","network":"IRCnet","type":"mode","channel":"#linux.se","nick":"Linuks","userhost":"Linuks@bot.example","modes":["+o alice"]}
{"v":1,"ts":"2026-10-10T12:00:09.500Z","network":"IRCnet","type":"log","level":"warn","source":"IRCnet","text":"Kicked from #test by op (out)"}
```

## Settings

All optional, under `plugins: eventlog:`. Like any plugin setting they
can also be set per network (`network_settings`) or changed while the bot
runs (`PLUGIN SET eventlog ...`).

| Setting | Default | |
| --- | --- | --- |
| `types` | all but `line` | Which record types to write |
| `only_channels` | `[]` | Only these channels (empty: all) |
| `ignore_channels` | `[]` | Never these channels |
| `ignore_nicks` | `[]` | Never events from these nicks |
| `private_messages` | `false` | Also log what users send the bot privately, and what it sends them |
| `hide_hosts` | `false` | Leave out `userhost` |
| `log_level` | `info` | Lowest level of the bot's log to record (`debug info warn error fatal`) |
| `outgoing_commands` | PRIVMSG NOTICE MODE KICK TOPIC JOIN PART INVITE | Which of the bot's own lines to record |
| `keep_days` | `90` | Delete older days (0: keep forever) |
| `compress_after_days` | `2` | Gzip days at least this old (0: never) |
| `max_text` | `2000` | Longest text in a record |
| `publish` | `true` | Hand every record to other plugins live (see below) |
| `search_days` | `30` | How far back `LOGSEARCH` looks |

## Reading it from other plugins

Live, as records are written:

```ruby
class Watcher < Gemdrop::Plugin
  listen "log.record" do |record, _info|
    say("#ops", "#{record['nick']} was kicked from #{record['channel']}") if record["type"] == "kick"
  end
end
```

Past records, with `records` (filters are all optional):

```ruby
log = plugin("eventlog") or raise Gemdrop::Error, "the eventlog plugin isn't loaded"
background do
  log.records(from: Date.today - 7, channel: "#linux.se", types: %w[message], text: "ruby", limit: 100)
     .each { |record| ... }
end
```

| Filter | |
| --- | --- |
| `from`, `to` | `Date`, `Time` or `"YYYY-MM-DD"` (UTC; default today). A `Time` also limits by time of day |
| `types` | List of types |
| `channel`, `nick` | Exact, with IRC case rules (`#Chan` = `#chan`) |
| `text` | Words (case-insensitive) or a `Regexp` |
| `limit` | At most this many |

It returns an Enumerator, oldest first, reading files lazily (compressed
days included), so large logs don't have to fit in memory. Records are
frozen hashes with string keys. Read inside `background`: it reads files.
`log_files` lists the days on disk as `[[Date, path], ...]`.

Records are plain JSON Lines, so outside the bot `jq`, `grep` or any JSON
library works too:

```sh
zcat -f instance/data/plugins/ircnet/eventlog/*.jsonl* | jq -c 'select(.type == "kick")'
```

## Searching from IRC

Channel ops (and bot admins) can search a channel's messages:

```
/msg Linuks LOGSEARCH #linux.se deploy
!logsearch deploy          (in the channel, with prefix: "!")
```

It answers privately with the newest 5 matches from the last
`search_days` days.

# Event log: a structured, machine-readable record of what the bot sees
# and does, one JSON object per line (JSON Lines), one file per day:
#
#   data/plugins/<network>/eventlog/2026-10-10.jsonl
#   {"v":1,"ts":"2026-10-10T12:00:01.234Z","network":"IRCnet","type":"message",
#    "channel":"#linux.se","nick":"alice","userhost":"alice@example.net","text":"hi"}
#
# It records channel events (messages, actions, joins, parts, kicks,
# quits, nick changes, modes, topics ...), what the bot itself sends, and
# the bot's own log. The schema is in docs/eventlog.md.
#
# Other plugins can read it:
#   plugin("eventlog").records(from: Date.today - 7, channel: "#linux.se", text: "ruby").each { |r| ... }
# or follow it live:
#   listen("log.record") { |record, _info| ... }
#
# Install:  bin/gemdrop-docker plugin install contrib/plugins/eventlog.rb
# Settings: under "plugins: eventlog:" (see docs/eventlog.md); all optional.
require "date"
require "json"
require "time"
require "zlib"

class Eventlog < Gemdrop::Plugin
  description "Structured JSON Lines log of IRC events, the bot's messages and its own log"

  SCHEMA = 1
  IRC_TYPES = %w[
    message action notice private_message join part kick quit nick mode topic invite
    ctcp ctcp_reply identified logout connected disconnected
  ].freeze
  ALL_TYPES = (IRC_TYPES + %w[outgoing log line]).freeze
  LEVELS = %w[debug info warn error fatal].freeze
  # Event types that can be private (sent to the bot rather than a channel).
  PRIVATE_TYPES = %w[private_message notice action ctcp ctcp_reply].freeze
  FILE_NAME = /\A(\d{4}-\d{2}-\d{2})\.jsonl(\.gz)?\z/
  FAILURE_REPORT_INTERVAL = 300

  setting "types", default: IRC_TYPES + %w[outgoing log], type: :list
  setting "only_channels", default: [], type: :list
  setting "ignore_channels", default: [], type: :list
  setting "ignore_nicks", default: [], type: :list
  setting "private_messages", default: false, type: :boolean
  setting "hide_hosts", default: false, type: :boolean
  setting "log_level", default: "info", values: LEVELS
  setting "outgoing_commands", default: %w[PRIVMSG NOTICE MODE KICK TOPIC JOIN PART INVITE], type: :list
  setting "keep_days", default: 90, type: :integer, min: 0
  setting "compress_after_days", default: 2, type: :integer, min: 0
  setting "max_text", default: 2000, type: :integer, min: 100, max: 20_000
  setting "publish", default: true, type: :boolean
  setting "search_days", default: 30, type: :integer, min: 1, max: 3650

  def setup
    unknown = settings["types"] - ALL_TYPES
    raise Gemdrop::Error, "unknown types: #{unknown.join(', ')} (known: #{ALL_TYPES.join(', ')})" if unknown.any?

    @file = nil
    @file_day = nil
    @lost = 0
    @last_report = nil
    # In the plugin's own queue, not in setup: setup runs while the bot is
    # locked, and a backlog of old days can take a while to compress.
    after(1) { housekeeping }
    every(3600) { housekeeping }
  end

  def teardown = close_file

  # Only the enabled types take a place in the plugin's queue.
  def wants_event?(type) = settings["types"].include?(type.to_s)

  # The bot had to drop events for this plugin (its queue overflowed): a
  # "gap" record marks the spot, so readers know something is missing.
  def events_dropped(count)
    super
    entry = { "v" => SCHEMA, "ts" => Time.now.utc.iso8601(3), "network" => network, "type" => "gap", "lost" => count }
    write(entry)
    publish("log.record", deep_freeze(entry)) if settings["publish"]
  end

  ALL_TYPES.each { |type| on(type.to_sym) { |event| record(event) } }

  command "LOGSEARCH", usage: "LOGSEARCH [#chan] <words>", help: "search a channel's log (newest 5 matches)",
                       level: "op", cooldown: 10 do |ctx, args|
    ctx.usage! if args.empty?
    channel = ctx.target_channel
    words = args.join(" ")
    queued = background do
      hits = records(from: today - settings["search_days"], channel: channel, types: %w[message action], text: words)
             .to_a.last(5)
      next ctx.reply_privately("Nothing in #{channel}'s log matches \"#{words}\".") if hits.empty?

      hits.each do |hit|
        who = hit["type"] == "action" ? "* #{hit['nick']}" : "<#{hit['nick']}>"
        ctx.reply_privately("#{hit['ts'][0, 16].tr('T', ' ')} #{who} #{hit['text']}")
      end
    end
    raise Gemdrop::Error, "Too busy right now; try again in a moment." unless queued
  end

  # --- reading the log (also for other plugins) -----------------------------------------

  # Records matching every filter given, oldest first, as frozen hashes
  # with string keys (see docs/eventlog.md). from/to: Date, Time or
  # "YYYY-MM-DD" (UTC days, both included; a Time also limits by the
  # time of day). types: list of types. channel, nick: exact (IRC case
  # rules). text: words (case-insensitive) or a Regexp. limit: at most this
  # many. Damaged lines are skipped. Returns an Enumerator, so large logs
  # are read lazily.
  def records(from: today, to: today, types: nil, channel: nil, nick: nil, text: nil, limit: nil)
    since = from.is_a?(Time) ? from.utc : nil
    till = to.is_a?(Time) ? to.utc : nil
    first_day = day_of(from)
    last_day = day_of(to)
    Enumerator.new do |out|
      count = 0
      catch(:enough) do
        log_files.each do |day, path|
          next if day < first_day || day > last_day

          each_record(path) do |record|
            next unless match?(record, types, channel, nick, text)
            next if since && Time.iso8601(record["ts"]) < since
            next if till && Time.iso8601(record["ts"]) > till

            out << record
            count += 1
            throw :enough if limit && count >= limit
          end
        end
      end
    end
  end

  # Days with a log, oldest first: [[Date, path], ...].
  def log_files
    Dir.children(data_dir).filter_map do |name|
      day = name[FILE_NAME, 1] or next
      [Date.iso8601(day), File.join(data_dir, name)]
    end.sort
  end

  private

  # --- writing ---------------------------------------------------------------------------

  def record(event)
    type = event.type.to_s
    return unless settings["types"].include?(type)

    entry = build(event, type) or return
    write(entry)
    publish("log.record", deep_freeze(entry)) if settings["publish"]
  end

  def build(event, type)
    base = { "v" => SCHEMA, "ts" => (event.at || Time.now.utc).utc.iso8601(3), "network" => network, "type" => type }
    case type
    when "log" then log_entry(base, event)
    when "outgoing" then outgoing_entry(base, event.message)
    when "line" then base.merge("raw" => trim(raw_line(event.message)))
    else irc_entry(base, event, type)
    end
  end

  def log_entry(base, event)
    level = event.level.to_s
    return nil if LEVELS.include?(level) && LEVELS.index(level) < LEVELS.index(settings["log_level"])

    base.merge("level" => level, "source" => event.source, "text" => trim(event.text))
  end

  def outgoing_entry(base, msg)
    return nil unless settings["outgoing_commands"].include?(msg.command)

    target = msg.params[0]
    channel = target if target && isupport_channel?(target)
    return nil if channel ? !channel_wanted?(channel) : !settings["private_messages"]

    text = %w[PRIVMSG NOTICE TOPIC KICK PART].include?(msg.command) ? msg.params.last : msg.params[1..]&.join(" ")
    text = text.to_s.delete_prefix("\x01ACTION ").delete("\x01") if msg.command == "PRIVMSG"
    base.merge("nick" => bot_nick, "command" => msg.command, "channel" => channel, "target" => target,
               "text" => trim(text)).compact
  end

  def irc_entry(base, event, type)
    if event.channel
      return nil unless channel_wanted?(event.channel)
    elsif PRIVATE_TYPES.include?(type) && !settings["private_messages"]
      return nil
    end
    return nil if event.nick && settings["ignore_nicks"].any? { |n| Gemdrop::Casemap.eq?(n, event.nick) }

    by = event.message&.nick if type == "kick"
    base.merge(
      "nick" => event.nick, "userhost" => (event.userhost unless settings["hide_hosts"]), "channel" => event.channel,
      "target" => event.target, "text" => event.text && trim(event.text), "new_nick" => event.new_nick,
      "modes" => event.modes&.map(&:to_s), "ctcp" => event.ctcp, "account" => event.account, "by" => by
    ).compact
  end

  # One line per record, written with a single append, so a crash can at
  # worst cut the last line short (readers skip it).
  def write(entry)
    file_for(entry["ts"][0, 10]).write("#{JSON.generate(entry)}\n")
    recovered if @lost.positive?
  rescue SystemCallError, IOError, JSON::GeneratorError => e
    failed(e)
  end

  def file_for(day)
    return @file if @file && @file_day == day

    close_file
    path = File.join(data_dir, "#{day}.jsonl")
    @file = File.open(path, File::WRONLY | File::APPEND | File::CREAT | File::NOFOLLOW, 0o600)
    @file.sync = true
    @file_day = day
    @file
  end

  def close_file
    @file&.close
  rescue IOError, SystemCallError
    nil
  ensure
    @file = nil
    @file_day = nil
  end

  # Records that can't be written are counted and reported at most every
  # few minutes, so a full disk doesn't flood the bot's log.
  def failed(error)
    close_file
    @lost += 1
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    return if @last_report && now - @last_report < FAILURE_REPORT_INTERVAL

    @last_report = now
    log.error("Can't write the event log (#{error.class}: #{error.message}); #{@lost} record(s) lost so far")
  end

  def recovered
    log.warn("The event log is writable again; #{@lost} record(s) were lost")
    @lost = 0
    @last_report = nil
  end

  # --- housekeeping ------------------------------------------------------------------------

  # Compresses past days after compress_after_days and deletes days older
  # than keep_days (0: never).
  def housekeeping
    log_files.each do |day, path|
      age = (today - day).to_i
      if settings["keep_days"].positive? && age > settings["keep_days"]
        File.delete(path)
      elsif settings["compress_after_days"].positive? && age >= settings["compress_after_days"] && !path.end_with?(".gz")
        compress(path)
      end
    end
  rescue SystemCallError, IOError, Zlib::Error => e
    log.warn("Event log housekeeping failed: #{e.message}")
  end

  def compress(path)
    tmp = "#{path}.gz.tmp"
    Zlib::GzipWriter.open(tmp) { |gz| File.open(path, "rb") { |file| IO.copy_stream(file, gz) } }
    File.chmod(0o600, tmp)
    File.rename(tmp, "#{path}.gz")
    File.delete(path)
  ensure
    FileUtils.rm_f(tmp)
  end

  # --- reading -----------------------------------------------------------------------------

  def each_record(path)
    reader = path.end_with?(".gz") ? Zlib::GzipReader.method(:open) : File.method(:open)
    reader.call(path) do |io|
      io.each_line do |line|
        record = parse(line) and yield record
      end
    end
  rescue SystemCallError, IOError, Zlib::Error
    nil # an unreadable or truncated file ends its records; others still count
  end

  def parse(line)
    record = JSON.parse(line)
    record.is_a?(Hash) && record["ts"].is_a?(String) ? deep_freeze(record) : nil
  rescue JSON::ParserError
    nil
  end

  def match?(record, types, channel, nick, text)
    return false if types && !types.include?(record["type"])
    return false if channel && !Gemdrop::Casemap.eq?(record["channel"], channel)
    return false if nick && !Gemdrop::Casemap.eq?(record["nick"], nick)
    return true unless text

    body = record["text"].to_s
    text.is_a?(Regexp) ? body.match?(text) : body.downcase.include?(text.to_s.downcase)
  end

  # --- helpers -------------------------------------------------------------------------------

  def channel_wanted?(channel)
    return false if settings["ignore_channels"].any? { |c| Gemdrop::Casemap.eq?(c, channel) }

    only = settings["only_channels"]
    only.empty? || only.any? { |c| Gemdrop::Casemap.eq?(c, channel) }
  end

  def isupport_channel?(target)
    types = isupport["CHANTYPES"].to_s
    types = "#&" if types.empty?
    types.include?(target[0])
  end

  # Valid UTF-8, at most max_text characters.
  def trim(text)
    text = text.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "�")
    text.length > settings["max_text"] ? "#{text[0, settings['max_text'] - 1]}…" : text
  end

  def raw_line(msg)
    params = msg.params.dup
    last = params.pop
    parts = [(":#{msg.prefix}" if msg.prefix), msg.command, *params]
    parts << ":#{last}" if last
    parts.compact.join(" ")
  end

  def day_of(value)
    case value
    when Date then value
    when Time then value.utc.to_date
    else Date.iso8601(value.to_s)
    end
  end

  def today = Time.now.utc.to_date

  def deep_freeze(value)
    case value
    when Hash then value.each_value { |v| deep_freeze(v) }.freeze
    when Array then value.each { |v| deep_freeze(v) }.freeze
    else value.freeze
    end
  end
end

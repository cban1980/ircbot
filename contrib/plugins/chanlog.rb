# Example plugin: channel logs. Writes what happens in the bot's channels,
# including the bot's own messages, to one file per channel and day:
#
#   data/plugins/<network>/chanlog/#linux.se.2026-10-09.log
#
# Shows most events, the outgoing event, data_dir, typed settings and a
# timer. Settings (all optional):
#
#   plugins:
#     chanlog:
#       only: ["#linux.se"]   # log just these channels (default: all)
#       keep_days: 30         # delete older logs (default 30)
require "date"

class Chanlog < Gemdrop::Plugin
  description "Logs channel activity to files"
  setting "only", default: [], type: :list, desc: "channels to log; empty: all"
  setting "keep_days", default: 30, type: :integer, min: 1, max: 3650

  def setup
    @where = Hash.new { |hash, key| hash[key] = [] } # nick => channels seen in, for quits
    after(1) { prune } # in the plugin's queue, not while the bot is locked for setup
    every(3600) { prune }
  end

  on(:message) { |e| write(e.channel, "<#{e.nick}> #{e.text}", e.nick) }
  on(:action) { |e| write(e.channel, "* #{e.nick} #{e.text}", e.nick) if e.channel }
  on(:notice) { |e| write(e.channel, "-#{e.nick}- #{e.text}") if e.channel && e.nick }
  on(:join) { |e| write(e.channel, "--> #{e.nick} (#{e.userhost}) joined", e.nick) }
  on(:part) { |e| write(e.channel, "<-- #{e.nick} left#{" (#{e.text})" if e.text}") }
  on(:kick) { |e| write(e.channel, "<-- #{e.nick} was kicked by #{e.message.nick}#{" (#{e.text})" if e.text}") }
  on(:mode) { |e| write(e.channel, "*** #{e.nick || e.message.prefix} sets mode #{e.modes.join(' ')}") }
  on(:topic) { |e| write(e.channel, "*** #{e.nick} changes the topic to: #{e.text}") }

  on(:quit) do |e|
    @where.delete(key(e.nick))&.each { |channel| write(channel, "<-- #{e.nick} quit#{" (#{e.text})" if e.text}") }
  end

  on(:nick) do |e|
    channels.select { |channel| user(channel, e.new_nick) }.each do |channel|
      write(channel, "*** #{e.nick} is now known as #{e.new_nick}", e.new_nick)
    end
    @where[key(e.new_nick)] = @where.delete(key(e.nick)) || []
  end

  # The bot's own messages never come back from the server.
  on(:outgoing) do |e|
    msg = e.message
    next unless msg.command == "PRIVMSG" && in_channel?(msg.params[0].to_s)

    text = msg.params[1].to_s
    if text.start_with?("\x01ACTION ")
      write(msg.params[0], "* #{bot_nick} #{text.delete_prefix("\x01ACTION ").delete("\x01")}")
    elsif !text.start_with?("\x01")
      write(msg.params[0], "<#{bot_nick}> #{text}")
    end
  end

  private

  def write(channel, text, nick = nil)
    return unless channel && logged?(channel)

    (@where[key(nick)] |= [channel]) if nick
    path = File.join(data_dir, "#{file_name(channel)}.#{Date.today.iso8601}.log")
    File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o600) do |file|
      file.puts("#{Time.now.strftime('%H:%M:%S')} #{text.delete("\x00-\x08\x0b-\x1f")}")
    end
  end

  def logged?(channel)
    only = settings["only"]
    only.empty? || only.any? { |c| Gemdrop::Casemap.eq?(c, channel) }
  end

  # Channel names may contain "/" and other characters unsafe in file names.
  def file_name(channel)
    Gemdrop::Casemap.downcase(channel).gsub(/[^\w#&+.-]/) { |c| format("%%%02X", c.ord) }
  end

  def key(nick) = Gemdrop::Casemap.downcase(nick)

  def prune
    cutoff = Date.today - settings["keep_days"]
    Dir.glob(File.join(data_dir, "*.log")).each do |path|
      day = path[/\.(\d{4}-\d{2}-\d{2})\.log\z/, 1] or next
      File.delete(path) if Date.iso8601(day) < cutoff
    end
  end
end

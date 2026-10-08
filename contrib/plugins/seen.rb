# Example plugin: SEEN <nick>. Shows event hooks, a timer, setup/teardown
# and stored data (data/plugins/seen.json). Install it while the bot runs:
#
#   cp contrib/plugins/seen.rb instance/plugins/ && bin/ircbot-docker reload
#
# Only what someone did and when is stored, never what they said.
class Seen < IRCBot::Plugin
  description "Remembers when nicks were last active"
  defaults "max_nicks" => 10_000

  def setup
    @seen = data["nicks"] || {}
    @dirty = false
    every(300) { save } # write at most every 5 minutes, not on every line
  end

  def teardown = save

  on(:message) { |event| record(event.nick, "talking in #{event.channel}") }
  on(:join) { |event| record(event.nick, "joining #{event.channel}") }
  on(:part) { |event| record(event.nick, "leaving #{event.channel}") }
  on(:kick) { |event| record(event.nick, "being kicked from #{event.channel}") }
  on(:quit) { |event| record(event.nick, "quitting") }
  on(:nick) { |event| record(event.nick, "changing nick to #{event.new_nick}") }

  command "SEEN", usage: "SEEN <nick>", help: "when a nick was last active" do |ctx, args|
    ctx.usage! unless args.size == 1

    entry = @seen[IRCBot::Casemap.downcase(args[0])]
    next ctx.reply("I haven't seen #{args[0]}.") unless entry

    ctx.reply("#{entry['nick']} was last seen #{ago(Time.now.to_i - entry['at'])} ago, #{entry['what']}.")
  end

  private

  def record(nick, what)
    return if nick.nil? || IRCBot::Casemap.eq?(nick, bot_nick)

    @seen[IRCBot::Casemap.downcase(nick)] = { "nick" => nick, "what" => what, "at" => Time.now.to_i }
    @dirty = true
    return if @seen.size <= settings["max_nicks"]

    @seen = @seen.max_by(settings["max_nicks"]) { |_, entry| entry["at"] }.to_h
  end

  def save
    return unless @dirty

    data["nicks"] = @seen
    @dirty = false
  end

  def ago(seconds)
    [[86_400, "day"], [3600, "hour"], [60, "minute"], [1, "second"]].each do |size, unit|
      count = seconds / size
      return "#{count} #{unit}#{'s' unless count == 1}" if count.positive? || size == 1
    end
  end
end

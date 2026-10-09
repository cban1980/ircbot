# Example plugin: relays chat between channels on different networks.
# Each link is a list of "Network/#channel" endpoints; what is said in one
# is repeated in the others. Shows on_network, typed settings, setup
# checks and rate limits.
#
#   plugins:
#     relay:
#       links:
#         - ["IRCnet/#linux.se", "EFnet/#gunnit"]
#       events: [message, action, join, part, quit]   # default: message, action
#       ignore_nicks: [otherbot]
#
# The bot must be in every linked channel (configured or registered).
class Relay < IRCBot::Plugin
  description "Relays chat between channels on different networks"
  setting "links", default: [], type: :list
  setting "events", default: %w[message action], type: :list
  setting "ignore_nicks", default: [], type: :list
  setting "max_per_10s", default: 8, type: :integer, min: 1

  EVENTS = %w[message action join part quit kick nick].freeze

  def setup
    unknown = settings["events"] - EVENTS
    raise IRCBot::Error, "unknown relay events: #{unknown.join(', ')} (use #{EVENTS.join(', ')})" if unknown.any?

    @links = settings["links"].map do |link|
      raise IRCBot::Error, "each relay link must be a list of Network/#channel" unless link.is_a?(Array) && link.size >= 2

      link.map { |endpoint| parse(endpoint) }
    end
  end

  on(:message) { |e| relay(e.channel, e.nick, "<#{e.nick}> #{e.text}", "message") }
  on(:action) { |e| relay(e.channel, e.nick, "* #{e.nick} #{e.text}", "action") if e.channel }
  on(:join) { |e| relay(e.channel, e.nick, "--> #{e.nick} joined", "join") }
  on(:part) { |e| relay(e.channel, e.nick, "<-- #{e.nick} left", "part") }
  on(:kick) { |e| relay(e.channel, e.nick, "<-- #{e.nick} was kicked by #{e.message.nick}", "kick") }

  # Quits and nick changes have no channel: relay them from every linked
  # channel the user is (or, for quits, was last seen) in.
  on(:quit) do |e|
    (@last_seen&.delete(key(e.nick)) || []).each { |channel| relay(channel, e.nick, "<-- #{e.nick} quit", "quit") }
  end

  on(:nick) do |e|
    channels.select { |channel| user(channel, e.new_nick) }.each do |channel|
      relay(channel, e.new_nick, "*** #{e.nick} is now #{e.new_nick}", "nick")
    end
  end

  private

  def relay(channel, nick, text, event)
    return if nick.nil? || IRCBot::Casemap.eq?(nick, bot_nick)

    remember(channel, nick)
    return unless settings["events"].include?(event)
    return if settings["ignore_nicks"].any? { |n| IRCBot::Casemap.eq?(n, nick) }

    targets_for(channel).each do |net, target|
      next unless rate_limit("#{net}/#{target}", limit: settings["max_per_10s"], per: 10)

      on_network(net)&.say(target, "[#{network}] #{text}")
    end
  end

  # Every other endpoint of the links that include network/channel.
  def targets_for(channel)
    @links.select { |link| link.any? { |net, chan| here?(net, chan, channel) } }
          .flat_map { |link| link.reject { |net, chan| here?(net, chan, channel) } }
          .uniq
  end

  def here?(net, chan, channel) = net.casecmp?(network) && IRCBot::Casemap.eq?(chan, channel)

  def remember(channel, nick)
    (@last_seen ||= Hash.new { |hash, k| hash[k] = [] })[key(nick)] |= [channel]
  end

  def parse(endpoint)
    net, channel = endpoint.to_s.split("/", 2)
    unless net && channel&.match?(IRCBot::Channels::NAME)
      raise IRCBot::Error, "relay endpoint #{endpoint.inspect} must look like \"EFnet/#channel\""
    end
    raise IRCBot::Error, "relay: the bot isn't on a network called #{net}" unless networks.any? { |n| n.casecmp?(net) }

    [networks.find { |n| n.casecmp?(net) }, channel]
  end

  def key(nick) = IRCBot::Casemap.downcase(nick)
end

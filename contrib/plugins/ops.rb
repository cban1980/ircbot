# Example plugin: channel moderation for users with op access (through the
# bot's access lists or as bot admins). Shows command levels, aliases and
# the moderation actions. Best with a prefix:
#
#   plugins:
#     ops:
#       prefix: "!"
#
# In a channel: !kick nick [reason], !kb nick [reason], !ban nick|mask,
# !unban mask, !topic text. By private message, put the channel first:
# /msg Gemdrop KICK #chan nick [reason].
class Ops < Gemdrop::Plugin
  description "Kick, ban and topic commands for channel ops"
  setting "default_reason", default: "Requested", type: :string

  command "KICK", usage: "KICK [#chan] <nick> [reason]", help: "kick someone", aliases: %w[K], level: "op" do |ctx, args|
    nick, *reason = args
    ctx.usage! unless nick
    check!(ctx, nick)
    kick(ctx.target_channel, nick, reason_text(ctx, reason))
  end

  command "KB", usage: "KB [#chan] <nick> [reason]", help: "ban someone's host and kick them",
                aliases: %w[KICKBAN], level: "op" do |ctx, args|
    nick, *reason = args
    ctx.usage! unless nick
    check!(ctx, nick)
    kickban(ctx.target_channel, nick, reason_text(ctx, reason))
  end

  command "BAN", usage: "BAN [#chan] <nick|mask>", help: "ban a nick's host or a mask", level: "op" do |ctx, args|
    ctx.usage! unless args.size == 1
    target = args.first
    unless target.include?("!")
      check!(ctx, target)
      target = ban_mask(target) or raise Gemdrop::Error, "I don't know #{args.first}'s host; give a mask."
    end
    bot_op!(ctx)
    ban(ctx.target_channel, target)
  end

  command "UNBAN", usage: "UNBAN [#chan] <mask>", help: "remove a ban", level: "op" do |ctx, args|
    ctx.usage! unless args.size == 1
    bot_op!(ctx)
    unban(ctx.target_channel, args.first)
  end

  command "TOPIC", usage: "TOPIC [#chan] <text>", help: "set the topic", level: "op" do |ctx, args|
    ctx.usage! if args.empty?
    set_topic(ctx.target_channel, args.join(" "))
  end

  private

  # Nobody can act on the bot, or on users with the same or higher access.
  def check!(ctx, nick)
    raise Gemdrop::Error, "I won't do that to myself." if Gemdrop::Casemap.eq?(nick, bot_nick)
    raise Gemdrop::Error, "#{nick} is not on #{ctx.target_channel}." unless user(ctx.target_channel, nick)

    bot_op!(ctx)
    target_level = access_level(ctx.target_channel, account_for(nick))
    return if Gemdrop::Channels.rank(target_level) < Gemdrop::Channels.rank(ctx.access_level)

    raise Gemdrop::Error, "#{nick} has equal or higher access on #{ctx.target_channel}."
  end

  def bot_op!(ctx)
    raise Gemdrop::Error, "I'm not a channel operator on #{ctx.target_channel}." unless op?(ctx.target_channel)
  end

  def reason_text(ctx, words)
    reason = words.empty? ? settings["default_reason"] : words.join(" ")
    "#{reason} (#{ctx.nick})"
  end
end

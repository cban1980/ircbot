# Channel services: registered channels, their access lists and hostmask
# entries, the commands to manage them, and automatic op/voice.
#
#   UP <#chan> / DOWN <#chan>                 give or remove your own modes
#   OP|DEOP|VOICE|DEVOICE <#chan> [nick]      for channel ops
#   ACCESS <#chan> LIST|ADD|DEL|ADDMASK|DELMASK ...
#   CHANREGISTER <#chan> <owner>              bot admins
#   CHANDROP <#chan>                          the channel's owner
#
# Identified users get their mode when they join a registered channel, or
# when they identify while in it; hostmask entries give it on join without
# identifying. Levels rank voice < op < owner; bot admins count as owner
# everywhere.
#
# The data (which channels are registered, their access lists and masks)
# belongs to the bot, not this plugin: it stays when the plugin is unloaded,
# the bot keeps joining registered channels, and bin/gemdrop-account manages
# it from the shell. Without this plugin there are just no channel commands
# and no automatic modes.
#
# Install:  bin/gemdrop-docker plugin install contrib/plugins/chanserv.rb
class Chanserv < Gemdrop::Plugin
  description "Registered channels: access lists, hostmasks, op/voice commands and automatic modes"
  help_group "Channel"

  MODE_COMMANDS = { "OP" => "+o", "DEOP" => "-o", "VOICE" => "+v", "DEVOICE" => "-v" }.freeze
  MODES = Gemdrop::Channels::MODES

  help_topic "levels", <<~TEXT, summary: "channel access levels"
    Registered channels give accounts voice, op or owner access (voice < op < owner).
    You get your mode when you join while identified, or when you identify while in the channel.
    You can only grant levels below your own; bot admins count as owner everywhere.
  TEXT

  # --- automatic modes ---------------------------------------------------------------

  # The higher of the identified account's level and any matching mask.
  on(:join) do |event|
    next if same_nick?(event.nick, bot_nick) || !registry.registered?(event.channel)

    account = account_for(event.nick, event.userhost)
    account_level = account && access_level(event.channel, account)
    mask_level, mask = registry.mask_level(event.channel, event.prefix)
    if Gemdrop::Channels.rank(mask_level) > Gemdrop::Channels.rank(account_level)
      log.info("#{event.prefix} matches mask #{mask} on #{event.channel}: giving #{mask_level}")
      mode(event.channel, "+#{MODES[mask_level]}", event.nick)
    elsif account_level
      mode(event.channel, "+#{MODES[account_level]}", event.nick)
    end
  end

  # Someone identified while already in registered channels.
  on(:identified) do |event|
    channels.each do |channel|
      next unless user(channel, event.nick) && registry.registered?(channel)

      level = access_level(channel, event.account)
      mode(channel, "+#{MODES[level]}", event.nick) if level
    end
  end

  # --- commands ------------------------------------------------------------------------

  command "UP", usage: "UP <#chan>", help: "give yourself your modes (voice or op)", access: "voice" do |ctx, args|
    answer(ctx) do
      usage!("UP <#chan>") unless args.size == 1
      channel = args[0]
      _account, level = require_level(ctx, channel, "voice")
      require_on_channel(channel, ctx.nick)
      mode(channel, "+#{MODES[level]}", ctx.nick)
    end
  end

  command "DOWN", usage: "DOWN <#chan>", help: "remove your own modes", access: "voice" do |ctx, args|
    answer(ctx) do
      usage!("DOWN <#chan>") unless args.size == 1
      channel = args[0]
      _account, level = require_level(ctx, channel, "voice")
      require_on_channel(channel, ctx.nick)
      mode(channel, "-#{MODES[level]}", ctx.nick)
    end
  end

  { "OP" => "give op", "DEOP" => "take op", "VOICE" => "give voice", "DEVOICE" => "take voice" }.each do |name, help|
    details = name.start_with?("DE") ? "Users with equal or higher access are protected." : "Without a nick, you."
    command name, usage: "#{name} <#chan> [nick]", help: help, details: details, access: "op" do |ctx, args|
      answer(ctx) { set_user_mode(ctx, name, args) }
    end
  end

  command "ACCESS", usage: "ACCESS <#chan> LIST|ADD|DEL|ADDMASK|DELMASK ...", help: "manage a channel's access list",
                    access: "op",
                    details: "ACCESS <#chan> LIST shows the list.\n" \
                             "ACCESS <#chan> ADD <account> <voice|op> gives access (only levels below your own).\n" \
                             "ACCESS <#chan> DEL <account> removes it.\n" \
                             "ACCESS <#chan> ADDMASK <nick!user@host> <voice|op> and DELMASK <mask>: auto-modes by " \
                             "hostmask (bot admins only)." do |ctx, args|
    answer(ctx) { access(ctx, args) }
  end

  command "CHANREGISTER", usage: "CHANREGISTER <#chan> <owner>", help: "register a channel with the bot",
                          access: "admin" do |ctx, args|
    answer(ctx) do
      account = require_account(ctx)
      usage!("CHANREGISTER <#chan> <owner>") unless args.size == 2
      raise Gemdrop::Error, "Only bot admins can register channels." unless admin?(account)

      channel, owner_name = args
      owner = account_name(owner_name) or raise Gemdrop::Error, "No account named #{owner_name}."
      registry.register(channel, owner)
      log.info("#{account} registered #{channel} for #{owner}")
      sync_channels # joins it
      tell(ctx, "#{channel} registered with owner #{owner}.")
    end
  end

  command "CHANDROP", usage: "CHANDROP <#chan>", help: "drop a registered channel", access: "owner" do |ctx, args|
    answer(ctx) do
      usage!("CHANDROP <#chan>") unless args.size == 1
      channel = args[0]
      account, = require_level(ctx, channel, "owner")
      registry.drop(channel)
      log.info("#{account} dropped #{channel}")
      sync_channels(part_reason: "Channel dropped") # leaves it, unless it is in the config
      tell(ctx, "#{channel} has been dropped.")
    end
  end

  private

  def set_user_mode(ctx, command, args)
    usage!("#{command} <#chan> [nick]") unless [1, 2].include?(args.size)
    channel, target = args
    target ||= ctx.nick
    account, my_level = require_level(ctx, channel, "op")
    raise Gemdrop::Error, "I don't change my own modes." if same_nick?(target, bot_nick)

    require_on_channel(channel, target)
    change = MODE_COMMANDS.fetch(command)
    if change.start_with?("-") && !same_nick?(target, ctx.nick)
      # Protect users whose stored access is not below the requester's.
      target_account = account_for(target)
      if target_account && rank(access_level(channel, target_account)) >= rank(my_level)
        raise Gemdrop::Error, "#{target} has equal or higher access on #{channel}."
      end
    end
    log.info("#{account} (#{ctx.nick}) set #{change} on #{target} in #{channel}")
    mode(channel, change, target)
  end

  def access(ctx, args)
    channel, sub, *rest = args
    usage!("ACCESS <#chan> LIST|ADD|DEL|ADDMASK|DELMASK ...") unless channel && sub
    return access_mask(ctx, channel, sub.upcase, rest) if %w[ADDMASK DELMASK].include?(sub.upcase)

    account, my_level = require_level(ctx, channel, "op")
    case sub.upcase
    when "LIST"
      registry.access_list(channel).each { |name, level| tell(ctx, "#{channel}: #{name} #{level}") }
      registry.masks(channel).each { |mask, level, by| tell(ctx, "#{channel}: mask #{mask} #{level} (added by #{by})") }
    when "ADD"
      usage!("ACCESS <#chan> ADD <account> <voice|op>") unless rest.size == 2
      target = existing_account(rest[0])
      level = rest[1].downcase
      raise Gemdrop::Error, "You can only grant levels below your own (#{my_level})." unless rank(level) < rank(my_level)

      check_outranks(channel, target, my_level)
      registry.set_access(channel, target, level)
      log.info("#{account} gave #{target} #{level} access on #{channel}")
      tell(ctx, "#{target} now has #{level} access on #{channel}.")
    when "DEL"
      usage!("ACCESS <#chan> DEL <account>") unless rest.size == 1
      target = existing_account(rest[0])
      check_outranks(channel, target, my_level)
      registry.remove_access(channel, target)
      log.info("#{account} removed #{target}'s access on #{channel}")
      tell(ctx, "Removed #{target} from #{channel}.")
    else
      usage!("ACCESS <#chan> LIST|ADD|DEL|ADDMASK|DELMASK ...")
    end
  end

  # Hostmask entries give voice/op on join without identifying, so only
  # bot admins may manage them (on any registered channel).
  def access_mask(ctx, channel, sub, rest)
    account = require_account(ctx)
    raise Gemdrop::Error, "Only bot admins can manage masks." unless admin?(account)
    raise Gemdrop::Error, "#{channel} is not registered." unless registry.registered?(channel)

    if sub == "ADDMASK"
      usage!("ACCESS <#chan> ADDMASK <nick!user@host> <voice|op>") unless rest.size == 2
      mask = registry.add_mask(channel, rest[0], rest[1].downcase, added_by: account)
      log.info("#{account} added mask #{mask} (#{rest[1].downcase}) on #{channel}")
      tell(ctx, "Mask #{mask} now gets #{rest[1].downcase} on #{channel} when joining.")
    else
      usage!("ACCESS <#chan> DELMASK <nick!user@host>") unless rest.size == 1
      registry.remove_mask(channel, rest[0])
      log.info("#{account} removed mask #{rest[0]} on #{channel}")
      tell(ctx, "Removed mask #{rest[0]} from #{channel}.")
    end
  end

  # --- checks ----------------------------------------------------------------------------

  def require_account(ctx) = ctx.account || raise(Gemdrop::Error, "You must IDENTIFY first.")

  # Returns [account, level] or raises if the user lacks min_level.
  def require_level(ctx, channel, min_level)
    account = require_account(ctx)
    raise Gemdrop::Error, "#{channel} is not registered." unless registry.registered?(channel)

    level = access_level(channel, account)
    raise Gemdrop::Error, "You need #{min_level} access on #{channel} for that." if rank(level) < rank(min_level)

    [account, level]
  end

  def require_on_channel(channel, nick)
    raise Gemdrop::Error, "#{nick} is not on #{channel}." unless user(channel, nick)
  end

  def existing_account(name) = account_name(name) || raise(Gemdrop::Error, "No account named #{name}.")

  def check_outranks(channel, target, my_level)
    return if rank(access_level(channel, target)) < rank(my_level)

    raise Gemdrop::Error, "#{target} has equal or higher access on #{channel}."
  end

  # --- helpers ----------------------------------------------------------------------------

  # Runs a command; an Error is the answer. Replies can echo user input
  # (channel or account names), so formatting and control codes go first.
  def answer(ctx)
    yield
  rescue Gemdrop::Error => e
    tell(ctx, e.message)
  end

  def tell(ctx, text) = ctx.reply_privately(text.gsub(Gemdrop::Bot::UNSAFE_CHARS, ""))

  def rank(level) = Gemdrop::Channels.rank(level)
  def same_nick?(a, b) = Gemdrop::Casemap.eq?(a, b)
end

# Layered help, built from everything the bot can do: the core's commands
# and every loaded plugin's, with the help pages plugins publish. Every
# answer is short; you drill down instead of getting everything at once:
#
#   HELP                  how help works, and the help topics
#   LIST                  the command groups (Account, Channel, each plugin)
#   LIST <group>          that group's commands
#   HELP <command>        what it does, how to use it, who may and where
#   HELP <topic>          a help page
#   HELP plugin <name>    a plugin: description, commands and topics
#   HELP topic <name>     a help page, when a command has the same name
#   MORE                  the rest of an answer that didn't fit
#
# Other plugins hook in by declaring things (docs/plugins.md, "Help"):
# their commands' usage:, help: and details: show up here; help_topic
# adds a page (fixed text, or a block that makes it when asked); and
# help_group files their commands under a shared heading in LIST.
#
# Install:  bin/gemdrop-docker plugin install contrib/plugins/help.rb
# Settings (optional, under "plugins: help:"):
#   lines_per_answer: 3   lines an answer sends before saving the rest for MORE
#   intro: ""             a first line for HELP, e.g. "Gemdrop, the #linux.se bot"
class Help < Gemdrop::Plugin
  description "Layered HELP, LIST and MORE for the bot's and its plugins' commands"
  setting "lines_per_answer", default: 3, type: :integer, min: 1, max: 20
  setting "intro", default: "", type: :string

  LINE_LENGTH = 380   # characters per reply line (IRC allows a bit more)
  MORE_TTL = 600      # seconds an unread rest of an answer is kept
  MORE_USERS = 200    # at most this many users' rests are kept

  ACCESS_TEXT = {
    "anyone" => "anyone", "identified" => "anyone identified to an account", "voice" => "voice and above on the channel",
    "op" => "op and above on the channel", "owner" => "the channel's owner", "admin" => "bot admins"
  }.freeze

  help_topic "accounts", <<~TEXT, summary: "accounts and logging in"
    Accounts belong to the bot and work on every network it is on.
    /msg %<nick>s REGISTER <password> makes your current nick an account.
    /msg %<nick>s IDENTIFY [account] <password> logs you in; logins are per network and end when you quit.
    Never send a password in a channel.
  TEXT

  def setup
    @rest = {} # user key => [lines, expires at]
  end

  command "HELP", usage: "HELP [command|topic]", help: "how help works, or help on a command or topic",
                  details: "HELP plugin <name> describes a plugin, HELP topic <name> shows a help page. " \
                           "LIST shows the command groups; MORE continues." do |ctx, args|
    lines =
      if args.empty? then intro_lines
      elsif args.first.casecmp?("plugin") && args[1] then plugin_lines(args[1], ctx.admin?)
      elsif args.first.casecmp?("topic") && args[1] then topic_lines(args[1])
      else about(args.first, ctx.admin?)
      end
    answer(ctx, lines)
  end

  command "LIST", usage: "LIST [group]", help: "the command groups, or one group's commands", aliases: %w[COMMANDS] do |ctx, args|
    answer(ctx, args.empty? ? groups_lines(ctx.admin?) : group_lines(args.join(" "), ctx.admin?))
  end

  command "MORE", help: "the rest of the last answer" do |ctx, _args|
    lines, expires = @rest.delete(user_key(ctx))
    next ctx.reply_privately("Nothing more.") unless lines && expires > now

    answer(ctx, lines)
  end

  private

  # --- the layers ---------------------------------------------------------------------

  def intro_lines
    lines = []
    lines << settings["intro"] unless settings["intro"].empty?
    lines << "LIST shows the command groups, LIST <group> a group's commands, HELP <command> explains one, " \
             "MORE continues a long answer."
    topics = help_catalog.topics
    lines << "Help topics: #{topics.map(&:name).join(', ')} (HELP <topic>)." if topics.any?
    lines
  end

  def groups_lines(admin)
    groups = usable(help_catalog, admin).group_by(&:group).map { |group, commands| "#{group} (#{commands.size})" }
    pack("Groups: ", groups, ", ", " - LIST <group> for its commands.")
  end

  def group_lines(word, admin)
    catalog = help_catalog
    commands = usable(catalog, admin).select { |c| c.group.casecmp?(word) }
    return ["No group called #{word}. LIST shows the groups."] if commands.empty?

    description = catalog.plugin(word)&.description.to_s
    head = "#{commands.first.group}#{" (#{description})" unless description.empty?}: "
    pack(head, commands.map { |c| display_name(c) }, ", ", " - HELP <command> for one.")
  end

  def about(word, admin)
    catalog = help_catalog
    word = word.delete_prefix("!")
    command = catalog.command(word)
    command = nil unless command&.usable_by?(admin: admin)
    if command
      command_lines(command, catalog.plugin(word), catalog.topic(word))
    elsif catalog.topic(word)
      topic_lines(word)
    elsif catalog.plugin(word)
      plugin_lines(word, admin)
    else
      ["No help for #{word}. LIST shows the command groups."]
    end
  end

  def topic_lines(word)
    topic = help_catalog.topic(word) or return ["No help page called #{word}."]

    lines = fill(topic.content).lines.map(&:strip).reject(&:empty?)
    lines.empty? ? ["Nothing to say about #{topic.name} right now."] : lines
  end

  # One line with the essentials, then the details (for MORE if long).
  def command_lines(command, same_named_plugin, same_named_topic)
    facts = ["#{syntax(command)}: #{command.help.empty? ? 'no description' : command.help}."]
    facts << "Also #{command.aliases.join(', ')}." if command.aliases.any?
    facts << "#{ACCESS_TEXT.fetch(command.access, command.access).capitalize}; #{where(command)}."
    facts << "(#{command.source} plugin)" unless command.source == "core"
    lines = pack("", facts, " ", "")
    command.details.to_s.split("\n").map(&:strip).reject(&:empty?).each { |detail| lines << detail }
    lines << "There is also a #{same_named_plugin.name} plugin: HELP plugin #{same_named_plugin.name}." if same_named_plugin
    lines << "There is also a help page: HELP topic #{same_named_topic.name}." if same_named_topic
    lines
  end

  def plugin_lines(word, admin)
    catalog = help_catalog
    info = catalog.plugin(word) or return ["No plugin called #{word} is loaded."]

    commands = info.commands.select { |c| c.usable_by?(admin: admin) }.map { |c| display_name(c) }
    lines = ["#{info.name}: #{info.description.empty? ? 'no description' : info.description}"]
    lines.concat(pack("Commands: ", commands, ", ", "")) if commands.any?
    lines.concat(pack("Topics: ", info.topics.map { |t| "#{t.name} (#{t.summary})" }, ", ", "")) if info.topics.any?
    lines
  end

  # --- answering ------------------------------------------------------------------------

  # Sends the first lines; the rest waits for MORE.
  def answer(ctx, lines)
    shown = settings["lines_per_answer"]
    rest = lines.drop(shown)
    head = lines.first(shown)
    if rest.any?
      remember_rest(ctx, rest)
      head[-1] = "#{head[-1]} (#{rest.size} more: MORE)"
    else
      @rest.delete(user_key(ctx))
    end
    head.each { |line| ctx.reply_privately(line) }
  end

  def remember_rest(ctx, lines)
    @rest.delete_if { |_, (_, expires)| expires <= now }
    @rest.shift while @rest.size >= MORE_USERS
    @rest[user_key(ctx)] = [lines, now + MORE_TTL]
  end

  # Joins items into as few lines as fit LINE_LENGTH.
  def pack(head, items, separator, tail)
    lines = []
    line = head.dup
    items.each_with_index do |item, i|
      piece = (i.zero? ? "" : separator) + item
      if line.length + piece.length > LINE_LENGTH && line.length > head.length
        lines << line.rstrip
        line = item.dup
      else
        line << piece
      end
    end
    lines << "#{line}#{tail}".rstrip
    lines
  end

  # --- formatting ---------------------------------------------------------------------

  def usable(catalog, admin) = catalog.commands.select { |c| c.usable_by?(admin: admin) }

  # How to type it: the /msg form if it works privately, else !name in channels.
  def syntax(command)
    command.private ? command.usage : "#{command.prefix}#{command.usage.sub(/\A\S+/, &:downcase)}"
  end

  def display_name(command) = command.private ? command.name : "#{command.prefix}#{command.name.downcase}"

  def where(command)
    places = []
    places << "/msg #{bot_nick} #{command.name}" if command.private
    places << "#{command.prefix}#{command.name.downcase} in channels" if command.prefix
    places.join(" or ")
  end

  # Topics may say %<nick>s for the bot's nick.
  def fill(text) = text.gsub("%<nick>s", bot_nick)

  def user_key(ctx) = ctx.userhost.to_s.split("@", 2).last.to_s.downcase

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

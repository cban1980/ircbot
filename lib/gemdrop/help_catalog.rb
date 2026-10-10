module Gemdrop
  # What the bot can do, as data, for help plugins: every command (the
  # core's and each loaded plugin's) and the help topics plugins publish.
  # Plugins get it with Plugin#help_catalog; the bot itself has no HELP
  # command, the help plugin (contrib/plugins/help.rb) builds one from this.
  module HelpCatalog
    # Who may use a command, lowest first.
    ACCESS = %w[anyone identified voice op owner admin].freeze

    # One command. source: "core" or the plugin's name. group: a heading
    # ("Account", "Channel", the plugin's name). access: one of ACCESS.
    # private: works by /msg. prefix: the channel prefix ("!"), or nil if
    # it doesn't work in channels. details: longer help, may be several lines.
    Command = Data.define(:name, :source, :group, :usage, :help, :details, :aliases, :access, :private, :prefix) do
      def initialize(name:, source:, group:, usage:, help:, details: nil, aliases: [], access: "anyone", private: true,
                     prefix: nil) = super

      # Matches the command's name or one of its aliases (any case).
      def named?(word) = ([name] + aliases).any? { |n| n.casecmp?(word.to_s) }

      # Whether someone with this access may use it (admins may use everything).
      def usable_by?(admin:) = access != "admin" || admin
    end

    # A help page a plugin publishes with help_topic. text may be several
    # lines, or a Proc (a page made when asked): use #content.
    Topic = Data.define(:name, :source, :summary, :text) do
      def content = text.respond_to?(:call) ? text.call.to_s : text.to_s
    end

    # A loaded plugin, with its commands and topics.
    PluginInfo = Data.define(:name, :description, :commands, :topics)

    Catalog = Data.define(:commands, :topics, :plugins) do
      def command(word) = commands.find { |c| c.named?(word) }
      def topic(word) = topics.find { |t| t.name.casecmp?(word.to_s) }
      def plugin(word) = plugins.find { |p| p.name.casecmp?(word.to_s) }
    end
  end
end

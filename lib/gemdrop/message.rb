module Gemdrop
  # A single parsed IRC protocol line, including optional IRCv3 tags.
  Message = Struct.new(:tags, :prefix, :command, :params, keyword_init: true) do
    def self.parse(line)
      rest = line.chomp
      tags = {}
      if rest.start_with?("@")
        raw, rest = rest[1..].split(" ", 2)
        raw.split(";").each do |tag|
          key, value = tag.split("=", 2)
          tags[key] = value
        end
      end

      prefix = nil
      prefix, rest = rest[1..].split(" ", 2) if rest.to_s.start_with?(":")

      head, trailing = rest.to_s.split(" :", 2)
      params = head.to_s.split(" ")
      command = params.shift.to_s.upcase
      params << trailing if trailing

      new(tags: tags, prefix: prefix, command: command, params: params)
    end

    def nick
      prefix&.split("!", 2)&.first
    end

    # "user@host" part of the prefix, or nil for server-originated messages.
    def userhost
      prefix&.split("!", 2)&.at(1)
    end
  end
end

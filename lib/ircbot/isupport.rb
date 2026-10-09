module IRCBot
  # One change from a MODE line: set (true for +, false for -), the mode
  # letter, and its parameter or nil.
  ModeChange = Data.define(:set, :mode, :param) do
    def to_s = "#{set ? '+' : '-'}#{mode}#{" #{param}" if param}"
  end

  # The server's features from RPL_ISUPPORT (005), with RFC 1459 defaults
  # for servers that don't send them.
  class ISupport
    DEFAULTS = {
      "PREFIX" => "(ov)@+",
      "CHANMODES" => "beI,k,l,imnpst",
      "CHANTYPES" => "#&",
      "MODES" => "3"
    }.freeze
    MAX_MODES = 6 # per line, also when the server sets no limit

    def initialize
      @tokens = {}
    end

    # Takes the tokens of one 005 line: "KEY=value", "KEY" or "-KEY".
    def update(tokens)
      tokens.each do |token|
        next if token.empty?

        if token.start_with?("-")
          @tokens.delete(token[1..].upcase)
        else
          name, value = token.split("=", 2)
          @tokens[name.upcase] = value.nil? ? true : unescape(value)
        end
      end
    end

    def clear = @tokens.clear

    # The token's value: a string, true for a token without a value, or nil.
    def [](name) = @tokens.fetch(name.to_s.upcase) { DEFAULTS[name.to_s.upcase] }

    def key?(name) = @tokens.key?(name.to_s.upcase)

    def to_h = DEFAULTS.merge(@tokens)

    # Status modes and their NAMES symbols, highest first: { "o" => "@", "v" => "+" }.
    def prefixes
      match = self["PREFIX"].to_s.match(/\A\(([A-Za-z]*)\)(\S*)\z/)
      return { "o" => "@", "v" => "+" } unless match && match[1].size == match[2].size

      match[1].chars.zip(match[2].chars).to_h
    end

    # Channel modes by type: [lists (b e I), always with a parameter (k),
    # with a parameter only when set (l), never with one (n t ...)].
    def chanmode_groups
      (self["CHANMODES"].to_s.split(",", -1) + ["", "", "", ""]).first(4).map(&:chars)
    end

    # How many mode changes with parameters fit in one MODE line.
    def max_modes
      value = self["MODES"]
      value.is_a?(String) && value.to_i.positive? ? [value.to_i, MAX_MODES].min : MAX_MODES
    end

    def channel?(name)
      types = self["CHANTYPES"].to_s
      types = "#&" if types.empty?
      !name.to_s.empty? && types.include?(name.to_s[0])
    end

    # Parses a channel MODE: "+o-v+l", ["alice", "bob", "10"] -> [ModeChange].
    def parse_modes(modestring, params)
      params = params.dup
      lists, always, when_set, = chanmode_groups
      status = prefixes.keys
      set = true
      changes = []
      modestring.to_s.each_char do |char|
        case char
        when "+" then set = true
        when "-" then set = false
        when /[A-Za-z]/
          takes = status.include?(char) || lists.include?(char) || always.include?(char) ||
                  (set && when_set.include?(char))
          changes << ModeChange.new(set: set, mode: char, param: takes ? params.shift : nil)
        end
      end
      changes
    end

    private

    # ISUPPORT escapes some characters as \xHH.
    def unescape(value) = value.gsub(/\\x(\h\h)/) { Regexp.last_match(1).hex.chr }
  end
end

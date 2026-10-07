module IRCBot
  # RFC 1459 case-insensitive comparison of nicks and channel names,
  # where {}|^ are the lowercase forms of []\~.
  module Casemap
    module_function

    def downcase(str)
      str.to_s.downcase.tr("[]\\~", "{}|^")
    end

    def eq?(a, b)
      downcase(a) == downcase(b)
    end
  end
end

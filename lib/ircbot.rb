require "logger"

module IRCBot
  # Raised for user-facing failures; the message is sent back to the user.
  class Error < StandardError; end

  # Raised for setup problems that must stop the bot from starting.
  class ConfigError < StandardError; end
end

require_relative "ircbot/log_formatter"
require_relative "ircbot/casemap"
require_relative "ircbot/message"
require_relative "ircbot/secure_file"
require_relative "ircbot/password_hasher"
require_relative "ircbot/pepper"
require_relative "ircbot/rate_limiter"
require_relative "ircbot/store"
require_relative "ircbot/accounts"
require_relative "ircbot/channels"
require_relative "ircbot/roster"
require_relative "ircbot/known_servers"
require_relative "ircbot/connection"
require_relative "ircbot/safe_http"
require_relative "ircbot/link_preview"
require_relative "ircbot/worker_pool"
require_relative "ircbot/config"
require_relative "ircbot/plugin"
require_relative "ircbot/plugin_manager"
require_relative "ircbot/bot"
require_relative "ircbot/bot_runtime"
require_relative "ircbot/bot_plugins"

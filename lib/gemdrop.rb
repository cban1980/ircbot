require "logger"
require "monitor"

# Gemdrop, a Ruby IRC bot.
module Gemdrop
  # Wraps the named methods of a class in a lock (a Monitor in @lock, which
  # the class sets up), for objects shared with plugin threads.
  module Synchronized
    def synchronize_methods(*names)
      prepend(Module.new do
        names.each do |name|
          define_method(name) { |*args, **opts, &block| @lock.synchronize { super(*args, **opts, &block) } }
        end
      end)
    end
  end

  # Raised for user-facing failures; the message is sent back to the user.
  class Error < StandardError; end

  # Raised for setup problems that must stop the bot from starting.
  class ConfigError < StandardError; end

  # The server is on another network than configured: that network stops.
  class WrongNetworkError < ConfigError; end
end

require_relative "gemdrop/log_tap"
require_relative "gemdrop/log_formatter"
require_relative "gemdrop/casemap"
require_relative "gemdrop/message"
require_relative "gemdrop/secure_file"
require_relative "gemdrop/hash_workers"
require_relative "gemdrop/password_hasher"
require_relative "gemdrop/pepper"
require_relative "gemdrop/rate_limiter"
require_relative "gemdrop/store"
require_relative "gemdrop/accounts"
require_relative "gemdrop/channels"
require_relative "gemdrop/isupport"
require_relative "gemdrop/roster"
require_relative "gemdrop/known_servers"
require_relative "gemdrop/connection"
require_relative "gemdrop/safe_http"
require_relative "gemdrop/worker_pool"
require_relative "gemdrop/keyed_executor"
require_relative "gemdrop/config"
require_relative "gemdrop/help_catalog"
require_relative "gemdrop/plugin_irc"
require_relative "gemdrop/plugin"
require_relative "gemdrop/plugin_gems"
require_relative "gemdrop/plugin_state"
require_relative "gemdrop/plugin_manager"
require_relative "gemdrop/signal_handling"
require_relative "gemdrop/bot"
require_relative "gemdrop/bot_runtime"
require_relative "gemdrop/bot_plugins"
require_relative "gemdrop/bot_rejoin"
require_relative "gemdrop/bot_health"
require_relative "gemdrop/supervisor"

require "logger"
require "monitor"

# Rubicon, a Ruby IRC bot (formerly "ircbot").
module Rubicon
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

require_relative "rubicon/log_tap"
require_relative "rubicon/log_formatter"
require_relative "rubicon/casemap"
require_relative "rubicon/message"
require_relative "rubicon/secure_file"
require_relative "rubicon/hash_workers"
require_relative "rubicon/password_hasher"
require_relative "rubicon/pepper"
require_relative "rubicon/rate_limiter"
require_relative "rubicon/store"
require_relative "rubicon/accounts"
require_relative "rubicon/channels"
require_relative "rubicon/isupport"
require_relative "rubicon/roster"
require_relative "rubicon/known_servers"
require_relative "rubicon/connection"
require_relative "rubicon/safe_http"
require_relative "rubicon/worker_pool"
require_relative "rubicon/keyed_executor"
require_relative "rubicon/config"
require_relative "rubicon/plugin_irc"
require_relative "rubicon/plugin"
require_relative "rubicon/plugin_gems"
require_relative "rubicon/plugin_state"
require_relative "rubicon/plugin_manager"
require_relative "rubicon/signal_handling"
require_relative "rubicon/bot"
require_relative "rubicon/bot_runtime"
require_relative "rubicon/bot_plugins"
require_relative "rubicon/bot_rejoin"
require_relative "rubicon/bot_health"
require_relative "rubicon/supervisor"

# The name from before the rename; plugins written for IRCBot::Plugin
# keep working.
IRCBot = Rubicon

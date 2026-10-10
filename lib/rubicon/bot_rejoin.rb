module Rubicon
  # Staying in channels: after a kick or a failed join (banned, invite-only,
  # full, wrong key ...), the bot tries again by itself. The delay doubles
  # while it keeps failing or being kicked (5 s, 10 s, ... up to 10 minutes)
  # and starts over once things have been calm for 15 minutes. Only
  # channels the bot should be in are retried: configured, registered or
  # joined by a plugin.
  class Bot
    REJOIN_DELAY = 5
    REJOIN_MAX_DELAY = 600
    REJOIN_RESET = 900

    # Replies to JOIN that mean the bot didn't get in, and why.
    JOIN_ERRORS = {
      "403" => "there is no such channel",
      "405" => "the bot is in too many channels",
      "437" => "the channel is temporarily unavailable",
      "471" => "the channel is full (+l)",
      "473" => "the channel is invite-only (+i)",
      "474" => "the bot is banned (+b)",
      "475" => "the channel key is wrong or missing (+k)",
      "477" => "the channel needs a registered nick"
    }.freeze

    private

    def on_kick(msg)
      channel, kicked, reason = msg.params
      on_part(channel, kicked)
      return unless self?(kicked)

      @log.warn("Kicked from #{channel} by #{msg.nick}#{" (#{reason})" if reason}")
      retry_join(channel, "kicked")
    end

    # A JOIN_ERRORS reply: me, channel, text.
    def on_join_failed(msg)
      channel = msg.params[1]
      retry_join(channel, JOIN_ERRORS.fetch(msg.command)) if wanted_channel?(channel)
    end

    def retry_join(channel, reason)
      return unless wanted_channel?(channel) && !@roster.on?(channel, @nick)

      now = @clock.call
      entry = @rejoins[key(channel)]
      recent = entry && now - entry[:last] < REJOIN_RESET
      delay = recent ? [entry[:delay] * 2, REJOIN_MAX_DELAY].min : REJOIN_DELAY
      @rejoins[key(channel)] = { channel: channel, delay: delay, at: now + delay, last: now }
      @log.warn("Can't stay in #{channel}: #{reason}; joining again in #{delay}s")
    end

    # Called by the ticker: sends the rejoins that are due. The entry stays
    # (without a time) to remember the backoff until things calm down.
    def process_rejoins
      now = @clock.call
      @rejoins.delete_if do |_, entry|
        next now - entry[:last] >= REJOIN_RESET if entry[:at].nil?
        next false if entry[:at] > now
        next true unless wanted_channel?(entry[:channel])

        entry[:at] = nil
        send_raw(join_line(entry[:channel])) if @welcomed && !@roster.on?(entry[:channel], @nick)
        false
      end
    end

    # Channels the bot should be in on this network.
    def wanted_channel?(channel)
      (@config["channels"] + @channels.names + plugin_channel_names).any? { |c| Casemap.eq?(c, channel) }
    end

    # "JOIN #chan", with the key a plugin joined it with.
    def join_line(channel)
      channel_key = @plugin_channels_lock.synchronize { @plugin_channel_keys[key(channel)] }
      "JOIN #{channel}#{" #{channel_key}" if channel_key}"
    end
  end
end

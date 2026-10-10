# Answers the standard CTCP requests: VERSION, PING, TIME and CLIENTINFO
# (which lists every CTCP command the bot answers, other plugins' too).
# Requests are rate limited by the bot like commands.
#
# Install:  bin/gemdrop-docker plugin install contrib/plugins/ctcp.rb
# Settings (optional, under "plugins: ctcp:"):
#   version: "Gemdrop (Ruby)"                     the VERSION answer
#   answer: [VERSION, PING, TIME, CLIENTINFO]     which of these to answer
class Ctcp < Gemdrop::Plugin
  description "Answers CTCP VERSION, PING, TIME and CLIENTINFO"
  setting "version", default: "Gemdrop (Ruby)", type: :string, min: 1, max: 200
  setting "answer", default: %w[VERSION PING TIME CLIENTINFO], type: :list

  STANDARD = %w[VERSION PING TIME CLIENTINFO].freeze

  def setup
    unknown = settings["answer"].map { |c| c.to_s.upcase } - STANDARD
    raise Gemdrop::Error, "answer: unknown CTCP #{unknown.join(', ')} (known: #{STANDARD.join(', ')})" if unknown.any?
  end

  ctcp_handler("VERSION") { |_event| settings["version"] if answers?("VERSION") }
  ctcp_handler("PING") { |event| event.text.to_s[0, 64] if answers?("PING") }
  ctcp_handler("TIME") { |_event| Time.now.utc.strftime("%a %b %d %H:%M:%S %Y UTC") if answers?("TIME") }

  ctcp_handler("CLIENTINFO") do |_event|
    next unless answers?("CLIENTINFO")

    offered = ctcp_commands.reject { |c| STANDARD.include?(c) && !answers?(c) }
    (["ACTION"] + offered).uniq.join(" ")
  end

  private

  def answers?(command) = settings["answer"].any? { |c| c.to_s.casecmp?(command) }
end

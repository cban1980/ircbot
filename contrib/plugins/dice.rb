# Example plugin: dice and coins. Install it while the bot runs:
#
#   cp contrib/plugins/dice.rb instance/plugins/ && bin/gemdrop-docker reload
#
# By default its commands work by private message (/msg Gemdrop ROLL 2d6).
# To also allow "!roll 2d6" in channels, add to config.yml and reload:
#
#   plugins:
#     dice:
#       prefix: "!"
#       max_dice: 20      # the plugin's own setting (default 10)
class Dice < Gemdrop::Plugin
  description "Rolls dice and flips coins"
  defaults "max_dice" => 10, "max_sides" => 1000

  command "ROLL", usage: "ROLL [NdM]", help: "roll dice, e.g. 2d6 (default 1d6)" do |ctx, args|
    ctx.usage! if args.size > 1
    match = (args.first || "1d6").match(/\A(\d{0,3})d(\d{1,6})\z/i) or ctx.usage!
    count = match[1].empty? ? 1 : match[1].to_i
    sides = match[2].to_i
    unless count.between?(1, settings["max_dice"]) && sides.between?(2, settings["max_sides"])
      raise Gemdrop::Error, "Up to #{settings['max_dice']} dice with 2 to #{settings['max_sides']} sides."
    end

    rolls = Array.new(count) { rand(1..sides) }
    total = count > 1 ? " = #{rolls.sum}" : ""
    ctx.reply("#{ctx.nick} rolls #{count}d#{sides}: #{rolls.join(' + ')}#{total}")
  end

  command "FLIP", help: "flip a coin" do |ctx, _args|
    ctx.reply("#{ctx.nick} flips a coin: #{%w[heads tails].sample}")
  end
end

# frozen_string_literal: true

# Turns an optional rule (or house rule) on or off for a game that is already
# in progress on a table server, then checks the whole game still replays.
# If it doesn't, nothing is changed and the first move that breaks is shown.
#
# Usage:
#   bundle exec ruby scripts/table_rule.rb GAME_ID RULE [--off] [--anyway]
#
# --anyway saves the change even if a recorded move no longer works; the game
# then stops at that move until it is repaired on the Fix history tab.
#
# Example (1844, GB destination bonus with the Furka-Oberalp tile):
#   bundle exec ruby scripts/table_rule.rb 12 gb_destination_p4
#
# Everyone should reload the game page afterwards.

require 'json'
require_relative '../db'
require_relative '../models'
require 'require_all'
require_rel '../models'
require_relative '../lib/engine'

args = ARGV.dup
off = !args.delete('--off').nil?
anyway = !args.delete('--anyway').nil?
game_id, rule = args
abort('usage: table_rule.rb GAME_ID RULE [--off] [--anyway]') if !game_id || !rule

game = Game[game_id.to_i] or abort("No game #{game_id}")
meta = Engine.meta_by_title(game.title)
known = meta::OPTIONAL_RULES.map { |r| r[:sym].to_s }
abort("#{game.title} has no rule '#{rule}'. Its rules are: #{known.join(', ')}") unless known.include?(rule)

settings = JSON.parse(JSON.generate(game.settings.to_h))
rules = Array(settings['optional_rules']).map(&:to_s)
rules = off ? rules - [rule] : (rules | [rule])
recorded_rules = settings['recorded_optional_rules'] || settings['optional_rules'] || []
settings['optional_rules'] = rules

DB.transaction do
  game.update(settings: Sequel.pg_jsonb_wrap(settings))
  game.reload
  actions = game.actions(reload: true).map(&:to_h)
  engine = Engine::Game.load(game, actions: actions)
  abort('The rule did not take effect; nothing was changed.') if engine.optional_rules.include?(rule.to_sym) == off
  if engine.exception
    id = engine.broken_action&.id || engine.last_processed_action
    state = "with '#{rule}' #{off ? 'off' : 'on'}, the game breaks at action #{id}: #{engine.exception.message.sub(/ at\s*\z/,
                                                                                                                   '')}"
    unless anyway
      warn "Not changed: #{state}"
      warn 'Run again with ANYWAY=1 to change it regardless, then repair the game on its Fix history tab.'
      raise Sequel::Rollback
    end

    # Fix history reads the recorded moves under the rules they were played with.
    settings['recorded_optional_rules'] = recorded_rules
    game.update(settings: Sequel.pg_jsonb_wrap(settings))

    puts "#{rule} is now #{off ? 'off' : 'on'} for game #{game.id}, but #{state}"
    puts 'Reload the game page and repair it on the Fix history tab.'
    next
  end

  game.update(settings: Sequel.pg_jsonb_wrap(settings)) if settings.delete('recorded_optional_rules')
  puts "#{rule} is now #{off ? 'off' : 'on'} for game #{game.id} (#{game.title}); #{actions.size} moves replay cleanly."
  puts 'Reload the game page on every device.'
end

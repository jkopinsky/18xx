# frozen_string_literal: true

# Imports a game exported from 18xx.games (Tools > Clone Game, or a spec
# fixture) into the local database, so it can be opened and continued on a
# local server.
#
# Each player in the file gets a local account (created if missing) named after
# them, with the email <name>@table.local and the password given (default
# "password"). Player ids inside the actions are rewritten to the local ids.
#
# Usage:
#   bundle exec ruby scripts/import_table_game.rb path/to/game.json [password] [--actions N]
#
# --actions N imports only the first N actions (after undo/redo are resolved),
# leaving the game in progress at that point.
#
# Prints the local game id; open http://<server>:9292/game/<id>

require 'json'
require_relative '../db'
require_relative '../models'
require 'require_all'
require_rel '../models'
require_relative '../lib/engine'

args = ARGV.dup
limit = nil
if (flag = args.index('--actions'))
  limit = Integer(args[flag + 1])
  args.slice!(flag, 2)
end
path = args[0] or abort('usage: import_table_game.rb game.json [password] [--actions N]')
password = args[1] || 'password'
data = JSON.parse(File.read(path))
data['actions'] = Engine::Retcon.flatten(data['actions'] || [])
data['actions'] = data['actions'].first(limit) if limit

players = data['players'] || abort('no players in file')

def local_name(name)
  name.to_s.strip.gsub(/[^A-Za-z0-9_ -]/, '').squeeze(' ')[0, 30]
end

id_map = {}
users = players.map do |p|
  name = local_name(p['name'])
  email = "#{name.downcase.gsub(/[^a-z0-9]/, '')}@table.local"
  # Local table seats: no email notifications, and privacy consent recorded so
  # the site doesn't stop each player at the consent page.
  user = User.where(email: email).first ||
         User.create(name: name, email: email, password: password,
                     settings: Sequel.pg_jsonb_wrap('consent' => true, 'notifications' => 'none'))
  id_map[p['id']] = user.id
  id_map[p['id'].to_s] = user.id
  id_map[p['name']] = user.id
  user
end

remap = lambda do |obj|
  case obj
  when Hash
    obj.to_h do |k, v|
      player_ref = (k == 'entity' && obj['entity_type'] == 'player') || k == 'user'
      if player_ref && id_map.key?(v)
        [k, id_map[v]]
      else
        [k, remap.call(v)]
      end
    end
  when Array
    obj.map { |v| remap.call(v) }
  else
    obj
  end
end

settings = data['settings'] || {}
settings['seed'] ||= data['id'].to_s.scan(/\d+/).first.to_i if data['id']
settings['player_order'] = users.map(&:id)
settings['auto_routing'] = true unless settings.key?('auto_routing')

DB.transaction do
  game = Game.create(
    user_id: users.first.id,
    description: "Imported: #{data['description'] || File.basename(path)}",
    title: data['title'],
    max_players: data['max_players'] || players.size,
    min_players: data['min_players'] || players.size,
    settings: Sequel.pg_jsonb_wrap(settings),
    status: 'active',
    turn: data['turn'] || 1,
    round: data['round'] || 'Stock Round',
    acting: Sequel.pg_array(users.map(&:id)),
  )
  users.each { |u| GameUser.create(game_id: game.id, user_id: u.id) }

  # Replay as we go so each action can be credited to the player who controlled
  # the acting entity at that moment (a company's president at the time).
  # Crediting anyone else makes the log show it as a master-mode action.
  engine = Engine::Game.load(game, actions: [])
  (data['actions'] || []).each_with_index do |action, index|
    h = remap.call(action).merge('id' => index + 1)
    h.delete('user')
    entity = engine.get(h['entity_type'], h['entity'])
    actor = engine.acting_for_player(entity&.player)&.id
    actor = nil unless actor.is_a?(Integer)
    engine.process_action(h)
    raise engine.exception if engine.exception

    Action.create(
      game_id: game.id,
      user_id: actor || users.first.id,
      action_id: index + 1,
      action: Sequel.pg_jsonb_wrap(h),
    )
  end

  game.update(
    status: engine.finished ? 'finished' : 'active',
    turn: engine.turn,
    round: engine.round.name,
    acting: Sequel.pg_array(engine.active_players_id),
    result: Sequel.pg_jsonb_wrap(engine.finished ? engine.result : {}),
    finished_at: engine.finished ? Time.now : nil,
  )
  puts game.id
end

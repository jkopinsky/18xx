# frozen_string_literal: true

# Server-side helpers for table mode: writing a whole action history into the
# database, as an import or a committed retcon.
module TableHistory
  module_function

  # Replays the actions from the start and returns, for each one, the action as
  # the engine recorded it (with recomputed auto actions) and the user id of
  # the player who controlled the acting entity at that moment (a company's
  # president at the time). Crediting anyone else would make the game log show
  # the action as taken in master mode.
  #
  # Raises Engine::GameError if any action is illegal.
  def credited(game_source, actions, fallback_user_id)
    engine = Engine::Game.load(game_source, actions: [])
    rows = actions.map.with_index do |action, index|
      h = action.to_h.merge('id' => index + 1)
      h.delete('user')
      h.delete('auto_actions')
      entity = engine.get(h['entity_type'], h['entity'])
      actor = engine.acting_for_player(entity&.player)&.id
      actor = nil unless actor.is_a?(Integer)

      engine.process_action(h, add_auto_actions: true)
      raise Engine::GameError, "Action #{index + 1}: #{engine.exception.message}" if engine.exception

      [actor || fallback_user_id, engine.raw_actions.last.to_h]
    end
    [rows, engine]
  end

  # Replaces a game's whole action list. Returns the engine for the new state.
  def replace_actions!(game, actions, fallback_user_id)
    rows, engine = credited(game, actions, fallback_user_id)
    Action.where(game_id: game.id).delete
    rows.each do |user_id, action|
      Action.create(
        game_id: game.id,
        user_id: user_id,
        action_id: action['id'],
        action: Sequel.pg_jsonb_wrap(action),
      )
    end
    engine
  end

  # Saves the current history before it is replaced, so a retcon can be undone
  # by importing the backup. Returns the file path.
  def backup!(game, dir = ENV['RETCON_BACKUP_DIR'] || File.join(__dir__, '..', 'db', 'retcon_backups'))
    require 'fileutils'
    require 'json'
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "game-#{game.id}-#{Time.now.strftime('%Y%m%d-%H%M%S')}.json")
    data = game.to_h(include_actions: true)
    File.write(path, JSON.pretty_generate(data))
    path
  end
end

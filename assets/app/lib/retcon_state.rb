# frozen_string_literal: true

require 'lib/storage'

module Lib
  # The browser's side of a retcon: wraps an Engine::Retcon::Session and tracks
  # where the table is in the flow.
  #
  #   :choosing  - nothing changed yet; pick an action to fix
  #   :move      - the table must make a move (a replacement, an insertion, or
  #                in place of an action that no longer works); the game page
  #                shows the game at that point and the normal move screens
  #                feed the move into the retcon instead of the live game
  #   :clean     - the corrected history replays to the end; preview and commit
  class RetconState
    # This device's master mode before the fix turned it on. Kept in storage,
    # not just in memory, so a reload in the middle of a fix can put it back.
    PREVIOUS_MASTER_MODE = 'retcon_previous_master_mode'

    attr_reader :session, :status, :result, :display_game, :message, :base_action_count, :last_edit, :game_id

    def initialize(game_data, game)
      @game_data = game_data
      # The game this fix belongs to. The fix lives in the app-wide store, so
      # the game page checks this and drops the fix if another game is opened.
      @game_id = game_data['id']
      @session = Engine::Retcon::Session.new(game_data, original_game: game)
      @base_action_count = (game_data['actions'] || []).size
      @status = :choosing
      @result = nil
      @display_game = nil
      @message = nil
      @last_edit = nil
      @history = []
    end

    # Turns master mode on for the fix, remembering the previous setting.
    def take_master_mode!
      storage = Lib::Storage[@game_id] || {}
      previous = storage.key?(PREVIOUS_MASTER_MODE) ? storage[PREVIOUS_MASTER_MODE] : storage['master_mode']
      Lib::Storage[@game_id] = storage.merge('master_mode' => true, PREVIOUS_MASTER_MODE => previous || false)
    end

    # Puts master mode back the way it was before the fix.
    def restore_master_mode!
      RetconState.restore_master_mode(@game_id)
    end

    def self.restore_master_mode(game_id)
      storage = Lib::Storage[game_id]
      return if !storage || !storage.key?(PREVIOUS_MASTER_MODE)

      restored = storage.dup
      restored['master_mode'] = restored.delete(PREVIOUS_MASTER_MODE)
      Lib::Storage[game_id] = restored
    end

    def for_game?(game_data)
      game_data && game_data['id'].to_s == @game_id.to_s
    end

    def awaiting_move?
      @status == :move
    end

    def clean?
      @status == :clean
    end

    def delete(id, description)
      @last_edit = "Deleted action #{id}: #{description}"
      @session.delete(id)
      apply(@session.replay)
    end

    def replace(id, description)
      @last_edit = "Replacing action #{id}: #{description}"
      @display_game = @session.open_slot(id, :replace)
      @message = 'Make the replacement move on the Game tab.'
      @status = :move
    end

    def insert_before(id, description)
      @last_edit = "Inserting a move before action #{id}: #{description}"
      @display_game = @session.open_slot(id, :insert)
      @message = 'Make the missing move on the Game tab.'
      @status = :move
    end

    # A move made on the Game tab while awaiting one.
    def fill(action_h)
      remember
      if @session.slot
        apply(@session.fill_slot(action_h))
      else
        apply(@session.resolve(action_h))
      end
    rescue StandardError
      undo_step
      raise
    end

    def skip
      remember
      apply(@session.skip)
    end

    # Uses the suggested equivalent of a recorded action that names share
    # certificates which no longer exist.
    def use_equivalent
      equivalent = @result&.suggestion&.dig('equivalent')
      raise Engine::GameError, 'Nothing to use instead' unless equivalent

      fill(equivalent)
    end

    # True when a move or skip made during this fix can be taken back.
    def can_undo_step?
      !@history.empty?
    end

    # Takes back the last move or skip made during this fix.
    def undo_step
      snap = @history.pop
      return false unless snap

      @session.restore(snap[:session])
      @result = snap[:result]
      @status = snap[:status]
      @display_game = snap[:display_game]
      @message = snap[:message]
      true
    end

    # What the table's next move will do, for the banner and the Fix history
    # tab: nil when no move is awaited.
    def next_move_note
      return nil unless awaiting_move?
      return 'Your next move goes into the gap you opened.' if @session.slot

      if @result&.kind == :missing_share
        return 'This recorded action can\'t be used as it is: skip it, use the equivalent shares, or make the ' \
               'move again on the Game tab (it takes its place).'
      end

      broken = @session.broken_recorded_action
      return nil if !broken || !@result

      game = @result.game
      actor = game.get(broken['entity_type'], broken['entity'])&.name || broken['entity'].to_s
      what = broken['type'].to_s.tr('_', ' ')
      current = game.current_entity
      return nil unless current

      type = current.player? ? 'player' : current.class.name.split('::').last.downcase
      move = { 'entity' => current.id, 'entity_type' => type }
      if @session.resolve_mode(move) == :replace
        "Your next move for #{actor} replaces the recorded \"#{what}\" (action #{broken['id']})."
      else
        "Your next move for #{current.name} is added before the recorded \"#{actor}: #{what}\" " \
          "(action #{broken['id']}), which is tried again afterwards."
      end
    end

    def preview
      @result ? @session.preview(@result) : []
    end

    def changes
      @result ? @result.changes : []
    end

    private

    def remember
      @history << {
        session: @session.snapshot,
        result: @result,
        status: @status,
        display_game: @display_game,
        message: @message,
      }
    end

    def apply(result)
      @result = result
      if result.broken?
        @status = :move
        @display_game = result.game
        @message = result.error_message
      else
        @status = :clean
        @display_game = nil
        @message = nil
      end
      result
    end
  end
end

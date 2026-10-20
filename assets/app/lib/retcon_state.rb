# frozen_string_literal: true

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
    attr_reader :session, :status, :result, :display_game, :message, :base_action_count, :last_edit

    def initialize(game_data, game)
      @game_data = game_data
      @session = Engine::Retcon::Session.new(game_data, original_game: game)
      @base_action_count = (game_data['actions'] || []).size
      @status = :choosing
      @result = nil
      @display_game = nil
      @message = nil
      @last_edit = nil
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
      if @session.slot
        apply(@session.fill_slot(action_h))
      else
        apply(@session.resolve(action_h))
      end
    end

    def skip
      apply(@session.skip)
    end

    def preview
      @result ? @session.preview(@result) : []
    end

    def changes
      @result ? @result.changes : []
    end

    private

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

# frozen_string_literal: true

module Engine
  # Warm spares for undo.
  #
  # Undo (and redo) rebuild the game by replaying every action from the start,
  # which takes seconds late in a long game in the browser. The cache keeps
  # spare copies of the game replayed up to a checkpoint (the start of the
  # current round). When the game is rebuilt with an action list whose prefix up
  # to the checkpoint is unchanged, a spare is handed over and only the actions
  # after the checkpoint are replayed. Games are deterministic, so the result is
  # the same as a full replay.
  #
  # Spares are built a few actions at a time (#step), so the browser can do it
  # in the background without freezing the page. Each spare is used once; the
  # cache moves on to the rebuilt game with the spares it has left, so several
  # undos in a row stay fast.
  class ReplayCache
    SPARES = 2

    attr_reader :checkpoint_id

    def initialize(game, checkpoint_id: nil, spares: SPARES)
      @template = game
      @checkpoint_id = checkpoint_id || game.round_history.last || 0
      @raw = game.raw_actions.take_while { |a| a['id'] <= @checkpoint_id }.map(&:dup)
      @filtered, = Game::Base.filtered_actions(@raw)
      @kept_ids = @filtered.compact.map { |a| a['id'] }
      @wanted = spares
      @ready = []
      @building = nil
      @pos = 0
      @failed = false
    end

    def ready?
      !@ready.empty?
    end

    def ready_count
      @ready.size
    end

    def complete?
      @failed || @ready.size >= @wanted
    end

    # Does up to n actions of work on the next spare. Returns true when there
    # is nothing left to build.
    def step(n = 25)
      return true if complete?

      unless @building
        @building = @template.blank_copy
        @building.instance_variable_set(:@raw_all_actions, @raw)
        @building.instance_variable_set(:@filtered_actions, @filtered)
        @pos = 0
      end

      @pos = [@pos + n, @raw.size].min
      @building.process_to_action(@pos.zero? ? 0 : @raw[@pos - 1]['id'])
      if @building.exception
        @failed = true
        @building = nil
      elsif @pos >= @raw.size
        @ready << @building
        @building = nil
      end
      complete?
    end

    # Builds all spares at once (tests, or when there is no event loop).
    def build!
      step(@raw.size + 1) until complete?
      ready?
    end

    # Returns a game for this full action list, using a spare if the list's
    # prefix still matches; nil if no spare can be used. The spare is consumed.
    def take(actions)
      return nil unless ready?
      return nil unless actions.take_while { |a| a['id'] <= @checkpoint_id }.size == @raw.size

      filtered, = Game::Base.filtered_actions(actions)
      prefix_ids = filtered.compact.map { |a| a['id'] }.select { |id| id <= @checkpoint_id }
      return nil unless prefix_ids == @kept_ids

      spare = @ready.shift
      spare.send(:initialize_actions, actions)
      spare.exception ? nil : spare
    end
  end
end

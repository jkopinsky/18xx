# frozen_string_literal: true

module Engine
  # Retcon: edit a game's past actions and replay forward under full rules.
  #
  # Typical use:
  #   session = Engine::Retcon::Session.new(game_data)   # game JSON as a Hash
  #   session.replace(42, new_action_hash)                # or delete(42) / insert_after(41, hash)
  #   result = session.replay
  #   while result.broken?
  #     # show result.error_message / result.broken_action to the table, then either:
  #     result = session.resolve(replacement_hash)        # or session.skip
  #   end
  #   result.game      # the replayed game
  #   session.actions  # the new action list to commit
  #
  # Replay trusts stored data only for actions before the first edit. Every
  # action from the first edit onwards is replayed with its automatic follow-up
  # actions recomputed, and stored route results (revenue, hexes, nodes) are
  # dropped so that routes are re-validated against the new map.
  module Retcon
    ROUTE_DERIVED_KEYS = %w[revenue revenue_str hexes nodes subsidy].freeze
    # Session-only note on each recorded action: which round and step
    # processed it in the original game. Never stored or sent anywhere.
    STEP_TAG = '_retcon_step'

    COMPARE_IGNORED_KEYS = %w[id created_at].freeze

    module_function

    def untag(action)
      return action unless action.key?(STEP_TAG)

      action.reject { |k, _| k == STEP_TAG }
    end

    # "Engine::Game::G1817::Step::Track" => "Track"
    def step_name(klass)
      klass.name.to_s.split('::').last.gsub(/([a-z])([A-Z])/, '\\1 \\2')
    end

    # "Engine::Round::Stock" => "the stock round"
    def round_title(klass)
      name = klass.name.to_s.split('::').last.gsub(/([a-z])([A-Z])/, '\\1 \\2').downcase
      name = "#{name} round" unless name.end_with?('round')
      "the #{name}"
    end

    # Where a recorded action's round stands compared with the round now
    # being played, from its step note:
    #   :over    - its round has ended (a different kind of round is on now)
    #   :later   - its round has not started yet (this round runs longer
    #              than it did in the original game)
    #   :current - the same round, or nothing to go on
    def recorded_round(game, tag)
      return :current if !tag || !tag[3]

      now = game.round_history.size
      return :current if tag[3] == now && tag[0] == game.round.class
      return :later if tag[3] >= now
      # An earlier round of the same kind (two operating rounds in a row):
      # let the turn order decide.
      return :current if tag[0] == game.round.class

      :over
    end

    # Where an entity stands in the current operating round's order:
    #   :over     - it has already operated this round
    #   :upcoming - it operates later this round
    #   :current  - it is operating now
    #   :unknown  - not an operating round, or not one of its operators
    def turn_status(game, entity_id)
      round = game.round
      return :unknown if !round.respond_to?(:operating?) || !round.operating?

      entities = round.entities
      index = entities.index { |e| e.id.to_s == entity_id.to_s }
      return :unknown unless index

      current = round.entity_index
      return :current if index == current

      index < current ? :over : :upcoming
    end

    def deep_dup(obj)
      case obj
      when Hash
        obj.transform_values { |v| deep_dup(v) }
      when Array
        obj.map { |v| deep_dup(v) }
      else
        obj
      end
    end

    # Resolves undo and redo into the actions that actually happened, drops the
    # undo/redo entries themselves, and renumbers ids 1..n so that inserting or
    # deleting actions cannot break id references.
    def flatten(actions)
      flatten_with_ids(actions).first
    end

    # Like flatten, and also returns the original id of each kept action, so
    # the game log (which is keyed by original ids) can describe it.
    def flatten_with_ids(actions)
      filtered, _active_undos = Engine::Game::Base.filtered_actions(actions)
      kept = filtered.compact
      flat = kept.each_with_index.map do |action, index|
        copy = deep_dup(action)
        copy['id'] = index + 1
        copy
      end
      [flat, kept.map { |a| a['id'] }]
    end

    def renumber!(actions)
      actions.each_with_index { |a, i| a['id'] = i + 1 }
      actions
    end

    # Prepares a stored action for replay with recomputed results.
    def scrub(action)
      h = deep_dup(action)
      h.delete('auto_actions')
      h.delete(STEP_TAG)
      if h['routes'].is_a?(Array)
        h['routes'] = h['routes'].map do |route|
          route.reject { |k, _| ROUTE_DERIVED_KEYS.include?(k) }
        end
      end
      h
    end

    TRAIN_KEYS = %w[train exchange].freeze

    # Applies a map of renumbered trains (old id => new id) to an action.
    def remap_trains(action, remap)
      return action if remap.nil? || remap.empty?

      h = deep_dup(action)
      TRAIN_KEYS.each { |k| h[k] = remap[h[k]] if h[k] && remap.key?(h[k]) }
      if h['routes'].is_a?(Array)
        h['routes'].each { |r| r['train'] = remap[r['train']] if remap.key?(r['train']) }
      end
      h
    end

    def comparable(action)
      return nil unless action

      strip = lambda do |obj|
        case obj
        when Hash
          obj.each_with_object({}) do |(k, v), out|
            next if COMPARE_IGNORED_KEYS.include?(k)

            out[k] = strip.call(v)
          end
        when Array
          obj.map { |v| strip.call(v) }
        else
          obj
        end
      end
      strip.call(action)
    end

    def route_revenues(action)
      return nil if !action || !action['routes'].is_a?(Array)

      revenues = action['routes'].map { |r| r['revenue'] }
      revenues.all? ? revenues : nil
    end

    def round_label(round)
      klass = round.class
      return klass.short_name if klass.respond_to?(:short_name)
      return klass.round_name if klass.respond_to?(:round_name)

      klass.name.split('::').last
    end

    # A compact picture of the game for before/after comparisons.
    def summary(game)
      players = game.players.to_h do |p|
        shares = game.corporations.each_with_object({}) do |c, h|
          pct = p.percent_of(c)
          h[c.name] = pct if pct && !pct.zero?
        end
        [p.name, {
          'cash' => p.cash,
          'value' => game.player_value(p),
          'shares' => shares,
          'companies' => p.companies.map(&:sym).sort,
        }]
      end
      corporations = game.corporations.select(&:ipoed).to_h do |c|
        info = {
          'cash' => c.cash,
          'share_price' => c.share_price&.price,
          'trains' => c.trains.map(&:name).sort,
          'president' => c.owner&.name,
        }
        info['loans'] = c.loans.size if c.respond_to?(:loans) && c.loans
        [c.name, info]
      end
      {
        'round' => "#{round_label(game.round)} #{game.turn}.#{game.round.round_num}",
        'finished' => game.finished,
        'bank_cash' => game.unlimited_bank? ? nil : game.bank.cash,
        'players' => players,
        'corporations' => corporations,
      }
    end

    # Returns a list of [path, before, after] for every value that differs.
    def diff(before, after, path = [])
      if before.is_a?(Hash) && after.is_a?(Hash)
        (before.keys | after.keys).flat_map { |k| diff(before[k], after[k], path + [k]) }
      elsif before == after
        []
      else
        [[path, before, after]]
      end
    end

    class Result
      attr_reader :status, :game, :broken_index, :broken_action, :error, :changes, :kind

      def initialize(status:, game:, broken_index: nil, broken_action: nil, error: nil, changes: [], kind: nil,
                     recorded_step: nil)
        @kind = kind
        @recorded_step = recorded_step
        @status = status
        @game = game
        @broken_index = broken_index
        @broken_action = broken_action
        @error = error
        @changes = changes
      end

      def broken?
        @status == :broken
      end

      def clean?
        @status == :clean
      end

      # Plain-words description of what broke, naming the round and the actor.
      def error_message
        return nil unless @error

        msg = friendly(@error.message.to_s)
        msg = @error.class.name if msg.empty?
        round = "#{Retcon.round_label(@game.round)} #{@game.turn}.#{@game.round.round_num}"
        "#{round}: #{actor_name} can no longer #{action_words}. #{msg}"
      end

      # A hint for the table, never applied automatically: a pass by someone
      # whose turn it no longer is has no effect on money or holdings, so
      # skipping it is usually right.
      def suggestion
        return nil if !broken? || !@broken_action

        current = @game.current_entity
        return nil unless current
        return same_entity_suggestion(current) if current.id.to_s == @broken_action['entity'].to_s

        case Retcon.recorded_round(@game, @recorded_step)
        when :over
          return {
            'choice' => 'skip',
            'reason' => "This was recorded in #{Retcon.round_title(@recorded_step[0])}, which is already over " \
                        "(the game is in #{Retcon.round_title(@game.round.class)} now), so it can no longer " \
                        'happen. Skip it, then check the preview, since it may have moved money or shares in ' \
                        'the original game.',
          }
        when :later
          # Recorded in a round still to come: the round in play needs moves
          # the original game didn't have (a stock round running longer, say).
          return {
            'choice' => 'move',
            'reason' => "This was recorded in #{Retcon.round_title(@recorded_step[0])}, but the game is still in " \
                        "#{Retcon.round_title(@game.round.class)}: the change means this round needs more moves " \
                        "first (for example everyone passing again). Make them, starting with #{current.name}; " \
                        "the recorded actions are tried again afterwards. Don't skip it.",
          }
        end

        case Retcon.turn_status(@game, @broken_action['entity'])
        when :upcoming
          # The company now operating has a decision the original game did not
          # have (cash for a loan payoff, a train it can now afford), and no
          # recorded action answers it. The recorded action belongs to a later
          # turn: skipping it would throw away a move that is still to come.
          {
            'choice' => 'move',
            'reason' => "It is still #{current.name}'s turn, and #{actor_name}'s turn comes later. " \
                        "#{current.name} has a decision here#{step_note} that it did not have in the original " \
                        "game. Make it, and #{actor_name}'s recorded #{action_words} is tried again " \
                        "afterwards. Don't skip it.",
          }
        when :over
          if @broken_action['type'] == 'pass'
            {
              'choice' => 'skip',
              'reason' => "It is #{current.name}'s turn, not #{actor_name}'s, " \
                          'and a pass changes no money or holdings.',
            }
          else
            # The change ended this entity's turn before the recorded action: it
            # can no longer happen at all. Skipping is usually right, but it did
            # move money or shares, so the table should check the preview.
            {
              'choice' => 'skip',
              'reason' => "#{actor_name}'s turn is already over (it is #{current.name}'s turn now), " \
                          "so this #{action_words} can no longer happen. Skip it, then check the " \
                          'preview, since it moved money or shares in the original game.',
            }
          end
        else
          # The same kind of round, but not an operating round (a stock round,
          # an auction): the order of play shifted, so this is usually a move
          # still to come.
          {
            'choice' => 'move',
            'reason' => "It is #{current.name}'s turn now, not #{actor_name}'s: after the change the order of " \
                        "play is different. Make #{current.name}'s move#{step_note}; #{actor_name}'s recorded " \
                        "#{action_words} is tried again afterwards. Only if #{actor_name} can no longer act in " \
                        'this round at all, skip it and check the preview.',
          }
        end
      end

      def step_note
        step = begin
          @game.round.active_step&.description
        rescue StandardError
          nil
        end
        step ? " (\"#{step}\")" : ''
      end

      # The entity is still acting but has moved past the step where the
      # recorded action belonged (the route step was skipped because there is
      # no route now, say).
      def same_entity_suggestion(current)
        return nil if @kind == :new_decision
        return nil if @game.round.actions_for(current).include?(@broken_action['type'])

        step = begin
          @game.round.active_step&.description
        rescue StandardError
          nil
        end
        at = step ? " (the game is at \"#{step}\")" : ''
        {
          'choice' => 'skip',
          'reason' => "#{actor_name} is past the point in its turn where it could #{action_words}#{at}, " \
                      'so this recorded action can no longer happen. Skip it, then check the preview, ' \
                      'since it may have moved money or shares in the original game.',
        }
      end

      HOUSEKEEPING_ACTIONS = %w[end_game log message undo redo].freeze

      def player_actions(actions)
        actions.reject { |a| HOUSEKEEPING_ACTIONS.include?(a) || a.start_with?('program_') }
      end

      # Rewords common engine messages for the table.
      def friendly(msg)
        if (m = msg.match(/Blocking step (.+?) cannot process action (\w+)/))
          step = m[1]
          return "The game is now at the \"#{step}\" step, where a #{m[2].tr('_', ' ')} is not possible."
        end

        msg.gsub(/\b([a-z]+(?:_[a-z]+)+)\b/) { Regexp.last_match(1).tr('_', ' ') }
      end

      def actor_name
        return nil unless @broken_action

        entity = @game.get(@broken_action['entity_type'], @broken_action['entity'])
        entity&.name || @broken_action['entity'].to_s
      end

      def action_words
        @broken_action ? @broken_action['type'].to_s.tr('_', ' ') : 'act'
      end

      # Who should act at the broken point, and which action types the rules
      # allow them, for offering a replacement move.
      def expected
        return nil unless broken?

        entity = @game.current_entity
        {
          'entity' => entity&.name,
          'entity_id' => entity&.id,
          'actions' => entity ? player_actions(@game.round.actions_for(entity)).map { |a| a.tr('_', ' ') } : [],
        }
      end
    end

    class Session
      attr_reader :original_actions, :dirty_from, :changes, :source_ids, :slot

      # data: the game as a Hash, as found in a game's JSON export.
      # original_game: the game already loaded from that data, if the caller
      # has one (saves a replay).
      def initialize(data, original_game: nil)
        @data = data
        @original_actions, @source_ids = Retcon.flatten_with_ids(data['actions'] || [])
        @actions = Retcon.deep_dup(@original_actions)
        @original_game = original_game
        @dirty_from = nil
        @broken_index = nil
        @slot = nil
        @changes = []
        @train_remap = {}
        @broken_kind = nil
        @broken_game = nil
        @tagged = false
      end

      # The action list to commit.
      def actions
        @actions.map { |a| Retcon.untag(a) }
      end

      # Notes on each recorded action which step processed it in the original
      # game, before anything is edited. A pass goes to whichever step is
      # blocking, so after an edit a recorded pass could otherwise land on a
      # different decision than the one the table made.
      def tag_steps!
        return if @tagged

        @tagged = true
        steps = original_game.action_steps
        @actions.each_with_index do |a, i|
          id = @original_ids_flat ? i + 1 : @source_ids[i]
          a[STEP_TAG] = steps[id] if steps[id]
        end
      end

      # Opens a place in history where a new move is needed: :replace removes
      # the action with this id and asks for one in its place, :insert asks for
      # a move just before it. Returns the game as it stood at that point, for
      # the table to make the move on.
      def open_slot(id, mode)
        tag_steps!
        idx = index_of(id)
        @actions.delete_at(idx) if mode == :replace
        Retcon.renumber!(@actions)
        @dirty_from = [@dirty_from || idx, idx].min
        @broken_index = nil
        @slot = idx
        load(@actions[0...idx])
      end

      # Fills the open slot with the table's move and replays forward.
      def fill_slot(action)
        raise GameError, 'No open slot' unless @slot

        idx = @slot
        @slot = nil
        @actions.insert(idx, Retcon.deep_dup(action))
        Retcon.renumber!(@actions)
        @changes = []
        @train_remap = {}
        continue_from(load(@actions[0...idx]), idx)
      end

      # True once anything has been changed.
      def edited?
        !@dirty_from.nil?
      end

      def load(actions)
        Engine::Game.load(@data, actions: actions.map { |a| Retcon.untag(a) })
      end

      def original_game
        return @original_game if @original_game

        @original_ids_flat = true
        @original_game = load(@original_actions)
      end

      def index_of(id)
        idx = @actions.index { |a| a['id'] == id }
        raise GameError, "No action with id #{id}" unless idx

        idx
      end

      def replace(id, action)
        tag_steps!
        idx = index_of(id)
        @actions[idx] = Retcon.deep_dup(action)
        mark_dirty(idx)
        self
      end

      def delete(id)
        tag_steps!
        idx = index_of(id)
        @actions.delete_at(idx)
        mark_dirty(idx)
        self
      end

      # Inserts an action after the given id (0 = at the very start).
      def insert_after(id, action)
        tag_steps!
        idx = id.zero? ? 0 : index_of(id) + 1
        @actions.insert(idx, Retcon.deep_dup(action))
        mark_dirty(idx)
        self
      end

      # Replays from the earliest edit to the end, stopping at the first action
      # that the rules reject.
      def replay
        start = @dirty_from || @actions.size
        game = load(@actions[0...start])
        raise game.exception if game.exception

        @changes = []
        @train_remap = {}
        continue_from(game, start)
      end

      # Uses the table's move at the point where replay stopped.
      #
      # A move by the entity whose recorded action broke takes that action's
      # place. A move by anyone else (the change already ended the recorded
      # entity's turn, say) is added before the broken action, which is then
      # tried again: a recorded action is only ever replaced by a move for the
      # same entity, so the table's moves and the recorded ones never drift
      # out of step.
      def resolve(action)
        raise GameError, 'Nothing to resolve' unless @broken_index

        idx = @broken_index
        if resolve_mode(action) == :replace
          @actions[idx] = Retcon.deep_dup(action)
        else
          @actions.insert(idx, Retcon.deep_dup(action))
        end
        Retcon.renumber!(@actions)
        continue_from(load(@actions[0...idx]), idx)
      end

      # :replace or :insert, for a move offered at the broken point.
      #
      # A move entered during the fix that was refused is always replaced.
      # Otherwise the move replaces the recorded action only when it is the same
      # decision: same entity, and the recorded action's kind of move is still
      # on offer but was refused (it can no longer afford the train, say).
      # When the game now stops at a different decision first (a new token
      # placement, a loan step reached early), the move is added before the
      # recorded action, which is tried again afterwards.
      def resolve_mode(action)
        broken = @broken_index && @actions[@broken_index]
        return :insert unless broken

        # A move entered during this fix that the rules refused: the next
        # move is its correction.
        return :replace unless broken[STEP_TAG]

        same = broken['entity'].to_s == action['entity'].to_s &&
               broken['entity_type'].to_s == action['entity_type'].to_s
        return :insert unless same
        return :insert if @broken_kind == :new_decision

        game = @broken_game
        entity = game&.get(broken['entity_type'], broken['entity'])
        return :replace unless entity

        game.round.actions_for(entity).include?(broken['type']) ? :replace : :insert
      end

      # The recorded action that stopped the replay, if any.
      def broken_recorded_action
        @broken_index && @actions[@broken_index]
      end

      # Everything needed to step back to this point.
      def snapshot
        {
          actions: Retcon.deep_dup(@actions),
          dirty_from: @dirty_from,
          broken_index: @broken_index,
          broken_kind: @broken_kind,
          broken_game: @broken_game,
          slot: @slot,
          changes: Retcon.deep_dup(@changes),
          train_remap: @train_remap.dup,
        }
      end

      def restore(snap)
        @actions = Retcon.deep_dup(snap[:actions])
        @dirty_from = snap[:dirty_from]
        @broken_index = snap[:broken_index]
        @broken_kind = snap[:broken_kind]
        @broken_game = snap[:broken_game]
        @slot = snap[:slot]
        @changes = Retcon.deep_dup(snap[:changes])
        @train_remap = snap[:train_remap].dup
        self
      end

      # Drops the broken action and carries on.
      def skip
        raise GameError, 'Nothing to skip' unless @broken_index

        idx = @broken_index
        @actions.delete_at(idx)
        Retcon.renumber!(@actions)
        continue_from(load(@actions[0...idx]), idx)
      end

      # What the table is agreeing to: every summary value that differs between
      # the original game and the replayed one.
      def preview(result)
        Retcon.diff(Retcon.summary(original_game), Retcon.summary(result.game))
      end

      private

      def mark_dirty(idx)
        Retcon.renumber!(@actions)
        @dirty_from = [@dirty_from || idx, idx].min
        @broken_index = nil
        @broken_kind = nil
      end

      def continue_from(game, start)
        done = []
        i = start
        while i < @actions.size
          stored = @actions[i]
          attempt = Retcon.remap_trains(Retcon.scrub(stored), @train_remap)

          case (verdict = check_recorded_pass(game, stored))
          when :drop
            @actions[start...i] = done
            done = []
            start = i
            drop_pass(game, i, attempt, @pass_drop_reason)
            next
          when GameError
            @actions[start...i] = done
            @broken_index = i
            @broken_kind = :new_decision
            @broken_game = game
            return Result.new(status: :broken, game: game, broken_index: i, kind: :new_decision,
                              broken_action: attempt, error: verdict, changes: @changes,
                              recorded_step: stored[STEP_TAG])
          end

          game.process_action(attempt, add_auto_actions: true)

          if game.exception
            error = game.exception
            # Keep what replayed successfully (with recomputed auto actions) and
            # rebuild from that clean list, so no partial state from the failed
            # action leaks into the game shown to the table. The game's own
            # raw_actions is not used here: when an action fails before it is
            # recorded, the engine's error handler drops the previous one.
            @actions[start...i] = done
            done = []
            start = i
            game = load(@actions[0...i])

            if stale_pass?(game, attempt, stored)
              drop_pass(game, i, attempt, 'its turn had already ended')
              next
            end

            repaired = repair_train_purchase(game, attempt)
            unless repaired
              game = load(@actions[0...i]) if game.exception
              @broken_index = i
              @broken_kind = :rejected
              @broken_game = game
              return Result.new(status: :broken, game: game, broken_index: i, kind: :rejected,
                                broken_action: attempt, error: error, changes: @changes,
                                recorded_step: stored[STEP_TAG])
            end
          end

          replayed = Retcon.deep_dup(game.raw_actions.last)
          replayed[STEP_TAG] = stored[STEP_TAG] if stored[STEP_TAG]
          done << replayed
          note_change(i, stored, replayed)
          i += 1
        end

        @broken_index = nil
        @broken_kind = nil
        @broken_game = nil
        @actions[start, @actions.size - start] = done
        Result.new(status: :clean, game: game, changes: @changes)
      end

      # A recorded pass by an entity that is no longer acting: the change ended
      # its turn early (it can no longer afford a train, say), so the pass that
      # ended its turn in the original game has nothing left to do. A pass
      # moves no money or holdings, so it is dropped without asking.
      def stale_pass?(game, attempt, stored)
        return false unless attempt['type'] == 'pass'

        active = game.round.active_entities.map { |e| e.id.to_s }
        return false if active.empty? || active.include?(attempt['entity'].to_s)

        # Only a company that has already operated in this operating round.
        # Anywhere else (a stock round that now runs longer, a pass recorded
        # for the next round) the pass is a real decision still to come, so
        # it is kept and the table is asked.
        case Retcon.recorded_round(game, stored[STEP_TAG])
        when :over then true # it answered a decision in a round that has ended
        when :later then false
        else Retcon.turn_status(game, attempt['entity']) == :over
        end
      end

      def drop_pass(game, index, attempt, reason)
        entity = game.get(attempt['entity_type'], attempt['entity'])
        @actions.delete_at(index)
        Retcon.renumber!(@actions)
        @changes << {
          'index' => index,
          'id' => attempt['id'],
          'type' => 'pass',
          'kind' => 'stale_pass_dropped',
          'before' => entity&.name || attempt['entity'].to_s,
          'after' => nil,
          'reason' => reason,
        }
      end

      # The step a pass by this entity would go to now: the same search the
      # round itself makes.
      def pass_target(round, entity)
        round.steps.each do |step|
          next unless step.active?
          return step if step.actions(entity).include?('pass')
          return nil if step.blocking?
        end
        nil
      end

      # A recorded pass answers one particular decision (no second tile lay,
      # no token, no train). After an edit the game can reach that pass at a
      # different decision. Returns:
      #   :drop     - the decision it answered was already settled or never
      #               came up this time (no token was possible after the new
      #               tile lay, say), so the pass has nothing to do
      #   GameError - a decision the original game did not have here comes up
      #               first (a token is now possible, say); the table is asked
      #   nil       - same decision as before, or nothing to check
      def check_recorded_pass(game, stored)
        tag = stored[STEP_TAG]
        return nil if stored['type'] != 'pass' || !tag

        round = game.round
        entity = game.get(stored['entity_type'], stored['entity'])
        return nil unless entity
        return nil unless round.active_entities.include?(entity) # turn over: handled as a stale pass
        return nil if round.class != tag[0] # a different round: let the rules decide

        target = pass_target(round, entity)
        return nil unless target

        steps = round.steps
        now = steps.index(target)
        was = tag[2] if tag[2] && steps[tag[2]].instance_of?(tag[1])
        was ||= steps.index { |s| s.instance_of?(tag[1]) }
        return nil if was == now

        if was && now && was < now
          @pass_drop_reason = "the #{describe_step(steps[was])} decision it answered had already been settled"
          return :drop
        end

        GameError.new("This pass was for the \"#{describe_step(was && steps[was], tag[1])}\" step, " \
                      "but #{entity.name} now has a decision at \"#{describe_step(target)}\" first, " \
                      'which it did not have here in the original game. Make that decision; the recorded ' \
                      'pass is checked again afterwards.')
      end

      def describe_step(step, klass = nil)
        step ? step.description : Retcon.step_name(klass)
      rescue NotImplementedError, StandardError
        Retcon.step_name(klass || step.class)
      end

      # Trains are identified by serial number ("2-1" is the second 2-train),
      # so adding or removing a purchase earlier in history shifts which
      # physical train later purchases refer to. When a purchase from the depot
      # fails, try the next available train of the same type instead, and
      # renumber that train in every later action. Returns true when the
      # repaired action was processed.
      def repair_train_purchase(game, attempt)
        return false if attempt['type'] != 'buy_train' || !attempt['train']

        old_id = attempt['train']
        name = original_game.train_by_id(old_id)&.name || old_id.to_s.rpartition('-').first
        candidate = game.depot.depot_trains.find { |t| t.name == name && t.id != old_id }
        return false unless candidate

        fixed = attempt.merge('train' => candidate.id)
        game.process_action(fixed, add_auto_actions: true)
        if game.exception
          # Leave the game exactly as it was before the attempt.
          return false
        end

        @train_remap[old_id] = candidate.id
        @changes << {
          'index' => game.raw_actions.size - 1,
          'id' => game.raw_actions.last['id'],
          'type' => 'buy_train',
          'kind' => 'train_renumbered',
          'before' => old_id,
          'after' => candidate.id,
        }
        true
      end

      # Flags actions that replayed without error but now mean something
      # different: other automatic actions fired, or a route paid differently.
      def note_change(index, stored, replayed)
        before_auto = Retcon.comparable(stored['auto_actions'])
        after_auto = Retcon.comparable(replayed['auto_actions'])
        if stored.key?('auto_actions') && before_auto != after_auto
          @changes << {
            'index' => index,
            'id' => replayed['id'],
            'type' => replayed['type'],
            'kind' => 'auto_actions',
            'before' => before_auto,
            'after' => after_auto,
          }
        end

        before_rev = Retcon.route_revenues(stored)
        after_rev = Retcon.route_revenues(replayed)
        return if !before_rev || before_rev == after_rev

        @changes << {
          'index' => index,
          'id' => replayed['id'],
          'type' => replayed['type'],
          'kind' => 'route_revenue',
          'before' => before_rev,
          'after' => after_rev,
        }
      end
    end
  end
end

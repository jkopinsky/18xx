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
    COMPARE_IGNORED_KEYS = %w[id created_at].freeze

    module_function

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
      filtered, _active_undos = Engine::Game::Base.filtered_actions(actions)
      filtered.compact.each_with_index.map do |action, index|
        flat = deep_dup(action)
        flat['id'] = index + 1
        flat
      end
    end

    def renumber!(actions)
      actions.each_with_index { |a, i| a['id'] = i + 1 }
      actions
    end

    # Prepares a stored action for replay with recomputed results.
    def scrub(action)
      h = deep_dup(action)
      h.delete('auto_actions')
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
      attr_reader :status, :game, :broken_index, :broken_action, :error, :changes

      def initialize(status:, game:, broken_index: nil, broken_action: nil, error: nil, changes: [])
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

        msg = @error.message.to_s
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
        if @broken_action['type'] == 'pass' && current && current.id.to_s != @broken_action['entity'].to_s
          return {
            'choice' => 'skip',
            'reason' => "It is #{current.name}'s turn, not #{actor_name}'s, " \
                        'and a pass changes no money or holdings.',
          }
        end

        nil
      end

      HOUSEKEEPING_ACTIONS = %w[end_game log message undo redo].freeze

      def player_actions(actions)
        actions.reject { |a| HOUSEKEEPING_ACTIONS.include?(a) || a.start_with?('program_') }
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
          'actions' => entity ? player_actions(@game.round.actions_for(entity)) : [],
        }
      end
    end

    class Session
      attr_reader :original_actions, :actions, :dirty_from, :changes

      # data: the game as a Hash, as found in a game's JSON export
      def initialize(data)
        @data = data
        @original_actions = Retcon.flatten(data['actions'] || [])
        @actions = Retcon.deep_dup(@original_actions)
        @dirty_from = nil
        @broken_index = nil
        @changes = []
        @train_remap = {}
      end

      def load(actions)
        Engine::Game.load(@data, actions: actions)
      end

      def original_game
        @original_game ||= load(@original_actions)
      end

      def index_of(id)
        idx = @actions.index { |a| a['id'] == id }
        raise GameError, "No action with id #{id}" unless idx

        idx
      end

      def replace(id, action)
        idx = index_of(id)
        @actions[idx] = Retcon.deep_dup(action)
        mark_dirty(idx)
        self
      end

      def delete(id)
        idx = index_of(id)
        @actions.delete_at(idx)
        mark_dirty(idx)
        self
      end

      # Inserts an action after the given id (0 = at the very start).
      def insert_after(id, action)
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

      # Replaces the broken action with a new one and carries on.
      def resolve(action)
        raise GameError, 'Nothing to resolve' unless @broken_index

        idx = @broken_index
        @actions[idx] = Retcon.deep_dup(action)
        Retcon.renumber!(@actions)
        continue_from(load(@actions[0...idx]), idx)
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
      end

      def continue_from(game, start)
        done = []
        (start...@actions.size).each do |i|
          stored = @actions[i]
          attempt = Retcon.remap_trains(Retcon.scrub(stored), @train_remap)
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

            repaired = repair_train_purchase(game, attempt)
            unless repaired
              game = load(@actions[0...i]) if game.exception
              @broken_index = i
              return Result.new(status: :broken, game: game, broken_index: i,
                                broken_action: attempt, error: error, changes: @changes)
            end
          end

          replayed = Retcon.deep_dup(game.raw_actions.last)
          done << replayed
          note_change(i, stored, replayed)
        end

        @broken_index = nil
        @actions = game.raw_actions.map { |a| Retcon.deep_dup(a) }
        Result.new(status: :clean, game: game, changes: @changes)
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

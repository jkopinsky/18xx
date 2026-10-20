# frozen_string_literal: true

# backtick_javascript: true

require 'lib/retcon_state'
require 'lib/storage'
require 'view/game/actionable'

module View
  module Game
    # Fix history (retcon): change, delete or insert any past action, replay the
    # rest under the rules, stop and ask for a new move wherever the change
    # breaks a later action, then preview and commit the corrected history.
    class FixHistory < Snabberb::Component
      include Actionable

      needs :retcon, default: nil, store: true
      needs :fix_history_shown, default: 40, store: true

      PAGE = 40

      def render
        body =
          if !@retcon
            render_action_list
          elsif @retcon.awaiting_move?
            render_awaiting_move
          elsif @retcon.clean?
            render_preview
          end

        h('div#fix_history', { style: { margin: '1rem 0' } }, [h(:h3, 'Fix history'), body].compact)
      end

      # --- starting a retcon ---

      def render_action_list
        return h(:div, 'Open the game first.') unless @game_data['actions']

        state = Lib::RetconState.new(@game_data, @game)
        session = state.session
        log_by_id = log_lines_by_action

        actions = session.original_actions
        indexes = (0...actions.size).to_a.reverse.reject { |i| actions[i]['type'] == 'message' }
        shown = indexes.first(@fix_history_shown)

        trs = shown.map do |index|
          action = actions[index]
          source_id = session.source_ids[index]
          lines = log_by_id[source_id] || []
          description = lines.empty? ? describe(action) : lines.join(' · ')
          h(:tr, [
            h(:td, { style: cell }, action['id'].to_s),
            h(:td, { style: cell }, description),
            h(:td, { style: cell.merge(whiteSpace: 'nowrap') }, [
              button('Replace', -> { begin_retcon(state) { state.replace(action['id'], description) } }),
              button('Delete', -> { begin_retcon(state) { state.delete(action['id'], description) } }),
              button('Insert before', -> { begin_retcon(state) { state.insert_before(action['id'], description) } }),
            ]),
          ])
        end

        more = []
        if indexes.size > shown.size
          more << h(:button, { on: { click: -> { store(:fix_history_shown, @fix_history_shown + PAGE) } } },
                    "Show #{[PAGE, indexes.size - shown.size].min} older")
        end

        h(:div, [
          h(:p, [
            'Pick the action to fix. Nothing changes in the live game until you commit. ',
            'After an edit, the rest of the game replays under the rules; if a later action no longer works ',
            'you will be asked for a new move at that point.',
          ]),
          h(:table, { style: { borderCollapse: 'collapse' } }, [
            h(:thead, [h(:tr, ['#', 'What happened', 'Fix'].map { |t| h(:th, { style: cell }, t) })]),
            h(:tbody, trs),
          ]),
          *more,
        ])
      end

      # Remembers this device's master mode while a fix is open. It is kept in
      # storage, not just in memory, so a reload in the middle of a fix can put
      # it back (see GamePage#restore_master_mode_after_reload).
      PREVIOUS_MASTER_MODE = 'retcon_previous_master_mode'

      def begin_retcon(state)
        @game_storage = Lib::Storage[@game.id] || {}
        previous = @game_storage.key?(PREVIOUS_MASTER_MODE) ? @game_storage[PREVIOUS_MASTER_MODE] : @game_storage['master_mode']
        state.instance_variable_set(:@previous_master_mode, previous)
        Lib::Storage[@game.id] = @game_storage.merge('master_mode' => true, PREVIOUS_MASTER_MODE => previous || false)
        yield
        store(:retcon, state, skip: true)
        if state.awaiting_move?
          store(:game, state.display_game, skip: true)
          store(:app_route, @app_route.split('#').first)
        else
          store(:game, state.result.game, skip: false)
        end
      rescue StandardError => e
        store(:flash_opts, "Could not start the fix: #{e.message}")
      end

      # --- waiting for a move ---

      def render_awaiting_move
        result = @retcon.result
        broken = result&.broken?
        expected = broken ? result.expected : nil
        suggestion = broken ? result.suggestion : nil

        lines = [h(:p, @retcon.last_edit)]
        if broken
          lines << h('p', { style: { fontWeight: 'bold' } }, "This action no longer works: #{@retcon.message}")
          lines << h(:p, "It is now #{expected['entity']}'s turn. They may: #{expected['actions'].join(', ')}.") if expected
          if suggestion
            lead = { 'skip' => 'Suggestion: skip it. ', 'move' => "Suggestion: move for #{expected&.dig('entity')} first. " }
            lines << h(:p, "#{lead[suggestion['choice']]}#{suggestion['reason']}")
          end
        else
          lines << h(:p, @retcon.message)
        end
        if (note = @retcon.next_move_note)
          lines << h(:p, { style: { fontStyle: 'italic' } }, note)
        end
        lines << h(:div, [
          h(:button, { on: { click: -> { store(:app_route, @app_route.split('#').first) } } }, 'Go to the Game tab to move'),
          broken ? button('Skip this action', -> { act { @retcon.skip } }) : nil,
          @retcon.can_undo_step? ? button('Undo last fix step (u)', -> { act { @retcon.undo_step } }) : nil,
          button('Cancel the fix', -> { cancel }),
        ].compact)
        h(:div, lines)
      end

      # --- preview and commit ---

      def render_preview
        diffs = @retcon.preview
        changes = @retcon.changes

        diff_rows = diffs.map do |diff|
          h(:tr, [
            h(:td, { style: cell }, diff[0].join(' › ')),
            h(:td, { style: cell }, show(diff[1])),
            h(:td, { style: cell }, show(diff[2])),
          ])
        end
        notes = changes.map do |c|
          text =
            case c['kind']
            when 'route_revenue' then "Action #{c['id']}: route revenue changes from #{show(c['before'])} to #{show(c['after'])}"
            when 'train_renumbered' then "Action #{c['id']}: buys train #{c['after']} instead of #{c['before']}"
            when 'stale_pass_dropped'
              "#{c['before']}'s recorded pass was dropped: #{c['reason'] || 'its turn had already ended'}"
            else "Action #{c['id']} (#{c['type']}): different automatic follow-up actions"
            end
          h(:li, text)
        end

        h(:div, [
          h(:p, @retcon.last_edit),
          h(:p, { style: { fontWeight: 'bold' } }, 'The corrected history replays to the end.'),
          notes.empty? ? nil : h(:div, [h(:p, 'Replayed, but now different — check these:'), h(:ul, notes)]),
          h(:p, diffs.empty? ? 'No change to cash, holdings, values, prices or trains.' : 'What changes:'),
          if diffs.empty?
            nil
          else
            h(:table, { style: { borderCollapse: 'collapse' } }, [
                      h(:thead, [h(:tr, %w[What Before After].map { |t| h(:th, { style: cell }, t) })]),
                      h(:tbody, diff_rows),
                    ])
          end,
          h(:div, { style: { marginTop: '1rem' } }, [
            button('Commit the corrected history', -> { commit }),
            @retcon.can_undo_step? ? button('Undo last fix step (u)', -> { act { @retcon.undo_step } }) : nil,
            button('Cancel the fix', -> { cancel }),
          ].compact),
        ].compact)
      end

      def commit
        actions = @retcon.session.actions
        if hotseat?
          @game_data['actions'] = actions
          game = @retcon.result.game
          @game_data[:turn] = game.turn
          @game_data[:round] = game.round.name
          @game_data[:acting] = game.active_players_id
          @game_data[:updated_at] = Time.now.to_i
          Lib::Storage[@game_data['id']] = @game_data
          finish(@game_data, 'History corrected.')
        else
          payload = { actions: actions, base_action_count: @retcon.base_action_count }
          @connection.post(GameManager.url(@game_data, '/retcon'), payload) do |data|
            if (error = data['error'])
              # Nothing changed on the server. The fix can't be committed as it
              # stands (most often someone moved meanwhile), so drop it and
              # catch up with the live game.
              finish(@game_data, "Not committed: #{error} The fix was discarded; the game is up to date again.")
              catch_up
            else
              finish(data, 'History corrected for everyone.')
            end
          end
        end
      end

      def cancel
        finish(@game_data, 'Fix cancelled; nothing changed.')
        catch_up
      end

      # Live updates are ignored while a fix is open, so fetch the game again
      # in case others moved meanwhile. Hotseat games have no server.
      def catch_up
        return if hotseat? || !@connection

        connection = @connection
        game_data = @game_data
        user = @user
        connection.get(GameManager.url(game_data)) do |data|
          next if data['error'] || store['retcon']
          next if (data['actions'] || []).size == (store['game_data']['actions'] || []).size

          store(:game_data, data, skip: true)
          store(:game, Engine::Game.load(data, user: user&.dig('id')))
        end
      end

      private

      def finish(game_data, message)
        restore_master_mode
        store(:retcon, nil, skip: true)
        store(:game_data, game_data, skip: true)
        # Rebuild the live game from the (possibly new) history, the same way
        # other devices do when they hear about the change.
        store(:game, Engine::Game.load(game_data, user: @user&.dig('id')), skip: true)
        store(:flash_opts, message, skip: true)
        store(:app_route, @app_route.split('#').first)
      end

      def restore_master_mode
        storage = (Lib::Storage[@game.id] || {}).dup
        storage.delete(PREVIOUS_MASTER_MODE)
        Lib::Storage[@game.id] = storage.merge('master_mode' => @retcon.instance_variable_get(:@previous_master_mode))
      end

      def act
        yield
        store(:retcon, @retcon, skip: true)
        store(:game, @retcon.awaiting_move? ? @retcon.display_game : @retcon.result.game)
      rescue StandardError => e
        store(:flash_opts, e.message)
      end

      def log_lines_by_action
        @game.log.each_with_object({}) do |entry, h|
          message = entry.respond_to?(:message) ? entry.message.to_s : entry.to_s
          next if message.start_with?('--') || message.strip.empty?

          (h[entry.action_id] ||= []) << message.sub(/\A[•\s]+/, '')
        end
      end

      def describe(action)
        "#{action['entity']}: #{action['type'].to_s.tr('_', ' ')}"
      end

      def button(text, click)
        h(:button, { style: { margin: '0 0.3rem 0.2rem 0' }, on: { click: click } }, text)
      end

      def show(value)
        case value
        when nil then '—'
        when Array then value.join(', ')
        when Hash then value.keys.map { |k| "#{k}: #{value[k]}" }.join(', ')
        else value.to_s
        end
      end

      def cell
        {
          padding: '0.2rem 0.6rem',
          borderBottom: '1px solid rgba(128,128,128,0.3)',
          verticalAlign: 'top',
          textAlign: 'left',
        }
      end
    end
  end
end

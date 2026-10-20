# frozen_string_literal: true

require 'view/game/actionable'
require 'view/form'

module View
  module Game
    # Every movement of one account's money, one line per action, with a
    # running balance, and a check against what is counted at the table.
    class Ledger < Form
      include Actionable

      needs :ledger_account, default: nil, store: true
      needs :ledger_check, default: nil, store: true

      # A checkpoint is a chat message, so every device sees it and it survives
      # a history fix.
      CHECKPOINT_TEXT = '✓ Ledger checkpoint: all piles at the table match the app.'

      KIND_TEXT = {
        missed: 'An action of exactly this amount (paid or received once too few or too many times)',
        half: 'An action of twice this amount (only half was paid or received)',
        double: 'An action of half this amount (paid or received twice)',
        chip: 'Exactly one chip of this value',
      }.freeze

      def render_content
        ledger = @game.ledger
        return h('div.padded', 'No ledger for this game.') unless ledger

        accounts = account_list(ledger)
        key = @ledger_account && accounts.any? { |a| a[:key] == @ledger_account } ? @ledger_account : accounts.first[:key]

        h('div#ledger', { style: { margin: '1rem 0' } }, [
          render_audit(ledger),
          render_account_picker(accounts, key),
          render_count_check(ledger, key),
          render_checkpoint,
          render_rows(ledger, key),
        ].compact)
      end

      private

      def account_list(ledger)
        players = @game.players.map { |p| { key: ledger.key_for(p), name: p.name, kind: :player } }
        seen = {}
        others = []
        add = lambda do |type, id, name|
          return if %w[player bank].include?(type)

          key = Engine::Ledger.account_key(type, id)
          return if seen[key]

          seen[key] = true
          others << { key: key, name: name, kind: type.to_sym }
        end
        ledger.entries.each do |e|
          add.call(e.from_type, e.from_id, e.from_name)
          add.call(e.to_type, e.to_id, e.to_name)
        end
        players + others.sort_by { |a| a[:name] } + [{ key: 'bank:bank', name: 'Bank', kind: :bank }]
      end

      def render_audit(ledger)
        problems = ledger.audit
        return nil if problems.empty?

        h('div.padded', { style: { border: '2px solid red', marginBottom: '1rem' } }, [
          h(:strong, 'App bug: the ledger does not match the game for these accounts. Please report it.'),
          h(:ul, problems.map { |p| h(:li, "#{p[:name]}: ledger #{fmt(p[:ledger])}, game #{fmt(p[:actual])}") }),
        ])
      end

      def render_account_picker(accounts, current)
        buttons = accounts.map do |a|
          style = { margin: '0 0.3rem 0.3rem 0' }
          style[:fontWeight] = 'bold' if a[:key] == current
          style[:border] = '2px solid currentColor' if a[:key] == current
          h(:button, {
              style: style,
              on: {
                click: lambda do
                  store(:ledger_check, nil, skip: true)
                  store(:ledger_account, a[:key])
                end,
              },
            }, a[:name])
        end
        h(:div, { style: { marginBottom: '0.5rem' } }, [h(:h3, 'Ledger'), h(:div, buttons)])
      end

      def render_count_check(ledger, key)
        balance = ledger.balance(key)
        input = render_input(
          'Counted at the table:',
          id: :ledger_counted,
          type: 'number',
          attrs: { placeholder: balance.to_s },
          input_style: { width: '7rem' },
          on: { keyup: ->(event) { check(ledger, key) if Native(event)['key'] == 'Enter' } },
        )
        result = @ledger_check && @ledger_check[:account] == key ? render_check_result(@ledger_check) : nil

        h(:div, { style: { margin: '0.5rem 0 1rem 0' } }, [
          h(:div, "App says: #{fmt(balance)}"),
          h(:div, { style: { display: 'flex', alignItems: 'center', gap: '0.5rem' } }, [
            input,
            render_button('Check') { check(ledger, key) },
          ]),
          result,
        ].compact)
      end

      def last_checkpoint_id
        @game.raw_actions.reverse_each do |a|
          return a['id'] if a['type'] == 'message' && a['message'].to_s.start_with?(CHECKPOINT_TEXT)
        end
        nil
      end

      def render_checkpoint
        last = last_checkpoint_id
        note = last ? "Last checkpoint: after action #{last}. Checks only look at actions since then." : 'No checkpoint yet.'
        mark = lambda do
          sender = @game.player_by_id(@user&.dig('id')) || @game.players.first
          process_action(Engine::Action::Message.new(sender, message: CHECKPOINT_TEXT))
        end
        h(:div, { style: { margin: '0 0 1rem 0' } }, [
          h(:span, "#{note} "),
          h(:button, { on: { click: mark } }, 'Mark all piles as checked'),
        ])
      end

      def check(ledger, key)
        counted = params['ledger_counted'].to_s.strip
        return if counted.empty?

        # skip: is passed explicitly: in the browser build a trailing Hash
        # argument would otherwise be taken as keyword options, storing nil.
        store(:ledger_check, ledger.explain_difference(key, counted.to_i, since_action: last_checkpoint_id), skip: false)
      end

      def render_check_result(result)
        if result[:difference].zero?
          return h('div.padded', { style: { color: 'green' } }, "The pile matches the app (#{fmt(result[:counted])}).")
        end

        direction = result[:difference].positive? ? 'more' : 'less'
        lines = result[:candidates].map do |c|
          if c[:kind] == :chip
            h(:li, "#{KIND_TEXT[:chip]} (#{fmt(c[:amount])}).")
          else
            h(:li, [
              "#{KIND_TEXT[c[:kind]]}: ",
              history_link("#{round_name(c)}, action #{c[:action_id]}", 'View the game at this action', c[:action_id]),
              " (#{signed(c[:change])}) — #{c[:reasons].join('; ')}",
            ])
          end
        end
        lines = [h(:li, 'No single action explains it; read the lines below back to the last checkpoint.')] if lines.empty?

        h('div.padded', { style: { border: '1px solid currentColor' } }, [
          h(:div, "The table has #{fmt(result[:difference].abs)} #{direction} than the app. Likely causes, most recent first:"),
          h(:ul, lines),
        ])
      end

      def render_rows(ledger, key)
        rows = ledger.account_by_action(key).reverse
        header = h(:tr, ['Round', 'Action', 'Change', 'Balance', 'What happened'].map { |t| h(:th, { style: cell_style }, t) })
        body = rows.map do |r|
          action = if r[:action_id].zero?
                     'setup'
                   else
                     history_link(r[:action_id].to_s, 'View the game at this action', r[:action_id])
                   end
          h(:tr, [
            h(:td, { style: cell_style }, round_name(r)),
            h(:td, { style: cell_style }, [action]),
            h(:td, { style: cell_style.merge(textAlign: 'right', color: r[:change].negative? ? 'red' : 'inherit') },
              signed(r[:change])),
            h(:td, { style: cell_style.merge(textAlign: 'right') }, fmt(r[:balance])),
            h(:td, { style: cell_style }, r[:reasons].join(' · ')),
          ])
        end
        h(:table, { style: { borderCollapse: 'collapse' } }, [h(:thead, [header]), h(:tbody, body)])
      end

      # "SR 3", "OR 3.2", "Setup"
      def round_name(row)
        return row[:round] if row[:action_id].zero? || !row[:turn]

        stock = %w[SR ISR].include?(row[:round])
        row[:round_num] && !stock ? "#{row[:round]} #{row[:turn]}.#{row[:round_num]}" : "#{row[:round]} #{row[:turn]}"
      end

      def cell_style
        { padding: '0.2rem 0.6rem', borderBottom: '1px solid rgba(128,128,128,0.3)', verticalAlign: 'top' }
      end

      def fmt(amount)
        amount.negative? ? "-#{@game.format_currency(-amount)}" : @game.format_currency(amount)
      end

      def signed(amount)
        amount.negative? ? "-#{fmt(-amount)}" : "+#{fmt(amount)}"
      end
    end
  end
end

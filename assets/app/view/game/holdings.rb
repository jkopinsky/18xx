# frozen_string_literal: true

require 'view/game/actionable'

module View
  module Game
    # How each company's share price, and each player's holdings, have done
    # since the last stock round started and since purchase.
    class Holdings < Snabberb::Component
      include Actionable

      needs :game

      def render
        perf = @game.performance
        return h('div.padded', 'No share data for this game.') unless perf

        start = perf.last_stock_round_start
        since = start ? "#{start.round} #{start.turn}" : 'the last stock round'

        h('div#holdings', { style: { margin: '1rem 0' } }, [
          h(:h3, 'Share prices'),
          render_companies(perf, since),
          *@game.players.map { |p| render_player(perf, p, since) },
          h('p.small_font', [
            'Cost is the share price when each share was bought, sold or shorted, averaged. ',
            'Shares received in exchanges or mergers count at the price when they arrived. ',
            'Shorts are negative positions; dividends paid on them count against the return.',
          ]),
        ])
      end

      private

      def render_companies(perf, since)
        companies = perf.companies.sort_by { |c| -(c[:price] || 0) }
        header = ['Company', 'Price', "At start of #{since}", 'Change'].map { |t| h(:th, { style: cell }, t) }
        rows = companies.map do |c|
          h(:tr, [
            h(:td, { style: cell }, c[:name]),
            h(:td, { style: num }, fmt(c[:price])),
            h(:td, { style: num }, c[:price_at_sr_start] ? fmt(c[:price_at_sr_start]) : '—'),
            h(:td, { style: num.merge(color: color(c[:change_since_sr])) },
              c[:change_since_sr] ? signed(c[:change_since_sr]) : 'new'),
          ])
        end
        h(:table, { style: table_style }, [h(:thead, [h(:tr, header)]), h(:tbody, rows)])
      end

      def render_player(perf, player, since)
        rows = perf.holdings_for(player).reject { |r| r[:shares].zero? && r[:realized].zero? && r[:dividends].zero? }
        rows = rows.sort_by { |r| [r[:shares].zero? ? 1 : 0, -r[:value].abs] }
        header = ['Company', 'Shares', 'Avg cost', 'Price', 'Value', "Since #{since}",
                  'Unrealized', 'Realized', 'Dividends', 'Total return'].map { |t| h(:th, { style: cell }, t) }
        body = rows.map do |r|
          h(:tr, { style: r[:shares].zero? ? { opacity: '0.6' } : {} }, [
            h(:td, { style: cell }, r[:short] ? "#{r[:name]} (short)" : r[:name]),
            h(:td, { style: num }, shares(r[:shares])),
            h(:td, { style: num }, r[:shares].zero? ? '' : fmt(r[:average_cost])),
            h(:td, { style: num }, r[:price] ? fmt(r[:price]) : '—'),
            h(:td, { style: num }, fmt(r[:value])),
            money_cell(r[:change_since_sr]),
            money_cell(r[:unrealized]),
            money_cell(r[:realized]),
            money_cell(r[:dividends]),
            money_cell(r[:total_return], bold: true),
          ])
        end
        total = rows.sum { |r| r[:total_return] }
        footer = h(:tr, [
          h(:td, { style: cell, attrs: { colspan: 9 } }, 'Total'),
          money_cell(total, bold: true),
        ])

        h(:div, { style: { marginTop: '1.5rem' } }, [
          h(:h3, "#{player.name} — cash #{fmt(player.cash)}"),
          if rows.empty?
            h(:div, 'No shares yet.')
          else
            h(:table, { style: table_style }, [h(:thead, [h(:tr, header)]),
                                               h(:tbody, body + [footer])])
          end,
        ])
      end

      def money_cell(value, bold: false)
        style = num.merge(color: color(value))
        style[:fontWeight] = 'bold' if bold
        h(:td, { style: style }, value.nil? ? '—' : signed(value))
      end

      def shares(count)
        rounded = count.round(2)
        rounded == rounded.to_i ? rounded.to_i.to_s : rounded.to_s
      end

      def color(value)
        return 'inherit' if value.nil? || value.zero?

        value.negative? ? 'red' : 'green'
      end

      def table_style
        { borderCollapse: 'collapse' }
      end

      def cell
        { padding: '0.2rem 0.6rem', borderBottom: '1px solid rgba(128,128,128,0.3)', textAlign: 'left' }
      end

      def num
        cell.merge(textAlign: 'right')
      end

      def fmt(amount)
        return '—' if amount.nil?

        @game.format_currency(amount.round(2) == amount.round ? amount.round : amount.round(2))
      end

      def signed(amount)
        amount.negative? ? "-#{fmt(-amount)}" : "+#{fmt(amount)}"
      end
    end
  end
end

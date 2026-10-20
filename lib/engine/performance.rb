# frozen_string_literal: true

module Engine
  # Share performance: how each company's price and each player's holdings
  # have done since the start of the last stock round and since purchase.
  #
  # Built while the game replays, like the ledger, so it stays correct after
  # undo or a retcon.
  #
  # Positions are counted in shares (a short is a negative count). Every change
  # in a position is valued at the share price at that moment: the price paid
  # for a buy, received for a sale or a short. Cost is tracked on an average
  # cost basis: selling part of a position removes that fraction of its cost,
  # and the difference to the sale value is realized gain.
  #
  # Shares received without a sale at market price (exchanges, mergers, a new
  # company's president's share) are valued at the price when they arrived.
  class Performance
    Snapshot = Struct.new(:round, :turn, :round_num, :action_id, :prices, keyword_init: true)

    Position = Struct.new(:shares, :cost, :realized, :dividends, :first_action_id, keyword_init: true) do
      def average_cost
        shares.zero? ? 0 : cost / shares
      end
    end

    attr_reader :snapshots

    def initialize(game)
      @game = game
      @snapshots = []
      # player id => corporation id => Position
      @positions = Hash.new { |h, k| h[k] = {} }
      @before = nil
      @action_id = 0
    end

    # --- recording (called by GameHooks) ---

    def begin_action(action_id)
      @action_id = action_id
      @before = holdings
    end

    def end_action(dividend_corporation: nil)
      after = holdings
      keys = (@before.keys | after.keys)
      keys.each do |key|
        player_id, corp_id = key
        old_shares, old_price = @before[key] || [0, nil]
        new_shares, new_price = after[key] || [0, nil]
        next if old_shares == new_shares

        price = old_price || new_price || 0
        apply_change(player_id, corp_id, new_shares - old_shares, price)
      end
      add_dividends(dividend_corporation) if dividend_corporation
      @before = nil
    end

    def snapshot!
      round = @game.round
      @snapshots << Snapshot.new(
        round: round ? Retcon.round_label(round) : 'Setup',
        turn: @game.turn,
        round_num: round&.round_num,
        action_id: @action_id,
        prices: @game.corporations.each_with_object({}) do |c, h|
          h[c.id] = c.share_price.price if c.share_price
        end,
      )
    end

    # --- reading ---

    # The snapshot taken when the most recent stock round started.
    def last_stock_round_start
      @snapshots.reverse.find { |s| stock_round_label?(s.round) }
    end

    # For each company with a price: price now, at the start of the last stock
    # round, and the change.
    def companies
      start = last_stock_round_start
      @game.corporations.select(&:share_price).map do |c|
        now = c.share_price.price
        was = start&.prices&.[](c.id)
        {
          id: c.id,
          name: c.name,
          price: now,
          price_at_sr_start: was,
          change_since_sr: was ? now - was : nil,
          history: price_history(c.id),
        }
      end
    end

    # One company's price at the start of every recorded round.
    def price_history(corporation_id)
      @snapshots.filter_map do |s|
        price = s.prices[corporation_id]
        { round: s.round, turn: s.turn, round_num: s.round_num, price: price } if price
      end
    end

    # A player's holdings, including closed-out positions with realized gains.
    def holdings_for(player)
      start = last_stock_round_start
      @positions[player.id].map do |corp_id, pos|
        corp = @game.corporation_by_id(corp_id)
        price = corp&.share_price&.price
        value = price ? pos.shares * price : 0
        was = start&.prices&.[](corp_id)
        {
          corporation: corp_id,
          name: corp&.name || corp_id,
          shares: pos.shares,
          short: pos.shares.negative?,
          price: price,
          average_cost: pos.average_cost.round(2),
          cost: pos.cost.round(2),
          value: value,
          unrealized: (value - pos.cost).round(2),
          realized: pos.realized.round(2),
          dividends: pos.dividends,
          total_return: (value - pos.cost + pos.realized + pos.dividends).round(2),
          change_since_sr: was && price ? (price - was) * pos.shares : nil,
          held_since_action: pos.first_action_id,
        }
      end
    end

    def position(player, corporation)
      @positions[player.id][corporation.id]
    end

    private

    def stock_round_label?(label)
      %w[SR ISR].include?(label) || label.to_s.include?('Stock')
    end

    # [player id, corporation id] => [shares, price]
    def holdings
      result = {}
      @game.players.each do |player|
        player.shares_by_corporation.each do |corp, shares|
          next if shares.empty? || !corp.corporation?

          percent = shares.sum(&:percent)
          next if percent.zero?

          count = percent.to_f / corp.share_percent
          result[[player.id, corp.id]] = [count, corp.share_price&.price]
        end
      end
      result
    end

    def apply_change(player_id, corp_id, delta, price)
      pos = (@positions[player_id][corp_id] ||= Position.new(shares: 0, cost: 0.0, realized: 0.0, dividends: 0,
                                                             first_action_id: @action_id))
      if pos.shares.zero? || (pos.shares.positive? == delta.positive?)
        # Opening or adding to a position (long or short).
        pos.first_action_id = @action_id if pos.shares.zero?
        pos.cost += delta * price
        pos.shares += delta
      else
        # Reducing a position; possibly flipping it.
        closing = [delta.abs, pos.shares.abs].min * (delta.positive? ? 1 : -1)
        fraction = closing.abs.to_f / pos.shares.abs
        removed_cost = pos.cost * fraction
        proceeds = -closing * price
        pos.realized += proceeds - removed_cost
        pos.cost -= removed_cost
        pos.shares += closing
        remainder = delta - closing
        unless remainder.zero?
          pos.first_action_id = @action_id
          pos.cost += remainder * price
          pos.shares += remainder
        end
      end
      pos.shares = pos.shares.round(6)
      pos.cost = 0.0 if pos.shares.zero?
    end

    # Money the company's dividend action moved to or from each player.
    def add_dividends(corporation_id)
      @game.ledger.entries.reverse_each do |e|
        break if e.action_id != @action_id

        if e.to_type == 'player'
          credit(e.to_id, corporation_id, e.amount)
        elsif e.from_type == 'player'
          credit(e.from_id, corporation_id, -e.amount)
        end
      end
    end

    def credit(player_id, corporation_id, amount)
      pos = (@positions[player_id][corporation_id] ||= Position.new(shares: 0, cost: 0.0, realized: 0.0, dividends: 0,
                                                                    first_action_id: @action_id))
      pos.dividends += amount
    end

    module GameHooks
      DIVIDEND_TYPES = %w[dividend].freeze

      def performance
        @performance
      end

      def initialize(*args, **kwargs)
        @performance = Performance.new(self)
        super
      end

      def process_action(action, **kwargs)
        return super unless @performance

        type = (action.is_a?(Hash) ? action['type'] : action.type).to_s
        return super if %w[undo redo message].include?(type)

        entity_type = action.is_a?(Hash) ? action['entity_type'] : type_s_for(action.entity)
        entity_id = action.is_a?(Hash) ? action['entity'] : action.entity&.id
        dividend_corp = DIVIDEND_TYPES.include?(type) && entity_type == 'corporation' ? entity_id : nil

        @performance.begin_action(current_action_id + 1)
        result = super
        @performance.end_action(dividend_corporation: exception ? nil : dividend_corp) unless exception
        result
      end

      def transition_to_next_round!
        super
        @performance&.snapshot! unless @finished
      end

      private

      def type_s_for(entity)
        return 'corporation' if entity.respond_to?(:corporation?) && entity.corporation?

        nil
      end
    end
  end
end

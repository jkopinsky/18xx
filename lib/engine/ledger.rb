# frozen_string_literal: true

module Engine
  # The money ledger: every movement of cash during a game, as a transfer
  # between two accounts, tied to the action and round that caused it.
  #
  # All money in the engine moves through Spender#spend, which calls
  # Ledger.record. Spenders don't know which game they belong to, so the game
  # that is currently running pushes its ledger on a stack while it builds
  # itself and while it processes each action (see Ledger::GameHooks).
  #
  # Because the ledger is rebuilt whenever a game is loaded or replayed, it is
  # always in step with the action history, including after undo or a retcon.
  class Ledger
    Entry = Struct.new(
      :seq, :action_id, :action_type, :round, :turn, :round_num,
      :from_id, :from_type, :from_name, :to_id, :to_type, :to_name,
      :amount, :reason, :log_from, :log_to,
      keyword_init: true
    )

    attr_reader :opening

    @stack = []

    class << self
      def current
        @stack.last
      end

      # Runs the block with this ledger receiving transfers.
      def with(ledger)
        @stack.push(ledger)
        yield
      ensure
        @stack.pop
      end

      def record(from, to, amount)
        current&.record(from, to, amount)
      end

      def account_type(entity)
        return 'bank' if entity.is_a?(Engine::Bank)
        return 'player' if entity.respond_to?(:player?) && entity.player?
        return 'corporation' if entity.respond_to?(:corporation?) && entity.corporation?
        return 'minor' if entity.respond_to?(:minor?) && entity.minor?
        return 'company' if entity.respond_to?(:company?) && entity.company?

        entity.class.name.split('::').last.downcase
      end

      def account_key(type, id)
        "#{type}:#{id}"
      end

      # The bank has no id of its own.
      def account_id(entity)
        return 'bank' if entity.is_a?(Engine::Bank)

        entity.respond_to?(:id) ? entity.id : entity.name
      end
    end

    def initialize(game)
      @game = game
      @entries = []
      @opening = {}
      @action = nil
      @log_start = 0
      @pending = []
    end

    # Cash an account held before any transfer was recorded (the bank's
    # starting cash).
    def open_account(entity, cash)
      @opening[key_for(entity)] = cash
    end

    # Called by the game around each top-level action.
    def begin_action(action)
      @action = action
      @log_start = @game.log.size
      @pending = []
    end

    def end_action
      if @game.exception
        # The action was rejected; its transfers are not part of the game.
        @entries.pop(@pending.size)
      else
        # Reasons are worked out from the log only when someone looks, so a
        # replay doesn't pay for them; remember which log lines to use.
        log_to = @game.log.size
        @pending.each do |e|
          e.log_from = @log_start
          e.log_to = log_to
        end
        @unresolved = true unless @pending.empty?
      end
      @action = nil
      @pending = []
    end

    # All transfers, each with its reason.
    def entries
      resolve_reasons!
      @entries
    end

    # Transfers without working out reasons (for internal use during replay).
    def raw_entries
      @entries
    end

    def resolve_reasons!
      return unless @unresolved

      @entries.reject(&:reason).chunk_while { |a, b| a.action_id == b.action_id }.each { |group| describe(group) }
      @unresolved = false
    end

    def record(from, to, amount)
      amount = amount.to_i
      return if amount.zero?

      # set_cash can move a negative amount; record it the right way round.
      return record(to, from, -amount) if amount.negative?

      round = @game.round
      entry = Entry.new(
        seq: @entries.size + 1,
        action_id: @action&.id || 0,
        action_type: @action&.type || 'setup',
        round: round ? round_label(round) : 'Setup',
        turn: @game.turn,
        round_num: round&.round_num,
        from_id: Ledger.account_id(from), from_type: Ledger.account_type(from), from_name: name_of(from),
        to_id: Ledger.account_id(to), to_type: Ledger.account_type(to), to_name: name_of(to),
        amount: amount.to_i,
        reason: nil,
      )
      @entries << entry
      if @action
        @pending << entry
      else
        entry.reason = 'Starting cash'
      end
      entry
    end

    def key_for(entity)
      Ledger.account_key(Ledger.account_type(entity), Ledger.account_id(entity))
    end

    # All entries touching one account, oldest first, each with the account's
    # running balance after it.
    def account(entity_or_key)
      resolve_reasons!
      key = entity_or_key.is_a?(String) ? entity_or_key : key_for(entity_or_key)
      balance = @opening[key] || 0
      @entries.each_with_object([]) do |e, rows|
        delta =
          if Ledger.account_key(e.to_type, e.to_id) == key
            e.amount
          elsif Ledger.account_key(e.from_type, e.from_id) == key
            -e.amount
          end
        next unless delta

        balance += delta
        rows << { entry: e, change: delta, balance: balance }
      end
    end

    # The table's view of one account: one row per action that moved its
    # money, with the net change, the balance after, and the transfers inside.
    # Several transfers in one action (a share buy that refunds a bid, an
    # acquisition) read as one line, the way people count chips.
    def account_by_action(entity_or_key)
      key = entity_or_key.is_a?(String) ? entity_or_key : key_for(entity_or_key)
      groups = account(key).chunk_while { |a, b| a[:entry].action_id == b[:entry].action_id }
      rows_by_action = groups.map do |rows|
        first = rows.first[:entry]
        net = rows.sum { |r| r[:change] }
        {
          action_id: first.action_id,
          action_type: first.action_type,
          round: first.round,
          turn: first.turn,
          round_num: first.round_num,
          change: net,
          balance: rows.last[:balance],
          reasons: rows.map { |r| r[:entry].reason }.compact.uniq,
          transfers: rows,
        }
      end
      rows_by_action.reject { |row| row[:change].zero? && row[:transfers].size > 1 }
    end

    CHIP_DENOMINATIONS = [1, 5, 10, 20, 50, 100, 500, 1000].freeze

    # Compares a pile counted at the table with the ledger, and lists the most
    # likely explanations, most recent first:
    #   :missed   - an action whose net amount equals the difference
    #               (paid or received at the table but not both ways, or twice)
    #   :half     - an action worth twice the difference (paid half)
    #   :double   - an action worth half the difference (paid twice)
    #   :chip     - the difference is a single chip denomination
    # since_action limits the search to actions after a checkpoint.
    def explain_difference(entity_or_key, counted, since_action: nil, limit: 5)
      key = entity_or_key.is_a?(String) ? entity_or_key : key_for(entity_or_key)
      expected = balance(key)
      diff = counted.to_i - expected
      result = { account: key, expected: expected, counted: counted.to_i, difference: diff, candidates: [] }
      return result if diff.zero?

      size = diff.abs
      rows = account_by_action(key)
      rows = rows.select { |r| r[:action_id] > since_action } if since_action
      rows.reverse_each do |row|
        amount = row[:change].abs
        kind =
          if amount == size then :missed
          elsif amount == size * 2 then :half
          elsif amount * 2 == size then :double
          end
        next unless kind

        result[:candidates] << {
          kind: kind,
          action_id: row[:action_id],
          round: row[:round],
          change: row[:change],
          reasons: row[:reasons],
        }
        break if result[:candidates].size >= limit
      end
      result[:candidates] << { kind: :chip, amount: size } if CHIP_DENOMINATIONS.include?(size)
      result
    end

    def balance(entity_or_key)
      key = entity_or_key.is_a?(String) ? entity_or_key : key_for(entity_or_key)
      rows = account(key)
      rows.empty? ? (@opening[key] || 0) : rows.last[:balance]
    end

    # Checks the ledger against the game: every account's ledger balance must
    # equal its actual cash. Returns a list of mismatches (empty when all is
    # well). A mismatch means money moved without going through the ledger.
    def audit
      @game.spenders.each_with_object([]) do |entity, problems|
        next unless entity.respond_to?(:cash)

        expected = balance(entity)
        actual = entity.cash
        problems << { account: key_for(entity), name: name_of(entity), ledger: expected, actual: actual } if expected != actual
      end
    end

    # Totals per account, for the whole game or a range of actions.
    def summary(from_action: nil, to_action: nil)
      totals = Hash.new { |h, k| h[k] = { 'in' => 0, 'out' => 0 } }
      @entries.each do |e|
        next if from_action && e.action_id < from_action
        next if to_action && e.action_id > to_action

        totals[Ledger.account_key(e.to_type, e.to_id)]['in'] += e.amount
        totals[Ledger.account_key(e.from_type, e.from_id)]['out'] += e.amount
      end
      totals
    end

    private

    def name_of(entity)
      entity.respond_to?(:name) ? entity.name.to_s : Ledger.account_id(entity).to_s
    end

    def round_label(round)
      Retcon.round_label(round)
    end

    # Gives each transfer of one action a plain-words reason, taken from the
    # game log line that mentions its amount (and ideally one of the two
    # parties); otherwise falls back to the action type.
    def describe(group)
      first = group.first
      lines = (@game.log[first.log_from...first.log_to] || []).map do |l|
        l.respond_to?(:message) ? l.message.to_s : l.to_s
      end
      used = {}
      group.each do |e|
        money = @game.format_currency(e.amount)
        candidates = []
        lines.each_with_index { |l, i| candidates << [l, i] if l.include?(money) }
        best = candidates.find { |c| !used[c[1]] && (c[0].include?(e.from_name) || c[0].include?(e.to_name)) } ||
               candidates.find { |c| c[0].include?(e.from_name) || c[0].include?(e.to_name) } ||
               candidates.find { |c| !used[c[1]] } ||
               candidates.first
        if best
          used[best[1]] = true
          e.reason = best[0].sub(/\A[-•\s]+/, '')
        else
          e.reason = e.action_type.to_s.tr('_', ' ').capitalize
        end
      end
    end

    # Installed on Game::Base so a game feeds its own ledger.
    module GameHooks
      def ledger
        @ledger
      end

      def initialize(*args, **kwargs)
        @ledger = Ledger.new(self)
        Ledger.with(@ledger) { super }
      end

      def init_bank
        bank = super
        @ledger&.open_account(bank, bank.cash)
        bank
      end

      def process_action(action, **kwargs)
        return super unless @ledger

        type = action.is_a?(Hash) ? action['type'] : action.type
        return super if %w[undo redo].include?(type.to_s)

        Ledger.with(@ledger) do
          # The engine converts the action and handles any error itself; the
          # ledger only needs the id the action is about to receive.
          @ledger.begin_action(LedgerAction.new(current_action_id + 1, type.to_s))
          begin
            super
          ensure
            @ledger.end_action
          end
        end
      end
    end

    LedgerAction = Struct.new(:id, :type)
  end
end

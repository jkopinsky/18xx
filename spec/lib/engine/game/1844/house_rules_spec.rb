# frozen_string_literal: true

require './spec/spec_helper'
require 'json'

module Engine
  describe 'G1844 house rule: GB destination with the Furka-Oberalp tile' do
    let(:data) { JSON.parse(File.read(File.join(__dir__, '..', '..', '..', '..', 'fixtures', '1844', '160062.json'))) }

    # Before action 150, GB has floated but not yet reached its destination.
    def game_before_bonus(rule:)
      d = JSON.parse(JSON.generate(data))
      d['settings'] = (d['settings'] || {}).merge('optional_rules' => rule ? ['gb_destination_p4'] : [])
      Game.load(d, actions: d['actions'].first(150))
    end

    it 'pays GB its destination bonus when the P4 tile is laid' do
      game = game_before_bonus(rule: true)
      gb = game.corporation_by_id('GB')
      expect(gb.floated?).to eq(true)
      expect(game.hex_by_id(gb.destination_coordinates).assigned?(gb)).to eq(true)
      before = gb.cash

      Ledger.with(game.ledger) { game.lay_p4_overpass! }

      bonus = gb.par_price.price * 2
      expect(gb.cash).to eq(before + bonus)
      expect(game.log.map { |l| (l.respond_to?(:message) ? l.message : l).to_s })
        .to include("GB has reached its destination and receives #{game.format_currency(bonus)}")
      expect(game.hex_by_id(gb.destination_coordinates).assigned?(gb)).to eq(false)
      expect(game.destinated?(gb)).to eq(false) # never paid twice
      expect(game.ledger.audit).to eq([])
    end

    it 'leaves the published rules alone when the house rule is off' do
      game = game_before_bonus(rule: false)
      gb = game.corporation_by_id('GB')
      before = gb.cash
      Ledger.with(game.ledger) { game.lay_p4_overpass! }
      expect(gb.cash).to eq(before)
      expect(game.hex_by_id(gb.destination_coordinates).assigned?(gb)).to eq(true)
    end

    it 'no longer counts the Gotthard tunnel when the house rule is on' do
      d = JSON.parse(JSON.generate(data))
      d['settings'] = (d['settings'] || {}).merge('optional_rules' => ['gb_destination_p4'])
      # Action 153 of 160062 builds the Gotthard tunnel; its recorded bonus is dropped.
      actions = d['actions'].first(153)
      actions[-1] = actions[-1].except('auto_actions')
      game = Game.load(d, actions: actions)
      expect(game.exception).to be_nil
      expect(game.hex_by_id('H19').tile.paths.any? { |path| path.track == :narrow }).to eq(true)
      expect(game.destinated?(game.corporation_by_id('GB'))).to eq(false)
    end
  end

  describe 'G1844 house rule: several Mountain Railways per stock round' do
    let(:data) { JSON.parse(File.read(File.join(__dir__, '..', '..', '..', '..', 'fixtures', '1844', '160062.json'))) }

    # Player 4 buys B1 at action 228; action 235 is their next turn in the same stock round.
    def second_mountain_turn(rules)
      d = JSON.parse(JSON.generate(data))
      d['settings'] = (d['settings'] || {}).merge('optional_rules' => rules)
      game = Game.load(d, actions: d['actions'].first(235))
      player = game.player_by_id(2798)
      game.bank.spend(500, player)
      [game, player]
    end

    it 'keeps the one-per-round limit without the house rule' do
      game, player = second_mountain_turn([])
      expect(game.round.active_step.current_entity).to eq(player)
      expect(game.round.active_step.can_buy_company?(player, game.company_by_id('B3'))).to eq(false)
    end

    it 'allows a second Mountain Railway in the same stock round with the house rule' do
      game, player = second_mountain_turn(['multiple_mountain_railways'])
      b3 = game.company_by_id('B3')
      expect(game.round.active_step.can_buy_company?(player, b3)).to eq(true)

      game.process_action(Action::BuyCompany.new(player, company: b3, price: 150))
      expect(game.exception).to be_nil
      expect(player.companies).to include(b3)
      expect(game.round.active_entities).to eq([b3]) # places its revenue marker next
    end
  end

  describe 'G1844 house rule: 3 and 3H trains rust in phase 5' do
    let(:data) { JSON.parse(File.read(File.join(__dir__, '..', '..', '..', '..', 'fixtures', '1844', '160062.json'))) }
    let(:first_five) { data['actions'].index { |a| a['type'] == 'buy_train' && a['variant'].to_s.start_with?('5') } }

    def three_trains_after_first_five(rules)
      d = JSON.parse(JSON.generate(data))
      d['settings'] = (d['settings'] || {}).merge('optional_rules' => rules)
      game = Game.load(d, actions: d['actions'].first(first_five + 1))
      expect(game.exception).to be_nil
      expect(game.phase.name).to eq('5')
      game.trains.select { |t| t.sym == '3' && t.owner && t.owner != game.depot && !t.rusted }
    end

    it 'keeps the 3H trains in phase 5 without the house rule' do
      expect(three_trains_after_first_five([])).not_to be_empty
    end

    it 'rusts every 3H train when the first 5 train is bought' do
      expect(three_trains_after_first_five(['three_trains_rust_phase5'])).to be_empty
    end
  end

  describe 'Fix history after switching on a house rule part way through' do
    let(:data) { JSON.parse(File.read(File.join(__dir__, '..', '..', '..', '..', 'fixtures', '1844', '160062.json'))) }

    it 'replays from where the live game stops and asks about the first move that no longer works' do
      d = JSON.parse(JSON.generate(data))
      d['settings'] = (d['settings'] || {}).merge('optional_rules' => ['three_trains_rust_phase5'],
                                                  'recorded_optional_rules' => [])
      live = Game.load(d)
      expect(live.exception).not_to be_nil
      stop = live.broken_action&.id || live.last_processed_action

      session = Retcon::Session.new(d, original_game: live)
      result = session.replay_from(stop)
      expect(result).to be_broken
      # The recorded moves were tagged under the rules they were played with.
      expect(session.actions.size).to eq(Retcon.flatten(d['actions']).size)
      expect(session.broken_recorded_action['id']).to be >= stop
      expect(result.error_message).to be_a(String)
    end
  end
end

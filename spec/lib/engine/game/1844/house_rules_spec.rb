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
end

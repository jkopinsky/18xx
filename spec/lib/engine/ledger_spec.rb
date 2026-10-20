# frozen_string_literal: true

require './spec/spec_helper'
require 'json'

module Engine
  LEDGER_FIXTURES = File.join(File.dirname(__FILE__), '..', '..', 'fixtures')

  describe Ledger do
    Dir[File.join(LEDGER_FIXTURES, '{1817,1844}', '*.json')].each do |path|
      title = File.basename(File.dirname(path))
      name = File.basename(path, '.json')

      describe "#{title} #{name}" do
        let(:game) { Game.load(path) }

        it 'accounts for every dollar: each ledger balance equals actual cash' do
          expect(game.exception).to be_nil
          expect(game.ledger.entries).not_to be_empty
          expect(game.ledger.audit).to eq([])
        end

        it 'gives every transfer a reason' do
          expect(game.ledger.entries.map(&:reason).compact.size).to eq(game.ledger.entries.size)
        end
      end
    end

    describe 'per-account views' do
      let(:game) { Game.load(File.join(LEDGER_FIXTURES, '1817', '16281.json')) }
      let(:player) { game.players.first }

      it 'starts every player with their starting cash from the bank' do
        first = game.ledger.account(player).first[:entry]
        expect(first.reason).to eq('Starting cash')
        expect(first.from_type).to eq('bank')
        expect(first.action_id).to eq(0)
      end

      it 'groups transfers by action with a net change and running balance' do
        rows = game.ledger.account_by_action(player)
        expect(rows.map { |r| r[:action_id] }).to eq(rows.map { |r| r[:action_id] }.uniq)
        expect(rows.last[:balance]).to eq(player.cash)
        expect(rows.sum { |r| r[:change] }).to eq(player.cash)
      end

      it 'finds the action behind a counted difference' do
        rows = game.ledger.account_by_action(player)
        target = rows.reverse.find { |r| r[:change].abs >= 10 }
        counted = player.cash - target[:change]
        result = game.ledger.explain_difference(player, counted)
        expect(result[:difference]).to eq(-target[:change])
        expect(result[:candidates].map { |c| c[:action_id] }).to include(target[:action_id])
      end

      it 'reports no difference when the pile matches' do
        result = game.ledger.explain_difference(player, player.cash)
        expect(result[:difference]).to eq(0)
        expect(result[:candidates]).to eq([])
      end
    end

    describe 'with undo and rejected actions' do
      let(:data) { JSON.parse(File.read(File.join(LEDGER_FIXTURES, '1817', '16281.json'))) }

      it 'drops transfers from a rejected action' do
        game = Game.load(data, actions: data['actions'].first(120))
        before = game.ledger.entries.size
        game.process_action({
                              'type' => 'buy_train',
                              'entity' => game.current_entity.id,
                              'entity_type' => 'corporation',
                              'train' => 'no-such-train',
                              'price' => 100,
                            })
        expect(game.exception).not_to be_nil
        expect(game.ledger.entries.size).to eq(before)
      end

      it 'is rebuilt by a retcon replay' do
        session = Retcon::Session.new(data)
        target = session.actions.find { |a| a['type'] == 'dividend' && a['kind'] == 'payout' }
        session.replace(target['id'], target.merge('kind' => 'withhold'))
        result = session.replay
        expect(result.game.ledger.audit).to eq([])
      end
    end
  end
end

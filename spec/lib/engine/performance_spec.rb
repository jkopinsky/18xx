# frozen_string_literal: true

require './spec/spec_helper'
require 'json'

module Engine
  PERFORMANCE_FIXTURES = File.join(File.dirname(__FILE__), '..', '..', 'fixtures')

  describe Performance do
    Dir[File.join(PERFORMANCE_FIXTURES, '{1817,1844}', '*.json')].each do |path|
      title = File.basename(File.dirname(path))
      name = File.basename(path, '.json')

      describe "#{title} #{name}" do
        let(:game) { Game.load(path) }

        it "values each player's holdings the same as the engine does" do
          game.players.each do |player|
            ours = game.performance.holdings_for(player).sum { |r| r[:value] }
            theirs = player.shares.select { |s| s.corporation.ipoed && s.corporation.share_price }.sum(&:price)
            expect((ours - theirs).abs).to be < 0.01
          end
        end

        it 'records share prices at the start of each stock round' do
          start = game.performance.last_stock_round_start
          expect(start).not_to be_nil
          expect(start.prices).not_to be_empty
        end
      end
    end

    describe 'in 1817 16281' do
      let(:data) { JSON.parse(File.read(File.join(PERFORMANCE_FIXTURES, '1817', '16281.json'))) }

      it 'records each share purchase at what the player paid' do
        game = Game.load(data, actions: [])
        Retcon.flatten(data['actions']).each do |action|
          player = action['entity_type'] == 'player' ? game.player_by_id(action['entity']) : nil
          before = player ? game.corporations.to_h { |c| [c.id, game.performance.position(player, c)&.cost || 0] } : {}
          game.process_action(action)
          next if !player || action['type'] != 'buy_shares'

          action_id = game.raw_actions.last['id']
          paid = game.ledger.entries.select { |e| e.action_id == action_id }.sum do |e|
            out = e.from_type == 'player' && e.from_id == player.id ? e.amount : 0
            inn = e.to_type == 'player' && e.to_id == player.id ? e.amount : 0
            out - inn
          end
          added = game.corporations.sum { |c| (game.performance.position(player, c)&.cost || 0) - before[c.id] }
          expect((paid - added).abs).to be < 0.01
        end
      end

      it 'treats shorts as negative positions whose dividends are a cost' do
        game = Game.load(data)
        shorts = game.players.flat_map { |p| game.performance.holdings_for(p) }.select { |r| r[:short] }
        expect(shorts).not_to be_empty
        expect(shorts.all? { |r| r[:value] <= 0 && r[:dividends] <= 0 }).to eq(true)
      end

      it 'reports each company price change since the last stock round started' do
        game = Game.load(data)
        game.performance.companies.each do |c|
          next unless c[:price_at_sr_start]

          expect(c[:change_since_sr]).to eq(c[:price] - c[:price_at_sr_start])
        end
      end
    end

    describe Performance::Position do
      it 'realizes gains on an average cost basis' do
        perf = Performance.allocate
        perf.instance_variable_set(:@positions, Hash.new { |h, k| h[k] = {} })
        perf.instance_variable_set(:@action_id, 1)
        perf.send(:apply_change, 'p', 'c', 2, 100)
        perf.send(:apply_change, 'p', 'c', 2, 50)
        pos = perf.instance_variable_get(:@positions)['p']['c']
        expect(pos.average_cost).to eq(75.0)
        perf.send(:apply_change, 'p', 'c', -1, 90)
        expect(pos.shares).to eq(3)
        expect(pos.realized).to eq(15.0)
        expect(pos.cost).to eq(225.0)
      end

      it 'tracks a short sale as a credit and its cover as a buy' do
        perf = Performance.allocate
        perf.instance_variable_set(:@positions, Hash.new { |h, k| h[k] = {} })
        perf.instance_variable_set(:@action_id, 1)
        perf.send(:apply_change, 'p', 'c', -1, 60)
        pos = perf.instance_variable_get(:@positions)['p']['c']
        expect(pos.cost).to eq(-60.0)
        perf.send(:apply_change, 'p', 'c', 1, 40)
        expect(pos.shares).to eq(0)
        expect(pos.realized).to eq(20.0)
      end
    end
  end
end

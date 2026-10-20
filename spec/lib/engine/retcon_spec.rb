# frozen_string_literal: true

require './spec/spec_helper'
require 'json'

module Engine
  RETCON_FIXTURES = File.join(File.dirname(__FILE__), '..', '..', 'fixtures')

  def self.retcon_fixture(title, id)
    JSON.parse(File.read(File.join(RETCON_FIXTURES, title, "#{id}.json")))
  end

  describe Retcon do
    describe '.flatten' do
      it 'drops undone actions and renumbers the rest' do
        actions = [
          { 'type' => 'pass', 'entity' => 'a', 'entity_type' => 'player', 'id' => 1 },
          { 'type' => 'pass', 'entity' => 'b', 'entity_type' => 'player', 'id' => 2 },
          { 'type' => 'undo', 'entity' => 'b', 'entity_type' => 'player', 'id' => 3 },
          { 'type' => 'message', 'entity' => 'a', 'entity_type' => 'player', 'id' => 4, 'message' => 'oops' },
          { 'type' => 'pass', 'entity' => 'c', 'entity_type' => 'player', 'id' => 5 },
        ]
        flat = Retcon.flatten(actions)
        expect(flat.map { |a| a['entity'] }).to eq(%w[a a c])
        expect(flat.map { |a| a['type'] }).to eq(%w[pass message pass])
        expect(flat.map { |a| a['id'] }).to eq([1, 2, 3])
      end

      it 'restores redone actions' do
        actions = [
          { 'type' => 'pass', 'entity' => 'a', 'entity_type' => 'player', 'id' => 1 },
          { 'type' => 'pass', 'entity' => 'b', 'entity_type' => 'player', 'id' => 2 },
          { 'type' => 'undo', 'entity' => 'b', 'entity_type' => 'player', 'id' => 3 },
          { 'type' => 'redo', 'entity' => 'b', 'entity_type' => 'player', 'id' => 4 },
        ]
        expect(Retcon.flatten(actions).map { |a| a['entity'] }).to eq(%w[a b])
      end
    end

    describe '.scrub' do
      it 'removes stored auto actions and derived route results' do
        action = {
          'type' => 'run_routes',
          'auto_actions' => [{ 'type' => 'pass' }],
          'routes' => [{ 'train' => '2-0', 'connections' => [%w[A1 A3]], 'revenue' => 50, 'hexes' => %w[A1 A3] }],
        }
        scrubbed = Retcon.scrub(action)
        expect(scrubbed.key?('auto_actions')).to eq(false)
        expect(scrubbed['routes']).to eq([{ 'train' => '2-0', 'connections' => [%w[A1 A3]] }])
        expect(action['routes'].first['revenue']).to eq(50)
      end
    end

    describe '.remap_trains' do
      it 'renumbers trains in purchases and route runs' do
        remap = { '2-1' => '2-0' }
        buy = Retcon.remap_trains({ 'type' => 'buy_train', 'train' => '2-1' }, remap)
        run = Retcon.remap_trains({ 'type' => 'run_routes', 'routes' => [{ 'train' => '2-1' }, { 'train' => '3-0' }] }, remap)
        expect(buy['train']).to eq('2-0')
        expect(run['routes'].map { |r| r['train'] }).to eq(%w[2-0 3-0])
      end
    end

    describe 'deleting an early train purchase in 1817 16281' do
      let(:data) { Engine.retcon_fixture('1817', '16281') }

      it 'renumbers later purchases of the same train type instead of stopping' do
        session = Retcon::Session.new(data)
        target = session.actions.find { |a| a['type'] == 'buy_train' }
        session.delete(target['id'])
        result = session.replay
        renumbered = result.changes.select { |c| c['kind'] == 'train_renumbered' }
        expect(renumbered.empty?).to eq(false)
        expect(result.broken?).to eq(true)
        expect(result.broken_action['type']).to eq('pass')
        expect(result.suggestion['choice']).to eq('skip')
      end
    end

    [%w[1817 16281], %w[1844 1844_game_end_bankrupt]].each do |title, id|
      describe "#{title} #{id}" do
        let(:data) { Engine.retcon_fixture(title, id) }

        it 'replays the whole game with recomputed results to the same end state' do
          session = Retcon::Session.new(data)
          session.insert_after(0, { 'type' => 'message', 'entity' => data['players'].first['id'],
                                    'entity_type' => 'player', 'message' => 'retcon test' })
          result = session.replay
          expect(result.clean?).to eq(true)
          expect(session.preview(result)).to eq([])
          expect(result.game.finished).to eq(true)
        end

        it 'stops at a broken action and resumes when it is replaced' do
          session = Retcon::Session.new(data)
          index = session.actions.size / 2
          index += 1 until %w[pass message].include?(session.actions[index]['type']) == false
          original = session.actions[index]
          broken = original.merge('type' => 'lay_tile', 'hex' => 'ZZ99', 'tile' => 'nope-0', 'rotation' => 0)

          session.replace(original['id'], broken)
          result = session.replay
          expect(result.broken?).to eq(true)
          expect(result.broken_index).to eq(index)
          expect(result.game.exception).to eq(nil)
          expect(result.error_message.nil?).to eq(false)
          expect(result.expected['actions'].empty?).to eq(false)

          resolved = session.resolve(original)
          expect(resolved.clean?).to eq(true)
          expect(session.preview(resolved)).to eq([])
        end

        it 'reports the first action that no longer fits after a deletion' do
          session = Retcon::Session.new(data)
          target = session.actions.find { |a| a['type'] == 'buy_shares' || a['type'] == 'buy_train' }
          session.delete(target['id'])
          result = session.replay
          next if result.clean?

          expect(result.broken_index >= target['id'] - 1).to eq(true)
          expect(result.game.exception).to eq(nil)
          skipped = session.skip
          expect([:clean, :broken].include?(skipped.status)).to eq(true)
        end
      end
    end
  end
end

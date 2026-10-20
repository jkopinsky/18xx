# frozen_string_literal: true

require './spec/spec_helper'
require 'json'

module Engine
  REPLAY_FIXTURES = File.join(File.dirname(__FILE__), '..', '..', 'fixtures')

  def self.state_of(game)
    {
      players: game.players.map { |p| [p.id, p.cash, p.shares.map(&:id).sort] },
      corporations: game.corporations.map { |c| [c.id, c.cash, c.share_price&.price, c.trains.map(&:id).sort] },
      round: [game.round.class.name, game.turn, game.round.round_num],
      entity: game.current_entity&.id,
      actions: game.raw_actions.map { |a| a['id'] },
      log: game.log.size,
      undo: game.undo_possible,
      redo: game.redo_possible,
    }
  end

  describe ReplayCache do
    [%w[1817 15528 1600], %w[1844 160062 800]].each do |title, id, upto|
      describe "#{title} #{id}" do
        let(:data) do
          d = JSON.parse(File.read(File.join(REPLAY_FIXTURES, title, "#{id}.json")))
          d['actions'] = d['actions'].first(upto.to_i)
          d
        end
        let(:game) { Game.load(data) }

        def undo_for(game)
          {
            'type' => 'undo',
            'entity' => game.current_entity.id,
            'entity_type' => game.current_entity.player? ? 'player' : 'corporation',
            'id' => game.raw_actions.last['id'] + 1,
          }
        end

        it 'gives the same game as a full replay after an undo' do
          cache = ReplayCache.new(game)
          expect(cache.build!).to eq(true)
          game.replay_cache = cache

          undo = undo_for(game)
          fast = game.process_action(undo)
          slow = Game.load(data, actions: data['actions'] + [undo])

          expect(Engine.state_of(fast)).to eq(Engine.state_of(slow))
          expect(fast.ledger.audit).to eq([])
          expect(game.replay_cache).to be_nil
          expect(fast.replay_cache.ready_count).to eq(1)
        end

        it 'stays fast for several undos in a row' do
          cache = ReplayCache.new(game)
          cache.build!
          game.replay_cache = cache
          first_undo = undo_for(game)
          once = game.process_action(first_undo)
          second_undo = undo_for(once)
          twice = once.process_action(second_undo)
          slow = Game.load(data, actions: data['actions'] + [first_undo, second_undo])

          expect(Engine.state_of(twice)).to eq(Engine.state_of(slow))
          expect(twice.replay_cache.ready_count).to eq(0)
        end

        it 'gives the same game after undo then redo' do
          cache = ReplayCache.new(game)
          cache.build!
          game.replay_cache = cache
          undo = undo_for(game)
          after_undo = game.process_action(undo)

          redo_action = {
            'type' => 'redo',
            'entity' => undo['entity'],
            'entity_type' => undo['entity_type'],
            'id' => undo['id'] + 1,
          }
          fast = after_undo.process_action(redo_action)
          slow = Game.load(data, actions: data['actions'] + [undo, redo_action])

          expect(Engine.state_of(fast)).to eq(Engine.state_of(slow))
        end

        it 'is not used when the undo reaches back past its checkpoint' do
          cache = ReplayCache.new(game, checkpoint_id: game.raw_actions.last['id'])
          cache.build!
          game.replay_cache = cache
          undo = undo_for(game)
          undone = game.process_action(undo)
          slow = Game.load(data, actions: data['actions'] + [undo])

          expect(Engine.state_of(undone)).to eq(Engine.state_of(slow))
        end

        # 1817 only: in the 1844 fixture none of the last dividends before the
        # checkpoint can be changed and still replay cleanly to the same length.
        it 'is not used when an earlier action changed but the ids did not (a committed history fix)',
           if: title == '1817' do
          cache = ReplayCache.new(game)
          cache.build!
          game.replay_cache = cache

          # A fixed history as a retcon commits it: one earlier dividend
          # changed, every id the same, and it replays cleanly.
          edited = nil
          candidates = data['actions'].select { |a| a['type'] == 'dividend' && a['id'] < cache.checkpoint_id }
          candidates.last(8).reverse_each do |a|
            session = Retcon::Session.new(data, original_game: game)
            flat = session.actions.find { |x| x['id'] == a['id'] }
            next unless flat

            other = flat['kind'] == 'payout' ? 'withhold' : 'payout'
            result = session.replace(flat['id'], flat.merge('kind' => other)).replay
            next if !result.clean? || session.actions.size != game.raw_actions.size
            next if Engine.state_of(result.game)[:players] == Engine.state_of(game)[:players]

            edited = session.actions
            break
          end
          expect(edited).not_to be_nil
          expect(edited.map { |a| a['id'] }).to eq(game.raw_actions.map { |a| a['id'] })

          fast = game.clone(edited)
          slow = Game.load(data, actions: edited)
          expect(Engine.state_of(fast)).to eq(Engine.state_of(slow))
        end

        it 'is not used before it is ready' do
          cache = ReplayCache.new(game)
          cache.step(5)
          expect(cache.ready?).to eq(false)
          game.replay_cache = cache
          undo = undo_for(game)
          undone = game.process_action(undo)
          slow = Game.load(data, actions: data['actions'] + [undo])

          expect(Engine.state_of(undone)).to eq(Engine.state_of(slow))
        end
      end
    end
  end
end

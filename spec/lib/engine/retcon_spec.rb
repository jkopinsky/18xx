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
        # Passes by companies whose turn the change already ended are dropped
        # without asking; replay stops at the first action that really breaks.
        expect(result.changes.count { |c| c['kind'] == 'stale_pass_dropped' }).to be > 0
        expect(result.broken_action['type']).not_to eq('pass')
        # Outside an operating round the app can't tell whose turn is still to
        # come, so it offers both choices rather than advising a skip.
        expect(%w[skip either]).to include(result.suggestion['choice'])
      end

      it 'adds a move for a different entity before the broken action instead of replacing it' do
        session = Retcon::Session.new(data)
        target = session.actions.find { |a| a['type'] == 'buy_train' }
        session.delete(target['id'])
        result = session.replay
        broken = session.broken_recorded_action
        current = result.game.current_entity
        expect(current.id.to_s).not_to eq(broken['entity'].to_s)

        move = { 'type' => 'pass', 'entity' => current.id, 'entity_type' => current.player? ? 'player' : 'corporation' }
        expect(session.resolve_mode(move)).to eq(:insert)
        index = result.broken_index
        session.resolve(move)
        expect(session.actions[index]['entity'].to_s).to eq(current.id.to_s)
        expect(Retcon.comparable(Retcon.scrub(session.actions[index + 1])).except('auto_actions'))
          .to eq(Retcon.comparable(Retcon.scrub(broken)))
      end
    end

    describe 'a step used twice in one turn, in 1844 160062' do
      let(:data) { Engine.retcon_fixture('1844', '160062') }

      # 1844 asks about buying a company early in a turn and again at the end.
      # A recorded "no company" pass from the end of a turn must be matched to
      # that last step, not the early one.
      it 'asks instead of dropping an end-of-turn pass that now meets a train decision' do
        session = Retcon::Session.new(data)
        game = session.original_game
        steps = game.action_steps
        acts = session.actions
        index = (0...acts.size - 1).find do |i|
          a = acts[i]
          b = acts[i + 1]
          a['type'] == 'pass' && b['type'] == 'pass' && a['entity'] == b['entity'] &&
            steps[a['id']]&.at(1)&.name.to_s.end_with?('BuyTrain') &&
            steps[b['id']]&.at(1)&.name.to_s.end_with?('BuyCompany')
        end
        expect(index).not_to be_nil
        train_pass = acts[index]
        company_pass = acts[index + 1]
        expect(steps[company_pass['id']][2]).to be > steps[train_pass['id']][2]

        # Without the "no train" pass, the recorded "no company" pass arrives
        # at the train decision, which comes before it in the turn.
        result = session.delete(train_pass['id']).replay
        expect(result.broken?).to eq(true)
        expect(result.broken_index).to eq(index)
        expect(result.kind).to eq(:new_decision)
        expect(result.changes.none? { |c| c['kind'] == 'stale_pass_dropped' }).to eq(true)
        expect(session.resolve_mode(Retcon.scrub(company_pass))).to eq(:insert)
      end
    end

    describe 'a new decision at the end of a turn, in 1817 15528' do
      let(:data) { Engine.retcon_fixture('1817', '15528') }

      # GT withholds instead of paying out, so it has cash to pay off a loan:
      # a decision the original game never asked about. The next recorded
      # action is WT's, whose turn has not come yet.
      it 'asks for the new decision instead of suggesting the later move be skipped' do
        session = Retcon::Session.new(data)
        dividend = session.actions.find { |a| a['id'] == 253 }
        expect([dividend['type'], dividend['entity'], dividend['kind']]).to eq(%w[dividend GT payout])

        result = session.replace(253, dividend.merge('kind' => 'withhold')).replay
        expect(result.broken?).to eq(true)
        expect(result.game.current_entity.id).to eq('GT')
        expect(result.broken_action['entity']).to eq('WT')
        expect(Retcon.turn_status(result.game, 'WT')).to eq(:upcoming)
        expect(result.suggestion['choice']).to eq('move')
        expect(result.suggestion['reason']).to include("Don't skip it")

        gt_pass = { 'type' => 'pass', 'entity' => 'GT', 'entity_type' => 'corporation' }
        expect(session.resolve_mode(gt_pass)).to eq(:insert)
        recorded = session.broken_recorded_action
        index = result.broken_index
        session.resolve(gt_pass)
        expect(session.actions[index]['entity']).to eq('GT')
        expect(session.actions[index + 1].values_at('type', 'entity', 'hex', 'tile'))
          .to eq(recorded.values_at('type', 'entity', 'hex', 'tile'))
      end
    end

    describe 'changing a tile lay that later passes depended on, in 1817 15528' do
      let(:data) { Engine.retcon_fixture('1817', '15528') }
      let(:pass) { { 'type' => 'pass', 'entity' => 'A&S', 'entity_type' => 'corporation' } }

      # Recorded: A&S lays a tile (211), passes its second lay (212), runs
      # routes (213), pays (214). The table says A&S never laid that tile.
      def without_the_lay(session)
        expect(session.actions[210..213].map { |a| a['type'] }).to eq(%w[lay_tile pass run_routes dividend])
        session.replace(211, pass)
        session.replay
      end

      it 'drops the recorded pass for a decision that is already settled instead of spending it elsewhere' do
        session = Retcon::Session.new(data)
        result = without_the_lay(session)

        dropped = result.changes.select { |c| c['kind'] == 'stale_pass_dropped' }
        expect(dropped.size).to eq(1)
        expect(dropped.first['reason']).to include('Track')

        # Without the tile A&S has no route; the recorded run is flagged, not
        # consumed by whatever move the table makes next.
        expect(result.broken_action['type']).to eq('run_routes')
        expect(result.suggestion['choice']).to eq('skip')
        expect(session.resolve_mode(pass)).to eq(:insert)
      end

      it 'stops for a decision the original game did not have, and keeps the recorded action for later' do
        # The edited history from above, up to the end of A&S's turn, as if it
        # had been committed.
        session = Retcon::Session.new(data)
        lay = Retcon.deep_dup(session.actions[210])
        result = without_the_lay(session)
        result = session.skip while result.broken? && result.broken_action['entity'] == 'A&S'
        edited = data.merge('actions' => session.actions.first(result.broken_index || session.actions.size))

        # Now put the tile lay back: A&S gets its second lay decision again.
        again = Retcon::Session.new(edited)
        result = again.replace(211, lay).replay
        expect(result.broken?).to eq(true)
        expect(result.broken_action['entity']).to eq('A&S')
        recorded = again.broken_recorded_action
        index = result.broken_index
        expect(again.resolve_mode(pass)).to eq(:insert)

        again.resolve(pass)
        expect(Retcon.comparable(Retcon.scrub(again.actions[index + 1])).except('auto_actions'))
          .to eq(Retcon.comparable(Retcon.scrub(recorded)).except('auto_actions'))
      end

      it 'never sends the step notes out with the actions' do
        session = Retcon::Session.new(data)
        without_the_lay(session)
        expect(session.actions.none? { |a| a.key?(Retcon::STEP_TAG) }).to eq(true)
      end
    end

    describe 'paying out in full instead of half in 1817 15528' do
      let(:data) { Engine.retcon_fixture('1817', '15528') }

      # PSNR paid half, bought a train, then passed on the rest of its train
      # step. Paying out in full leaves it unable to afford the train.
      it 'keeps the table in step after the train purchase is replaced by a pass' do
        session = Retcon::Session.new(data)
        original = session.actions.map { |a| Retcon.deep_dup(a) }
        dividend = session.actions.find { |a| a['id'] == 381 }
        expect([dividend['type'], dividend['entity'], dividend['kind']]).to eq(%w[dividend PSNR half])
        expect(original[381..382].map { |a| [a['type'], a['entity']] }).to eq([%w[buy_train PSNR], %w[pass PSNR]])

        session.replace(381, dividend.merge('kind' => 'payout'))
        result = session.replay
        expect(result.broken?).to eq(true)
        expect(result.broken_action['type']).to eq('buy_train')

        pass = { 'type' => 'pass', 'entity' => 'PSNR', 'entity_type' => 'corporation' }
        expect(session.resolve_mode(pass)).to eq(:replace)
        result = session.resolve(pass)

        # The recorded "pass on the remaining trains" is dropped, and the next
        # company's recorded actions follow the table's pass directly.
        dropped = result.changes.select { |c| c['kind'] == 'stale_pass_dropped' }
        expect(dropped.map { |c| c['before'] }).to eq(['PSNR'])
        expect(session.actions[381]['type']).to eq('pass')
        expect(session.actions[381]['entity']).to eq('PSNR')
        expect([session.actions[382]['type'], session.actions[382]['entity']])
          .to eq([original[383]['type'], original[383]['entity']])
        expect(result.broken_action['entity']).to eq('PSNR') if result.broken?
        expect(result.broken_action['type']).not_to eq('pass') if result.broken?
      end

      it 'steps back to an earlier point with snapshot and restore' do
        session = Retcon::Session.new(data)
        dividend = session.actions.find { |a| a['id'] == 381 }
        session.replace(381, dividend.merge('kind' => 'payout'))
        session.replay
        snap = session.snapshot
        before = session.actions.map { |a| a['type'] }
        session.resolve({ 'type' => 'pass', 'entity' => 'PSNR', 'entity_type' => 'corporation' })
        expect(session.actions.map { |a| a['type'] }).not_to eq(before)

        session.restore(snap)
        expect(session.actions.map { |a| a['type'] }).to eq(before)
        expect(session.broken_recorded_action['type']).to eq('buy_train')
      end
    end

    [%w[1817 16281], %w[1844 1844_game_end_bankrupt]].each do |title, id|
      describe "#{title} #{id}" do
        let(:data) { Engine.retcon_fixture(title, id) }

        it 'replays the whole game with recomputed results to the same end state' do
          session = Retcon::Session.new(data)
          session.insert_after(0, {
                                 'type' => 'message',
                                 'entity' => data['players'].first['id'],
                                 'entity_type' => 'player',
                                 'message' => 'retcon test',
                               })
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
          expect(%i[clean broken].include?(skipped.status)).to eq(true)
        end
      end
    end
  end
end

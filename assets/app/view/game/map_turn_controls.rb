# frozen_string_literal: true

require 'view/game/actionable'
require 'view/game/pass_button'
require 'view/game/undo_button'

module View
  module Game
    # Pass and Undo on the Map tab, so track and token steps can be passed
    # (hotkey p) or taken back (hotkey u) without leaving the map.
    class MapTurnControls < Snabberb::Component
      include Actionable

      needs :actions, default: []

      MAP_ACTIONS = %w[lay_tile place_token remove_token].freeze

      def self.map_step?(game)
        round = game.round
        entity = round.active_step&.current_entity
        actions = entity ? round.actions_for(entity) || [] : []
        !(MAP_ACTIONS & actions).empty?
      end

      def render
        children = []
        if @actions.include?('pass') && !(MAP_ACTIONS & @actions).empty?
          entity = @game.round.active_step&.current_entity
          children << h(:span, { style: { marginRight: '0.5rem' } }, "#{entity.name}:") if entity
          children << h(PassButton)
        end
        children << h(UndoButton) unless @retcon
        h('div#map_turn_controls', { style: { margin: '0 0 0.5rem 0', display: 'flex', alignItems: 'center', gap: '0.5rem' } },
          children)
      end
    end
  end
end

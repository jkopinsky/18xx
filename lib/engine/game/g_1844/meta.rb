# frozen_string_literal: true

require_relative '../meta'

module Engine
  module Game
    module G1844
      module Meta
        include Game::Meta

        DEV_STAGE = :production

        GAME_DESIGNER = 'Helmut Ohley'
        GAME_LOCATION = 'Switzerland'
        GAME_PUBLISHER = :lookout
        GAME_RULES_URL = 'https://lookout-spiele.de/upload/en_1844_1854.html_Rules_1844_EN.pdf'
        GAME_INFO_URL = 'https://github.com/tobymao/18xx/wiki/1844'

        PLAYER_RANGE = [3, 7].freeze

        OPTIONAL_RULES = [
          {
            sym: :gb_destination_p4,
            short_name: 'House rule: GB destination with the Furka-Oberalp tile',
            desc: 'Not in the published rules. GB (V5) receives its destination bonus when the P4 '\
                  'Furka-Oberalp special tile is laid, instead of when the Gotthard tunnel is built.',
          },
          {
            sym: :multiple_mountain_railways,
            short_name: 'House rule: several Mountain Railways per stock round',
            desc: 'Not in the published rules. A player may buy more than one Mountain Railway in the same '\
                  "stock round (each purchase is still that turn's buy). Tunnel companies keep the "\
                  'one-per-round limit.',
          },
        ].freeze
      end
    end
  end
end

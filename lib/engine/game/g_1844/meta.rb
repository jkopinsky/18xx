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
          {
            sym: :three_trains_rust_phase5,
            short_name: 'House rule: 3 and 3H trains rust in phase 5',
            desc: 'Not in the published rules. 3 and 3H trains rust when the first 5 (or 5H) train is bought, '\
                  'instead of the first 6.',
          },
          {
            sym: :privates_close_phase6,
            short_name: 'House rule: private companies close in phase 6',
            desc: 'Not in the published rules. Private companies close when the first 6 (or 6H) train is bought '\
                  'instead of the first 5, and corporations may still buy them in phase 5. P7 still gives EVA '\
                  'from phase 5.',
          },
        ].freeze
      end
    end
  end
end

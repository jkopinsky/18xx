# frozen_string_literal: true

module Lib
  # Whether the site runs as a table server (set once by the app from the
  # server's TABLE_MODE). At a table every device may move for anyone, the
  # way hotseat works, but with the game stored on the server so any number
  # of devices can open it.
  module TableMode
    @on = false

    def self.on?
      @on
    end

    def self.on=(value)
      @on = value ? true : false
    end
  end
end

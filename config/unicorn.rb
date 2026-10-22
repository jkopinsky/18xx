# frozen_string_literal: true

require_relative '../db'
require 'message_bus'

PRODUCTION = ENV['RACK_ENV'] == 'production'

listen 9292
worker_processes PRODUCTION ? 4 : 1
# A table server compiles the whole app on the first page load after each
# start, which takes several minutes on a slower laptop; don't cut it off.
timeout PRODUCTION ? 15 : (ENV['TABLE_MODE'] == 'true' ? 900 : 60)
preload_app true

before_fork do |_server, _worker|
  DB.disconnect
end

after_fork do |_server, _worker|
  MessageBus.after_fork
end

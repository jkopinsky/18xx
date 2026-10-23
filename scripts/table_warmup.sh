#!/bin/sh
# Table mode: compile the app as soon as the server is up, instead of on the
# first page someone opens, then say when it's ready. The development setup
# compiles on demand; each file is cached in build/, so after the first time
# only changed files are recompiled.
PORT=${PORT:-9292}
until curl -s -o /dev/null --max-time 900 "http://localhost:$PORT/"; do sleep 5; done
for game in g_1817 g_1844; do
  curl -s -o /dev/null --max-time 900 "http://localhost:$PORT/assets/$game.js"
done
echo "Table server ready: open http://localhost:$PORT (other devices: http://<this laptop's address>:$PORT)"

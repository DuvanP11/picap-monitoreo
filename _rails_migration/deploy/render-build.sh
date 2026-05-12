#!/usr/bin/env bash
# bin/render-build.sh — script de build para Render (Rails 7.1)
# Falla rápido si algo va mal.
set -o errexit

echo "── 1. Bundle install ──"
bundle install

echo "── 2. Precompile assets (importmap + sprockets) ──"
bundle exec rails assets:precompile
bundle exec rails assets:clean

# Picap NO usa Active Record para datos (todo va a ClickHouse via HTTP).
# El SQLite default solo guarda sesiones/cookies si configurás session store DB.
# Si más adelante agregás tablas Rails: descomentá esto.
# echo "── 3. DB migrate ──"
# bundle exec rails db:migrate

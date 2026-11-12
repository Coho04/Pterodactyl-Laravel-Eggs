#!/bin/sh
# Writes egg-startup.sh as a single line into the "Startup" command of egg-laravel.json.
# Run after every change to egg-startup.sh:  sh scripts/build-egg-startup.sh
set -eu
cd "$(dirname "$0")/.."

line=$(grep -v '^[[:space:]]*#' egg-startup.sh | sed -E 's/^[[:space:]]+//' | grep -v '^$' | tr '\n' ' ' | sed -E 's/ +$//')

case "$line" in
  *'{{'*) echo "egg-startup.sh must not contain two opening curly braces in a row" >&2; exit 1 ;;
esac

tmp=$(mktemp)
# Keep the panel export format: 4-space indent, no newline at the end of the file.
jq --indent 4 --arg s "$line" '.startup_commands.Startup = $s' egg-laravel.json | perl -pe 'chomp if eof' > "$tmp"
mv "$tmp" egg-laravel.json
echo "Startup updated ($(printf '%s' "$line" | wc -c | tr -d ' ') characters)"

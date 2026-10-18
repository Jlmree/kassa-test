#!/usr/bin/env bash
# Maakt kassa.tar.gz: de gebouwde app, de databasebestanden en de serverscripts.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d dist ] || npm run build
T=$(mktemp -d)
cp -r dist supabase server "$T/"
rm -f "$T/dist/config.js"
echo "${1:-$(git describe --always --dirty 2>/dev/null || date +%Y%m%d)}" > "$T/versie"
tar czf kassa.tar.gz -C "$T" dist supabase/migrations server versie
rm -rf "$T"
echo kassa.tar.gz

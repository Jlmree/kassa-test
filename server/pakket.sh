#!/usr/bin/env bash
# Maakt het installatiebestand kassa-installatie.run: één bestand met de app,
# de databasebestanden, de serverscripts, de programma's PostgREST en Supabase Auth,
# de voorwaarden (LICENTIE.txt) en de licenties van die onderdelen (ONDERDELEN.txt).
#   server/pakket.sh [versie]
set -euo pipefail
cd "$(dirname "$0")/.."
POSTGREST_VERSIE=v12.2.3
AUTH_VERSIE=v2.177.0
VERSIE=${1:-$(git describe --always --dirty 2>/dev/null || date +%Y%m%d)}

npm run build >/dev/null
CACHE=.cache/programmas
mkdir -p "$CACHE"
[ -f "$CACHE/postgrest-$POSTGREST_VERSIE" ] || {
  curl -fsSL "https://github.com/PostgREST/postgrest/releases/download/$POSTGREST_VERSIE/postgrest-$POSTGREST_VERSIE-linux-static-x64.tar.xz" | tar xJ -C "$CACHE"
  mv "$CACHE/postgrest" "$CACHE/postgrest-$POSTGREST_VERSIE"
}
[ -f "$CACHE/auth-$AUTH_VERSIE.tar.gz" ] || \
  curl -fsSL -o "$CACHE/auth-$AUTH_VERSIE.tar.gz" "https://github.com/supabase/auth/releases/download/$AUTH_VERSIE/auth-$AUTH_VERSIE-x86.tar.gz"
for p in "PostgREST $POSTGREST_VERSIE|PostgREST/postgrest/$POSTGREST_VERSIE" "Supabase Auth $AUTH_VERSIE|supabase/auth/$AUTH_VERSIE"; do
  [ -f "$CACHE/${p%%|*}.txt" ] || curl -fsSL -o "$CACHE/${p%%|*}.txt" "https://raw.githubusercontent.com/${p#*|}/LICENSE"
done

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/auth" "$T/supabase" "$T/server"
cp -r dist "$T/dist" && rm -f "$T/dist/config.js"
cp -r supabase/migrations "$T/supabase/"
cp server/*.sh server/welkom.html "$T/server/"
install -m 755 "$CACHE/postgrest-$POSTGREST_VERSIE" "$T/bin/postgrest"
tar xzf "$CACHE/auth-$AUTH_VERSIE.tar.gz" -C "$T/auth"
echo "$VERSIE" > "$T/versie"
cp LICENTIE.txt "$T/"
node server/onderdelen.mjs "$T/ONDERDELEN.txt" "$CACHE/PostgREST $POSTGREST_VERSIE.txt" "$CACHE/Supabase Auth $AUTH_VERSIE.txt"

sed "s/@VERSIE@/$VERSIE/" server/uitpakker.sh > kassa-installatie.run
tar czf - -C "$T" . >> kassa-installatie.run
chmod +x kassa-installatie.run
echo "kassa-installatie.run ($(du -h kassa-installatie.run | cut -f1), versie $VERSIE)"

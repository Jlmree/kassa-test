#!/usr/bin/env bash
# Back-up van de kassa-database. Draait elk uur (kassa-backup.timer, met "elkuur").
# Elk uur: alleen als er iets veranderd is sinds de vorige back-up. Oude back-ups
# worden uitgedund: alles van de laatste 2 dagen, daarna de laatste van elke dag
# tot 90 dagen, daarna de laatste van elke maand tot 2 jaar. De nieuwste blijft altijd.
# Zit er een USB-stick in met de naam KASSA-BACKUP, dan gaat er ook een kopie naartoe,
# versleuteld met het wachtwoord uit /etc/kassa/backup.wachtwoord: wie de stick
# meeneemt, kan er zonder dat wachtwoord niets mee (geen kaartcodes, geen gegevens).
#   backup.sh              back-up maken (altijd, bijv. voor een update)
#   backup.sh elkuur       alleen als er iets veranderd is
#   backup.sh wachtwoord   het wachtwoord van de back-ups op de stick laten zien
set -euo pipefail
WW=/etc/kassa/backup.wachtwoord
if [ "${1:-}" = wachtwoord ]; then
  [ -s "$WW" ] || { echo "Er is nog geen back-upwachtwoord (installeer de kassa opnieuw)."; exit 1; }
  echo "Wachtwoord van de back-ups op de USB-stick: $(cat "$WW")"
  exit 0
fi
MAP=/var/backups/kassa
mkdir -p "$MAP"

# Oude back-ups uitdunnen (zie boven). $1 = map, $2 = einde van de naam.
uitdunnen() {
  local map=$1 eind=$2 nu f naam s dag t eerste=1
  local -A dagen=() maanden=()
  nu=$(date +%s)
  while IFS= read -r f; do
    naam=${f##*/}; s=${naam#kassa-}; s=${s%"$eind"}
    [[ $s =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})-([0-9]{2})([0-9]{2})([0-9]{2})$ ]] || continue
    dag=${BASH_REMATCH[1]}
    t=$(date -d "$dag ${BASH_REMATCH[2]}:${BASH_REMATCH[3]}:${BASH_REMATCH[4]}" +%s) || continue
    if (( eerste )); then eerste=0
    elif (( nu - t < 2 * 86400 )); then :
    elif (( nu - t < 90 * 86400 )) && [ -z "${dagen[$dag]:-}" ]; then :
    elif (( nu - t < 730 * 86400 )) && [ -z "${maanden[${dag:0:7}]:-}" ]; then :
    else rm -f -- "$f"; continue
    fi
    dagen[$dag]=1; maanden[${dag:0:7}]=1
  done < <(find "$map" -maxdepth 1 -name "kassa-*$eind" | sort -r)
}

# Stand van de gegevens: verandert bij elke wijziging in de kassa en bij inloggen of een nieuw wachtwoord.
stand() {
  su postgres -c "psql -XtAq -d kassa" <<'SQL' 2>/dev/null || true
select (select last_value from public.wijziging) || '/' || coalesce((select max(greatest(updated_at, last_sign_in_at))::text from auth.users), '');
SQL
}

NU=$(stand)
LAATSTE=$(find "$MAP" -maxdepth 1 -name 'kassa-*.dump' | sort | tail -n 1)
if [ "${1:-}" = elkuur ] && [ -n "$NU" ] && [ -n "$LAATSTE" ] && [ "$NU" = "$(cat "$MAP/.stand" 2>/dev/null)" ]; then
  # Niets veranderd: geen nieuwe back-up, wel de laatste nog op de stick zetten als die er net in zit.
  BESTAND=$LAATSTE
else
  BESTAND="$MAP/kassa-$(date +%Y-%m-%d-%H%M%S).dump"
  if ! su postgres -c "pg_dump -Fc kassa" > "$BESTAND.tmp"; then
    rm -f "$BESTAND.tmp"; echo "Back-up mislukt." >&2; exit 1
  fi
  mv "$BESTAND.tmp" "$BESTAND"
  # De stand pas onthouden als de back-up gelukt is.
  if [ -n "$NU" ]; then echo "$NU" > "$MAP/.stand"; fi
fi
uitdunnen "$MAP" .dump

if [ -s "$WW" ] && STICK=$(blkid -L KASSA-BACKUP 2>/dev/null); then
  M=$(mktemp -d)
  if mount "$STICK" "$M" 2>/dev/null; then
    mkdir -p "$M/kassa"
    DOEL="$M/kassa/$(basename "$BESTAND").enc"
    if [ -s "$DOEL" ]; then :
    elif openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass "file:$WW" -in "$BESTAND" -out "$DOEL.tmp"; then
      mv "$DOEL.tmp" "$DOEL"
      # Oude, onversleutelde back-ups van vóór deze versie weghalen: die staan ook op de server zelf.
      find "$M/kassa" -name 'kassa-*.dump' -delete
    else
      rm -f "$DOEL.tmp"
    fi
    uitdunnen "$M/kassa" .dump.enc
    umount "$M"
  fi
  rmdir "$M"
fi
echo "$BESTAND"

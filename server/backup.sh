#!/usr/bin/env bash
# Back-up van de kassa-database. Draait elk uur (kassa-backup.timer).
# Zit er een USB-stick in met de naam KASSA-BACKUP, dan gaat er ook een kopie naartoe,
# versleuteld met het wachtwoord uit /etc/kassa/backup.wachtwoord: wie de stick
# meeneemt, kan er zonder dat wachtwoord niets mee (geen kaartcodes, geen gegevens).
#   backup.sh              back-up maken
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
BESTAND="$MAP/kassa-$(date +%Y-%m-%d-%H%M%S).dump"
su postgres -c "pg_dump -Fc kassa" > "$BESTAND.tmp" && mv "$BESTAND.tmp" "$BESTAND"
find "$MAP" -name 'kassa-*.dump' -mtime +14 -delete

if [ -s "$WW" ] && STICK=$(blkid -L KASSA-BACKUP 2>/dev/null); then
  M=$(mktemp -d)
  if mount "$STICK" "$M" 2>/dev/null; then
    mkdir -p "$M/kassa"
    DOEL="$M/kassa/$(basename "$BESTAND").enc"
    if openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass "file:$WW" -in "$BESTAND" -out "$DOEL.tmp"; then
      mv "$DOEL.tmp" "$DOEL"
      # Oude, onversleutelde back-ups van vóór deze versie weghalen: die staan ook op de server zelf.
      find "$M/kassa" -name 'kassa-*.dump' -delete
    else
      rm -f "$DOEL.tmp"
    fi
    find "$M/kassa" -name 'kassa-*.dump.enc' -mtime +90 -delete
    umount "$M"
  fi
  rmdir "$M"
fi
echo "$BESTAND"

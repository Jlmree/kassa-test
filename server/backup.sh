#!/usr/bin/env bash
# Back-up van de kassa-database. Draait elk uur (kassa-backup.timer).
# Zit er een USB-stick in met de naam KASSA-BACKUP, dan gaat er ook een kopie naartoe.
set -euo pipefail
MAP=/var/backups/kassa
mkdir -p "$MAP"
BESTAND="$MAP/kassa-$(date +%Y-%m-%d-%H%M%S).dump"
su postgres -c "pg_dump -Fc kassa" > "$BESTAND.tmp" && mv "$BESTAND.tmp" "$BESTAND"
find "$MAP" -name 'kassa-*.dump' -mtime +14 -delete

if STICK=$(blkid -L KASSA-BACKUP 2>/dev/null); then
  M=$(mktemp -d)
  if mount "$STICK" "$M" 2>/dev/null; then
    mkdir -p "$M/kassa" && cp "$BESTAND" "$M/kassa/"
    find "$M/kassa" -name 'kassa-*.dump' -mtime +90 -delete
    umount "$M"
  fi
  rmdir "$M"
fi
echo "$BESTAND"

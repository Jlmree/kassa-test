#!/usr/bin/env bash
# Back-up van de kassa-database(s). Draait elk uur (kassa-backup.timer).
#   backup.sh          alle kassa's op deze server
#   backup.sh voetbal  alleen deze kassa
# Zit er een USB-stick in met de naam KASSA-BACKUP, dan gaat er ook een kopie naartoe.
set -euo pipefail
. /opt/kassa/bin/kassa-lib.sh
NAMEN=${1:-$(kassa_namen)}
BESTANDEN=()
for n in $NAMEN; do
  kassa_paden "$n"
  mkdir -p "$K_BACKUP" && chmod 700 "$K_BACKUP"
  BESTAND="$K_BACKUP/$n-$(date +%Y-%m-%d-%H%M%S).dump"
  su postgres -c "pg_dump -Fc $K_DB" > "$BESTAND.tmp" && mv "$BESTAND.tmp" "$BESTAND"
  find "$K_BACKUP" -maxdepth 1 -name "$n-*.dump" -mtime +14 -delete
  BESTANDEN+=("$BESTAND")
done

if STICK=$(blkid -L KASSA-BACKUP 2>/dev/null); then
  M=$(mktemp -d)
  if mount "$STICK" "$M" 2>/dev/null; then
    for B in "${BESTANDEN[@]}"; do
      # De eerste kassa in de map kassa/ (zoals altijd), de andere in een eigen map.
      D="$M/$(basename "$B" | sed 's/-[0-9-]*\.dump$//')"
      mkdir -p "$D" && cp "$B" "$D/"
      find "$D" -name '*.dump' -mtime +90 -delete
    done
    umount "$M"
  fi
  rmdir "$M"
fi
printf '%s\n' "${BESTANDEN[@]}"

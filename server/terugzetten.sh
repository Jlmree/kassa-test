#!/usr/bin/env bash
# Zet een back-up terug. LET OP: alles wat sinds die back-up is gebeurd, gaat verloren.
#   sudo /opt/kassa/bin/terugzetten.sh /var/backups/kassa/kassa-2026-10-18-040000.dump
#   sudo /opt/kassa/bin/terugzetten.sh /var/backups/kassa/voetbal/voetbal-2026-10-18-040000.dump
# Aan de bestandsnaam ziet het script bij welke kassa de back-up hoort.
set -euo pipefail
. /opt/kassa/bin/kassa-lib.sh
B=${1:?gebruik: terugzetten.sh <back-upbestand>   (zie ls /var/backups/kassa)}
[ -f "$B" ] || { echo "Bestand niet gevonden: $B"; exit 1; }
N=$(basename "$B" | sed 's/-[0-9-]*\.dump$//')
kassa_namen | grep -qx "$N" || { echo "Bij welke kassa hoort $B? Er is geen kassa \"$N\" op deze server ($(kassa_namen | tr '\n' ' '))."; exit 1; }
kassa_paden "$N"
read -r -p "Alle huidige gegevens van kassa \"$N\" vervangen door $B? Typ ja: " a
[ "$a" = ja ] || exit 1
# Eerst een kopie maken: de veiligheidsback-up hieronder mag dit bestand nooit raken.
T=$(mktemp); trap 'rm -f "$T"' EXIT
cp "$B" "$T"
echo "Eerst nog een back-up van de huidige stand..."
/opt/kassa/bin/backup.sh "$N"
dienst() { if [ -d /run/systemd/system ]; then systemctl "$1" "$K_UNIT-auth" "$K_UNIT-rest"; elif [ "$1" = start ]; then echo "Herstart de server om opnieuw te kunnen inloggen."; fi; }
dienst stop
su postgres -c "dropdb --force $K_DB" && su postgres -c "createdb $K_DB"
su postgres -c "pg_restore -d $K_DB --exit-on-error" < "$T"
dienst start
echo "Teruggezet."

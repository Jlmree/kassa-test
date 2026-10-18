#!/usr/bin/env bash
# Zet een back-up terug. LET OP: alles wat sinds die back-up is gebeurd, gaat verloren.
#   sudo /opt/kassa/bin/terugzetten.sh /var/backups/kassa/kassa-2026-10-18-040000.dump
set -euo pipefail
B=${1:?gebruik: terugzetten.sh <back-upbestand>   (zie ls /var/backups/kassa)}
[ -f "$B" ] || { echo "Bestand niet gevonden: $B"; exit 1; }
read -r -p "Alle huidige gegevens vervangen door $B? Typ ja: " a
[ "$a" = ja ] || exit 1
# Eerst een kopie maken: de veiligheidsback-up hieronder mag dit bestand nooit raken.
T=$(mktemp); trap 'rm -f "$T"' EXIT
cp "$B" "$T"
echo "Eerst nog een back-up van de huidige stand..."
/opt/kassa/bin/backup.sh
dienst() { if [ -d /run/systemd/system ]; then systemctl "$1" kassa-auth kassa-rest; elif [ "$1" = start ]; then echo "Herstart de server om opnieuw te kunnen inloggen."; fi; }
dienst stop
su postgres -c "dropdb --force kassa" && su postgres -c "createdb kassa"
su postgres -c "pg_restore -d kassa --exit-on-error" < "$T"
dienst start
echo "Teruggezet."

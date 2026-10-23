#!/usr/bin/env bash
# Zet een back-up terug. LET OP: alles wat sinds die back-up is gebeurd, gaat verloren.
#   sudo /opt/kassa/bin/terugzetten.sh /var/backups/kassa/kassa-2026-10-18-040000.dump
#   sudo /opt/kassa/bin/terugzetten.sh /media/stick/kassa/kassa-2026-10-18-040000.dump.enc   (van de USB-stick)
# Een versleutelde back-up (.enc) gaat open met het back-upwachtwoord van deze kassa;
# komt hij van een andere computer, dan vraagt het script om het wachtwoord van die kassa.
set -euo pipefail
B=${1:?gebruik: terugzetten.sh <back-upbestand>   (zie ls /var/backups/kassa)}
[ -f "$B" ] || { echo "Bestand niet gevonden: $B"; exit 1; }
WW=/etc/kassa/backup.wachtwoord
# Eerst een kopie maken: de veiligheidsback-up hieronder mag dit bestand nooit raken.
T=$(mktemp); trap 'rm -f "$T"' EXIT
case "$B" in
  *.enc)
    ontsleutel() { openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass "$1" -in "$B" -out "$T" 2>/dev/null; }
    if ! { [ -s "$WW" ] && ontsleutel "file:$WW"; }; then
      read -r -s -p "Wachtwoord van de back-up (van de kassa waar hij gemaakt is): " w; echo
      KASSA_WW=$w ontsleutel env:KASSA_WW || { echo "Dat wachtwoord klopt niet."; exit 1; }
    fi
    ;;
  *) cp "$B" "$T" ;;
esac
read -r -p "Alle huidige gegevens vervangen door $B? Typ ja: " a
[ "$a" = ja ] || exit 1
echo "Eerst nog een back-up van de huidige stand..."
/opt/kassa/bin/backup.sh
dienst() { if [ -d /run/systemd/system ]; then systemctl "$1" kassa-auth kassa-rest; elif [ "$1" = start ]; then echo "Herstart de server om opnieuw te kunnen inloggen."; fi; }
dienst stop
su postgres -c "dropdb --force kassa" && su postgres -c "createdb kassa"
su postgres -c "pg_restore -d kassa --exit-on-error" < "$T"
dienst start
echo "Teruggezet."

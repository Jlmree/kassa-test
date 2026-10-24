#!/usr/bin/env bash
# Zet een back-up terug. LET OP: alles wat sinds die back-up is gebeurd, gaat verloren.
#   sudo /opt/kassa/bin/terugzetten.sh /var/backups/kassa/kassa-2026-10-18-040000.dump
#   sudo /opt/kassa/bin/terugzetten.sh /media/stick/kassa/kassa-2026-10-18-040000.dump.enc   (van de USB-stick)
#   sudo /opt/kassa/bin/terugzetten.sh /root/voetbal-2026-10-18-040000.dump.enc voetbal    (bij kassa "voetbal")
# Zonder naam ziet het script aan de bestandsnaam bij welke kassa de back-up hoort.
# Een versleutelde back-up (.enc) gaat open met het back-upwachtwoord van die kassa;
# komt hij van een andere computer, dan vraagt het script om het wachtwoord van daar.
set -euo pipefail
. /opt/kassa/bin/kassa-lib.sh
B=${1:?gebruik: terugzetten.sh <back-upbestand> [naam van de kassa]   (zie ls /var/backups/kassa)}
[ -f "$B" ] || { echo "Bestand niet gevonden: $B"; exit 1; }
N=${2:-$(basename "$B" | sed -E 's/-[0-9-]*\.dump(\.enc)?$//')}
kassa_namen | grep -qx -- "$N" || { echo "Bij welke kassa hoort $B? Er is geen kassa \"$N\" op deze server ($(kassa_namen | tr '\n' ' ')). Geef de naam mee: terugzetten.sh $B <naam>"; exit 1; }
kassa_paden "$N"
# Eerst een kopie maken: de veiligheidsback-up hieronder mag dit bestand nooit raken.
T=$(mktemp); trap 'rm -f "$T"' EXIT
case "$B" in
  *.enc)
    ontsleutel() { openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass "$1" -in "$B" -out "$T" 2>/dev/null; }
    if ! { [ -s "$K_WW" ] && ontsleutel "file:$K_WW"; }; then
      read -r -s -p "Back-upwachtwoord (van de kassa waar hij gemaakt is): " w; echo
      KASSA_WW=$w ontsleutel env:KASSA_WW || { echo "Dat wachtwoord klopt niet."; exit 1; }
    fi
    ;;
  *) cp "$B" "$T" ;;
esac
read -r -p "Alle huidige gegevens van kassa \"$N\" vervangen door $B? Typ ja: " a
[ "$a" = ja ] || exit 1
echo "Eerst nog een back-up van de huidige stand..."
/opt/kassa/bin/backup.sh "$N" >/dev/null
dienst() { if [ -d /run/systemd/system ]; then systemctl "$1" "$K_UNIT-auth" "$K_UNIT-rest"; elif [ "$1" = start ]; then echo "Herstart de server om opnieuw te kunnen inloggen."; fi; }
dienst stop
su postgres -c "dropdb --force $K_DB" && su postgres -c "createdb $K_DB"
su postgres -c "pg_restore -d $K_DB --exit-on-error" < "$T"
# Een back-up van een oudere versie bijwerken naar de databaseversie van deze kassa.
[ -d /opt/kassa/migraties ] && /opt/kassa/bin/migraties.sh /opt/kassa/migraties "$K_DB"
# Wat bij deze server hoort (wifi, downloadadres, versie) niet uit de back-up overnemen.
kassa_systeem_schrijven || true
/opt/kassa/bin/bijwerker.sh >/dev/null 2>&1 || true
dienst start
echo "Teruggezet."

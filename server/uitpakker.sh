#!/usr/bin/env bash
# Bar-kassa installatiebestand.
#
#   bash kassa-installatie.run                                    installeren of bijwerken
#   bash kassa-installatie.run --duckdns mijnbar.duckdns.org TOKEN    met een echt certificaat via DuckDNS
#
# Start als root (na "su -", of met sudo). Je gegevens blijven altijd staan.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Start dit als root:  sudo bash $0   (of eerst: su -)"; exit 1; }
echo "Bar-kassa installatiebestand, versie @VERSIE@"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
REGEL=$(awk '/^__KASSA_PAKKET__$/ { print NR + 1; exit }' "$0")
tail -n +"$REGEL" "$0" | tar xz -C "$T" || { echo "Het installatiebestand is beschadigd. Download het opnieuw."; exit 1; }
KASSA_BRON="$T" bash "$T/server/installeer.sh" "$@"
exit 0
__KASSA_PAKKET__

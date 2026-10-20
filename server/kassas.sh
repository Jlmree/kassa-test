#!/usr/bin/env bash
# Overzicht en beheer van de kassa's op deze server (als root).
#   kassas.sh                    overzicht: naam, adres, accounts, omzet laatste 30 dagen, laatste back-up
#   kassas.sh verwijderen <naam> een kassa weghalen (er blijft een laatste back-up staan)
# Een nieuwe kassa erbij:  bash kassa-installatie.run --naam voetbal --domein voetbal.mijndomein.nl
set -euo pipefail
. /opt/kassa/bin/kassa-lib.sh
[ "$(id -u)" = 0 ] || { echo "Start dit als root (met sudo of na su -)."; exit 1; }
sql() { runuser -u postgres -- psql -d "$1" -Atq -c "$2" 2>/dev/null; }

case "${1:-}" in
  ""|lijst)
    printf '%-12s %-34s %9s %14s %9s  %s\n' NAAM ADRES ACCOUNTS "OMZET 30 DGN" DATABASE "LAATSTE BACK-UP"
    for n in $(kassa_namen); do
      kassa_paden "$n"
      adres=$(kassa_lees KASSA_DOMEIN); adres=https://${adres:-$(hostname -I | awk '{print $1}')}
      accounts=$(sql "$K_DB" "select count(*) from public.profielen")
      omzet=$(sql "$K_DB" "select replace(to_char(coalesce(sum(totaal_cent),0)/100.0, 'FM9999990.00'), '.', ',') from public.verkopen where not geannuleerd and ts > now() - interval '30 days'")
      grootte=$(sql "$K_DB" "select pg_size_pretty(pg_database_size(current_database()))")
      laatste=$(ls -t "$K_BACKUP"/"$n"-*.dump 2>/dev/null | head -1)
      printf '%-12s %-34s %9s %14s %9s  %s\n' "$n" "$adres" "${accounts:-?}" "€ ${omzet:-?}" "${grootte:-?}" "${laatste:+$(date -r "$laatste" '+%F %H:%M')}"
    done
    echo
    echo "Versie: $(cat /opt/kassa/versie 2>/dev/null || echo onbekend)"
    ;;
  verwijderen)
    N=${2:?gebruik: kassas.sh verwijderen <naam>}
    kassa_namen | grep -qx "$N" || { echo "Er is geen kassa \"$N\"."; exit 1; }
    [ "$N" != kassa ] || { echo "De eerste kassa kan niet worden verwijderd."; exit 1; }
    kassa_paden "$N"
    read -r -p "Kassa \"$N\" met alle gegevens verwijderen? Typ de naam ter bevestiging: " a
    [ "$a" = "$N" ] || { echo "Niet verwijderd."; exit 1; }
    echo "Laatste back-up maken..."
    B=$(/opt/kassa/bin/backup.sh "$N")
    if [ -d /run/systemd/system ]; then
      systemctl disable --now "$K_UNIT-auth" "$K_UNIT-rest" >/dev/null 2>&1 || true
    else
      pkill -f "$K_ETC/postgrest.conf" 2>/dev/null || true
    fi
    rm -f "/etc/systemd/system/$K_UNIT-auth.service" "/etc/systemd/system/$K_UNIT-rest.service"
    su postgres -c "dropdb --force $K_DB"
    rm -rf "$K_ETC" "$(dirname "$K_APP")"
    caddy_schrijven
    if [ -d /run/systemd/system ]; then systemctl daemon-reload; systemctl reload caddy; fi
    echo "Verwijderd. De laatste back-up staat in $B"
    echo "Terugzetten kan door de kassa opnieuw te installeren (--naam $N --domein ...) en dan: /opt/kassa/bin/terugzetten.sh $B"
    ;;
  *) sed -n '2,5p' "$0"; exit 1 ;;
esac

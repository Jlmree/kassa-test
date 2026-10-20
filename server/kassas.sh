#!/usr/bin/env bash
# Overzicht en beheer van de kassa's op deze server (als root).
#   kassas.sh                    overzicht: naam, adres, accounts, omzet laatste 30 dagen, laatste back-up
#   kassas.sh beheerder [naam]   een beheerder aanmaken (of iemand weer beheerder maken, met een nieuw wachtwoord)
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
  beheerder)
    # Een beheerder aanmaken op de server zelf. Zo kan niemand anders via internet
    # als eerste een account aanmaken en beheerder worden. Bestaat de naam al, dan
    # wordt die persoon (weer) beheerder met het nieuwe wachtwoord: de noodknop als
    # je jezelf hebt buitengesloten.
    N=${2:-kassa}
    kassa_namen | grep -qx "$N" || { echo "Er is geen kassa \"$N\" ($(kassa_namen | tr '\n' ' '))."; exit 1; }
    kassa_paden "$N"
    db() { runuser -u postgres -- psql -d "$K_DB" -Atq -v ON_ERROR_STOP=1 "$@"; }
    while :; do
      read -r -p "Naam van de beheerder (om mee in te loggen, bijv. Jelmer): " naam
      naam=$(printf '%s' "$naam" | sed 's/^ *//; s/ *$//')
      if [ -z "$naam" ]; then continue; fi
      # Zelfde omzetting als de app (inlogEmail): kleine letters, de rest wordt een punt.
      if printf '%s' "$naam" | LC_ALL=C grep -q '[^ -~]'; then echo "Gebruik een naam zonder accenten of speciale tekens."; continue; fi
      if [[ "$naam" == *@* ]]; then email=$(printf '%s' "$naam" | tr '[:upper:]' '[:lower:]')
      else
        email=$(printf '%s' "$naam" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/./g; s/^\.+//; s/\.+$//')
        email="${email:-gebruiker}@kassa.lokaal"
      fi
      break
    done
    while :; do
      read -r -s -p "Wachtwoord (minstens 8 tekens): " ww; echo
      [ "${#ww}" -ge 8 ] || { echo "Te kort."; continue; }
      read -r -s -p "Nog een keer: " ww2; echo
      [ "$ww" = "$ww2" ] && break
      echo "De wachtwoorden zijn niet gelijk."
    done
    bestaand=$(db -v e="$email" <<<"select id from auth.users where email = :'e'")
    if [ -n "$bestaand" ]; then
      db -v id="$bestaand" -v w="$ww" <<'SQL'
update auth.users set encrypted_password = extensions.crypt(:'w', extensions.gen_salt('bf')), updated_at = now() where id = :'id';
update public.profielen set rol = 'beheerder', actief = true where id = :'id';
SQL
      echo "$naam is nu beheerder van \"$N\", met het nieuwe wachtwoord."
    else
      esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
      poort=$(kassa_lees KASSA_AUTH_POORT); poort=${poort:-9999}
      sleutel=$(jwt service_role "$(kassa_jwt_geheim)")
      uit=$(mktemp); trap 'rm -f "$uit"' EXIT
      antwoord=$(curl --noproxy '*' -sS -o "$uit" -w '%{http_code}' -X POST "http://127.0.0.1:$poort/admin/users" \
        -H "Authorization: Bearer $sleutel" -H 'Content-Type: application/json' \
        -d "{\"email\":\"$(esc "$email")\",\"password\":\"$(esc "$ww")\",\"email_confirm\":true,\"user_metadata\":{\"naam\":\"$(esc "$naam")\"}}" || true)
      [ "$antwoord" = 200 ] || { echo "Aanmaken mislukt (code ${antwoord:-geen verbinding}): $(cat "$uit")"; exit 1; }
      db -v e="$email" <<<"update public.profielen set rol = 'beheerder', actief = true where id = (select id from auth.users where email = :'e')"
      echo "Beheerder $naam aangemaakt voor \"$N\". Log in de app in met naam \"$naam\" en dit wachtwoord."
    fi
    # Vanaf nu wordt een account uit de app nooit meer vanzelf beheerder.
    db <<<"update public.instellingen set eerste_account_wordt_beheerder = false"
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
  *) sed -n '2,6p' "$0"; exit 1 ;;
esac

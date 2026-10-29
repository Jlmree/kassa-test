#!/usr/bin/env bash
# Tapkas installeren. Normaal start je dit via het installatiebestand
# (als root):  bash kassa-installatie.run
# Werkt op Debian 12 of Ubuntu 24.04, op een computer in het gebouw (bijv. een
# HP t620) of op een gehuurde server op internet.
#
# Computer in het gebouw, met een eigen wifi-netwerk voor de telefoons (wifi-kaart of -stick nodig):
#   bash kassa-installatie.run --wifi                    (naam "Kassa", wachtwoord wordt bedacht)
#   bash kassa-installatie.run --wifi-naam "Kantine Kassa" --wifi-wachtwoord geheim123
#   uitzetten: --zonder-wifi
# Optioneel, voor een echt https-certificaat via DuckDNS:
#   bash kassa-installatie.run --duckdns mijnbar.duckdns.org <token>
# De kassa ook op het eigen scherm van de server (aanraakscherm aan de bar, alleen Debian):
#   bash kassa-installatie.run --scherm        (uitzetten: --zonder-scherm)
#
# Gehuurde server op internet: een adres dat naar de server wijst (eigen domein, of
# een gratis naam bij duckdns.org met het IP-adres van de server). Er komt een
# firewall en veiligheidsupdates gaan vanzelf:
#   bash kassa-installatie.run --domein kassa.mijnclub.nl
# Meer kassa's op dezelfde server, elk met een eigen naam, adres en eigen gegevens:
#   bash kassa-installatie.run --naam voetbal --domein voetbal.mijnclub.nl
# Daarnaast een website op een eigen adres (pagina's, proefversie en aanvraagformulier):
#   bash kassa-installatie.run --website tapkas.nl     (later: /opt/kassa/bin/website.sh)
#
# Bij een nieuwe installatie laat het eerst zien wat er waar komt en vraagt het
# akkoord met de voorwaarden (LICENTIE.txt). Zonder vragen, bijv. vanuit een script:
#   bash kassa-installatie.run --akkoord
#
# Wordt dit script los gestart (zonder installatiebestand), dan haalt het
# eerst het nieuwste installatiebestand op en voert dat uit.
# Het kan veilig opnieuw worden gedraaid: het werkt alle kassa's op deze server
# bij en bestaande gegevens blijven staan.
set -euo pipefail

REPO="${KASSA_REPO:-Jlmree/kassa-test}"
OPT=/opt/kassa
ETC=/etc/kassa

stap() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
fout() { printf '\n\033[1;31mFOUT: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || fout "Start dit als root (met sudo of na su -)."
[ "$(uname -m)" = x86_64 ] || fout "Alleen x86_64 (64-bit pc) wordt ondersteund."
command -v apt-get >/dev/null || fout "Alleen Debian of Ubuntu wordt ondersteund."

# Opties gelden voor de kassa die met --naam is gekozen (zonder --naam: de eerste kassa).
ARGS=("$@")
NAAM=kassa
while [ $# -gt 0 ]; do
  case "$1" in
    --naam) NAAM=${2:?naam ontbreekt}; shift 2 ;;
    --domein) C_DOMEIN=${2:?adres ontbreekt}; C_TOKEN=; shift 2 ;;
    --duckdns) C_DOMEIN=${2:?naam ontbreekt}; C_TOKEN=${3:?token ontbreekt}; shift 3 ;;
    --zonder-duckdns|--zonder-domein) C_DOMEIN=; C_TOKEN=; shift ;;
    --wifi) KASSA_WIFI=1; WIFI_OPTIE=1; shift ;;
    --wifi-naam) KASSA_WIFI=1; KASSA_WIFI_NAAM=${2:?wifi-naam ontbreekt}; WIFI_OPTIE=1; shift 2 ;;
    --wifi-wachtwoord) KASSA_WIFI=1; KASSA_WIFI_WACHTWOORD=${2:?wifi-wachtwoord ontbreekt}; WIFI_OPTIE=1; shift 2 ;;
    --zonder-wifi) KASSA_WIFI=0; WIFI_OPTIE=1; shift ;;
    --scherm) C_SCHERM=1; shift ;;
    --zonder-scherm) C_SCHERM=0; shift ;;
    --akkoord) KASSA_AKKOORD=1; shift ;;
    --website) WEBSITE_ADRES=${2:?adres van de website ontbreekt}; shift 2 ;;
    *) fout "Onbekende optie: $1" ;;
  esac
done

# Los gestart: het installatiebestand ophalen en dat laten installeren.
if [ -z "${KASSA_BRON:-}" ]; then
  command -v curl >/dev/null || { apt-get update -q && apt-get install -y -q curl ca-certificates >/dev/null; }
  stap "Nieuwste installatiebestand ophalen"
  T=$(mktemp -d)
  curl -fL --progress-bar -o "$T/kassa-installatie.run" "https://github.com/$REPO/releases/latest/download/kassa-installatie.run" \
    || fout "Downloaden mislukt. Is er internet?"
  # Opties gewoon doorgeven: zonder opties blijven eerdere keuzes (adres, wifi, scherm) staan.
  bash "$T/kassa-installatie.run" "${ARGS[@]}"
  rm -rf "$T"
  exit 0
fi
[ -d "$KASSA_BRON/dist" ] || fout "Installatiebestand is onvolledig."
# shellcheck source=kassa-lib.sh
. "$KASSA_BRON/server/kassa-lib.sh"

# Welke kassa's: alle bestaande, plus de gekozen (de eerste kassa is er altijd).
BESTAAND=0; [ -f "$ETC/instellingen.env" ] && BESTAAND=1
[ "$NAAM" = kassa ] || kassa_naam_geldig "$NAAM" || fout "Kies als naam 2 tot 20 kleine letters of cijfers, beginnend met een letter (bijv. voetbal)."
[ "$NAAM" = kassa ] || [ "$BESTAAND" = 1 ] || fout "Installeer eerst de eerste kassa (zonder --naam, met --domein). Daarna kun je er kassa's met een eigen naam bij zetten."
NIEUWE_KASSA=0; kassa_namen | grep -qx -- "$NAAM" || NIEUWE_KASSA=1
KASSAS=$(printf '%s\n' "kassa" "$(kassa_namen)" "$NAAM" | grep . | awk '!x[$0]++')
kassa_paden "$NAAM"
C_DOMEIN_NU=${C_DOMEIN-$(kassa_lees KASSA_DOMEIN)}
C_TOKEN_NU=${C_TOKEN-$(kassa_lees KASSA_DUCKDNS_TOKEN)}
if [ "$NAAM" != kassa ]; then
  [ -n "${C_TOKEN:-}" ] && fout "DuckDNS met een token kan alleen bij de eerste kassa. Gebruik --domein naam.duckdns.org en vul op duckdns.org het IP-adres van deze server in."
  [ -n "${C_SCHERM:-}${WIFI_OPTIE:-}" ] && fout "Eigen wifi en eigen scherm kunnen alleen bij de eerste kassa (in het gebouw)."
  [ -n "$C_DOMEIN_NU" ] || fout "Een kassa met een eigen naam heeft een eigen adres nodig: --domein $NAAM.mijnclub.nl (dat adres moet naar deze server wijzen)."
fi
if [ -n "$C_DOMEIN_NU" ]; then
  [[ "$C_DOMEIN_NU" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$ ]] || fout "\"$C_DOMEIN_NU\" is geen geldig adres (bijv. kassa.mijnclub.nl, zonder https://)."
  for n in $(kassa_namen); do
    [ "$n" = "$NAAM" ] && continue
    kassa_paden "$n"
    [ "$(kassa_lees KASSA_DOMEIN)" != "$C_DOMEIN_NU" ] || fout "Het adres $C_DOMEIN_NU is al van kassa \"$n\"."
  done
fi

# Eerdere wifi-keuzes van de eerste kassa (naam en wachtwoord mogen spaties bevatten, dus een eigen bestand).
if [ -f "$ETC/wifi.env" ]; then
  { IFS= read -r OUD_WIFI; IFS= read -r OUD_WIFI_NAAM; IFS= read -r OUD_WIFI_WW; } < <(
    . "$ETC/wifi.env"; printf '%s\n' "${KASSA_WIFI:-0}" "${KASSA_WIFI_NAAM:-}" "${KASSA_WIFI_WACHTWOORD:-}")
  KASSA_WIFI=${KASSA_WIFI:-$OUD_WIFI}
  KASSA_WIFI_NAAM=${KASSA_WIFI_NAAM:-$OUD_WIFI_NAAM}
  KASSA_WIFI_WACHTWOORD=${KASSA_WIFI_WACHTWOORD:-$OUD_WIFI_WW}
fi
if [ "${KASSA_WIFI:-0}" = 1 ]; then
  KASSA_WIFI_NAAM=${KASSA_WIFI_NAAM:-Kassa}
  # Een wachtwoord dat makkelijk over te typen is, bijv. 3fa9-81c2-d0e4.
  KASSA_WIFI_WACHTWOORD=${KASSA_WIFI_WACHTWOORD:-$(openssl rand -hex 6 | sed -E 's/(....)(....)(....)/\1-\2-\3/')}
  [ "${#KASSA_WIFI_WACHTWOORD}" -ge 8 ] && [ "${#KASSA_WIFI_WACHTWOORD}" -le 63 ] || fout "Het wifi-wachtwoord moet 8 tot 63 tekens zijn."
  [ "$(printf '%s' "$KASSA_WIFI_NAAM" | wc -c)" -le 32 ] || fout "De wifi-naam mag hoogstens 32 tekens zijn."
fi
# Komt deze server op internet (een adres zonder DuckDNS-token)? Dan firewall en automatische updates.
ONLINE=0
if [ -n "$C_DOMEIN_NU" ] && [ -z "$C_TOKEN_NU" ]; then ONLINE=1
elif [ "$BESTAAND" = 1 ] && kassa_online; then ONLINE=1
fi
[ "$ONLINE" = 1 ] && [ "${KASSA_WIFI:-0}" = 1 ] && [ "$NAAM" = kassa ] && [ -n "${C_DOMEIN:-}" ] \
  && fout "Een eigen wifi-netwerk past niet bij een server op internet. Laat --domein weg, of zet de wifi uit met --zonder-wifi."

# ───────────────────────── Welkom en voorwaarden ─────────────────────────
# Vragen kan alleen in een terminal; bij bijwerken vanuit de app is die er niet.
kan_vragen() { [ -t 1 ] && { : </dev/tty; } 2>/dev/null; }
NIEUWE_VERSIE=$(cat "$KASSA_BRON/versie")
VRIJ_MB=$(df -Pm / | awk 'NR == 2 { print $4 }')
if [ "$BESTAAND" = 1 ]; then NODIG_MB=500; else NODIG_MB=2000; fi
VW=$(sed -n 's/^Versie \([0-9][0-9]*\).*/\1/p' "$KASSA_BRON/LICENTIE.txt" | head -n 1)
VW_OUD=$(sed -n 's/^VOORWAARDEN=//p' "$ETC/akkoord" 2>/dev/null || true)
gb() { awk -v m="$1" 'BEGIN { printf "%.1f", m / 1000 }' | tr . ,; }
ruimte() { echo "  Vrije ruimte   $(gb "$VRIJ_MB") GB (nodig: $(gb "$NODIG_MB") GB)"; }

if kan_vragen; then
  kassa_paden "$NAAM"
  if [ "$BESTAAND" = 1 ] && [ "$NIEUWE_KASSA" = 1 ]; then
    printf '\n\033[1mNieuwe kassa "%s" toevoegen\033[0m, versie %s\n' "$NAAM" "$NIEUWE_VERSIE"
    echo "De kassa krijgt een eigen database, eigen accounts en eigen back-ups; de andere kassa's merken er niets van."
    echo "  Adres          https://$C_DOMEIN_NU (moet al naar deze server wijzen)"
    echo "  Instellingen   $K_ETC"
    echo "  Gegevens       database \"$K_DB\""
    echo "  Back-ups       $K_BACKUP"
    ruimte
    echo "De andere kassa's op deze server worden ook bijgewerkt naar versie $NIEUWE_VERSIE."
  elif [ "$BESTAAND" = 1 ]; then
    printf '\n\033[1mTapkas bijwerken\033[0m naar versie %s\n' "$NIEUWE_VERSIE"
    echo "Nu: versie $(cat "$OPT/versie" 2>/dev/null || echo onbekend). Je gegevens en instellingen blijven staan."
    [ "$(wc -l <<<"$KASSAS")" -gt 1 ] && echo "Kassa's op deze server: $(echo $KASSAS)"
  else
    printf '\n\033[1mTapkas installeren\033[0m, versie %s\n' "$NIEUWE_VERSIE"
    if [ "$ONLINE" = 1 ]; then WIFI_TEKST="niet nodig (server op internet)"
    elif [ "${KASSA_WIFI:-0}" = 1 ]; then WIFI_TEKST="eigen netwerk \"$KASSA_WIFI_NAAM\" voor de telefoons"
    else WIFI_TEKST="geen eigen wifi (de telefoons gebruiken het netwerk van het gebouw)"; fi
    PAKKETTEN="PostgreSQL, Caddy (webserver)"
    [ "${KASSA_WIFI:-0}" = 1 ] && PAKKETTEN="$PAKKETTEN, hostapd en dnsmasq (wifi)"
    [ "$ONLINE" = 1 ] && PAKKETTEN="$PAKKETTEN, nftables (firewall), unattended-upgrades"
    if [ "${C_SCHERM:-0}" = 1 ]; then SCHERM_TEKST="ja, de kassa ook op het scherm van deze computer"; else SCHERM_TEKST=nee; fi
    echo "Dit komt er op deze computer:"
    echo "  Programma      $OPT"
    echo "  Instellingen   $ETC (alleen leesbaar voor root)"
    echo "  Gegevens       database \"kassa\" in /var/lib/postgresql"
    if [ "$ONLINE" = 1 ]; then
      echo "  Adres          https://$C_DOMEIN_NU (moet al naar deze server wijzen)"
      echo "  Back-ups       /var/backups/kassa, en versleuteld te downloaden in de app"
      echo "  Beveiliging    firewall (alleen SSH, http en https open), veiligheidsupdates gaan vanzelf"
    else
      echo "  Back-ups       /var/backups/kassa, en versleuteld op een USB-stick met de naam KASSA-BACKUP"
    fi
    echo "  Pakketten      $PAKKETTEN"
    echo "  Wifi           $WIFI_TEKST"
    echo "  Eigen scherm   $SCHERM_TEKST"
    ruimte
    echo "De kassa start voortaan vanzelf als de computer aangaat. Gebruik er een computer voor"
    echo "waar verder niets op hoeft te draaien."
  fi
fi
[ "$VRIJ_MB" -ge "$NODIG_MB" ] || fout "Te weinig vrije schijfruimte: $VRIJ_MB MB vrij, $NODIG_MB MB nodig. Maak ruimte vrij of gebruik een grotere schijf."

if [ "$VW_OUD" != "$VW" ]; then
  if [ "${KASSA_AKKOORD:-0}" = 1 ]; then
    :
  elif kan_vragen; then
    echo
    if [ -n "$VW_OUD" ]; then echo "De voorwaarden zijn veranderd. Lees ze opnieuw."; else echo "Lees eerst de voorwaarden."; fi
    read -r -p "Druk op Enter om ze te tonen (spatie: verder lezen). " _ </dev/tty
    if command -v more >/dev/null; then more "$KASSA_BRON/LICENTIE.txt" </dev/tty; else cat "$KASSA_BRON/LICENTIE.txt"; fi
    echo
    read -r -p "Typ ja om akkoord te gaan en verder te gaan (iets anders stopt): " ANTWOORD </dev/tty
    case "$ANTWOORD" in ja|Ja|JA) ;; *) echo "Gestopt. Er is niets veranderd."; exit 1 ;; esac
  elif [ "$BESTAAND" = 0 ]; then
    fout "Start de installatie in een terminal om de voorwaarden te lezen en te accepteren, of geef --akkoord mee."
  else
    # Bijwerken zonder terminal (vanuit de app): niet halverwege stoppen. Het oude akkoord
    # blijft gelden; bij de volgende keer in een terminal wordt opnieuw gevraagd.
    VW=$VW_OUD
    echo "Let op: $([ -n "$VW_OUD" ] && echo "de voorwaarden zijn veranderd" || echo "er zijn nu voorwaarden"), zie $OPT/LICENTIE.txt. Bij de volgende installatie in een terminal word je gevraagd akkoord te gaan."
  fi
  if [ "$VW" != "$VW_OUD" ]; then
    mkdir -p "$ETC" && chmod 700 "$ETC"
    printf 'VOORWAARDEN=%s\nDATUM=%s\nDOOR=%s\n' "$VW" "$(date '+%F %T')" "${SUDO_USER:-$(id -un)}" > "$ETC/akkoord"
  fi
elif kan_vragen && [ "$BESTAAND" = 1 ]; then
  echo "Stoppen kan nog met Ctrl+C."; sleep 3
fi

# ───────────────────────── Pakketten ─────────────────────────
stap "Pakketten installeren (PostgreSQL, Caddy) — dit kan een paar minuten duren"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q postgresql caddy curl ca-certificates openssl >/dev/null
if [ "${KASSA_WIFI:-0}" = 1 ]; then
  apt-get install -y -q hostapd dnsmasq-base iw rfkill iproute2 nftables qrencode >/dev/null
fi
if [ "$ONLINE" = 1 ]; then
  apt-get install -y -q nftables unattended-upgrades >/dev/null
  # Veiligheidsupdates van Debian/Ubuntu elke dag vanzelf installeren.
  printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' > /etc/apt/apt.conf.d/20auto-upgrades
fi
timedatectl set-timezone Europe/Amsterdam 2>/dev/null || true

mkdir -p "$OPT/bin" "$ETC" /var/backups/kassa
chmod 700 "$ETC" /var/backups/kassa

# ───────────────────────── Programma's ─────────────────────────
stap "Programma's plaatsen"
install -m 755 "$KASSA_BRON/bin/postgrest" "$OPT/bin/postgrest"
rm -rf "$OPT/auth" && cp -r "$KASSA_BRON/auth" "$OPT/auth"
install -m 755 "$KASSA_BRON"/server/*.sh "$KASSA_BRON"/server/*.py "$OPT/bin/"
# De verkoopwebsite (alleen in gebruik met website.sh aan).
[ -d "$KASSA_BRON/website" ] && { rm -rf "$OPT/website" && cp -r "$KASSA_BRON/website" "$OPT/website"; }
# De databasebestanden bewaren: terugzetten.sh werkt een oudere back-up ermee bij.
rm -rf "$OPT/migraties" && cp -r "$KASSA_BRON/supabase/migrations" "$OPT/migraties"
cp "$KASSA_BRON/LICENTIE.txt" "$KASSA_BRON/ONDERDELEN.txt" "$OPT/"
rm -rf "$OPT/welkom" && mkdir -p "$OPT/welkom" && cp "$KASSA_BRON/server/welkom.html" "$OPT/welkom/index.html"

# ───────────────────────── Geheimen ─────────────────────────
# De databasewachtwoorden gelden voor de hele server; elke kassa heeft daarnaast
# een eigen sleutel (JWT_SECRET), zodat een login van de ene kassa nooit bij een andere werkt.
stap "Sleutels aanmaken"
if [ ! -f "$ETC/geheim.env" ]; then
  umask 077
  cat > "$ETC/geheim.env" <<EOF
JWT_SECRET=$(openssl rand -hex 32)
AUTH_DB_WACHTWOORD=$(openssl rand -hex 24)
REST_DB_WACHTWOORD=$(openssl rand -hex 24)
EOF
  umask 022
fi
# shellcheck disable=SC1091
. "$ETC/geheim.env"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
jwt() { # rol geheim
  local h p
  h=$(printf '{"alg":"HS256","typ":"JWT"}' | b64url)
  p=$(printf '{"role":"%s","iss":"kassa","iat":1700000000,"exp":4102444800}' "$1" | b64url)
  printf '%s.%s.%s' "$h" "$p" "$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -hmac "$2" -binary | b64url)"
}

# ───────────────────────── Database ─────────────────────────
stap "Database inrichten"
command -v systemctl >/dev/null && [ -d /run/systemd/system ] && systemctl enable --now postgresql >/dev/null 2>&1 || true
PG_VERSIE=$(ls /etc/postgresql | sort -V | tail -1)
# Elke kassa houdt een paar verbindingen open; met meerdere kassa's is de standaard (100) te krap.
PG_CONF=/etc/postgresql/$PG_VERSIE/main/conf.d/kassa.conf
if [ "$(wc -l <<<"$KASSAS")" -gt 1 ] && ! grep -qs 'max_connections = 300' "$PG_CONF"; then
  mkdir -p "$(dirname "$PG_CONF")"
  echo "max_connections = 300" > "$PG_CONF"
  if [ -d /run/systemd/system ]; then systemctl restart postgresql; else pg_ctlcluster "$PG_VERSIE" main restart 2>/dev/null || true; fi
fi
if ! su postgres -c "pg_isready -q"; then
  # Zonder systemd (bijv. in een container): cluster zelf starten.
  pg_ctlcluster "$PG_VERSIE" main start
fi
# Rollen gelden voor de hele server (alle kassa's).
su postgres -c "PGOPTIONS=--client-min-messages=warning psql -v ON_ERROR_STOP=1 -q" <<EOF
do \$\$ begin
  if not exists (select from pg_roles where rolname = 'anon') then create role anon nologin noinherit; end if;
  if not exists (select from pg_roles where rolname = 'authenticated') then create role authenticated nologin noinherit; end if;
  if not exists (select from pg_roles where rolname = 'service_role') then create role service_role nologin noinherit bypassrls; end if;
  if not exists (select from pg_roles where rolname = 'authenticator') then create role authenticator login noinherit; end if;
  if not exists (select from pg_roles where rolname = 'supabase_auth_admin') then create role supabase_auth_admin login createrole; end if;
end \$\$;
alter role authenticator password '$REST_DB_WACHTWOORD';
alter role supabase_auth_admin password '$AUTH_DB_WACHTWOORD';
grant anon, authenticated, service_role to authenticator;
EOF

# Vrije poorten voor een nieuwe kassa (de eerste kassa gebruikt 9999 en 3000).
vrije_poorten() {
  local gebruikt="" n p=10000
  for n in $(kassa_namen); do kassa_paden "$n"; gebruikt+=" $(kassa_lees KASSA_AUTH_POORT) $(kassa_lees KASSA_REST_POORT)"; done
  while [[ " $gebruikt " == *" $p "* || " $gebruikt " == *" $((p + 1)) "* ]]; do p=$((p + 2)); done
  echo "$p $((p + 1))"
}

NIEUW_BACKUP_WW=""
# Richt één kassa in of werkt hem bij: instellingen, database, inlogsysteem, app en diensten.
kassa_inrichten() {
  local n=$1 domein token scherm auth rest jwt_geheim anon_key pool omschrijving=Tapkas
  kassa_paden "$n"
  [ "$n" = kassa ] || omschrijving="Tapkas $n:"
  mkdir -p "$K_ETC" "$K_BACKUP" "$(dirname "$K_APP")"
  chmod 700 "$K_ETC" "$K_BACKUP"
  domein=$(kassa_lees KASSA_DOMEIN); token=$(kassa_lees KASSA_DUCKDNS_TOKEN); scherm=$(kassa_lees KASSA_SCHERM)
  auth=$(kassa_lees KASSA_AUTH_POORT); rest=$(kassa_lees KASSA_REST_POORT)
  if [ "$n" = "$NAAM" ]; then
    [ -n "${C_DOMEIN+x}" ] && { domein=$C_DOMEIN; token=$C_TOKEN; }
    [ -n "${C_SCHERM+x}" ] && scherm=$C_SCHERM
  fi
  if [ "$n" = kassa ]; then auth=${auth:-9999}; rest=${rest:-3000}; pool=10
  else pool=4; [ -n "$auth" ] || read -r auth rest < <(vrije_poorten)
  fi

  umask 077
  {
    [ "$n" = kassa ] && echo "KASSA_REPO=$REPO"
    echo "KASSA_DOMEIN=${domein:-}"
    echo "KASSA_DUCKDNS_TOKEN=${token:-}"
    [ "$n" = kassa ] && echo "KASSA_SCHERM=${scherm:-0}"
    echo "KASSA_AUTH_POORT=$auth"
    echo "KASSA_REST_POORT=$rest"
  } > "$K_ETC/instellingen.env"
  # Eigen sleutel per kassa; de eerste kassa gebruikt die uit geheim.env.
  if [ "$n" = kassa ]; then jwt_geheim=$JWT_SECRET
  else
    [ -f "$K_ETC/sleutel.env" ] || echo "JWT_SECRET=$(openssl rand -hex 32)" > "$K_ETC/sleutel.env"
    jwt_geheim=$(sed -n 's/^JWT_SECRET=//p' "$K_ETC/sleutel.env")
  fi
  # Eigen wachtwoord voor de versleutelde back-ups (USB-stick en downloaden). Nodig om een
  # back-up op een andere computer terug te zetten, dus aan het eind laten zien om op te schrijven.
  if [ ! -s "$K_WW" ]; then
    openssl rand -hex 8 | sed -E 's/(....)(....)(....)(....)/\1-\2-\3-\4/' > "$K_WW"
    NIEUW_BACKUP_WW+=" $n"
  fi
  # Geheim pad waarop een beheerder de nieuwste back-up downloadt (zie backup.sh).
  [ -s "$K_ETC/download.env" ] || echo "PAD=$(openssl rand -hex 16)" > "$K_ETC/download.env"
  umask 022
  anon_key=$(jwt anon "$jwt_geheim")

  if [ "$n" = kassa ] && [ -n "$domein" ] && [ -n "$token" ]; then
    "$OPT/bin/duckdns.sh" installeer "$domein" "$token"
  elif [ "$n" = kassa ] && [ -f /etc/systemd/system/kassa-duckdns.timer ] && [ -z "$token" ]; then
    systemctl disable --now kassa-duckdns.timer >/dev/null 2>&1 || true
  fi

  if ! su postgres -c "psql -tAc \"select 1 from pg_database where datname='$K_DB'\"" | grep -q 1; then
    su postgres -c "createdb $K_DB"
  fi
  su postgres -c "PGOPTIONS=--client-min-messages=warning psql -v ON_ERROR_STOP=1 -q -d $K_DB" <<EOF
create schema if not exists auth authorization supabase_auth_admin;
grant usage on schema auth to anon, authenticated, service_role;
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
grant usage on schema extensions to anon, authenticated, service_role;
grant usage on schema public to anon, authenticated, service_role;
grant create on database $K_DB to supabase_auth_admin;
create table if not exists public.kassa_migraties (naam text primary key, ts timestamptz not null default now());
revoke all on public.kassa_migraties from anon, authenticated;
EOF

  cat > "$K_ETC/auth.env" <<EOF
GOTRUE_DB_DRIVER=postgres
DATABASE_URL=postgres://supabase_auth_admin:$AUTH_DB_WACHTWOORD@127.0.0.1:5432/$K_DB?search_path=auth
GOTRUE_DB_MIGRATIONS_PATH=$OPT/auth/migrations
GOTRUE_DB_MAX_POOL_SIZE=$pool
GOTRUE_JWT_SECRET=$jwt_geheim
GOTRUE_JWT_EXP=43200
GOTRUE_JWT_AUD=authenticated
GOTRUE_JWT_DEFAULT_GROUP_NAME=authenticated
GOTRUE_JWT_ADMIN_ROLES=service_role
GOTRUE_SITE_URL=https://${domein:-kassa}
API_EXTERNAL_URL=https://${domein:-kassa}/auth/v1
GOTRUE_MAILER_AUTOCONFIRM=true
GOTRUE_EXTERNAL_EMAIL_ENABLED=true
GOTRUE_DISABLE_SIGNUP=false
GOTRUE_PASSWORD_MIN_LENGTH=8
GOTRUE_API_HOST=127.0.0.1
PORT=$auth
GOTRUE_LOG_LEVEL=warn
GOTRUE_RATE_LIMIT_TOKEN_REFRESH=1000
GOTRUE_RATE_LIMIT_VERIFY=1000
# Na 10 verkeerde wachtwoorden in 10 minuten gaat een account even op slot (zie de database).
GOTRUE_HOOK_PASSWORD_VERIFICATION_ATTEMPT_ENABLED=true
GOTRUE_HOOK_PASSWORD_VERIFICATION_ATTEMPT_URI=pg-functions://postgres/public/hook_password_verification_attempt
EOF
  cat > "$K_ETC/postgrest.conf" <<EOF
db-uri = "postgres://authenticator:$REST_DB_WACHTWOORD@127.0.0.1:5432/$K_DB"
db-schemas = "public"
db-anon-role = "anon"
db-pool = $pool
jwt-secret = "$jwt_geheim"
server-host = "127.0.0.1"
server-port = $rest
EOF
  chmod 600 "$K_ETC/auth.env" "$K_ETC/postgrest.conf"

  ( set -a; . "$K_ETC/auth.env"; set +a; cd "$OPT/auth" && ./auth migrate >/dev/null )
  "$OPT/bin/migraties.sh" "$KASSA_BRON/supabase/migrations" "$K_DB"
  kassa_systeem_schrijven

  rm -rf "$K_APP.nieuw" && cp -r "$KASSA_BRON/dist" "$K_APP.nieuw"
  cat > "$K_APP.nieuw/config.js" <<EOF
// Gemaakt door de installatie. De database draait op deze server zelf.
window.KASSA_CONFIG = { supabaseUrl: location.origin, supabaseAnonKey: '$anon_key' };
EOF
  rm -rf "$K_APP.oud"
  [ -d "$K_APP" ] && mv "$K_APP" "$K_APP.oud"
  mv "$K_APP.nieuw" "$K_APP"

  cat > "/etc/systemd/system/$K_UNIT-auth.service" <<EOF
[Unit]
Description=$omschrijving inloggen (Supabase Auth)
After=postgresql.service
Requires=postgresql.service
[Service]
EnvironmentFile=$K_ETC/auth.env
WorkingDirectory=$OPT/auth
ExecStart=$OPT/auth/auth serve
Restart=always
RestartSec=3
DynamicUser=yes
[Install]
WantedBy=multi-user.target
EOF
  # De API leest zijn instellingen (met wachtwoord) via een systemd-credential,
  # zodat /etc/kassa alleen voor root leesbaar blijft.
  cat > "/etc/systemd/system/$K_UNIT-rest.service" <<EOF
[Unit]
Description=$omschrijving database-API (PostgREST)
After=postgresql.service
Requires=postgresql.service
[Service]
LoadCredential=postgrest.conf:$K_ETC/postgrest.conf
ExecStart=/bin/sh -c 'exec $OPT/bin/postgrest "\$CREDENTIALS_DIRECTORY/postgrest.conf"'
ExecReload=/bin/kill -SIGUSR1 \$MAINPID
Restart=always
RestartSec=3
DynamicUser=yes
[Install]
WantedBy=multi-user.target
EOF
}

# De eigen wifi (alleen de eerste kassa) vóór het inrichten opslaan: de wifi-code bij een uitnodiging leest hem.
umask 077
printf 'KASSA_WIFI=%q\nKASSA_WIFI_NAAM=%q\nKASSA_WIFI_WACHTWOORD=%q\n' "${KASSA_WIFI:-0}" "${KASSA_WIFI_NAAM:-}" "${KASSA_WIFI_WACHTWOORD:-}" > "$ETC/wifi.env"
umask 022

stap "Kassa installeren"
for n in $KASSAS; do
  [ "$(wc -l <<<"$KASSAS")" -gt 1 ] && echo "  $n"
  kassa_inrichten "$n"
done
cp "$KASSA_BRON/versie" "$OPT/versie"

# ───────────────────────── Webserver en https ─────────────────────────
stap "Webserver instellen"
caddy_schrijven || fout "Caddy-instellingen ongeldig"

# ───────────────────────── Diensten ─────────────────────────
stap "Diensten starten"
cat > /etc/systemd/system/kassa-backup.service <<EOF
[Unit]
Description=Tapkas back-up
[Service]
Type=oneshot
ExecStart=$OPT/bin/backup.sh elkuur
EOF
cat > /etc/systemd/system/kassa-backup.timer <<EOF
[Unit]
Description=Tapkas back-up elk uur
[Timer]
OnCalendar=hourly
Persistent=true
[Install]
WantedBy=timers.target
EOF
# Voert verzoeken uit de app uit (Beheer → Instellingen → Bijwerken).
cat > /etc/systemd/system/kassa-bijwerker.service <<EOF
[Unit]
Description=Tapkas bijwerken vanuit de app
After=postgresql.service
[Service]
Type=oneshot
ExecStart=$OPT/bin/bijwerker.sh
EOF
cat > /etc/systemd/system/kassa-bijwerker.timer <<EOF
[Unit]
Description=Tapkas: elke minuut kijken of er bijgewerkt moet worden
[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=5s
[Install]
WantedBy=timers.target
EOF

UNITS=""
for n in $KASSAS; do kassa_paden "$n"; UNITS+=" $K_UNIT-auth $K_UNIT-rest"; done
if [ -d /run/systemd/system ]; then
  systemctl daemon-reload
  # shellcheck disable=SC2086
  systemctl enable --now $UNITS kassa-backup.timer kassa-bijwerker.timer >/dev/null 2>&1
  # shellcheck disable=SC2086
  systemctl restart $UNITS
  systemctl enable caddy >/dev/null 2>&1 && systemctl restart caddy
else
  # Geen systemd (container/test): zelf starten.
  pkill -x auth 2>/dev/null || true; pkill -x postgrest 2>/dev/null || true; pkill -x caddy 2>/dev/null || true
  sleep 1
  for n in $KASSAS; do
    kassa_paden "$n"
    ( cd "$OPT/auth"; set -a; . "$K_ETC/auth.env"; set +a; exec ./auth serve ) </dev/null >"/var/log/$K_UNIT-auth.log" 2>&1 &
    "$OPT/bin/postgrest" "$K_ETC/postgrest.conf" </dev/null >"/var/log/$K_UNIT-rest.log" 2>&1 &
  done
  HOME=/var/lib/caddy caddy run --config /etc/caddy/Caddyfile --adapter caddyfile </dev/null >/var/log/kassa-caddy.log 2>&1 &
fi

stap "Controleren"
for n in $KASSAS; do
  kassa_paden "$n"
  auth=$(kassa_lees KASSA_AUTH_POORT); rest=$(kassa_lees KASSA_REST_POORT)
  for _ in $(seq 1 30); do
    curl --noproxy "*" -fsS -o /dev/null "http://127.0.0.1:$auth/health" 2>/dev/null && curl --noproxy "*" -fsS -o /dev/null "http://127.0.0.1:$rest/" 2>/dev/null && break
    sleep 1
  done
  curl --noproxy "*" -fsS -o /dev/null "http://127.0.0.1:$auth/health" || fout "Inlogsysteem van $n start niet (zie: journalctl -u $K_UNIT-auth)"
  curl --noproxy "*" -fsS -o /dev/null "http://127.0.0.1:$rest/" || fout "Database-API van $n start niet (zie: journalctl -u $K_UNIT-rest)"
done
"$OPT/bin/backup.sh" >/dev/null
"$OPT/bin/bijwerker.sh" || true   # versie meteen doorgeven aan de app

# Firewall op een server die op internet staat.
if kassa_online; then
  stap "Firewall instellen"
  if [ -d /run/systemd/system ]; then "$OPT/bin/firewall.sh" aan; else echo "Geen systemd: firewall overgeslagen."; fi
elif [ -f /etc/systemd/system/kassa-firewall.service ]; then
  "$OPT/bin/firewall.sh" uit
fi

# Verkoopwebsite (--website), of na een update het formulier opnieuw starten met de nieuwe versie.
if [ -n "${WEBSITE_ADRES:-}" ]; then
  stap "Website $WEBSITE_ADRES instellen"
  "$OPT/bin/website.sh" aan "$WEBSITE_ADRES"
elif [ -f "$ETC/website.env" ] && [ -d /run/systemd/system ]; then
  systemctl restart kassa-website 2>/dev/null || true
fi

# Eigen wifi-netwerk voor de telefoons (--wifi, alleen de eerste kassa).
WIFI_OK=0
if [ "${KASSA_WIFI:-0}" = 1 ]; then
  stap "Eigen wifi-netwerk \"$KASSA_WIFI_NAAM\" instellen"
  if [ ! -d /run/systemd/system ]; then
    echo "Geen systemd: wifi overgeslagen."
  elif "$OPT/bin/wifi.sh" aan; then
    WIFI_OK=1
  else
    echo "Het wifi-netwerk kon niet worden ingesteld (zie hierboven). De kassa werkt wel via het netwerk van het gebouw."
  fi
elif [ -f /etc/systemd/system/kassa-wifi.service ]; then
  "$OPT/bin/wifi.sh" uit
fi

# Nog geen beheerder? Dan maak je die hier aan, op de server zelf. Een account dat
# via de app wordt aangemaakt, wordt daarna nooit meer vanzelf beheerder.
GEEN_BEHEERDER=""
for n in $KASSAS; do
  kassa_paden "$n"
  if [ "$(su postgres -c "psql -d $K_DB -Atc \"select count(*) from public.profielen where rol = 'beheerder' and actief\"")" = 0 ]; then
    su postgres -c "psql -d $K_DB -qc 'update public.instellingen set eerste_account_wordt_beheerder = false'"
    # Nieuwe kassa op internet: medewerkers komen er alleen met een uitnodiging in, anders
    # kan iedereen die het adres vindt een account aanmaken (de beheerder kan het later aanzetten).
    deze_kassa_online && su postgres -c "psql -d $K_DB -qc 'update public.instellingen set zelf_aanmelden = false'"
    if [ "$n" = "$NAAM" ] && [ -t 0 ]; then
      stap "Beheerder aanmaken$([ "$n" = kassa ] || echo " voor kassa \"$n\"")"
      "$OPT/bin/beheerder.sh" "$n" || GEEN_BEHEERDER+=" $n"
    else
      GEEN_BEHEERDER+=" $n"
    fi
  fi
done

# Eigen scherm aan de server (--scherm, alleen de eerste kassa): na elke installatie opnieuw starten met de nieuwe versie.
kassa_paden kassa
if [ "$(kassa_lees KASSA_SCHERM)" = 1 ]; then
  stap "Eigen scherm instellen"
  if [ -d /run/systemd/system ]; then
    "$OPT/bin/scherm.sh" aan || echo "Het eigen scherm kon niet worden ingesteld; de kassa werkt wel via telefoons en tablets."
  else
    echo "Geen systemd: eigen scherm overgeslagen."
  fi
elif [ -f /etc/systemd/system/kassa-scherm.service ]; then
  "$OPT/bin/scherm.sh" uit
fi

if [ "$WIFI_OK" = 1 ]; then IP=10.42.0.1; else IP=$(hostname -I 2>/dev/null | awk '{print $1}'); fi
printf '\n\033[1;32mKlaar!\033[0m\n\n'
if [ "$WIFI_OK" = 1 ]; then
  echo "Wifi-netwerk van de kassa:  $KASSA_WIFI_NAAM"
  echo "Wachtwoord:                 $KASSA_WIFI_WACHTWOORD"
  echo "Verbind de telefoons met dit netwerk (of scan de code met de camera):"
  "$OPT/bin/wifi.sh" status | sed -n '/^Scan/,$p' | tail -n +2
fi
for n in $KASSAS; do
  kassa_paden "$n"
  domein=$(kassa_lees KASSA_DOMEIN)
  [ "$(wc -l <<<"$KASSAS")" -gt 1 ] && printf '\033[1mKassa "%s"\033[0m\n' "$n"
  if [ -n "$domein" ]; then
    echo "Open op elke telefoon of tablet:   https://$domein"
  else
    echo "1. Open op elke telefoon of tablet:  http://$IP"
    echo "   en volg de stappen om het certificaat te installeren (eenmalig per apparaat)."
    echo "2. Daarna is de kassa:               https://$IP"
  fi
  [[ " $GEEN_BEHEERDER " == *" $n "* ]] && echo "Er is nog geen beheerder. Maak die aan met:  $OPT/bin/beheerder.sh$([ "$n" = kassa ] || echo " $n")"
  if [[ " $NIEUW_BACKUP_WW " == *" $n "* ]]; then
    printf '\033[1;33mBack-upwachtwoord:  %s\033[0m\n' "$(cat "$K_WW")"
    echo "Schrijf dit op en bewaar het op een andere plek. Zonder dit wachtwoord is een back-up op een andere computer niet terug te zetten."
    echo "Later nog eens zien: $OPT/bin/backup.sh wachtwoord$([ "$n" = kassa ] || echo " $n")"
  fi
  echo
done
[ -f /etc/systemd/system/kassa-scherm.service ] && echo "Eigen scherm: de kassa staat ook op het scherm van deze server (onderhoud: Ctrl+Alt+F2)."
if kassa_online; then
  echo "Medewerkers van een kassa op internet voeg je toe met een uitnodiging: Beheer → Medewerkers → Uitnodigen."
  echo "Back-ups: elk uur als er iets veranderd is, in /var/backups/kassa. Download ze ook geregeld in de app (Beheer → Instellingen → Back-up downloaden)."
  [ -f /etc/systemd/system/kassa-firewall.service ] && echo "Beveiliging: firewall aan ($OPT/bin/firewall.sh status), veiligheidsupdates gaan vanzelf."
  if ssh_wachtwoord_aan; then
    # 00-: sshd neemt de eerste waarde die het leest, dus vóór bijvoorbeeld 50-cloud-init.conf.
    printf '\n\033[1;33mLet op: op deze server kun je met een wachtwoord inloggen (SSH).\033[0m\n'
    echo "Robots op internet proberen de hele dag wachtwoorden. Veiliger is inloggen met een sleutel:"
    echo "  1. Op je eigen computer:  ssh-keygen      (eenmalig; Enter, Enter)"
    echo "  2. Op je eigen computer:  ssh-copy-id root@$IP"
    echo "  3. Lukt inloggen nu zonder wachtwoord? Zet dan op deze server wachtwoorden uit:"
    echo "     echo 'PasswordAuthentication no' > /etc/ssh/sshd_config.d/00-kassa.conf && systemctl reload ssh"
    echo "  Doe stap 3 pas als stap 2 werkt, anders kom je zelf niet meer binnen. Lukt het niet,"
    echo "  dan kun je bij de verhuurder (bijvoorbeeld netcup) altijd via de webconsole inloggen."
  fi
else
  echo "Back-ups: elk uur als er iets veranderd is, in /var/backups/kassa (en versleuteld op een USB-stick met de naam KASSA-BACKUP als die erin zit)."
  echo "Medewerkers maken in de app zelf een account aan; de beheerder keurt ze goed bij Beheer → Medewerkers."
fi
echo "Back-up elke nacht per e-mail (een kopie buiten de server): $OPT/bin/backup-mail.sh instellen  (status: $OPT/bin/backup-mail.sh status)"
echo "Bijwerken naar een nieuwe versie:    in de app bij Beheer → Instellingen, of $OPT/bin/bijwerken.sh (als root)"
[ "$WIFI_OK" = 1 ] && echo "Wifi-naam en wachtwoord later nog eens zien: $OPT/bin/wifi.sh status"
[ "$(wc -l <<<"$KASSAS")" -gt 1 ] && echo "Overzicht van de kassa's op deze server: $OPT/bin/kassas.sh"
echo "Voorwaarden: $OPT/LICENTIE.txt  ·  Onderdelen van anderen: $OPT/ONDERDELEN.txt"
exit 0

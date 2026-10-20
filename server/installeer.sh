#!/usr/bin/env bash
# Bar-kassa installeren op een eigen (thin client) server, bijv. een HP t620
# met Debian 12 of Ubuntu Server 24.04, of op een cloudserver. Normaal start je
# dit via het installatiebestand:  bash kassa-installatie.run   (als root)
#
# Optioneel, voor een echt https-certificaat via DuckDNS:
#   bash kassa-installatie.run --duckdns mijnbar.duckdns.org <token>
# Op een server met een eigen domein dat naar de server wijst (cloudserver):
#   bash kassa-installatie.run --domein kassa.mijnclub.nl
# De kassa ook op het eigen scherm van de server (aanraakscherm aan de bar, alleen Debian):
#   bash kassa-installatie.run --scherm        (uitzetten: --zonder-scherm)
# Nog een kassa op dezelfde server, bijv. voor een andere vereniging (eigen
# database, accounts en back-ups; een eigen adres is verplicht):
#   bash kassa-installatie.run --naam voetbal --domein voetbal.mijndomein.nl
#
# Wordt dit script los gestart (zonder installatiebestand), dan haalt het
# eerst het nieuwste installatiebestand op en voert dat uit.
# Het kan veilig opnieuw worden gedraaid; bestaande gegevens blijven staan.
# Elke keer worden alle kassa's op deze server bijgewerkt.
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
NAAM_GEGEVEN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --naam) NAAM=${2:?naam ontbreekt}; NAAM_GEGEVEN=1; shift 2 ;;
    --domein) C_DOMEIN=${2:?domein ontbreekt}; C_TOKEN=; shift 2 ;;
    --duckdns) C_DOMEIN=${2:?naam ontbreekt}; C_TOKEN=${3:?token ontbreekt}; shift 3 ;;
    --zonder-duckdns|--zonder-domein) C_DOMEIN=; C_TOKEN=; shift ;;
    --scherm) C_SCHERM=1; shift ;;
    --zonder-scherm) C_SCHERM=0; shift ;;
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
  # Opties gewoon doorgeven: zonder opties blijven eerdere keuzes (domein, scherm) staan.
  bash "$T/kassa-installatie.run" "${ARGS[@]}"
  rm -rf "$T"
  exit 0
fi
[ -d "$KASSA_BRON/dist" ] || fout "Installatiebestand is onvolledig."
# shellcheck source=kassa-lib.sh
. "$KASSA_BRON/server/kassa-lib.sh"

# Welke kassa's: alle bestaande, plus de gekozen. Zonder --naam komt de eerste
# kassa er alleen bij als er nog geen andere kassa's zijn (een cloudserver met
# alleen kassa's op naam krijgt er bij het bijwerken geen lege kassa bij).
BESTAAND=$(kassa_namen)
if [ "$NAAM_GEGEVEN" = 1 ]; then
  [ "$NAAM" = kassa ] || kassa_naam_geldig "$NAAM" || fout "Kies als naam 2 tot 20 kleine letters of cijfers, beginnend met een letter (bijv. voetbal)."
fi
if [ "$NAAM_GEGEVEN" = 0 ] && [ -n "$BESTAAND" ] && ! grep -qx kassa <<<"$BESTAAND"; then
  NAAM=""
  [ -n "${C_DOMEIN+x}${C_SCHERM+x}" ] && fout "Er staan hier alleen kassa's op naam ($(echo $BESTAAND)). Geef met --naam aan voor welke kassa de opties zijn."
fi
KASSAS=$(printf '%s\n%s\n' "$BESTAAND" "$NAAM" | grep . | awk '!x[$0]++')
if [ -n "$NAAM" ] && [ "$NAAM" != kassa ]; then
  kassa_paden "$NAAM"
  [ -n "${C_TOKEN:-}" ] && fout "DuckDNS kan alleen bij de eerste kassa. Gebruik --domein (de naam moet naar deze server wijzen)."
  [ "${C_SCHERM:-0}" = 1 ] && fout "Het eigen scherm kan alleen met de eerste kassa."
  if [ -z "${C_DOMEIN:-}" ] && [ -z "$(kassa_lees KASSA_DOMEIN)" ]; then
    fout "Een tweede kassa heeft een eigen adres nodig: --domein $NAAM.jouwdomein.nl (dat adres moet naar deze server wijzen)."
  fi
fi

# ───────────────────────── Pakketten ─────────────────────────
stap "Pakketten installeren (PostgreSQL, Caddy) — dit kan een paar minuten duren"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q postgresql caddy curl ca-certificates openssl >/dev/null
timedatectl set-timezone Europe/Amsterdam 2>/dev/null || true

mkdir -p "$OPT/bin" "$ETC" /var/backups/kassa
chmod 700 "$ETC" /var/backups/kassa
# Voor de hele server: waar nieuwe versies vandaan komen (bijwerken.sh, bijwerker.sh).
echo "KASSA_REPO=$REPO" > "$ETC/server.env"

# ───────────────────────── Programma's ─────────────────────────
stap "Programma's plaatsen"
install -m 755 "$KASSA_BRON/bin/postgrest" "$OPT/bin/postgrest"
rm -rf "$OPT/auth" && cp -r "$KASSA_BRON/auth" "$OPT/auth"
install -m 755 "$KASSA_BRON"/server/*.sh "$OPT/bin/"
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

# ───────────────────────── Database ─────────────────────────
stap "Database inrichten"
command -v systemctl >/dev/null && [ -d /run/systemd/system ] && systemctl enable --now postgresql >/dev/null 2>&1 || true
PG_VERSIE=$(ls /etc/postgresql | sort -V | tail -1)
# Elke kassa houdt een paar verbindingen open; met meerdere kassa's is de standaard (100) te krap.
PG_CONF=/etc/postgresql/$PG_VERSIE/main/conf.d/kassa.conf
if [ "$(wc -l <<<"$KASSAS")" -gt 1 ] && ! grep -qs 'max_connections = 400' "$PG_CONF"; then
  mkdir -p "$(dirname "$PG_CONF")"
  echo "max_connections = 400" > "$PG_CONF"
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

# Richt één kassa in of werkt hem bij: instellingen, database, inlogsysteem, app en diensten.
kassa_inrichten() {
  local n=$1 domein token scherm auth rest jwt_geheim anon_key
  kassa_paden "$n"
  mkdir -p "$K_ETC" "$K_BACKUP" "$(dirname "$K_APP")"
  chmod 700 "$K_ETC" "$K_BACKUP"
  domein=$(kassa_lees KASSA_DOMEIN); token=$(kassa_lees KASSA_DUCKDNS_TOKEN); scherm=$(kassa_lees KASSA_SCHERM)
  auth=$(kassa_lees KASSA_AUTH_POORT); rest=$(kassa_lees KASSA_REST_POORT)
  if [ "$n" = "$NAAM" ]; then
    [ -n "${C_DOMEIN+x}" ] && { domein=$C_DOMEIN; token=$C_TOKEN; }
    [ -n "${C_SCHERM+x}" ] && scherm=$C_SCHERM
  fi
  if [ "$n" = kassa ]; then auth=${auth:-9999}; rest=${rest:-3000}
  elif [ -z "$auth" ]; then read -r auth rest < <(vrije_poorten)
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
  umask 022
  anon_key=$(jwt anon "$jwt_geheim")

  if [ -n "$domein" ] && [ -n "$token" ]; then
    "$OPT/bin/duckdns.sh" installeer "$domein" "$token"
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
GOTRUE_DB_MAX_POOL_SIZE=5
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
EOF
  cat > "$K_ETC/postgrest.conf" <<EOF
db-uri = "postgres://authenticator:$REST_DB_WACHTWOORD@127.0.0.1:5432/$K_DB"
db-schemas = "public"
db-anon-role = "anon"
db-pool = 10
jwt-secret = "$jwt_geheim"
server-host = "127.0.0.1"
server-port = $rest
EOF
  chmod 600 "$K_ETC/auth.env" "$K_ETC/postgrest.conf"

  ( set -a; . "$K_ETC/auth.env"; set +a; cd "$OPT/auth" && ./auth migrate >/dev/null )
  "$OPT/bin/migraties.sh" "$KASSA_BRON/supabase/migrations" "$K_DB"

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
Description=Bar-kassa $n: inloggen (Supabase Auth)
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
Description=Bar-kassa $n: database-API (PostgREST)
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

stap "Kassa installeren"
for n in $KASSAS; do
  echo "  $n"
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
Description=Bar-kassa back-up
[Service]
Type=oneshot
ExecStart=$OPT/bin/backup.sh
EOF
cat > /etc/systemd/system/kassa-backup.timer <<EOF
[Unit]
Description=Bar-kassa back-up elk uur
[Timer]
OnCalendar=hourly
Persistent=true
[Install]
WantedBy=timers.target
EOF
# Voert verzoeken uit de app uit (Beheer → Instellingen → Bijwerken).
cat > /etc/systemd/system/kassa-bijwerker.service <<EOF
[Unit]
Description=Bar-kassa bijwerken vanuit de app
After=postgresql.service
[Service]
Type=oneshot
ExecStart=$OPT/bin/bijwerker.sh
EOF
cat > /etc/systemd/system/kassa-bijwerker.timer <<EOF
[Unit]
Description=Bar-kassa: elke minuut kijken of er bijgewerkt moet worden
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
  for i in $(seq 1 30); do
    curl --noproxy "*" -fsS -o /dev/null "http://127.0.0.1:$auth/health" 2>/dev/null && curl --noproxy "*" -fsS -o /dev/null "http://127.0.0.1:$rest/" 2>/dev/null && break
    sleep 1
  done
  curl --noproxy "*" -fsS -o /dev/null "http://127.0.0.1:$auth/health" || fout "Inlogsysteem van $n start niet (zie: journalctl -u $K_UNIT-auth)"
  curl --noproxy "*" -fsS -o /dev/null "http://127.0.0.1:$rest/" || fout "Database-API van $n start niet (zie: journalctl -u $K_UNIT-rest)"
done
"$OPT/bin/backup.sh" >/dev/null
"$OPT/bin/bijwerker.sh" || true   # versie meteen doorgeven aan de app

# Nog geen beheerder? Dan maak je die hier aan, op de server zelf. Een account dat
# via de app wordt aangemaakt, wordt daarna nooit meer vanzelf beheerder (anders
# kan een onbekende je via internet voor zijn).
ZONDER_BEHEERDER=""
for n in $KASSAS; do
  kassa_paden "$n"
  if [ "$(su postgres -c "psql -d $K_DB -Atc \"select count(*) from public.profielen where rol = 'beheerder' and actief\"")" = 0 ]; then
    su postgres -c "psql -d $K_DB -qc 'update public.instellingen set eerste_account_wordt_beheerder = false'"
    if [ -t 0 ] && { [ "$n" = "$NAAM" ] || [ -z "$NAAM" ]; }; then
      stap "Beheerder aanmaken voor $n"
      "$OPT/bin/kassas.sh" beheerder "$n" || ZONDER_BEHEERDER+=" $n"
    else
      ZONDER_BEHEERDER+=" $n"
    fi
  fi
done

# Eigen scherm aan de server (--scherm, alleen de eerste kassa): na elke installatie opnieuw starten met de nieuwe versie.
SCHERM=0
if grep -qx kassa <<<"$KASSAS"; then kassa_paden kassa; SCHERM=$(kassa_lees KASSA_SCHERM); fi
if [ "${SCHERM:-0}" = 1 ]; then
  stap "Eigen scherm instellen"
  if [ -d /run/systemd/system ]; then
    "$OPT/bin/scherm.sh" aan || echo "Het eigen scherm kon niet worden ingesteld; de kassa werkt wel via telefoons en tablets."
  else
    echo "Geen systemd: eigen scherm overgeslagen."
  fi
elif [ -f /etc/systemd/system/kassa-scherm.service ]; then
  "$OPT/bin/scherm.sh" uit
fi

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
printf '\n\033[1;32mKlaar!\033[0m\n\n'
for n in $KASSAS; do
  kassa_paden "$n"
  domein=$(kassa_lees KASSA_DOMEIN)
  [ "$(wc -l <<<"$KASSAS")" -gt 1 ] && printf '\033[1m%s\033[0m\n' "$n"
  if [ -n "$domein" ]; then
    echo "Open op elke telefoon of tablet:   https://$domein"
  else
    echo "1. Open op elke telefoon of tablet:  http://$IP"
    echo "   en volg de stappen om het certificaat te installeren (eenmalig per apparaat)."
    echo "2. Daarna is de kassa:               https://$IP"
  fi
  echo
done
[ -f /etc/systemd/system/kassa-scherm.service ] && echo "Eigen scherm: de kassa staat ook op het scherm van deze server (onderhoud: Ctrl+Alt+F2)."
for n in $ZONDER_BEHEERDER; do
  echo "Kassa $n heeft nog geen beheerder. Maak die aan met:  $OPT/bin/kassas.sh beheerder $n"
done
echo "Medewerkers maken in de app zelf een account aan; de beheerder keurt ze goed bij Beheer → Medewerkers."
echo "Back-ups: elk uur in /var/backups/kassa (en op een USB-stick met de naam KASSA-BACKUP als die erin zit)."
echo "Bijwerken naar een nieuwe versie:    in de app bij Beheer → Instellingen, of $OPT/bin/bijwerken.sh (als root)"
[ "$(wc -l <<<"$KASSAS")" -gt 1 ] && echo "Overzicht van de kassa's op deze server: $OPT/bin/kassas.sh"
exit 0

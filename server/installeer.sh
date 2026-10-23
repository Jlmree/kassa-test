#!/usr/bin/env bash
# Bar-kassa installeren op een eigen (thin client) server, bijv. een HP t620
# met Debian 12 of Ubuntu Server 24.04. Normaal start je dit via het
# installatiebestand:  bash kassa-installatie.run   (als root)
#
# De server maakt zelf een wifi-netwerk voor de telefoons (wifi-kaart of -stick nodig):
#   bash kassa-installatie.run --wifi                    (naam "Kassa", wachtwoord wordt bedacht)
#   bash kassa-installatie.run --wifi-naam "Kantine Kassa" --wifi-wachtwoord geheim123
#   uitzetten: --zonder-wifi
# Optioneel, voor een echt https-certificaat via DuckDNS:
#   bash kassa-installatie.run --duckdns mijnbar.duckdns.org <token>
# De kassa ook op het eigen scherm van de server (aanraakscherm aan de bar, alleen Debian):
#   bash kassa-installatie.run --scherm        (uitzetten: --zonder-scherm)
#
# Wordt dit script los gestart (zonder installatiebestand), dan haalt het
# eerst het nieuwste installatiebestand op en voert dat uit.
# Het kan veilig opnieuw worden gedraaid; bestaande gegevens blijven staan.
set -euo pipefail

REPO="${KASSA_REPO:-Jlmree/kassa-test}"
OPT=/opt/kassa
ETC=/etc/kassa
DB=kassa

stap() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
fout() { printf '\n\033[1;31mFOUT: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || fout "Start dit als root (met sudo of na su -)."
[ "$(uname -m)" = x86_64 ] || fout "Alleen x86_64 (64-bit pc) wordt ondersteund."
command -v apt-get >/dev/null || fout "Alleen Debian of Ubuntu wordt ondersteund."

ARGS=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    --duckdns) KASSA_DOMEIN=${2:?naam ontbreekt}; KASSA_DUCKDNS_TOKEN=${3:?token ontbreekt}; shift 3 ;;
    --zonder-duckdns) KASSA_DOMEIN=; KASSA_DUCKDNS_TOKEN=; shift ;;
    --wifi) KASSA_WIFI=1; shift ;;
    --wifi-naam) KASSA_WIFI=1; KASSA_WIFI_NAAM=${2:?wifi-naam ontbreekt}; shift 2 ;;
    --wifi-wachtwoord) KASSA_WIFI=1; KASSA_WIFI_WACHTWOORD=${2:?wifi-wachtwoord ontbreekt}; shift 2 ;;
    --zonder-wifi) KASSA_WIFI=0; shift ;;
    --scherm) KASSA_SCHERM=1; shift ;;
    --zonder-scherm) KASSA_SCHERM=0; shift ;;
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
  # Opties gewoon doorgeven: zonder opties blijven eerdere keuzes (DuckDNS, scherm) staan.
  bash "$T/kassa-installatie.run" "${ARGS[@]}"
  rm -rf "$T"
  exit 0
fi
[ -d "$KASSA_BRON/dist" ] || fout "Installatiebestand is onvolledig."

# Eerder gekozen domein onthouden, tenzij nu iets anders is opgegeven.
if [ -f "$ETC/instellingen.env" ]; then
  OUD_DOMEIN=$(sed -n 's/^KASSA_DOMEIN=//p' "$ETC/instellingen.env")
  OUD_TOKEN=$(sed -n 's/^KASSA_DUCKDNS_TOKEN=//p' "$ETC/instellingen.env")
  KASSA_DOMEIN=${KASSA_DOMEIN-$OUD_DOMEIN}
  KASSA_DUCKDNS_TOKEN=${KASSA_DUCKDNS_TOKEN-$OUD_TOKEN}
  OUD_SCHERM=$(sed -n 's/^KASSA_SCHERM=//p' "$ETC/instellingen.env")
  KASSA_SCHERM=${KASSA_SCHERM:-$OUD_SCHERM}
fi
# Eerdere wifi-keuzes (naam en wachtwoord mogen spaties bevatten, dus een eigen bestand).
if [ -f "$ETC/wifi.env" ]; then
  { IFS= read -r OUD_WIFI; IFS= read -r OUD_WIFI_NAAM; IFS= read -r OUD_WIFI_WW; } < <(
    . "$ETC/wifi.env"; printf '%s\n' "${KASSA_WIFI:-0}" "${KASSA_WIFI_NAAM:-}" "${KASSA_WIFI_WACHTWOORD:-}")
  KASSA_WIFI=${KASSA_WIFI:-$OUD_WIFI}
  KASSA_WIFI_NAAM=${KASSA_WIFI_NAAM:-$OUD_WIFI_NAAM}
  KASSA_WIFI_WACHTWOORD=${KASSA_WIFI_WACHTWOORD:-$OUD_WIFI_WW}
fi
# Een eigen domein zonder DuckDNS (van de cloudversie) wordt niet meer gebruikt:
# de kassa draait op een computer in het gebouw, op het eigen netwerk.
if [ -n "${KASSA_DOMEIN:-}" ] && [ -z "${KASSA_DUCKDNS_TOKEN:-}" ]; then
  echo "Het adres $KASSA_DOMEIN wordt niet meer gebruikt; de kassa werkt nu op het eigen netwerk."
  KASSA_DOMEIN=
fi
# Kassa's op naam (van de cloudversie) zouden bij deze versie onbereikbaar worden.
if compgen -G "$ETC/kassas/*/auth.env" >/dev/null; then
  fout "Op deze server staan meerdere kassa's ($(ls "$ETC/kassas" | tr '\n' ' ')). Deze versie werkt met één kassa op een computer in het gebouw. Zet die kassa's eerst over (back-up maken en terugzetten op hun eigen computer)."
fi
if [ "${KASSA_WIFI:-0}" = 1 ]; then
  KASSA_WIFI_NAAM=${KASSA_WIFI_NAAM:-Kassa}
  # Een wachtwoord dat makkelijk over te typen is, bijv. 3fa9-81c2-d0e4.
  KASSA_WIFI_WACHTWOORD=${KASSA_WIFI_WACHTWOORD:-$(openssl rand -hex 6 | sed -E 's/(....)(....)(....)/\1-\2-\3/')}
  [ "${#KASSA_WIFI_WACHTWOORD}" -ge 8 ] && [ "${#KASSA_WIFI_WACHTWOORD}" -le 63 ] || fout "Het wifi-wachtwoord moet 8 tot 63 tekens zijn."
  [ "$(printf '%s' "$KASSA_WIFI_NAAM" | wc -c)" -le 32 ] || fout "De wifi-naam mag hoogstens 32 tekens zijn."
fi

# ───────────────────────── Pakketten ─────────────────────────
stap "Pakketten installeren (PostgreSQL, Caddy) — dit kan een paar minuten duren"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q postgresql caddy curl ca-certificates openssl >/dev/null
if [ "${KASSA_WIFI:-0}" = 1 ]; then
  apt-get install -y -q hostapd dnsmasq-base iw rfkill iproute2 nftables qrencode >/dev/null
fi
timedatectl set-timezone Europe/Amsterdam 2>/dev/null || true

mkdir -p "$OPT/bin" "$ETC" /var/backups/kassa
chmod 700 "$ETC" /var/backups/kassa

# ───────────────────────── Programma's ─────────────────────────
stap "Programma's plaatsen"
install -m 755 "$KASSA_BRON/bin/postgrest" "$OPT/bin/postgrest"
rm -rf "$OPT/auth" && cp -r "$KASSA_BRON/auth" "$OPT/auth"
install -m 755 "$KASSA_BRON"/server/*.sh "$OPT/bin/"
rm -rf "$OPT/welkom" && mkdir -p "$OPT/welkom" && cp "$KASSA_BRON/server/welkom.html" "$OPT/welkom/index.html"

umask 077
cat > "$ETC/instellingen.env" <<EOF
KASSA_REPO=$REPO
KASSA_DOMEIN=${KASSA_DOMEIN:-}
KASSA_DUCKDNS_TOKEN=${KASSA_DUCKDNS_TOKEN:-}
KASSA_SCHERM=${KASSA_SCHERM:-0}
EOF
printf 'KASSA_WIFI=%q\nKASSA_WIFI_NAAM=%q\nKASSA_WIFI_WACHTWOORD=%q\n' "${KASSA_WIFI:-0}" "${KASSA_WIFI_NAAM:-}" "${KASSA_WIFI_WACHTWOORD:-}" > "$ETC/wifi.env"
umask 022

# ───────────────────────── Geheimen ─────────────────────────
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
# Wachtwoord voor de back-ups op de USB-stick (versleuteld). Nodig om een back-up
# op een andere computer terug te zetten, dus aan het eind laten zien om op te schrijven.
NIEUW_BACKUP_WW=0
if [ ! -s "$ETC/backup.wachtwoord" ]; then
  ( umask 077; openssl rand -hex 8 | sed -E 's/(....)(....)(....)(....)/\1-\2-\3-\4/' > "$ETC/backup.wachtwoord" )
  NIEUW_BACKUP_WW=1
fi

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
jwt() {
  local h p
  h=$(printf '{"alg":"HS256","typ":"JWT"}' | b64url)
  p=$(printf '{"role":"%s","iss":"kassa","iat":1700000000,"exp":4102444800}' "$1" | b64url)
  printf '%s.%s.%s' "$h" "$p" "$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -hmac "$JWT_SECRET" -binary | b64url)"
}
ANON_KEY=$(jwt anon)

# ───────────────────────── Database ─────────────────────────
stap "Database inrichten"
command -v systemctl >/dev/null && [ -d /run/systemd/system ] && systemctl enable --now postgresql >/dev/null 2>&1 || true
if ! su postgres -c "pg_isready -q"; then
  # Zonder systemd (bijv. in een container): cluster zelf starten.
  pg_ctlcluster "$(ls /etc/postgresql | sort -V | tail -1)" main start
fi
psql_su() { su postgres -c "psql -v ON_ERROR_STOP=1 -q $*"; }

if ! su postgres -c "psql -tAc \"select 1 from pg_database where datname='$DB'\"" | grep -q 1; then
  su postgres -c "createdb $DB"
fi
su postgres -c "PGOPTIONS=--client-min-messages=warning psql -v ON_ERROR_STOP=1 -q -d $DB" <<EOF
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
create schema if not exists auth authorization supabase_auth_admin;
grant usage on schema auth to anon, authenticated, service_role;
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
grant usage on schema extensions to anon, authenticated, service_role;
grant usage on schema public to anon, authenticated, service_role;
grant create on database $DB to supabase_auth_admin;
create table if not exists public.kassa_migraties (naam text primary key, ts timestamptz not null default now());
revoke all on public.kassa_migraties from anon, authenticated;
EOF

cat > "$ETC/auth.env" <<EOF
GOTRUE_DB_DRIVER=postgres
DATABASE_URL=postgres://supabase_auth_admin:$AUTH_DB_WACHTWOORD@127.0.0.1:5432/$DB?search_path=auth
GOTRUE_DB_MIGRATIONS_PATH=$OPT/auth/migrations
GOTRUE_JWT_SECRET=$JWT_SECRET
GOTRUE_JWT_EXP=43200
GOTRUE_JWT_AUD=authenticated
GOTRUE_JWT_DEFAULT_GROUP_NAME=authenticated
GOTRUE_JWT_ADMIN_ROLES=service_role
GOTRUE_SITE_URL=https://${KASSA_DOMEIN:-kassa}
API_EXTERNAL_URL=https://${KASSA_DOMEIN:-kassa}/auth/v1
GOTRUE_MAILER_AUTOCONFIRM=true
GOTRUE_EXTERNAL_EMAIL_ENABLED=true
GOTRUE_DISABLE_SIGNUP=false
GOTRUE_PASSWORD_MIN_LENGTH=8
GOTRUE_API_HOST=127.0.0.1
PORT=9999
GOTRUE_LOG_LEVEL=warn
GOTRUE_RATE_LIMIT_TOKEN_REFRESH=1000
GOTRUE_RATE_LIMIT_VERIFY=1000
# Na 10 verkeerde wachtwoorden in 10 minuten gaat een account even op slot (zie de database).
GOTRUE_HOOK_PASSWORD_VERIFICATION_ATTEMPT_ENABLED=true
GOTRUE_HOOK_PASSWORD_VERIFICATION_ATTEMPT_URI=pg-functions://postgres/public/hook_password_verification_attempt
EOF
cat > "$ETC/postgrest.conf" <<EOF
db-uri = "postgres://authenticator:$REST_DB_WACHTWOORD@127.0.0.1:5432/$DB"
db-schemas = "public"
db-anon-role = "anon"
db-pool = 10
jwt-secret = "$JWT_SECRET"
server-host = "127.0.0.1"
server-port = 3000
EOF
chmod 600 "$ETC/auth.env" "$ETC/postgrest.conf"

stap "Inlogsysteem bijwerken"
( set -a; . "$ETC/auth.env"; set +a; cd "$OPT/auth" && ./auth migrate >/dev/null )

# ───────────────────────── App en databasefuncties ─────────────────────────
stap "Kassa installeren"
"$OPT/bin/migraties.sh" "$KASSA_BRON/supabase/migrations"
rm -rf "$OPT/app.nieuw" && cp -r "$KASSA_BRON/dist" "$OPT/app.nieuw"
cat > "$OPT/app.nieuw/config.js" <<EOF
// Gemaakt door de installatie. De database draait op deze server zelf.
window.KASSA_CONFIG = { supabaseUrl: location.origin, supabaseAnonKey: '$ANON_KEY' };
EOF
rm -rf "$OPT/app.oud"
[ -d "$OPT/app" ] && mv "$OPT/app" "$OPT/app.oud"
mv "$OPT/app.nieuw" "$OPT/app"
cp "$KASSA_BRON/versie" "$OPT/versie"

# ───────────────────────── Webserver en https ─────────────────────────
stap "Webserver instellen"
SITE_BLOK='
	encode gzip
	handle_path /auth/v1/* {
		reverse_proxy 127.0.0.1:9999
	}
	handle_path /rest/v1/* {
		reverse_proxy 127.0.0.1:3000
	}
	handle {
		root * /opt/kassa/app
		@assets path /assets/*
		header @assets Cache-Control "public, max-age=31536000, immutable"
		try_files {path} /index.html
		file_server
	}'
# Voor het eigen scherm van de server (scherm.sh): alleen vanaf de server zelf bereikbaar.
# http://localhost telt voor de browser als beveiligd, dus daar is geen certificaat nodig.
SCHERM_BLOK="http://localhost:8080 {
	bind 127.0.0.1
$SITE_BLOK
}"
if [ -n "${KASSA_DOMEIN:-}" ]; then
  [ -n "${KASSA_DUCKDNS_TOKEN:-}" ] || fout "KASSA_DUCKDNS_TOKEN ontbreekt"
  "$OPT/bin/duckdns.sh" installeer "$KASSA_DOMEIN" "$KASSA_DUCKDNS_TOKEN"
  cat > /etc/caddy/Caddyfile <<EOF
# Gemaakt door installeer.sh (DuckDNS-certificaat)
https://$KASSA_DOMEIN {
	tls /etc/kassa-tls/fullchain.pem /etc/kassa-tls/key.pem
$SITE_BLOK
}
http:// {
	redir https://$KASSA_DOMEIN{uri}
}
$SCHERM_BLOK
EOF
else
  cat > /etc/caddy/Caddyfile <<EOF
# Gemaakt door installeer.sh (eigen certificaat; telefoons installeren eenmalig het certificaat)
{
	skip_install_trust
	on_demand_tls {
		ask http://127.0.0.1:8765/
	}
}
https:// {
	tls internal {
		on_demand
	}
$SITE_BLOK
}
# Welkomstpagina met het certificaat om te installeren.
http:// {
	handle /kassa-certificaat.crt {
		root * /var/lib/caddy/.local/share/caddy/pki/authorities/local
		rewrite * /root.crt
		header Content-Type application/x-x509-ca-cert
		file_server
	}
	handle {
		root * $OPT/welkom
		try_files {path} /index.html
		file_server
	}
}
# Alleen voor deze server zelf: mag er een certificaat gemaakt worden? (ja, het is een lokaal certificaat)
http://127.0.0.1:8765 {
	respond 200
}
$SCHERM_BLOK
EOF
fi
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || { caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile; fout "Caddy-instellingen ongeldig"; }

# ───────────────────────── Diensten ─────────────────────────
stap "Diensten starten"
cat > /etc/systemd/system/kassa-auth.service <<EOF
[Unit]
Description=Bar-kassa inloggen (Supabase Auth)
After=postgresql.service
Requires=postgresql.service
[Service]
EnvironmentFile=$ETC/auth.env
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
cat > /etc/systemd/system/kassa-rest.service <<EOF
[Unit]
Description=Bar-kassa database-API (PostgREST)
After=postgresql.service
Requires=postgresql.service
[Service]
LoadCredential=postgrest.conf:$ETC/postgrest.conf
ExecStart=/bin/sh -c 'exec $OPT/bin/postgrest "\$CREDENTIALS_DIRECTORY/postgrest.conf"'
ExecReload=/bin/kill -SIGUSR1 \$MAINPID
Restart=always
RestartSec=3
DynamicUser=yes
[Install]
WantedBy=multi-user.target
EOF
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

if [ -d /run/systemd/system ]; then
  systemctl daemon-reload
  systemctl enable --now kassa-auth kassa-rest kassa-backup.timer kassa-bijwerker.timer >/dev/null 2>&1
  systemctl restart kassa-auth kassa-rest
  systemctl enable caddy >/dev/null 2>&1 && systemctl restart caddy
else
  # Geen systemd (container/test): zelf starten.
  pkill -x auth 2>/dev/null || true; pkill -x postgrest 2>/dev/null || true; pkill -x caddy 2>/dev/null || true
  sleep 1
  ( cd "$OPT/auth"; set -a; . "$ETC/auth.env"; set +a; exec ./auth serve ) </dev/null >/var/log/kassa-auth.log 2>&1 &
  "$OPT/bin/postgrest" "$ETC/postgrest.conf" </dev/null >/var/log/kassa-rest.log 2>&1 &
  HOME=/var/lib/caddy caddy run --config /etc/caddy/Caddyfile --adapter caddyfile </dev/null >/var/log/kassa-caddy.log 2>&1 &
fi

stap "Controleren"
for i in $(seq 1 30); do
  curl --noproxy "*" -fsS -o /dev/null http://127.0.0.1:9999/health 2>/dev/null && curl --noproxy "*" -fsS -o /dev/null http://127.0.0.1:3000/ 2>/dev/null && break
  sleep 1
done
curl --noproxy "*" -fsS -o /dev/null http://127.0.0.1:9999/health || fout "Inlogsysteem start niet (zie: journalctl -u kassa-auth)"
curl --noproxy "*" -fsS -o /dev/null http://127.0.0.1:3000/ || fout "Database-API start niet (zie: journalctl -u kassa-rest)"
"$OPT/bin/backup.sh" >/dev/null
"$OPT/bin/bijwerker.sh" || true   # versie meteen doorgeven aan de app

# Eigen wifi-netwerk voor de telefoons (--wifi).
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
# Wifi-naam en wachtwoord voor de wifi-code bij een uitnodiging (alleen beheerders zien ze).
if [ "${KASSA_WIFI:-0}" = 1 ]; then WN=$KASSA_WIFI_NAAM; WW=$KASSA_WIFI_WACHTWOORD; else WN=; WW=; fi
runuser -u postgres -- psql -d "$DB" -q -v n="$WN" -v w="$WW" <<'SQL'
update public.systeem set wifi_naam = nullif(:'n', ''), wifi_wachtwoord = nullif(:'w', '');
SQL

# Nog geen beheerder? Dan maak je die hier aan, op de server zelf. Een account dat
# via de app wordt aangemaakt, wordt daarna nooit meer vanzelf beheerder.
GEEN_BEHEERDER=0
if [ "$(su postgres -c "psql -d $DB -Atc \"select count(*) from public.profielen where rol = 'beheerder' and actief\"")" = 0 ]; then
  su postgres -c "psql -d $DB -qc 'update public.instellingen set eerste_account_wordt_beheerder = false'"
  if [ -t 0 ]; then
    stap "Beheerder aanmaken"
    "$OPT/bin/beheerder.sh" || GEEN_BEHEERDER=1
  else
    GEEN_BEHEERDER=1
  fi
fi

# Eigen scherm aan de server (--scherm): na elke installatie opnieuw starten met de nieuwe versie.
if [ "${KASSA_SCHERM:-0}" = 1 ]; then
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
if [ -n "${KASSA_DOMEIN:-}" ]; then
  echo "Open op elke telefoon of tablet:   https://$KASSA_DOMEIN"
else
  echo "1. Open op elke telefoon of tablet:  http://$IP"
  echo "   en volg de stappen om het certificaat te installeren (eenmalig per apparaat)."
  echo "2. Daarna is de kassa:               https://$IP"
fi
echo
[ -f /etc/systemd/system/kassa-scherm.service ] && echo "Eigen scherm: de kassa staat ook op het scherm van deze server (onderhoud: Ctrl+Alt+F2)."
[ "$GEEN_BEHEERDER" = 1 ] && echo "Er is nog geen beheerder. Maak die aan met:  $OPT/bin/beheerder.sh"
echo "Medewerkers maken in de app zelf een account aan; de beheerder keurt ze goed bij Beheer → Medewerkers."
echo "Back-ups: elk uur in /var/backups/kassa (en versleuteld op een USB-stick met de naam KASSA-BACKUP als die erin zit)."
if [ "$NIEUW_BACKUP_WW" = 1 ]; then
  printf '\n\033[1;33mWachtwoord van de back-ups op de USB-stick:  %s\033[0m\n' "$(cat "$ETC/backup.wachtwoord")"
  echo "Schrijf dit op en bewaar het buiten de kantine. Zonder dit wachtwoord is een back-up op een andere computer niet terug te zetten."
  echo "Later nog eens zien: $OPT/bin/backup.sh wachtwoord"
fi
echo "Bijwerken naar een nieuwe versie:    in de app bij Beheer → Instellingen, of $OPT/bin/bijwerken.sh (als root)"
[ "$WIFI_OK" = 1 ] && echo "Wifi-naam en wachtwoord later nog eens zien: $OPT/bin/wifi.sh status"
exit 0

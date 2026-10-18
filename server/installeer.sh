#!/usr/bin/env bash
# Bar-kassa installeren op een eigen (thin client) server, bijv. een HP t620
# met Debian 12 of Ubuntu Server 24.04.
#
#   curl -fsSL https://raw.githubusercontent.com/Jlmree/kassa-test/main/server/installeer.sh | bash   (als root)
#
# Optioneel (vóór het commando zetten, bijv. "sudo KASSA_DOMEIN=... bash installeer.sh"):
#   KASSA_DOMEIN=mijnbar.duckdns.org  + KASSA_DUCKDNS_TOKEN=...   echt https-certificaat via DuckDNS
#   KASSA_PAKKET=/pad/naar/kassa.tar.gz                           lokaal pakket i.p.v. de nieuwste release
#
# Het script kan veilig opnieuw worden gedraaid; bestaande gegevens blijven staan.
set -euo pipefail

# Eerder gekozen instellingen (domein) onthouden bij opnieuw draaien / bijwerken.
# shellcheck disable=SC1091
[ -f /etc/kassa/instellingen.env ] && . /etc/kassa/instellingen.env
REPO="${KASSA_REPO:-Jlmree/kassa-test}"
POSTGREST_VERSIE=v12.2.3
AUTH_VERSIE=v2.177.0
OPT=/opt/kassa
ETC=/etc/kassa
DB=kassa

stap() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
fout() { printf '\n\033[1;31mFOUT: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || fout "Draai dit script als root (met sudo)."
[ "$(uname -m)" = x86_64 ] || fout "Alleen x86_64 (64-bit pc) wordt ondersteund."
command -v apt-get >/dev/null || fout "Alleen Debian of Ubuntu wordt ondersteund."

# ───────────────────────── Pakketten ─────────────────────────
stap "Pakketten installeren (PostgreSQL, Caddy)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q postgresql caddy curl ca-certificates openssl xz-utils tar >/dev/null
timedatectl set-timezone Europe/Amsterdam 2>/dev/null || true

mkdir -p "$OPT/bin" "$OPT/auth" "$OPT/app" "$ETC" /var/backups/kassa
chmod 700 "$ETC" /var/backups/kassa

# ───────────────────────── Programma's ─────────────────────────
stap "PostgREST en Supabase Auth downloaden"
if [ "$("$OPT/bin/postgrest" --version 2>/dev/null)" != "PostgREST ${POSTGREST_VERSIE#v}" ]; then
  curl -fsSL "https://github.com/PostgREST/postgrest/releases/download/$POSTGREST_VERSIE/postgrest-$POSTGREST_VERSIE-linux-static-x64.tar.xz" | tar xJ -C "$OPT/bin"
fi
if [ "$(cat "$OPT/auth/.versie" 2>/dev/null)" != "$AUTH_VERSIE" ]; then
  rm -rf "$OPT/auth" && mkdir -p "$OPT/auth"
  curl -fsSL "https://github.com/supabase/auth/releases/download/$AUTH_VERSIE/auth-$AUTH_VERSIE-x86.tar.gz" | tar xz -C "$OPT/auth"
  echo "$AUTH_VERSIE" > "$OPT/auth/.versie"
fi

umask 077
cat > "$ETC/instellingen.env" <<EOF
KASSA_REPO=$REPO
KASSA_DOMEIN=${KASSA_DOMEIN:-}
KASSA_DUCKDNS_TOKEN=${KASSA_DUCKDNS_TOKEN:-}
EOF
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
su postgres -c "psql -v ON_ERROR_STOP=1 -q -d $DB" <<EOF
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
WERK=$(mktemp -d)
trap 'rm -rf "$WERK"' EXIT
if [ -n "${KASSA_PAKKET:-}" ]; then
  cp "$KASSA_PAKKET" "$WERK/kassa.tar.gz"
else
  URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | grep -o '"browser_download_url": *"[^"]*kassa\.tar\.gz"' | head -1 | cut -d'"' -f4)
  [ -n "$URL" ] || fout "Geen release gevonden op github.com/$REPO"
  curl -fsSL -o "$WERK/kassa.tar.gz" "$URL"
fi
tar xzf "$WERK/kassa.tar.gz" -C "$WERK"
install -m 755 "$WERK"/server/*.sh "$OPT/bin/"
rm -rf "$OPT/welkom" && mkdir -p "$OPT/welkom" && cp "$WERK/server/welkom.html" "$OPT/welkom/index.html"
"$OPT/bin/migraties.sh" "$WERK/supabase/migrations"
rm -rf "$OPT/app.nieuw" && cp -r "$WERK/dist" "$OPT/app.nieuw"
cat > "$OPT/app.nieuw/config.js" <<EOF
// Gemaakt door installeer.sh. De database draait op deze server zelf.
window.KASSA_CONFIG = { supabaseUrl: location.origin, supabaseAnonKey: '$ANON_KEY' };
EOF
rm -rf "$OPT/app.oud" && { [ -d "$OPT/app" ] && mv "$OPT/app" "$OPT/app.oud" || true; } && mv "$OPT/app.nieuw" "$OPT/app"
cat "$WERK/versie" > "$OPT/versie" 2>/dev/null || true

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

if [ -d /run/systemd/system ]; then
  systemctl daemon-reload
  systemctl enable --now kassa-auth kassa-rest kassa-backup.timer >/dev/null 2>&1
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

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
printf '\n\033[1;32mKlaar!\033[0m\n\n'
if [ -n "${KASSA_DOMEIN:-}" ]; then
  echo "Open op elke telefoon of tablet:   https://$KASSA_DOMEIN"
else
  echo "1. Open op elke telefoon of tablet:  http://$IP"
  echo "   en volg de stappen om het certificaat te installeren (eenmalig per apparaat)."
  echo "2. Daarna is de kassa:               https://$IP"
fi
echo
echo "Het eerste account dat je aanmaakt wordt beheerder."
echo "Back-ups: elk uur in /var/backups/kassa (en op een USB-stick met de naam KASSA-BACKUP als die erin zit)."
echo "Bijwerken naar een nieuwe versie:    sudo $OPT/bin/bijwerken.sh"

# Gedeeld door de serverscripts (wordt ingelezen, niet los gestart):
# welke kassa's er op deze server staan en waar alles van een kassa staat.
#
# Op één server kunnen meerdere kassa's staan, bijvoorbeeld voor verschillende
# verenigingen. Elke kassa heeft een eigen database, eigen accounts, eigen
# sleutel en eigen back-ups. De eerste kassa heet "kassa" en staat op de
# oorspronkelijke plekken (/etc/kassa, /opt/kassa/app, database kassa), zodat
# bestaande installaties niets hoeven te verhuizen.

KASSA_OPT=/opt/kassa
KASSA_ETC=/etc/kassa

# Alle kassa's op deze server, één naam per regel.
kassa_namen() {
  [ -f "$KASSA_ETC/auth.env" ] && echo kassa
  local d
  for d in "$KASSA_ETC"/kassas/*/; do
    [ -f "$d/auth.env" ] && basename "$d"
  done
  return 0
}

# Zet K_ETC, K_APP, K_DB, K_UNIT en K_BACKUP voor de kassa met deze naam.
kassa_paden() {
  K_NAAM=$1
  if [ "$1" = kassa ]; then
    K_ETC=$KASSA_ETC; K_APP=$KASSA_OPT/app; K_DB=kassa; K_UNIT=kassa; K_BACKUP=/var/backups/kassa
  else
    K_ETC=$KASSA_ETC/kassas/$1; K_APP=$KASSA_OPT/kassas/$1/app; K_DB=kassa_$1; K_UNIT=kassa-$1; K_BACKUP=/var/backups/kassa/$1
  fi
}

# Eén instelling van de huidige kassa (na kassa_paden): kassa_lees KASSA_DOMEIN
kassa_lees() { [ -f "$K_ETC/instellingen.env" ] && sed -n "s/^$1=//p" "$K_ETC/instellingen.env"; return 0; }

# Sleutel (JWT-geheim) van de huidige kassa: de eerste kassa in geheim.env, de andere in sleutel.env.
kassa_jwt_geheim() {
  if [ "$K_NAAM" = kassa ]; then sed -n 's/^JWT_SECRET=//p' "$KASSA_ETC/geheim.env"
  else sed -n 's/^JWT_SECRET=//p' "$K_ETC/sleutel.env"; fi
}

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
# Een sleutel (JWT) met deze rol, ondertekend met dit geheim: jwt anon <geheim>
jwt() {
  local h p
  h=$(printf '{"alg":"HS256","typ":"JWT"}' | b64url)
  p=$(printf '{"role":"%s","iss":"kassa","iat":1700000000,"exp":4102444800}' "$1" | b64url)
  printf '%s.%s.%s' "$h" "$p" "$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -hmac "$2" -binary | b64url)"
}

kassa_naam_geldig() { [[ "$1" =~ ^[a-z][a-z0-9]{1,19}$ ]] && [ "$1" != kassa ]; }

# Schrijft /etc/caddy/Caddyfile voor alle kassa's op deze server.
caddy_schrijven() {
  local n domein token auth rest blok sites="" intern=0 http_blok=""
  for n in $(kassa_namen); do
    kassa_paden "$n"
    domein=$(kassa_lees KASSA_DOMEIN); token=$(kassa_lees KASSA_DUCKDNS_TOKEN)
    auth=$(kassa_lees KASSA_AUTH_POORT); auth=${auth:-9999}
    rest=$(kassa_lees KASSA_REST_POORT); rest=${rest:-3000}
    blok="
	encode gzip
	handle_path /auth/v1/* {
		reverse_proxy 127.0.0.1:$auth
	}
	handle_path /rest/v1/* {
		reverse_proxy 127.0.0.1:$rest
	}
	handle {
		root * $K_APP
		@assets path /assets/*
		header @assets Cache-Control \"public, max-age=31536000, immutable\"
		try_files {path} /index.html
		file_server
	}"
    if [ -n "$token" ]; then
      # DuckDNS-certificaat (alleen de eerste kassa; zie duckdns.sh).
      sites+="
# $n (DuckDNS-certificaat)
https://$domein {
	tls /etc/kassa-tls/fullchain.pem /etc/kassa-tls/key.pem
$blok
}
"
      [ "$n" = kassa ] && http_blok="http:// {
	redir https://$domein{uri}
}"
    elif [ -n "$domein" ]; then
      # Eigen domein dat naar deze server wijst: Caddy haalt zelf een certificaat (Let's Encrypt).
      sites+="
# $n
$domein {
$blok
}
"
    else
      # Geen domein (alleen de eerste kassa): eigen certificaat op het IP-adres.
      intern=1
      sites+="
# $n (eigen certificaat; telefoons installeren eenmalig het certificaat)
https:// {
	tls internal {
		on_demand
	}
$blok
}
"
      http_blok="# Welkomstpagina met het certificaat om te installeren.
http:// {
	handle /kassa-certificaat.crt {
		root * /var/lib/caddy/.local/share/caddy/pki/authorities/local
		rewrite * /root.crt
		header Content-Type application/x-x509-ca-cert
		file_server
	}
	handle {
		root * $KASSA_OPT/welkom
		try_files {path} /index.html
		file_server
	}
}
# Alleen voor deze server zelf: mag er een certificaat gemaakt worden? (ja, het is een lokaal certificaat)
http://127.0.0.1:8765 {
	respond 200
}"
    fi
    if [ "$n" = kassa ]; then
      # Voor het eigen scherm van de server (scherm.sh): alleen vanaf de server zelf bereikbaar.
      # http://localhost telt voor de browser als beveiligd, dus daar is geen certificaat nodig.
      sites+="
http://localhost:8080 {
	bind 127.0.0.1
$blok
}
"
    fi
  done
  {
    echo "# Gemaakt door de kassa-installatie ($(kassa_namen | tr '\n' ' ')). Niet met de hand aanpassen."
    if [ "$intern" = 1 ]; then
      printf '{\n\tskip_install_trust\n\ton_demand_tls {\n\t\task http://127.0.0.1:8765/\n\t}\n}\n'
    fi
    printf '%s\n%s\n' "$sites" "$http_blok"
  } > /etc/caddy/Caddyfile.nieuw
  if ! caddy validate --config /etc/caddy/Caddyfile.nieuw --adapter caddyfile >/dev/null 2>&1; then
    caddy validate --config /etc/caddy/Caddyfile.nieuw --adapter caddyfile
    rm -f /etc/caddy/Caddyfile.nieuw
    return 1
  fi
  mv /etc/caddy/Caddyfile.nieuw /etc/caddy/Caddyfile
}

# shellcheck shell=bash
# Gedeeld door de serverscripts (wordt ingelezen, niet los gestart):
# welke kassa's er op deze server staan en waar alles van een kassa staat.
#
# Op één server kunnen meerdere kassa's staan, bijvoorbeeld voor verschillende
# kantines of verenigingen. Elke kassa heeft een eigen database, eigen accounts,
# eigen sleutel, eigen adres en eigen back-ups: ze zien niets van elkaar en een
# barkaart van de ene kassa werkt niet bij de andere. De eerste kassa heet
# "kassa" en staat op de oorspronkelijke plekken (/etc/kassa, /opt/kassa/app,
# database kassa), zodat bestaande installaties niets hoeven te verhuizen.

KASSA_OPT=/opt/kassa
KASSA_ETC=/etc/kassa

# Alle kassa's op deze server, één naam per regel (de eerste kassa eerst).
kassa_namen() {
  [ -f "$KASSA_ETC/auth.env" ] && echo kassa
  local d
  for d in "$KASSA_ETC"/kassas/*/; do
    [ -f "$d/auth.env" ] && basename "$d"
  done
  return 0
}

# Zet de paden van de kassa met deze naam:
#   K_ETC (instellingen), K_APP (de app), K_DB (database), K_UNIT (begin van de dienstnamen),
#   K_BACKUP (back-ups), K_DOWNLOAD (back-up om te downloaden), K_WW (back-upwachtwoord).
kassa_paden() {
  K_NAAM=$1
  if [ "$1" = kassa ]; then
    K_ETC=$KASSA_ETC; K_APP=$KASSA_OPT/app; K_DB=kassa; K_UNIT=kassa; K_BACKUP=/var/backups/kassa
    K_DOWNLOAD=$KASSA_OPT/download
  else
    K_ETC=$KASSA_ETC/kassas/$1; K_APP=$KASSA_OPT/kassas/$1/app; K_DB=kassa_$1; K_UNIT=kassa-$1; K_BACKUP=/var/backups/kassa/$1
    K_DOWNLOAD=$KASSA_OPT/kassas/$1/download
  fi
  K_WW=$K_ETC/backup.wachtwoord
}

# Eén instelling van de huidige kassa (na kassa_paden): kassa_lees KASSA_DOMEIN
kassa_lees() { [ -f "$K_ETC/instellingen.env" ] && sed -n "s/^$1=//p" "$K_ETC/instellingen.env"; return 0; }

# Versleutelt een back-up met het back-upwachtwoord van de kassa (na kassa_paden).
kassa_versleutel() { openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass "file:$K_WW" -in "$1" -out "$2"; }

kassa_naam_geldig() { [[ "$1" =~ ^[a-z][a-z0-9]{1,19}$ ]] && [ "$1" != kassa ] && [ "$1" != kassas ]; }

# Staat deze server op internet (een kassa met een eigen adres, zonder DuckDNS-token)?
# Dan is er een firewall en worden veiligheidsupdates vanzelf geïnstalleerd.
kassa_online() {
  local n
  for n in $(kassa_namen); do
    kassa_paden "$n"
    deze_kassa_online && return 0
  done
  return 1
}
# Staat de huidige kassa (na kassa_paden) op internet?
deze_kassa_online() { [ -n "$(kassa_lees KASSA_DOMEIN)" ] && [ -z "$(kassa_lees KASSA_DUCKDNS_TOKEN)" ]; }

# Mag iemand met een wachtwoord inloggen op deze server (SSH)? Op internet proberen
# robots dat de hele dag; met een sleutel kan dat niet.
ssh_wachtwoord_aan() {
  command -v sshd >/dev/null || return 1
  sshd -T 2>/dev/null | grep -qi '^passwordauthentication yes'
}

# Schrijft /etc/caddy/Caddyfile voor alle kassa's op deze server.
caddy_schrijven() {
  local n domein token auth rest pad hsts blok sites="" intern=0 http_blok=""
  for n in $(kassa_namen); do
    kassa_paden "$n"
    domein=$(kassa_lees KASSA_DOMEIN); token=$(kassa_lees KASSA_DUCKDNS_TOKEN)
    auth=$(kassa_lees KASSA_AUTH_POORT); auth=${auth:-9999}
    rest=$(kassa_lees KASSA_REST_POORT); rest=${rest:-3000}
    pad=$(sed -n 's/^PAD=//p' "$K_ETC/download.env" 2>/dev/null)
    # Met een eigen adres: de browser gebruikt daarna altijd https (op een IP-adres negeert de browser dit).
    hsts=""
    [ -n "$domein" ] && hsts="
		Strict-Transport-Security \"max-age=31536000\""
    blok="
	encode gzip
	header {
		X-Content-Type-Options nosniff
		X-Frame-Options DENY
		Referrer-Policy same-origin
		-Server$hsts
	}
	handle_path /auth/v1/* {
		reverse_proxy 127.0.0.1:$auth
	}
	handle_path /rest/v1/* {
		reverse_proxy 127.0.0.1:$rest
	}"
    # De nieuwste back-up (versleuteld) om te downloaden; het pad is geheim en alleen beheerders zien het.
    [ -n "$pad" ] && blok+="
	handle_path /back-up/$pad/* {
		root * $K_DOWNLOAD
		header Content-Disposition attachment
		file_server
	}"
    blok+="
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
      http_blok="http:// {
	redir https://$domein{uri}
}"
    elif [ -n "$domein" ]; then
      # Eigen adres dat naar deze server wijst: Caddy haalt zelf een certificaat (Let's Encrypt).
      sites+="
# $n
$domein {
$blok
}
"
    else
      # Geen adres (alleen de eerste kassa, in het gebouw): eigen certificaat op het IP-adres.
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
    echo "# Gemaakt door de kassa-installatie ($(kassa_namen | tr '\n' ' ' | sed 's/ $//')). Niet met de hand aanpassen."
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

# Wat bij deze server hoort in de tabel systeem van de kassa zetten (na kassa_paden):
# het downloadpad en het mailadres van de back-up, of bijwerken vanuit de app mag (alleen bij de eerste
# kassa: een update geldt voor alle kassa's op de server) en de wifi voor de wifi-code.
# Ook na het terugzetten van een back-up, want die kan van een andere server komen.
kassa_systeem_schrijven() {
  local pad mag=false wn="" ww="" mail
  pad=$(sed -n 's/^PAD=//p' "$K_ETC/download.env" 2>/dev/null)
  if [ "$K_NAAM" = kassa ]; then
    mag=true
    if [ -f "$KASSA_ETC/wifi.env" ]; then
      { IFS= read -r wn; IFS= read -r ww; } < <(. "$KASSA_ETC/wifi.env"
        if [ "${KASSA_WIFI:-0}" = 1 ]; then printf '%s\n' "${KASSA_WIFI_NAAM:-}" "${KASSA_WIFI_WACHTWOORD:-}"; else printf '\n\n'; fi)
    fi
  fi
  mail=$(sed -n 's/^NAAR=//p' "$K_ETC/mail.env" 2>/dev/null || true)
  runuser -u postgres -- psql -d "$K_DB" -q -v ON_ERROR_STOP=1 -v p="$pad" -v m="$mag" -v n="$wn" -v w="$ww" -v mail="$mail" <<'SQL'
update public.systeem set backup_pad = nullif(:'p', ''), bijwerken_mag = :'m'::boolean,
  wifi_naam = nullif(:'n', ''), wifi_wachtwoord = nullif(:'w', ''), backup_mail_naar = nullif(:'mail', '') where id = 1;
SQL
}

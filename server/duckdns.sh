#!/usr/bin/env bash
# Echt https-certificaat via DuckDNS (gratis), zodat telefoons geen certificaat hoeven te installeren.
#   duckdns.sh installeer <naam.duckdns.org> <token>   (door installeer.sh)
#   duckdns.sh vernieuw                                (dagelijks, door kassa-duckdns.timer)
set -euo pipefail
ACME_VERSIE=3.1.1
HOME_ACME=/opt/kassa/acme
CONF=/etc/kassa/acme
TLS=/etc/kassa-tls
. /etc/kassa/instellingen.env 2>/dev/null || true

ip_bijwerken() {
  local sub=${KASSA_DOMEIN%.duckdns.org} ip
  ip=$(hostname -I | awk '{print $1}')
  [ "$(curl -fsS "https://www.duckdns.org/update?domains=$sub&token=$KASSA_DUCKDNS_TOKEN&ip=$ip")" = OK ] \
    || { echo "DuckDNS weigert de update: klopt de naam en het token?"; exit 1; }
}
acme() { DuckDNS_Token=$KASSA_DUCKDNS_TOKEN "$HOME_ACME/acme.sh" --home "$HOME_ACME" --config-home "$CONF" "$@"; }

case "${1:-}" in
  installeer)
    KASSA_DOMEIN=$2; KASSA_DUCKDNS_TOKEN=$3
    case "$KASSA_DOMEIN" in *.duckdns.org) ;; *) echo "Gebruik een naam die eindigt op .duckdns.org"; exit 1 ;; esac
    ip_bijwerken
    if [ ! -x "$HOME_ACME/acme.sh" ]; then
      T=$(mktemp -d)
      curl -fsSL "https://github.com/acmesh-official/acme.sh/archive/refs/tags/$ACME_VERSIE.tar.gz" | tar xz -C "$T"
      (cd "$T/acme.sh-$ACME_VERSIE" && ./acme.sh --install --home "$HOME_ACME" --config-home "$CONF" --nocron --noprofile >/dev/null)
      rm -rf "$T"
    fi
    install -d -m 750 -o root -g caddy "$TLS"
    acme --issue --server letsencrypt --dns dns_duckdns -d "$KASSA_DOMEIN" --dnssleep 90 || [ $? = 2 ]   # 2 = nog geldig
    acme --install-cert -d "$KASSA_DOMEIN" --key-file "$TLS/key.pem" --fullchain-file "$TLS/fullchain.pem" \
      --reloadcmd "chgrp caddy $TLS/*.pem; chmod 640 $TLS/*.pem; systemctl reload caddy 2>/dev/null || true"
    cat > /etc/systemd/system/kassa-duckdns.service <<UNIT
[Unit]
Description=Bar-kassa DuckDNS en certificaat vernieuwen
[Service]
Type=oneshot
ExecStart=/opt/kassa/bin/duckdns.sh vernieuw
UNIT
    cat > /etc/systemd/system/kassa-duckdns.timer <<UNIT
[Unit]
Description=Bar-kassa DuckDNS en certificaat vernieuwen
[Timer]
OnCalendar=*:0/30
Persistent=true
[Install]
WantedBy=timers.target
UNIT
    [ -d /run/systemd/system ] && systemctl daemon-reload && systemctl enable --now kassa-duckdns.timer >/dev/null 2>&1 || true
    ;;
  vernieuw)
    ip_bijwerken
    acme --cron >/dev/null
    ;;
  *) echo "gebruik: duckdns.sh installeer <domein> <token> | vernieuw"; exit 1 ;;
esac

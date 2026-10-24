#!/usr/bin/env bash
# Firewall voor een kassa-server die op internet staat (een gehuurde server met
# --domein). Alleen SSH (om in te loggen), http en https komen binnen; de rest
# (zoals de database) is van buitenaf niet bereikbaar. Andere firewallregels
# op de server blijven staan: dit is een eigen tabel die er alleen bij komt.
#   firewall.sh aan      instellen en bij het opstarten laden (door installeer.sh)
#   firewall.sh uit      weghalen
#   firewall.sh status   laten zien wat er open staat
set -euo pipefail
REGELS=/etc/kassa/firewall.nft

ssh_poorten() {
  # De poort(en) waarop SSH luistert, zodat je jezelf nooit buitensluit; 22 altijd.
  { echo 22; sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }'
    ss -Htlnp 2>/dev/null | awk '/"sshd"/ { n = split($4, a, ":"); print a[n] }'; } | grep -E '^[0-9]+$' | sort -un | paste -sd, -
}

case "${1:-}" in
  aan)
    command -v nft >/dev/null || { DEBIAN_FRONTEND=noninteractive apt-get install -y -q nftables >/dev/null; }
    POORTEN=$(ssh_poorten)
    # Met een eigen wifi-netwerk (wifi.sh) vragen de telefoons daar een adres (DHCP) en namen (DNS).
    WIFI=""
    if [ "$(. /etc/kassa/wifi.env 2>/dev/null; echo "${KASSA_WIFI:-0}")" = 1 ]; then
      WIFI='udp dport { 53, 67 } accept comment "eigen wifi (DHCP en DNS)"
		tcp dport 53 accept comment "eigen wifi (DNS)"'
    fi
    cat > "$REGELS" <<EOF
# Gemaakt door firewall.sh (Bar-kassa). Niet met de hand aanpassen.
table inet kassa_firewall
delete table inet kassa_firewall
table inet kassa_firewall {
	chain binnen {
		type filter hook input priority 0; policy drop;
		iif lo accept
		ct state established,related accept
		ct state invalid drop
		ip protocol icmp accept
		ip6 nexthdr ipv6-icmp accept
		tcp dport { $POORTEN } accept comment "SSH"
		tcp dport { 80, 443 } accept comment "kassa (http en https)"
		udp dport 443 accept comment "kassa (http/3)"
		$WIFI
	}
}
EOF
    nft -f "$REGELS"
    cat > /etc/systemd/system/kassa-firewall.service <<EOF
[Unit]
Description=Bar-kassa firewall
Before=network-pre.target
Wants=network-pre.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f $REGELS
ExecStop=/usr/sbin/nft delete table inet kassa_firewall
[Install]
WantedBy=multi-user.target
EOF
    if [ -d /run/systemd/system ]; then
      systemctl daemon-reload
      systemctl enable kassa-firewall >/dev/null 2>&1
    fi
    echo "Firewall aan: alleen SSH (poort $POORTEN), http en https zijn van buitenaf bereikbaar."
    ;;
  uit)
    nft delete table inet kassa_firewall 2>/dev/null || true
    if [ -f /etc/systemd/system/kassa-firewall.service ]; then
      [ -d /run/systemd/system ] && systemctl disable kassa-firewall >/dev/null 2>&1 || true
      rm -f /etc/systemd/system/kassa-firewall.service
      [ -d /run/systemd/system ] && systemctl daemon-reload || true
    fi
    rm -f "$REGELS"
    echo "Firewall van de kassa uit."
    ;;
  status)
    nft list table inet kassa_firewall 2>/dev/null || echo "De firewall van de kassa staat uit."
    ;;
  *) sed -n '2,8p' "$0"; exit 1 ;;
esac

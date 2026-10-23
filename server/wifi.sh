#!/usr/bin/env bash
# Eigen wifi-netwerk van de kassa: de server is zelf het wifi-punt voor de
# telefoons. Zo werkt de kassa overal, ook zonder (of met slechte) wifi van het
# gebouw, en heeft de kassa altijd hetzelfde adres: https://10.42.0.1
# Heeft de server via de netwerkkabel internet, dan krijgen de telefoons dat ook.
#   wifi.sh aan            (door installeer.sh, met de naam en het wachtwoord uit /etc/kassa/wifi.env)
#   wifi.sh uit
#   wifi.sh status         naam, wachtwoord en QR-code om te verbinden
#   wifi.sh nat            (door kassa-wifi.service) internet van de kabel doorgeven
set -euo pipefail
ETC=/etc/kassa
MAP=$ETC/wifi
IP=10.42.0.1
NET=10.42.0.0/24
# shellcheck disable=SC1091
. "$ETC/instellingen.env" 2>/dev/null || true
# shellcheck disable=SC1091
. "$ETC/wifi.env" 2>/dev/null || true

fout() { printf '\033[1;31mFOUT: %s\033[0m\n' "$*" >&2; exit 1; }

# De eerste wifi-kaart (of wifi-stick) in deze computer.
wifi_kaart() {
  local d
  for d in /sys/class/net/*; do
    [ -d "$d/wireless" ] || [ -e "$d/phy80211" ] || continue
    basename "$d"; return 0
  done
  return 1
}

# QR-code die telefoons met de camera scannen om te verbinden.
wifi_qr() {
  local e='s/[\\;,:"]/\\&/g' n w
  n=$(printf '%s' "$KASSA_WIFI_NAAM" | sed "$e"); w=$(printf '%s' "$KASSA_WIFI_WACHTWOORD" | sed "$e")
  command -v qrencode >/dev/null && qrencode -t ansiutf8 -m 2 "WIFI:T:WPA;S:$n;P:$w;;"
  return 0
}

case "${1:-}" in
  aan)
    [ -n "${KASSA_WIFI_NAAM:-}" ] && [ -n "${KASSA_WIFI_WACHTWOORD:-}" ] || fout "Wifi-naam of wachtwoord ontbreekt."
    IF=$(wifi_kaart) || fout "Deze computer heeft geen wifi. Plaats een wifi-kaart of een USB-wifi-stick die als wifi-punt kan werken (\"AP-modus\"), of sluit een los wifi-punt aan op de netwerkkabel en installeer zonder --wifi."
    PHY=$(cat "/sys/class/net/$IF/phy80211/name" 2>/dev/null || echo phy0)
    if ! iw phy "$PHY" info 2>/dev/null | sed -n '/Supported interface modes/,/^\t[^\t]/p' | grep -q '\* AP$'; then
      fout "De wifi van deze computer ($IF) kan geen eigen netwerk maken (geen AP-modus). Gebruik een andere wifi-stick of een los wifi-punt."
    fi
    # De wifi mag niet al gebruikt worden om zelf internet te krijgen.
    if grep -qsw "$IF" /etc/network/interfaces /etc/network/interfaces.d/* 2>/dev/null; then
      fout "De wifi ($IF) wordt nu gebruikt voor internet (in /etc/network/interfaces). Sluit de server met een netwerkkabel aan, haal de regels voor $IF daar weg en probeer het opnieuw."
    fi
    if grep -qs 'wifis:' /etc/netplan/*.yaml 2>/dev/null; then
      fout "De wifi wordt nu gebruikt voor internet (in /etc/netplan). Sluit de server met een netwerkkabel aan, haal het wifi-deel daar weg en probeer het opnieuw."
    fi
    # NetworkManager (bijv. op een Debian met bureaublad) moet van deze wifi afblijven.
    if command -v nmcli >/dev/null && [ -d /etc/NetworkManager ]; then
      mkdir -p /etc/NetworkManager/conf.d
      printf '[keyfile]\nunmanaged-devices=interface-name:%s\n' "$IF" > /etc/NetworkManager/conf.d/kassa-wifi.conf
      nmcli general reload 2>/dev/null || true
      nmcli device set "$IF" managed no 2>/dev/null || true
    fi
    mkdir -p "$MAP"; chmod 700 "$MAP"
    umask 077
    cat > "$MAP/hostapd.conf" <<CONF
# Gemaakt door wifi.sh. Niet met de hand aanpassen; opnieuw installeren met --wifi-naam / --wifi-wachtwoord.
interface=$IF
driver=nl80211
ssid=$KASSA_WIFI_NAAM
utf8_ssid=1
country_code=NL
ieee80211d=1
hw_mode=g
channel=${KASSA_WIFI_KANAAL:-6}
ieee80211n=1
wmm_enabled=1
auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=$KASSA_WIFI_WACHTWOORD
CONF
    # Telefoons krijgen een adres en vinden de kassa; andere namen gaan door naar internet.
    {
      echo "# Gemaakt door wifi.sh."
      echo "interface=$IF"
      echo "except-interface=lo"
      echo "bind-dynamic"
      echo "domain-needed"
      echo "bogus-priv"
      echo "dhcp-range=10.42.0.20,10.42.0.250,255.255.255.0,12h"
      echo "dhcp-option=option:router,$IP"
      echo "dhcp-option=option:dns-server,$IP"
      echo "dhcp-leasefile=/var/lib/misc/kassa-wifi.leases"
      echo "pid-file=/run/kassa-wifi-dns.pid"
      # Met DuckDNS: de naam van de kassa wijst op dit netwerk altijd naar de server, ook zonder internet.
      [ -n "${KASSA_DOMEIN:-}" ] && echo "address=/$KASSA_DOMEIN/$IP"
    } > "$MAP/dnsmasq.conf"
    umask 022
    echo "IF=$IF" > "$MAP/kaart.env"

    cat > /etc/systemd/system/kassa-wifi.service <<UNIT
[Unit]
Description=Bar-kassa: eigen wifi-netwerk ($KASSA_WIFI_NAAM)
After=network.target
Wants=kassa-wifi-dns.service
[Service]
ExecStartPre=-$(command -v rfkill) unblock wifi
ExecStartPre=$(command -v ip) addr replace $IP/24 dev $IF
ExecStart=$(command -v hostapd) $MAP/hostapd.conf
ExecStartPost=-/opt/kassa/bin/wifi.sh nat
ExecStopPost=-$(command -v ip) addr del $IP/24 dev $IF
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT
    cat > /etc/systemd/system/kassa-wifi-dns.service <<UNIT
[Unit]
Description=Bar-kassa: adressen en namen op het eigen wifi-netwerk
After=kassa-wifi.service
[Service]
ExecStart=$(command -v dnsmasq) --keep-in-foreground --conf-file=$MAP/dnsmasq.conf
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT
    # De gewone diensten van deze pakketten niet gebruiken (die zouden in de weg zitten).
    if [ -d /run/systemd/system ]; then
      systemctl disable --now hostapd.service >/dev/null 2>&1 || true
      systemctl daemon-reload
      systemctl enable kassa-wifi.service kassa-wifi-dns.service >/dev/null 2>&1
      systemctl restart kassa-wifi.service kassa-wifi-dns.service
      sleep 3
      systemctl is-active -q kassa-wifi.service || fout "Het wifi-netwerk start niet. Zie: journalctl -u kassa-wifi"
    fi
    ;;
  nat)
    # shellcheck disable=SC1091
    . "$MAP/kaart.env"
    sysctl -qw net.ipv4.ip_forward=1
    nft -f - <<NFT
table ip kassa_wifi
delete table ip kassa_wifi
table ip kassa_wifi {
	chain nat {
		type nat hook postrouting priority srcnat; policy accept;
		ip saddr $NET oifname != "$IF" masquerade
	}
}
NFT
    ;;
  uit)
    if [ -d /run/systemd/system ]; then
      systemctl disable --now kassa-wifi.service kassa-wifi-dns.service >/dev/null 2>&1 || true
    fi
    rm -f /etc/systemd/system/kassa-wifi.service /etc/systemd/system/kassa-wifi-dns.service /etc/NetworkManager/conf.d/kassa-wifi.conf
    nft delete table ip kassa_wifi 2>/dev/null || true
    rm -rf "$MAP"
    [ -d /run/systemd/system ] && systemctl daemon-reload
    command -v nmcli >/dev/null && nmcli general reload 2>/dev/null || true
    ;;
  status)
    [ "${KASSA_WIFI:-0}" = 1 ] || { echo "Het eigen wifi-netwerk staat uit (aanzetten: bash kassa-installatie.run --wifi)."; exit 0; }
    echo "Wifi-netwerk:  $KASSA_WIFI_NAAM"
    echo "Wachtwoord:    $KASSA_WIFI_WACHTWOORD"
    echo "Kassa:         https://${KASSA_DOMEIN:-$IP}"
    [ -d /run/systemd/system ] && echo "Status:        $(systemctl is-active kassa-wifi.service 2>/dev/null || true)"
    echo
    echo "Scan deze code met de camera van een telefoon om met de wifi te verbinden:"
    wifi_qr
    ;;
  *) sed -n '2,10p' "$0"; exit 1 ;;
esac

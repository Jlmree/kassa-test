#!/usr/bin/env bash
# De verkoopwebsite van Tapkas op deze server, naast de kassa's: de pagina's uit
# /opt/kassa/website (met de proefversie onder /proef/) op een eigen adres, en het
# aanvraagformulier (website-aanvraag.py) dat aanvragen bewaart en doormailt.
#   website.sh aan <adres>      website aanzetten, bijv. website.sh aan tapkas.nl
#   website.sh mail             instellen naar welk adres aanvragen gaan (met proefmail)
#   website.sh aanvragen [n]    de laatste n aanvragen laten zien (standaard 10)
#   website.sh status           adres, formulier, mail, aantal aanvragen
#   website.sh uit              website uitzetten (de aanvragen blijven bewaard)
set -euo pipefail
. /opt/kassa/bin/kassa-lib.sh
fout() { echo "$*" >&2; exit 1; }
ENV=$KASSA_ETC/website.env
MAIL=$KASSA_ETC/website-mail.env
STAAT=/var/lib/kassa-website
UNIT=/etc/systemd/system/kassa-website.service
[ "$(id -u)" = 0 ] || fout "Doe dit als root (eerst: su -)."

caddy_herladen() {
  caddy_schrijven || fout "De webserver kon niet worden ingesteld (zie hierboven)."
  if [ -d /run/systemd/system ]; then systemctl reload caddy; else caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || true; fi
}

dienst_starten() {
  if [ -d /run/systemd/system ]; then
    systemctl daemon-reload
    systemctl enable kassa-website >/dev/null 2>&1
    systemctl restart kassa-website
  else
    # Zonder systemd (bijv. een test in een container): gewoon op de achtergrond.
    kill "$(cat /run/kassa-website.pid 2>/dev/null)" 2>/dev/null || true
    mkdir -p "$STAAT"
    STATE_DIRECTORY=$STAAT setsid python3 "$KASSA_OPT/bin/website-aanvraag.py" </dev/null >>/var/log/kassa-website.log 2>&1 &
    echo $! > /run/kassa-website.pid
  fi
}

case "${1:-}" in
  aan)
    adres=${2:-}
    [[ $adres =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || fout "Geef het adres van de website, bijvoorbeeld: website.sh aan tapkas.nl"
    for n in $(kassa_namen); do
      kassa_paden "$n"
      [ "$(kassa_lees KASSA_DOMEIN)" = "$adres" ] && fout "Dat adres gebruikt kassa \"$n\" al. Kies een ander adres voor de website."
    done
    command -v python3 >/dev/null || { echo "Python installeren (voor het aanvraagformulier)..."; apt-get install -y -q python3-minimal >/dev/null; }
    [ -d "$KASSA_OPT/website" ] || fout "De websitebestanden ontbreken; installeer de kassa opnieuw."
    printf 'WEBSITE_DOMEIN=%s\n' "$adres" > "$ENV"
    [ -f "$MAIL" ] || ( umask 077; : > "$MAIL" )
    cat > "$UNIT" <<EOF
[Unit]
Description=Tapkas website: aanvraagformulier
After=network.target

[Service]
ExecStart=/usr/bin/python3 $KASSA_OPT/bin/website-aanvraag.py
DynamicUser=yes
StateDirectory=kassa-website
StateDirectoryMode=0700
LoadCredential=mail.env:$MAIL
Restart=on-failure
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
NoNewPrivileges=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
MemoryMax=64M

[Install]
WantedBy=multi-user.target
EOF
    dienst_starten
    caddy_herladen
    echo "De website staat aan op https://$adres"
    echo "Zorg dat het adres (A-record in de DNS) naar deze server wijst; het certificaat komt dan vanzelf."
    [ -s "$MAIL" ] || echo "Stel nog in waar aanvragen naartoe gaan: $0 mail"
    ;;
  mail)
    [ -t 0 ] || fout "Instellen kan alleen in een terminal."
    lees() { sed -n "s/^$1=//p" "$MAIL" 2>/dev/null | head -n 1 || true; }
    vraag() { local a; read -r -p "$1${2:+ [$2]}: " a; echo "${a:-$2}"; }
    echo "Aanvragen via het formulier gaan naar een e-mailadres naar keuze. De server heeft"
    echo "daarvoor een mailaccount nodig om mee te versturen (hetzelfde als voor de back-up mag)."
    echo
    naar=$(vraag "Naar welk e-mailadres gaan de aanvragen" "$(lees NAAR)")
    gebruiker=$(vraag "Mailaccount om mee te versturen (e-mailadres)" "$(lees GEBRUIKER)")
    case "${gebruiker,,}" in
      *@gmail.com|*@googlemail.com) s=smtp.gmail.com
        echo "Gmail: gebruik een app-wachtwoord (myaccount.google.com/apppasswords), niet je gewone wachtwoord." ;;
      *@outlook.*|*@hotmail.*|*@live.*) s=smtp-mail.outlook.com ;;
      *) s=$(lees SERVER) ;;
    esac
    server=$(vraag "Mailserver (staat bij je mailaanbieder onder SMTP)" "$s")
    p=$(lees POORT)
    poort=$(vraag "Poort (587 of 465)" "${p:-587}")
    read -r -s -p "Wachtwoord van het mailaccount: " ww; echo
    [ -n "$naar" ] && [ -n "$gebruiker" ] && [ -n "$server" ] && [ -n "$ww" ] || fout "Niet alles is ingevuld."
    [[ $naar == *@*.* && $gebruiker == *@*.* ]] || fout "Dat lijkt geen e-mailadres."
    t=$(mktemp); chmod 600 "$t"
    printf 'NAAR=%s\nGEBRUIKER=%s\nVAN=%s\nSERVER=%s\nPOORT=%s\nWACHTWOORD=%s\n' "$naar" "$gebruiker" "$gebruiker" "$server" "$poort" "$ww" > "$t"
    echo "Proefmail versturen..."
    if python3 "$KASSA_OPT/bin/website-aanvraag.py" --test "$t"; then
      mv "$t" "$MAIL"; chmod 600 "$MAIL"
      [ -f "$ENV" ] && dienst_starten
      echo "Opgeslagen. Kijk of de proefmail aankomt (ook in de map spam)."
    else
      rm -f "$t"; fout "Niet opgeslagen. Controleer de gegevens en probeer opnieuw: $0 mail"
    fi
    ;;
  aanvragen)
    n=${2:-10}; [[ $n =~ ^[0-9]+$ ]] || fout "Gebruik: $0 aanvragen [aantal]"
    f=$(ls /var/lib/private/kassa-website/aanvragen.jsonl "$STAAT/aanvragen.jsonl" 2>/dev/null | head -n 1 || true)
    [ -n "$f" ] || { echo "Nog geen aanvragen."; exit 0; }
    tail -n "$n" "$f" | python3 -c '
import json, sys
for r in sys.stdin:
    a = json.loads(r)
    bericht = (a.get("bericht") or "(geen bericht)").replace("\n", " ")[:300]
    print("%s  %s  ·  %s <%s> %s" % (a["tijd"], a["club"], a["naam"], a["email"], a.get("telefoon") or ""))
    print("   %s: %s" % (a["keus"], bericht))'
    ;;
  status)
    if [ -f "$ENV" ]; then echo "Website: https://$(sed -n 's/^WEBSITE_DOMEIN=//p' "$ENV")"; else echo "Website: uit (aanzetten: $0 aan <adres>)"; fi
    if [ -d /run/systemd/system ] && [ -f "$UNIT" ]; then echo "Formulier: $(systemctl is-active kassa-website 2>/dev/null || true)"; fi
    if [ -s "$MAIL" ]; then echo "Aanvragen gaan naar: $(sed -n 's/^NAAR=//p' "$MAIL")"; else echo "Mail: nog niet ingesteld ($0 mail); aanvragen worden wel bewaard"; fi
    f=$(ls /var/lib/private/kassa-website/aanvragen.jsonl "$STAAT/aanvragen.jsonl" 2>/dev/null | head -n 1 || true)
    echo "Aanvragen bewaard: $([ -n "$f" ] && wc -l < "$f" || echo 0)"
    ;;
  uit)
    rm -f "$ENV"
    if [ -d /run/systemd/system ]; then systemctl disable --now kassa-website >/dev/null 2>&1 || true; else kill "$(cat /run/kassa-website.pid 2>/dev/null)" 2>/dev/null || true; fi
    rm -f "$UNIT"
    caddy_herladen
    echo "De website staat uit. Bewaarde aanvragen blijven staan; aanzetten: $0 aan <adres>"
    ;;
  *) fout "Gebruik: $0 aan <adres> | mail | aanvragen [n] | status | uit" ;;
esac

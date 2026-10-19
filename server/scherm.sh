#!/usr/bin/env bash
# De kassa ook op het eigen scherm van de server tonen (bijv. een aanraakscherm
# aan de bar op de HP t620). Start na het aanzetten vanzelf, schermvullend,
# zonder bureaublad. Telefoons en tablets blijven gewoon werken.
#   scherm.sh aan    installeren en starten
#   scherm.sh uit    weer uitzetten
#   scherm.sh start  (door systemd) het scherm zelf starten
# Onderhoud aan de server zelf: Ctrl+Alt+F2 geeft een gewone inlog.
set -euo pipefail
GEBRUIKER=kassa-scherm
UNIT=/etc/systemd/system/kassa-scherm.service
case "${1:-}" in
  aan|uit) [ "$(id -u)" = 0 ] || { echo "Start dit als root."; exit 1; } ;;
esac

case "${1:-}" in
  aan)
    . /etc/os-release
    if [ "${ID:-}" != debian ]; then
      echo "Het eigen scherm werkt alleen op Debian: Ubuntu levert Chromium alleen als snap. De kassa zelf werkt wel."
      exit 1
    fi
    echo "Scherm-onderdelen installeren (Chromium, cage) — kan een paar minuten duren..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends cage chromium fonts-dejavu-core >/dev/null
    id "$GEBRUIKER" >/dev/null 2>&1 || useradd -m -c "Bar-kassa scherm" "$GEBRUIKER"
    for g in video input render; do getent group "$g" >/dev/null && usermod -aG "$g" "$GEBRUIKER"; done
    # cage = een schermvullende omgeving voor precies één programma; via PAM
    # krijgt de gebruiker het scherm, toetsenbord en aanraakscherm van tty1.
    cat > "$UNIT" <<'EOF'
[Unit]
Description=Bar-kassa op het eigen scherm
After=systemd-user-sessions.service caddy.service kassa-auth.service kassa-rest.service
Wants=caddy.service
Conflicts=getty@tty1.service
[Service]
User=kassa-scherm
PAMName=login
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
StandardInput=tty-fail
StandardOutput=journal
StandardError=journal
UtmpIdentifier=tty1
UtmpMode=user
Environment=XDG_SESSION_TYPE=wayland
ExecStart=/opt/kassa/bin/scherm.sh start
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable kassa-scherm >/dev/null 2>&1
    systemctl restart kassa-scherm
    echo "Het eigen scherm staat aan. Log één keer in met een (USB-)toetsenbord; daarna blijft de kassa ingelogd."
    ;;
  start)
    # Door kassa-scherm.service als gebruiker kassa-scherm gestart.
    # Na een stroomstoring geen "pagina's herstellen?"-melding van Chromium.
    f=$HOME/.config/chromium/Default/Preferences
    [ -f "$f" ] && sed -i 's/"exited_cleanly":false/"exited_cleanly":true/; s/"exit_type":"[A-Za-z]*"/"exit_type":"Normal"/' "$f"
    # http://localhost is voor de browser een beveiligde verbinding: geen certificaat nodig.
    exec cage -s -- chromium --kiosk --ozone-platform=wayland --no-first-run --noerrdialogs \
      --disable-infobars --disable-features=Translate,TranslateUI --overscroll-history-navigation=0 \
      --check-for-update-interval=31536000 --password-store=basic http://localhost:8080/
    ;;
  uit)
    if [ -f "$UNIT" ]; then
      systemctl disable --now kassa-scherm >/dev/null 2>&1 || true
      rm -f "$UNIT"
      systemctl daemon-reload
      systemctl start getty@tty1 2>/dev/null || true
    fi
    echo "Het eigen scherm staat uit."
    ;;
  *)
    echo "gebruik: scherm.sh aan | uit"; exit 1 ;;
esac

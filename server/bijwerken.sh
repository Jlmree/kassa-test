#!/usr/bin/env bash
# Kassa bijwerken naar de nieuwste versie (of naar een gegeven pakket).
#   sudo /opt/kassa/bin/bijwerken.sh [kassa.tar.gz]
set -euo pipefail
. /etc/kassa/instellingen.env 2>/dev/null || true
REPO=${KASSA_REPO:-Jlmree/kassa-test}
WERK=$(mktemp -d); trap 'rm -rf "$WERK"' EXIT
if [ -n "${1:-}" ]; then
  cp "$1" "$WERK/kassa.tar.gz"
else
  URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | grep -o '"browser_download_url": *"[^"]*kassa\.tar\.gz"' | head -1 | cut -d'"' -f4)
  [ -n "$URL" ] || { echo "Geen release gevonden"; exit 1; }
  curl -fsSL -o "$WERK/kassa.tar.gz" "$URL"
fi
tar xzf "$WERK/kassa.tar.gz" -C "$WERK"
echo "Huidige versie: $(cat /opt/kassa/versie 2>/dev/null || echo onbekend), nieuwe versie: $(cat "$WERK/versie" 2>/dev/null || echo onbekend)"
echo "Eerst een back-up..."
/opt/kassa/bin/backup.sh
KASSA_PAKKET="$WERK/kassa.tar.gz" bash "$WERK/server/installeer.sh"

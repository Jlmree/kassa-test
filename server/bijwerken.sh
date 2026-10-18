#!/usr/bin/env bash
# Kassa bijwerken naar de nieuwste versie (of met een gedownload installatiebestand).
#   /opt/kassa/bin/bijwerken.sh [kassa-installatie.run]
set -euo pipefail
REPO=$(sed -n 's/^KASSA_REPO=//p' /etc/kassa/instellingen.env 2>/dev/null)
REPO=${REPO:-Jlmree/kassa-test}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
if [ -n "${1:-}" ]; then
  cp "$1" "$T/kassa-installatie.run"
else
  echo "Nieuwste versie ophalen..."
  curl -fL --progress-bar -o "$T/kassa-installatie.run" "https://github.com/$REPO/releases/latest/download/kassa-installatie.run"
fi
echo "Huidige versie: $(cat /opt/kassa/versie 2>/dev/null || echo onbekend)"
echo "Eerst een back-up..."
/opt/kassa/bin/backup.sh
bash "$T/kassa-installatie.run"

#!/usr/bin/env bash
# Voert de verzoeken uit die een beheerder in de app doet (Beheer → Instellingen):
# zoeken naar een nieuwe versie en bijwerken. Draait elke minuut als root
# (kassa-bijwerker.timer). Houdt ook de geïnstalleerde versie bij in de database.
#   bijwerker.sh            kijken of er iets te doen is
#   bijwerker.sh uitvoeren  de update zelf (los van de timer gestart)
set -uo pipefail
OPT=/opt/kassa
LOG=/var/log/kassa-bijwerken.log
PID=/run/kassa-bijwerken.pid
REPO=$(sed -n 's/^KASSA_REPO=//p' /etc/kassa/instellingen.env 2>/dev/null)
REPO=${REPO:-Jlmree/kassa-test}
cd /

# SQL uitvoeren als postgres; waarden gaan als psql-variabelen mee (:'naam'), nooit in de tekst.
sql() { runuser -u postgres -- psql -d kassa -Atq -v ON_ERROR_STOP=1 "$@"; }
klaar() { # status melding
  sql -v s="$1" -v m="$2" -v v="$(cat $OPT/versie 2>/dev/null)" <<'EOF'
-- gecontroleerd leeg: de volgende ronde kijkt meteen weer wat de nieuwste versie is.
update public.systeem set status = :'s', melding = :'m', versie = :'v', gecontroleerd = null,
  bijgewerkt_ts = case when :'s' = 'klaar' then now() else bijgewerkt_ts end where id = 1;
EOF
}

if [ "${1:-}" = uitvoeren ]; then
  echo $$ > "$PID"
  { echo; echo "=== $(date '+%F %T') bijwerken vanuit de app ==="; } >> "$LOG"
  if "$OPT/bin/bijwerken.sh" </dev/null >> "$LOG" 2>&1; then
    klaar klaar "Bijgewerkt naar $(cat $OPT/versie)"
  else
    klaar mislukt "Bijwerken is mislukt. De kassa draait nog op de oude versie. Laatste regels uit $LOG: $(sed 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -v '^\s*$' | tail -n 4 | tr '\n' ' ')"
  fi
  rm -f "$PID"
  exit 0
fi

IFS='|' read -r VERZOEK STATUS LEEFTIJD < <(sql -c "select coalesce(verzoek, ''), status,
  coalesce(extract(epoch from now() - gecontroleerd)::int, 999999) from public.systeem where id = 1") || exit 0
[ -n "${STATUS:-}" ] || exit 0

# Eigen versie bijhouden (alleen schrijven als hij anders is).
sql -v v="$(cat $OPT/versie 2>/dev/null || echo onbekend)" <<'EOF'
update public.systeem set versie = :'v' where id = 1 and versie is distinct from :'v';
EOF

# Een update die niet meer loopt (bijv. stroomstoring halverwege) netjes afsluiten.
if [ "$STATUS" = bezig ] && ! { [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; }; then
  klaar mislukt "De update is onderbroken. Probeer het opnieuw."
  STATUS=mislukt
fi

# Nieuwste versie opzoeken: op verzoek, en verder elke 6 uur.
if [ "$VERZOEK" = controleren ] || [ "$LEEFTIJD" -gt 21600 ]; then
  N=$(curl -fsS --max-time 20 "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
      | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)
  if [ -n "$N" ]; then
    # Wat er nieuw is in die versie (alleen bewaren als het geldige JSON is).
    W=$(curl -fsSL --max-time 20 "https://github.com/$REPO/releases/latest/download/wijzigingen.json" 2>/dev/null | head -c 200000)
    [ -n "$W" ] && sql -v w="$W" >/dev/null 2>&1 <<'EOF'
update public.systeem set wijzigingen = :'w'::jsonb where id = 1;
EOF
    sql -v n="$N" <<'EOF'
update public.systeem set nieuwste = :'n', gecontroleerd = now(),
  melding = case when verzoek = 'controleren' then null else melding end,
  verzoek = case when verzoek = 'controleren' then null else verzoek end where id = 1;
EOF
  elif [ "$VERZOEK" = controleren ]; then
    sql -c "update public.systeem set verzoek = null, melding = 'Geen verbinding met GitHub. Heeft de kassa-server internet?' where id = 1"
  fi
fi

if [ "$VERZOEK" = bijwerken ] && [ "$STATUS" != bezig ]; then
  if ! curl -fsSL --max-time 20 -o /dev/null -r 0-0 "https://github.com/$REPO/releases/latest/download/kassa-installatie.run" 2>/dev/null; then
    sql -c "update public.systeem set verzoek = null, status = 'mislukt', melding = 'Geen verbinding met GitHub. Heeft de kassa-server internet? Bijwerken kan ook met een USB-stick (zie de handleiding).' where id = 1"
    exit 0
  fi
  sql -c "update public.systeem set verzoek = null, status = 'bezig', melding = 'Bezig met bijwerken. Dit duurt een paar minuten; de kassa is zo even niet bereikbaar.' where id = 1"
  # Los van deze timer starten: de installatie herstart diensten en vervangt dit script.
  if [ -d /run/systemd/system ]; then
    systemd-run --quiet --collect --unit="kassa-bijwerken-$(date +%s)" "$OPT/bin/bijwerker.sh" uitvoeren
  else
    setsid "$OPT/bin/bijwerker.sh" uitvoeren </dev/null >/dev/null 2>&1 &
  fi
fi

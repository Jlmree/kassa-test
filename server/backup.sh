#!/usr/bin/env bash
# Back-up van de kassa-database(s). Draait elk uur (kassa-backup.timer, met "elkuur").
# Elk uur: alleen als er iets veranderd is sinds de vorige back-up. Oude back-ups
# worden uitgedund: alles van de laatste 2 dagen, daarna de laatste van elke dag
# tot 90 dagen, daarna de laatste van elke maand tot 2 jaar. De nieuwste blijft altijd.
# Elke kassa heeft een eigen back-upwachtwoord. Daarmee versleuteld gaat de nieuwste
# back-up naar:
# - een USB-stick met de naam KASSA-BACKUP, als die erin zit;
# - een e-mailadres, elke nacht (als dat is ingesteld, zie backup-mail.sh);
# - de downloadmap van de kassa: een beheerder downloadt hem in de app
#   (Beheer → Instellingen → Back-up downloaden).
# Wie zo'n bestand heeft, kan er zonder dat wachtwoord niets mee (geen kaartcodes, geen gegevens).
#   backup.sh [naam...]              back-up maken (altijd, bijv. voor een update); zonder naam: alle kassa's
#   backup.sh elkuur [naam...]       alleen als er iets veranderd is
#   backup.sh wachtwoord [naam]      het back-upwachtwoord van een kassa laten zien
set -euo pipefail
. /opt/kassa/bin/kassa-lib.sh

if [ "${1:-}" = wachtwoord ]; then
  kassa_paden "${2:-kassa}"
  [ -s "$K_WW" ] || { echo "Er is nog geen back-upwachtwoord (installeer de kassa opnieuw)."; exit 1; }
  echo "Back-upwachtwoord${2:+ van kassa $2}: $(cat "$K_WW")"
  exit 0
fi
ELKUUR=0
if [ "${1:-}" = elkuur ]; then ELKUUR=1; shift; fi
NAMEN=${*:-$(kassa_namen)}

# Oude back-ups uitdunnen (zie boven). $1 = map, $2 = begin van de naam, $3 = einde van de naam.
uitdunnen() {
  local map=$1 begin=$2 eind=$3 nu f naam s dag t eerste=1
  local -A dagen=() maanden=()
  nu=$(date +%s)
  while IFS= read -r f; do
    naam=${f##*/}; s=${naam#"$begin"-}; s=${s%"$eind"}
    [[ $s =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})-([0-9]{2})([0-9]{2})([0-9]{2})$ ]] || continue
    dag=${BASH_REMATCH[1]}
    t=$(date -d "$dag ${BASH_REMATCH[2]}:${BASH_REMATCH[3]}:${BASH_REMATCH[4]}" +%s) || continue
    if (( eerste )); then eerste=0
    elif (( nu - t < 2 * 86400 )); then :
    elif (( nu - t < 90 * 86400 )) && [ -z "${dagen[$dag]:-}" ]; then :
    elif (( nu - t < 730 * 86400 )) && [ -z "${maanden[${dag:0:7}]:-}" ]; then :
    else rm -f -- "$f"; continue
    fi
    dagen[$dag]=1; maanden[${dag:0:7}]=1
  done < <(find "$map" -maxdepth 1 -name "$begin-*$eind" | sort -r)
}

# Stand van de gegevens: verandert bij elke wijziging in de kassa en bij inloggen of een nieuw wachtwoord.
stand() {
  su postgres -c "psql -XtAq -d $K_DB" <<'SQL' 2>/dev/null || true
select (select last_value from public.wijziging) || '/' || coalesce((select max(greatest(updated_at, last_sign_in_at))::text from auth.users), '');
SQL
}

BESTANDEN=()
for n in $NAMEN; do
  kassa_paden "$n"
  mkdir -p "$K_BACKUP" && chmod 700 "$K_BACKUP"
  NU=$(stand)
  LAATSTE=$(find "$K_BACKUP" -maxdepth 1 -name "$n-*.dump" | sort | tail -n 1)
  if [ "$ELKUUR" = 1 ] && [ -n "$NU" ] && [ -n "$LAATSTE" ] && [ "$NU" = "$(cat "$K_BACKUP/.stand" 2>/dev/null)" ]; then
    # Niets veranderd: geen nieuwe back-up, wel de laatste nog op de stick zetten als die er net in zit.
    BESTAND=$LAATSTE
  else
    BESTAND="$K_BACKUP/$n-$(date +%Y-%m-%d-%H%M%S).dump"
    if ! su postgres -c "pg_dump -Fc $K_DB" > "$BESTAND.tmp"; then
      rm -f "$BESTAND.tmp"; echo "Back-up van $n mislukt." >&2; exit 1
    fi
    mv "$BESTAND.tmp" "$BESTAND"
    # De stand pas onthouden als de back-up gelukt is.
    if [ -n "$NU" ]; then echo "$NU" > "$K_BACKUP/.stand"; fi
  fi
  uitdunnen "$K_BACKUP" "$n" .dump
  BESTANDEN+=("$BESTAND")

  # De nieuwste versleuteld in de downloadmap (alleen als daar een pad voor is, zie installeer.sh).
  if [ -s "$K_WW" ] && [ -f "$K_ETC/download.env" ]; then
    NAAM=$(basename "$BESTAND").enc
    mkdir -p "$K_DOWNLOAD"
    if [ ! -s "$K_DOWNLOAD/$NAAM" ] && kassa_versleutel "$BESTAND" "$K_DOWNLOAD/$NAAM.tmp"; then
      chmod 644 "$K_DOWNLOAD/$NAAM.tmp" && mv "$K_DOWNLOAD/$NAAM.tmp" "$K_DOWNLOAD/$NAAM"
      find "$K_DOWNLOAD" -maxdepth 1 -type f ! -name "$NAAM" -delete
      runuser -u postgres -- psql -d "$K_DB" -q -v b="$NAAM" <<'SQL' 2>/dev/null || true
update public.systeem set backup_bestand = :'b', backup_ts = now() where id = 1;
SQL
    fi
    rm -f "$K_DOWNLOAD/$NAAM.tmp"
  fi
done

if STICK=$(blkid -L KASSA-BACKUP 2>/dev/null); then
  M=$(mktemp -d)
  if mount "$STICK" "$M" 2>/dev/null; then
    for B in "${BESTANDEN[@]}"; do
      n=$(basename "$B" | sed 's/-[0-9-]*\.dump$//')
      kassa_paden "$n"
      [ -s "$K_WW" ] || continue
      # De eerste kassa in de map kassa/ (zoals altijd), de andere in een eigen map.
      mkdir -p "$M/$n"
      DOEL="$M/$n/$(basename "$B").enc"
      if [ -s "$DOEL" ]; then :
      elif kassa_versleutel "$B" "$DOEL.tmp"; then
        mv "$DOEL.tmp" "$DOEL"
        # Oude, onversleutelde back-ups van vóór deze versie weghalen: die staan ook op de server zelf.
        find "$M/$n" -name "$n-*.dump" -delete
      else
        rm -f "$DOEL.tmp"
      fi
      uitdunnen "$M/$n" "$n" .dump.enc
    done
    umount "$M"
  fi
  rmdir "$M"
fi
# Elke nacht per e-mail (backup-mail.sh bepaalt zelf of het tijd is).
if [ "$ELKUUR" = 1 ]; then /opt/kassa/bin/backup-mail.sh || true; fi
printf '%s\n' "${BESTANDEN[@]}"

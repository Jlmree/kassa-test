#!/usr/bin/env bash
# Back-up per e-mail: elke nacht (rond 4 uur) gaat de nieuwste back-up versleuteld naar
# een e-mailadres, zodat er altijd een kopie buiten de server is. Alleen als er die dag
# iets veranderd is; lukt het niet, dan elk uur opnieuw. Het back-upwachtwoord gaat niet
# mee: wie de mail onderschept, kan er niets mee. backup.sh roept dit elk uur aan.
#   backup-mail.sh instellen [naam]   adres en mailaccount instellen (en een proefmail sturen)
#   backup-mail.sh nu [naam]          de nieuwste back-up nu versturen
#   backup-mail.sh uit [naam]         niet meer mailen
#   backup-mail.sh status             per kassa: aan welk adres, laatst verstuurd
set -euo pipefail
. /opt/kassa/bin/kassa-lib.sh
fout() { echo "$*" >&2; exit 1; }
MAX_MB=20   # grotere bijlagen weigeren de meeste mailboxen

mail_lees() { sed -n "s/^$1=//p" "$K_ETC/mail.env" 2>/dev/null | head -n 1 || true; }

# Voortgang voor de app (Beheer → Instellingen): $1 = gelukt (1/0), $2 = foutmelding.
status_schrijven() {
  runuser -u postgres -- psql -d "$K_DB" -q -v naar="$(mail_lees NAAR)" -v ok="$1" -v fout="${2:-}" <<'SQL' 2>/dev/null || true
update public.systeem set backup_mail_naar = nullif(:'naar', ''),
  backup_mail_ts = case when :'ok' = '1' then now() else backup_mail_ts end,
  backup_mail_fout = nullif(:'fout', '') where id = 1;
SQL
}

# Waarde voor een curl-configbestand: tussen aanhalingstekens, \ en " ontsnapt.
cq() { local s=${1//\\/\\\\}; printf '"%s"' "${s//\"/\\\"}"; }

# Verstuurt de nieuwste back-up van de huidige kassa (na kassa_paden). Geeft een foutmelding terug op stderr.
versturen() {
  local dump t enc mb grens host poort url
  dump=$(find "$K_BACKUP" -maxdepth 1 -name "$K_NAAM-*.dump" | sort | tail -n 1)
  [ -n "$dump" ] || { echo "Er is nog geen back-up" >&2; return 1; }
  [ -s "$K_WW" ] || { echo "Er is geen back-upwachtwoord" >&2; return 1; }
  t=$(mktemp -d); chmod 700 "$t"
  enc="$t/$(basename "$dump").enc"
  kassa_versleutel "$dump" "$enc" || { rm -rf "$t"; echo "Versleutelen mislukt" >&2; return 1; }
  mb=$(( ($(stat -c %s "$enc") + 1048575) / 1048576 ))
  if (( mb > MAX_MB )); then
    rm -rf "$t"; echo "De back-up is te groot voor e-mail ($mb MB, hoogstens $MAX_MB MB)" >&2; return 1
  fi
  grens="kassa-$(openssl rand -hex 12)"
  {
    printf 'From: Tapkas <%s>\r\nTo: <%s>\r\nSubject: Back-up kassa %s %s\r\nDate: %s\r\n' \
      "$(mail_lees VAN)" "$(mail_lees NAAR)" "$K_NAAM" "$(date +%Y-%m-%d)" "$(LC_ALL=C date -R)"
    printf 'Message-ID: <%s@kassa>\r\nMIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary="%s"\r\n\r\n' "$grens" "$grens"
    printf -- '--%s\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n' "$grens"
    base64 <<EOF | sed 's/$/\r/'
Dit is de back-up van kassa "$K_NAAM" van $(date '+%d-%m-%Y %H:%M').

Bewaar deze mail: dit is je kopie buiten de server. Gaat de server kapot,
dan zet je de kassa hiermee terug op een nieuwe server.

Het bestand is versleuteld. Terugzetten kan alleen met het back-upwachtwoord
dat je bij de installatie kreeg (dat staat niet in deze mail). Kwijt? Op de
server: /opt/kassa/bin/backup.sh wachtwoord$([ "$K_NAAM" = kassa ] || echo " $K_NAAM")

Terugzetten: zet het bestand op de server en typ
  /opt/kassa/bin/terugzetten.sh <bestand>$([ "$K_NAAM" = kassa ] || echo " $K_NAAM")

Deze mail komt elke nacht als er die dag iets veranderd is.
EOF
    printf -- '--%s\r\nContent-Type: application/octet-stream; name="%s"\r\nContent-Disposition: attachment; filename="%s"\r\nContent-Transfer-Encoding: base64\r\n\r\n' \
      "$grens" "$(basename "$enc")" "$(basename "$enc")"
    base64 -w 76 "$enc" | sed 's/$/\r/'
    printf -- '--%s--\r\n' "$grens"
  } > "$t/mail"
  host=$(mail_lees SERVER); poort=$(mail_lees POORT)
  # Poort 465: meteen versleuteld; anders (587) eerst gewoon en dan versleuteld (STARTTLS, verplicht).
  if [ "$poort" = 465 ]; then url="smtps://$host:$poort"; else url="smtp://$host:${poort:-587}"; fi
  # Het wachtwoord via een bestand, niet op de opdrachtregel (daar kan iedereen op de server het zien).
  {
    echo "url = $(cq "$url")"
    echo "user = $(cq "$(mail_lees GEBRUIKER):$(mail_lees WACHTWOORD)")"
    echo "mail-from = $(cq "$(mail_lees VAN)")"
    echo "mail-rcpt = $(cq "$(mail_lees NAAR)")"
  } > "$t/curl.conf"
  local uit
  if uit=$(curl -sS --ssl-reqd --connect-timeout 20 --max-time 600 -K "$t/curl.conf" -T "$t/mail" 2>&1); then
    rm -rf "$t"; return 0
  fi
  rm -rf "$t"
  case "$uit" in
    *535*|*"Login denied"*|*authentication*) echo "De mailserver weigert de gebruikersnaam of het wachtwoord" >&2 ;;
    *"Could not resolve"*) echo "Mailserver $host niet gevonden" >&2 ;;
    *"Failed to connect"*|*"timed out"*|*Timeout*) echo "Geen verbinding met mailserver $host (poort ${poort:-587})" >&2 ;;
    *552*|*"too large"*|*"size limit"*) echo "De mailserver vindt de back-up te groot ($mb MB)" >&2 ;;
    *) echo "Versturen mislukt: $(tail -n 1 <<<"$uit")" >&2 ;;
  esac
  return 1
}

# Eén kassa versturen en de uitkomst onthouden.
verstuur_en_onthoud() {
  local fout
  if fout=$(versturen 2>&1 >/dev/null); then
    find "$K_BACKUP" -maxdepth 1 -name "$K_NAAM-*.dump" | sort | tail -n 1 > "$K_BACKUP/.gemaild"
    date +%Y-%m-%d > "$K_BACKUP/.gemaild-dag"
    status_schrijven 1
    return 0
  fi
  status_schrijven 0 "$fout"
  echo "$fout" >&2
  return 1
}

vraag() { local a; read -r -p "$1${2:+ [$2]}: " a; echo "${a:-$2}"; }

case "${1:-}" in
  instellen)
    kassa_paden "${2:-kassa}"
    [ -d "$K_ETC" ] || fout "Kassa \"${2:-kassa}\" bestaat niet"
    [ -t 0 ] || fout "Instellen kan alleen in een terminal"
    echo "Elke nacht gaat de back-up versleuteld naar een e-mailadres naar keuze,"
    echo "bijvoorbeeld van de penningmeester. Daarvoor heeft de server een mailaccount"
    echo "nodig om mee te versturen (bijvoorbeeld een Gmail-adres van de vereniging)."
    echo
    naar=$(vraag "Naar welk e-mailadres gaat de back-up" "$(mail_lees NAAR)")
    gebruiker=$(vraag "Mailaccount om mee te versturen (e-mailadres)" "$(mail_lees GEBRUIKER)")
    case "${gebruiker,,}" in
      *@gmail.com|*@googlemail.com) s=smtp.gmail.com
        echo "Gmail: gebruik een app-wachtwoord, niet je gewone wachtwoord. Maak het aan op"
        echo "https://myaccount.google.com/apppasswords (tweestapsverificatie moet aan staan)." ;;
      *@outlook.*|*@hotmail.*|*@live.*) s=smtp-mail.outlook.com ;;
      *) s=$(mail_lees SERVER) ;;
    esac
    server=$(vraag "Mailserver (staat bij je mailaanbieder onder SMTP)" "$s")
    p=$(mail_lees POORT)
    poort=$(vraag "Poort (587 of 465)" "${p:-587}")
    read -r -s -p "Wachtwoord van het mailaccount: " ww; echo
    [ -n "$naar" ] && [ -n "$gebruiker" ] && [ -n "$server" ] && [ -n "$ww" ] || fout "Niet alles is ingevuld"
    [[ $naar == *@*.* && $gebruiker == *@*.* ]] || fout "Dat lijkt geen e-mailadres"
    oud="$K_ETC/mail.env.oud"; [ -f "$K_ETC/mail.env" ] && cp -p "$K_ETC/mail.env" "$oud"
    ( umask 077; printf 'NAAR=%s\nGEBRUIKER=%s\nVAN=%s\nSERVER=%s\nPOORT=%s\nWACHTWOORD=%s\n' \
        "$naar" "$gebruiker" "$gebruiker" "$server" "$poort" "$ww" > "$K_ETC/mail.env" )
    echo "Proefmail met de nieuwste back-up versturen..."
    if verstuur_en_onthoud; then
      rm -f "$oud"
      echo "Verstuurd naar $naar. Kijk of hij aankomt (ook in de map spam)."
      echo "Vanaf nu gaat de back-up elke nacht rond 4 uur naar dit adres als er iets veranderd is."
    else
      if [ -f "$oud" ]; then mv "$oud" "$K_ETC/mail.env"; else rm -f "$K_ETC/mail.env"; fi
      status_schrijven 0
      fout "Niet opgeslagen. Controleer de gegevens en probeer opnieuw: $0 instellen${2:+ $2}"
    fi
    ;;
  nu)
    kassa_paden "${2:-kassa}"
    [ -f "$K_ETC/mail.env" ] || fout "Nog niet ingesteld: $0 instellen${2:+ $2}"
    verstuur_en_onthoud && echo "Verstuurd naar $(mail_lees NAAR)."
    ;;
  uit)
    kassa_paden "${2:-kassa}"
    rm -f "$K_ETC/mail.env" "$K_BACKUP/.gemaild" "$K_BACKUP/.gemaild-dag"
    status_schrijven 0
    echo "De back-up gaat niet meer per e-mail."
    ;;
  status)
    for n in $(kassa_namen); do
      kassa_paden "$n"
      if [ -f "$K_ETC/mail.env" ]; then
        echo "$n: naar $(mail_lees NAAR), laatst verstuurd $(cat "$K_BACKUP/.gemaild-dag" 2>/dev/null || echo nooit)"
      else
        echo "$n: uit (instellen: $0 instellen$([ "$n" = kassa ] || echo " $n"))"
      fi
    done
    ;;
  "")
    # Elk uur vanuit backup.sh: vanaf 4 uur 's nachts, één keer per dag, alleen als er een nieuwe back-up is.
    (( 10#$(date +%H) >= 4 )) || exit 0
    for n in $(kassa_namen); do
      kassa_paden "$n"
      [ -f "$K_ETC/mail.env" ] || continue
      [ "$(cat "$K_BACKUP/.gemaild-dag" 2>/dev/null)" = "$(date +%Y-%m-%d)" ] && continue
      nieuwste=$(find "$K_BACKUP" -maxdepth 1 -name "$n-*.dump" | sort | tail -n 1)
      [ "$nieuwste" = "$(cat "$K_BACKUP/.gemaild" 2>/dev/null)" ] && continue
      verstuur_en_onthoud || true
    done
    ;;
  *) fout "Onbekend: $1 (instellen, nu, uit of status)" ;;
esac

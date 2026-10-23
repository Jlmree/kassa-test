#!/usr/bin/env bash
# Een beheerder aanmaken op de server zelf (als root). De installatie start dit
# als er nog geen beheerder is; een account uit de app wordt daarna nooit meer
# vanzelf beheerder. Bestaat de naam al, dan wordt die persoon (weer) beheerder
# met het nieuwe wachtwoord: de noodknop als je jezelf hebt buitengesloten.
#   /opt/kassa/bin/beheerder.sh
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Start dit als root (met sudo of na su -)."; exit 1; }
# shellcheck disable=SC1091
. /etc/kassa/geheim.env
db() { runuser -u postgres -- psql -d kassa -Atq -v ON_ERROR_STOP=1 "$@"; }

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
jwt() {
  local h p
  h=$(printf '{"alg":"HS256","typ":"JWT"}' | b64url)
  p=$(printf '{"role":"%s","iss":"kassa","iat":1700000000,"exp":4102444800}' "$1" | b64url)
  printf '%s.%s.%s' "$h" "$p" "$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -hmac "$JWT_SECRET" -binary | b64url)"
}

while :; do
  read -r -p "Naam van de beheerder (om mee in te loggen, bijv. Jelmer): " naam
  naam=$(printf '%s' "$naam" | sed 's/^ *//; s/ *$//')
  if [ -z "$naam" ]; then continue; fi
  # Zelfde omzetting als de app (inlogEmail): kleine letters, de rest wordt een punt.
  if printf '%s' "$naam" | LC_ALL=C grep -q '[^ -~]'; then echo "Gebruik een naam zonder accenten of speciale tekens."; continue; fi
  if [[ "$naam" == *@* ]]; then email=$(printf '%s' "$naam" | tr '[:upper:]' '[:lower:]')
  else
    email=$(printf '%s' "$naam" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/./g; s/^\.+//; s/\.+$//')
    email="${email:-gebruiker}@kassa.lokaal"
  fi
  break
done
while :; do
  read -r -s -p "Wachtwoord (minstens 8 tekens): " ww; echo
  [ "${#ww}" -ge 8 ] || { echo "Te kort."; continue; }
  read -r -s -p "Nog een keer: " ww2; echo
  [ "$ww" = "$ww2" ] && break
  echo "De wachtwoorden zijn niet gelijk."
done

bestaand=$(db -v e="$email" <<<"select id from auth.users where email = :'e'")
if [ -n "$bestaand" ]; then
  db -v id="$bestaand" -v w="$ww" <<'SQL'
update auth.users set encrypted_password = extensions.crypt(:'w', extensions.gen_salt('bf')), updated_at = now() where id = :'id';
update public.profielen set rol = 'beheerder', actief = true where id = :'id';
SQL
  echo "$naam is nu beheerder, met het nieuwe wachtwoord."
else
  esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
  uit=$(mktemp); trap 'rm -f "$uit"' EXIT
  antwoord=$(curl --noproxy '*' -sS -o "$uit" -w '%{http_code}' -X POST "http://127.0.0.1:9999/admin/users" \
    -H "Authorization: Bearer $(jwt service_role)" -H 'Content-Type: application/json' \
    -d "{\"email\":\"$(esc "$email")\",\"password\":\"$(esc "$ww")\",\"email_confirm\":true,\"user_metadata\":{\"naam\":\"$(esc "$naam")\"}}" || true)
  [ "$antwoord" = 200 ] || { echo "Aanmaken mislukt (code ${antwoord:-geen verbinding}): $(cat "$uit")"; exit 1; }
  db -v e="$email" <<<"update public.profielen set rol = 'beheerder', actief = true where id = (select id from auth.users where email = :'e')"
  echo "Beheerder $naam aangemaakt. Log in de app in met naam \"$naam\" en dit wachtwoord."
fi
# Vanaf nu wordt een account uit de app nooit meer vanzelf beheerder.
db <<<"update public.instellingen set eerste_account_wordt_beheerder = false"

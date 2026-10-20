#!/usr/bin/env bash
# Past nieuwe databasebestanden (supabase/migrations/*.sql) toe die nog niet zijn uitgevoerd.
#   migraties.sh <map met .sql-bestanden> [database]
set -euo pipefail
MAP=${1:?gebruik: migraties.sh <map met .sql-bestanden> [database]}
DB=${2:-kassa}
for f in $(ls "$MAP"/*.sql | sort); do
  naam=$(basename "$f")
  if [ -z "$(su postgres -c "psql -d $DB -tAc \"select 1 from public.kassa_migraties where naam = '$naam'\"")" ]; then
    echo "  database bijwerken ($DB): $naam"
    # Bestand en registratie in één transactie: lukt het niet, dan verandert er niets.
    su postgres -c "psql -d $DB -v ON_ERROR_STOP=1 -q -1 -f - -c \"insert into public.kassa_migraties (naam) values ('$naam')\"" < "$f"
  fi
done
su postgres -c "psql -d $DB -qc \"notify pgrst, 'reload schema'\""

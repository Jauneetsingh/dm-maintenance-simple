#!/usr/bin/env bash
# save_test_data.sh: saves a copy of the test tables, so they can be put back after a maintenance run.
# Each table is copied into schema test_snapshot (dm.files -> test_snapshot.dm_files).
# Run it ONCE, before the first maintenance run. A table that is already saved is not saved again.
#
#   ./tests/save_test_data.sh                    all tables in run_maintenance.sh
#   ./tests/save_test_data.sh dm.filerequests    only the tables you name
#
# TEST databases only. Put the data back with ./tests/restore_test_data.sh
set -o pipefail
cd "$(dirname "$0")/.."

# Same table list as run_maintenance.sh (read from it), or the tables named on the command line.
eval "$(sed -n '/^TABLES=(/,/^)/p' run_maintenance.sh)"
[[ $# -gt 0 ]] && TABLES=("$@")

# Database connection.
read -rp "Host: " PGHOST
read -rp "Port [5432]: " PGPORT;  PGPORT=${PGPORT:-5432}
read -rp "Database: " PGDATABASE
read -rp "User: " PGUSER
read -rsp "Password (press Enter to use ~/.pgpass): " password; echo
[[ -n "$password" ]] && export PGPASSWORD="$password"
export PGHOST PGPORT PGDATABASE PGUSER

echo "$(date '+%Y-%m-%d %H:%M:%S') SAVE test data on $PGUSER@$PGHOST:$PGPORT/$PGDATABASE: ${TABLES[*]}"
PGOPTIONS="-c client_min_messages=warning" psql -X -q -v ON_ERROR_STOP=1 -c "CREATE SCHEMA IF NOT EXISTS test_snapshot" || exit 1

for t in "${TABLES[@]}"; do
  snap="test_snapshot.${t/./_}"                                        # dm.files -> test_snapshot.dm_files
  if [[ $(psql -X -At -c "SELECT to_regclass('$snap') IS NOT NULL") == t ]]; then
    echo "  $t: already saved in $snap - not saved again (to save again: DROP TABLE $snap;)"
    continue
  fi
  rows=$(psql -X -At -v ON_ERROR_STOP=1 -c "CREATE TABLE $snap AS SELECT * FROM $t" | awk '{print $2}') || { echo "  $t: FAILED"; exit 1; }
  echo "  $t: $rows rows saved in $snap"
done
echo "$(date '+%Y-%m-%d %H:%M:%S') SAVE done"

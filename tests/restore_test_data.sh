#!/usr/bin/env bash
# restore_test_data.sh: puts the test tables back exactly as they were saved by save_test_data.sh,
# so a maintenance run can be tested again. For each table, in one transaction:
#   TRUNCATE the table, INSERT all rows back from test_snapshot, COMMIT, then ANALYZE.
# It also drops the dated maintenance tables (maintenance_<table>_<date>), so the next run works on the same day.
#
#   ./tests/restore_test_data.sh                    all tables in run_maintenance.sh
#   ./tests/restore_test_data.sh dm.filerequests    only the tables you name
#
# TEST databases only: it empties the tables before putting the saved rows back.
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

echo "$(date '+%Y-%m-%d %H:%M:%S') RESTORE test data on $PGUSER@$PGHOST:$PGPORT/$PGDATABASE: ${TABLES[*]}"
for t in "${TABLES[@]}"; do
  snap="test_snapshot.${t/./_}"                                        # dm.files -> test_snapshot.dm_files
  schema=${t%%.*}; table=${t#*.}

  # Put the rows back. If anything fails (e.g. no snapshot), the transaction is undone and the table is unchanged.
  if ! psql -X -q -v ON_ERROR_STOP=1 <<SQL
BEGIN;
TRUNCATE TABLE $t;
INSERT INTO $t SELECT * FROM $snap;
COMMIT;
ANALYZE $t;
SQL
  then
    echo "  $t: FAILED - table unchanged (was it saved with save_test_data.sh?)"
    exit 1
  fi

  # Drop the dated maintenance tables made by earlier runs (e.g. dm.maintenance_filerequests_20261024).
  psql -X -q -At -v ON_ERROR_STOP=1 <<SQL
SELECT 'DROP TABLE ' || oid::regclass FROM pg_class
 WHERE relnamespace = '$schema'::regnamespace AND relname LIKE 'maintenance\_${table}\_%' AND relkind = 'r' \gexec
SQL

  # Check: the table has the same number of rows as the snapshot (test data only).
  psql -X -At -c "SELECT '  $t: ' || (SELECT count(*) FROM $t) || ' rows restored, snapshot has ' || (SELECT count(*) FROM $snap)
                         || CASE WHEN (SELECT count(*) FROM $t) = (SELECT count(*) FROM $snap) THEN ' - OK' ELSE ' - MISMATCH' END"
done
echo "$(date '+%Y-%m-%d %H:%M:%S') RESTORE done"

#!/usr/bin/env bash
# run_maintenance.sh: DM maintenance (runs about every 6 months, in an outage of max 1 hour).
# Asks only for the database connection, then runs tables/<table>.sql for each table, one by one.
# Stops at the first error. Everything is written to logs/dm_maintenance_<date_time>.log
#
#   ./run_maintenance.sh                     all tables in the list below
#   ./run_maintenance.sh dm.files            only the tables you name (each needs tables/<table>.sql)
set -o pipefail
cd "$(dirname "$0")"

# ---------------------------------------------------------------------------
# Tables to maintain (static list). To skip a table, put # in front of its line.
# The steps for each table are in tables/<table>.sql
# ---------------------------------------------------------------------------
TABLES=(
  dm.files             # partitioned: empty the partition is_removed = 'Y'
  dm.filerequests      # normal: keep statusid IN (1, 2)
)
[[ $# -gt 0 ]] && TABLES=("$@")     # tables named on the command line replace the list

# Every table must have its script, before anything runs.
for t in "${TABLES[@]}"; do
  [[ -f "tables/$t.sql" ]] || { echo "ERROR: no script tables/$t.sql for table $t - nothing was run"; exit 1; }
done

# ---------------------------------------------------------------------------
# Database connection: the only questions.
# ---------------------------------------------------------------------------
read -rp "Host: " PGHOST
read -rp "Port [5432]: " PGPORT;  PGPORT=${PGPORT:-5432}
read -rp "Database: " PGDATABASE
read -rp "User: " PGUSER
read -rsp "Password (press Enter to use ~/.pgpass): " password; echo
[[ -n "$password" ]] && export PGPASSWORD="$password"
export PGHOST PGPORT PGDATABASE PGUSER
export PGOPTIONS="-c lock_timeout=60s"   # if a table is in use, fail after 60 seconds instead of waiting forever

mkdir -p logs
LOG="logs/dm_maintenance_$(date +%Y%m%d_%H%M%S).log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"; }

# Check the connection before doing anything.
if ! psql -X -q -At -c "SELECT 1" >/dev/null 2>>"$LOG"; then
  log "ERROR: cannot connect to $PGUSER@$PGHOST:$PGPORT/$PGDATABASE (details in $LOG)"
  exit 1
fi

# Run the tables one after another. Stop at the first error.
log "START DM maintenance on $PGUSER@$PGHOST:$PGPORT/$PGDATABASE: ${TABLES[*]}"
run_start=$SECONDS
for t in "${TABLES[@]}"; do
  log "START  $t"
  table_start=$SECONDS
  if psql -X -q -v ON_ERROR_STOP=1 -v today="$(date +%Y%m%d)" -f "tables/$t.sql" 2>&1 | tee -a "$LOG"; then
    log "DONE   $t ($((SECONDS - table_start)) s)"
  else
    log "FAILED $t after $((SECONDS - table_start)) s - maintenance stopped, the tables after it were not run (error above)"
    exit 1
  fi
done
log "COMPLETED DM maintenance: ${#TABLES[@]} table(s) in $((SECONDS - run_start)) s. Log: $LOG"

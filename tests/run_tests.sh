#!/usr/bin/env bash
# run_tests.sh: runs every test scenario of main.sql against a TEST database.
# Before each scenario the dummy data is reset (tests/reset_data.sql) and any extra
# data for that scenario is inserted. Results go to tests/results/.
#
# Usage (password from ~/.pgpass):
#   PGHOST=<server> PGUSER=postgres ./tests/run_tests.sh
# WARNING: drops and recreates schemas dm and maint in database testdb.
set -u
cd "$(dirname "$0")/.."
DB=${TESTDB:-testdb}
OUT=tests/results
rm -rf "$OUT"; mkdir -p "$OUT"

# Connection settings: give up on a lost connection instead of waiting forever.
export PGCONNECT_TIMEOUT=${PGCONNECT_TIMEOUT:-15}
KA="keepalives_idle=5 keepalives_interval=5 keepalives_count=3"
pg()     { perl -e 'alarm 90; exec @ARGV' psql -X -w "$@"; }            # psql, stopped after 90 seconds at most
Q()      { pg -q -d "dbname=$DB $KA" -Atc "$1" 2>&1; }                  # one query, plain output
reset()  { pg -q -d "dbname=$DB $KA" -f tests/reset_data.sql >/dev/null 2>&1; Q "DROP SCHEMA IF EXISTS maint CASCADE" >/dev/null; }
run()    { printf "$2" | pg -d "dbname=${3:-$DB} $KA" -f main.sql > "$OUT/$1.out" 2>&1; echo $? > "$OUT/$1.exit"; }
status() { [[ $(Q "SELECT to_regclass('maint.maintenance_log') IS NULL") == t ]] && echo "no log" ||
           Q "SELECT status FROM maint.maintenance_log ORDER BY log_id DESC LIMIT 1"; }
has()    { grep -qF "$2" "$OUT/$1.out" && echo yes || echo no; }       # does the output contain this text?
rows()   { Q "SELECT count(*) FROM $1"; }
backup() { Q "SELECT coalesce(to_regclass('dm.maintenance_filerequests_$D')::text, 'no backup')"; }

# Runs one scenario (function s_<id>) and records PASS / FAIL. If the network drops a
# connection, the whole scenario is repeated from a fresh reset (up to 3 attempts).
scenario() { # id | name | expected
  local id=$1 actual attempt
  for attempt in 1 2 3; do
    actual=$("s_$id")
    local ok=yes
    grep -qE "could not connect|server closed|connection to server|SSL SYSCALL|timeout expired|Alarm clock" "$OUT/$id.out" && ok=no
    [[ "$actual" == *psql:* || "$actual" == *error:* || "|$actual|" == *"||"* ]] && ok=no   # a check query failed
    [[ $ok == yes ]] && break
    echo "     $id: connection problem, retrying (attempt $((attempt + 1)))"
  done
  local r=FAIL; [[ "$3" == "$actual" ]] && r=PASS
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$2" "$3" "$actual" "$(cat "$OUT/$id.exit")" "$r" >> "$OUT/results.tsv"
  printf '%-4s %-4s %s\n' "$r" "$id" "$2"
}

KEEP='dm\nfilerequests\nstatusid IN (1, 2)\nYES\n'
D=$(Q "SELECT to_char(now(), 'YYYYMMDD')")
echo "Server: $(Q "SELECT split_part(version(), ' on ', 1)")  database: $DB  date: $D"
Q "SELECT now()::timestamp(0)" > "$OUT/started_at"

# S01 normal table: keep statusid 1 and 2 (5000 rows -> 2000)
s_S01() { reset; run S01 "$KEEP"
  echo "$(rows dm.filerequests)|$(Q "SELECT count(*) FROM dm.filerequests WHERE statusid NOT IN (1, 2)")|$(rows dm.maintenance_filerequests_$D)|$(status)"; }
scenario S01 "Normal table: keep statusid IN (1, 2)" "2000|0|2000|SUCCESS"

# S02 partitioned table: empty the 'Y' partition (3000 rows), keep 'N' (2000)
s_S02() { reset; run S02 'dm\nfiles\nY\nYES\n'
  echo "$(rows dm.files_removed)|$(rows dm.files_active)|$(rows dm.files_other)|$(status)"; }
scenario S02 "Partitioned table: empty partition Y" "0|2000|0|SUCCESS"

# S03 wrong database: run against database 'postgres'
s_S03() { reset; run S03 '' postgres
  echo "$(has S03 'STOP: not the TEST database')|$(rows dm.filerequests)|$(status)"; }
scenario S03 "Wrong database is refused" "yes|5000|no log"

# S04 table does not exist
s_S04() { reset; run S04 'dm\nno_such_table\n'
  echo "$(has S04 'STOP: table not found')|$(rows dm.filerequests)|$(status)"; }
scenario S04 "Table not found is refused" "yes|5000|no log"

# S05 user does not type YES
s_S05() { reset; run S05 'dm\nfilerequests\nstatusid IN (1, 2)\nno\n'
  echo "$(has S05 'Cancelled - nothing was changed')|$(rows dm.filerequests)|$(backup)|$(status)"; }
scenario S05 "No YES = cancelled" "yes|5000|no backup|no log"

# S06 keep rule matches 0 rows
s_S06() { reset; run S06 'dm\nfilerequests\nstatusid IN (99)\nYES\n'
  echo "$(has S06 'Copy check failed: copied 0')|$(rows dm.filerequests)|$(backup)|$(status)"; }
scenario S06 "Keep rule matching 0 rows is refused" "yes|5000|no backup|FAILED"

# S07 keep rule with a wrong column name
s_S07() { reset; run S07 'dm\nfilerequests\nno_such_column = 1\nYES\n'
  echo "$(has S07 'column "no_such_column" does not exist')|$(rows dm.filerequests)|$(backup)|$(status)"; }
scenario S07 "Invalid keep rule is rolled back" "yes|5000|no backup|FAILED"

# S08 another table has a foreign key to dm.filerequests
s_S08() { reset; Q "CREATE TABLE dm.child (requestid numeric REFERENCES dm.filerequests)" >/dev/null; run S08 "$KEEP"
  echo "$(has S08 'foreign key constraint')|$(rows dm.filerequests)|$(backup)|$(status)"; }
scenario S08 "Foreign key: TRUNCATE fails, all rolled back" "yes|5000|no backup|FAILED"

# S09 second run on the same day
s_S09() { reset; run S09a "$KEEP"; run S09 "$KEEP"
  echo "$(has S09 'already exists')|$(rows dm.filerequests)|$(rows dm.maintenance_filerequests_$D)|$(status)"; }
scenario S09 "Second run same day fails safely" "yes|2000|2000|FAILED"

# S10 identity column, generated column, index and trigger are preserved
s_S10() { reset; pg -q -d "dbname=$DB $KA" -f tests/setup_orders.sql >/dev/null 2>&1; run S10 'dm\norders\nstatusid = 1\nYES\n'
  echo "$(rows dm.orders)|$(Q "SELECT bool_and(id % 5 = 0) FROM dm.orders")|$(Q "SELECT bool_and(amount_x2 = amount * 2) FROM dm.orders")|$(Q "SELECT count(*) FROM pg_index WHERE indrelid = 'dm.orders'::regclass AND indisvalid")|$(Q "SELECT count(*) FROM pg_trigger WHERE tgrelid = 'dm.orders'::regclass AND NOT tgisinternal")|$(rows dm.order_audit)|$(Q "INSERT INTO dm.orders (statusid, amount) VALUES (1, 1) RETURNING id")|$(status)"; }
scenario S10 "Identity, generated column, index, trigger kept" "200|t|t|2|1|1200|1001|SUCCESS"

# S11 table name that needs quotes ("Order Items")
s_S11() { reset; Q 'CREATE TABLE dm."Order Items" (id int PRIMARY KEY, statusid int); INSERT INTO dm."Order Items" SELECT g, g % 5 + 1 FROM generate_series(1, 1000) g; ANALYZE dm."Order Items"' >/dev/null
  run S11 'dm\nOrder Items\nstatusid IN (1, 2)\nYES\n'
  echo "$(rows 'dm."Order Items"')|$(rows "dm.\"maintenance_Order Items_$D\"")|$(status)"; }
scenario S11 "Table name with a space" "400|400|SUCCESS"

# S12 partition value that has no partition
s_S12() { reset; run S12 'dm\nfiles\nX\nYES\n'
  echo "$(has S12 "No partition of dm.files is defined as FOR VALUES IN ('X')")|$(rows dm.files_removed)|$(rows dm.files_active)|$(status)"; }
scenario S12 "Partition value not found: nothing changed" "yes|3000|2000|FAILED"

# S13 table partitioned by date (RANGE), not by the removed column
s_S13() { reset; Q "CREATE TABLE dm.events (id int, is_removed char(1), created_on date) PARTITION BY RANGE (created_on);
    CREATE TABLE dm.events_2025 PARTITION OF dm.events FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');
    CREATE TABLE dm.events_2026 PARTITION OF dm.events FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
    INSERT INTO dm.events SELECT g, CASE WHEN g % 2 = 0 THEN 'Y' ELSE 'N' END, date '2025-06-01' + g % 400 FROM generate_series(1, 1000) g" >/dev/null
  run S13 'dm\nevents\nY\nYES\n'
  echo "$(has S13 'No partition of dm.events')|$(rows dm.events)|$(status)"; }
scenario S13 "RANGE-partitioned table: nothing changed" "yes|1000|FAILED"

# S14 no full read of the main table except the copy step
s_S14() { reset; sleep 2; local before after
  before=$(Q "SELECT seq_scan FROM pg_stat_user_tables WHERE relid = 'dm.filerequests'::regclass")
  run S14 "$KEEP"; sleep 2
  after=$(Q "SELECT seq_scan FROM pg_stat_user_tables WHERE relid = 'dm.filerequests'::regclass")
  [[ "$before" =~ ^[0-9]+$ && "$after" =~ ^[0-9]+$ ]] && echo "$((after - before))|$(status)" || echo "psql: scan counter not read"; }
scenario S14 "No count(*) on the main table (scan counter)" "3|SUCCESS"

Q "SELECT now()::timestamp(0)" > "$OUT/finished_at"
echo; echo "PASSED: $(grep -c $'\tPASS$' "$OUT/results.tsv")  FAILED: $(grep -c $'\tFAIL$' "$OUT/results.tsv")"

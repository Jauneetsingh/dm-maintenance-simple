#!/usr/bin/env bash
# run_tests.sh: runs every test scenario of run_maintenance.sh against a TEST database.
# Before each scenario the dummy data is reset (tests/reset_data.sql) and any extra data
# for that scenario is inserted. Each scenario runs a COPY of the scripts in tests/results/,
# so run_maintenance.sh and tables/*.sql are never changed by the tests.
#
# Usage (password from ~/.pgpass):
#   PGHOST=<server> PGUSER=postgres ./tests/run_tests.sh
# WARNING: drops and recreates schema dm in database testdb.
set -u
cd "$(dirname "$0")/.."
DB=${TESTDB:-testdb}
OUT=$PWD/tests/results
rm -rf "$OUT"; mkdir -p "$OUT"

# Connection settings: give up on a lost connection instead of waiting forever.
export PGCONNECT_TIMEOUT=${PGCONNECT_TIMEOUT:-15} PGPORT=${PGPORT:-5432}
KA="keepalives_idle=5 keepalives_interval=5 keepalives_count=3"
pg()     { perl -e 'alarm 150; exec @ARGV' psql -X -w "$@"; }           # psql, stopped after 150 seconds at most
Q()      { pg -q -d "dbname=$DB $KA" -Atc "$1" 2>&1; }                  # one query, plain output
reset()  { pg -q -d "dbname=$DB $KA" -f tests/reset_data.sql >/dev/null 2>&1; }
rows()   { Q "SELECT count(*) FROM $1"; }
backup() { Q "SELECT coalesce(to_regclass('dm.maintenance_filerequests_$D')::text, 'no backup')"; }
has()    { grep -qF "$2" "$OUT/$1.out" && echo yes || echo no; }       # does the output contain this text?
code()   { cat "$OUT/$1.exit"; }

# copy <id>: a copy of the scripts for one scenario (so a test can change it).
copy() { local w="$OUT/work_$1"; rm -rf "$w"; mkdir -p "$w"; cp -R run_maintenance.sh tables "$w/"; echo "$w"; }
# run <id> <work dir> [table names...]: run_maintenance.sh, answering only the connection questions.
run() {
  local id=$1 w=$2; shift 2
  printf '%s\n%s\n%s\n%s\n\n' "$PGHOST" "$PGPORT" "${DBNAME:-$DB}" "$PGUSER" |
    perl -e 'alarm 300; exec @ARGV' bash "$w/run_maintenance.sh" "$@" > "$OUT/$id.out" 2>&1
  echo $? > "$OUT/$id.exit"
}

# Runs one scenario (function s_<id>) and records PASS / FAIL. If the network drops a
# connection, the whole scenario is repeated from a fresh reset (up to 3 attempts).
scenario() { # id | name | expected
  local id=$1 actual attempt ok
  for attempt in 1 2 3; do
    actual=$("s_$id")
    ok=yes
    grep -qE "server closed|connection to server .* failed|SSL SYSCALL|timeout expired|Alarm clock" "$OUT/$id.out" 2>/dev/null && ok=no
    [[ "$actual" == *psql:* || "$actual" == *error:* || "|$actual|" == *"||"* ]] && ok=no   # a check query failed
    [[ $ok == yes ]] && break
    echo "     $id: connection problem, retrying (attempt $((attempt + 1)))"
  done
  local r=FAIL; [[ "$3" == "$actual" ]] && r=PASS
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$2" "$3" "$actual" "$(code "$id")" "$r" >> "$OUT/results.tsv"
  printf '%-4s %-4s %s\n' "$r" "$id" "$2"
}

D=$(Q "SELECT to_char(now(), 'YYYYMMDD')")
echo "Server: $(Q "SELECT split_part(version(), ' on ', 1)")  database: $DB  date: $D"
Q "SELECT now()::timestamp(0)" > "$OUT/started_at"

# S01 full run of the static list: dm.files partition 'N' emptied, dm.filerequests keeps statusid 1, 2
s_S01() { reset; run S01 "$(copy S01)"
  echo "$(rows dm.files_active)|$(rows dm.files_removed)|$(rows dm.filerequests)|$(Q "SELECT count(*) FROM dm.filerequests WHERE statusid NOT IN (1, 2)")|$(rows dm.maintenance_filerequests_$D)|$(code S01)"; }
scenario S01 "Full run: partition N emptied, filerequests keeps statusid 1, 2" "0|3000|2000|0|2000|0"

# S02 one table named on the command line: only that table is done
s_S02() { reset; run S02 "$(copy S02)" dm.filerequests
  echo "$(rows dm.filerequests)|$(rows dm.files_active)|$(has S02 'START  dm.files')|$(code S02)"; }
scenario S02 "Table named on the command line: only that one runs" "2000|2000|no|0"

# S03 table named that has no script in tables/
s_S03() { reset; run S03 "$(copy S03)" dm.no_such_table
  echo "$(has S03 'ERROR: no script tables/dm.no_such_table.sql')|$(rows dm.filerequests)|$(rows dm.files_active)|$(code S03)"; }
scenario S03 "Table without a script is refused, nothing runs" "yes|5000|2000|1"

# S04 wrong database name in the connection prompt
s_S04() { reset; DBNAME=no_such_db run S04 "$(copy S04)"
  echo "$(has S04 'ERROR: cannot connect')|$(rows dm.filerequests)|$(code S04)"; }
scenario S04 "Connection error is reported, nothing runs" "yes|5000|1"

# S05 table commented out of the list: only dm.files is done
s_S05() { reset; local w; w=$(copy S05); sed -i '' 's/^  dm.filerequests /# dm.filerequests /' "$w/run_maintenance.sh"; run S05 "$w"
  echo "$(rows dm.files_active)|$(rows dm.filerequests)|$(has S05 'START  dm.filerequests')|$(has S05 'COMPLETED DM maintenance: 1 table(s)')"; }
scenario S05 "Commented-out table is not touched" "0|5000|no|yes"

# S06 partition for 'N' does not exist: first table fails, run stops, next table not run
s_S06() { reset; Q "DROP TABLE dm.files_active" >/dev/null; run S06 "$(copy S06)"
  echo "$(has S06 'relation "dm.files_active" does not exist')|$(has S06 'FAILED dm.files')|$(has S06 'START  dm.filerequests')|$(rows dm.filerequests)|$(code S06)"; }
scenario S06 "Partition missing: run stops, next table not run" "yes|yes|no|5000|1"

# S07 script points at the wrong partition (files_removed holds 'Y'): rule check fails, nothing emptied
s_S07() { reset; local w; w=$(copy S07); sed -i '' 's/files_active/files_removed/g' "$w/tables/dm.files.sql"; run S07 "$w" dm.files
  echo "$(has S07 'is not the partition for is_removed = N')|$(rows dm.files_removed)|$(rows dm.files_active)|$(code S07)"; }
scenario S07 "Wrong partition in the script: rule check stops it" "yes|3000|2000|1"

# S08 foreign key to dm.filerequests: TRUNCATE fails, table rolled back
s_S08() { reset; Q "CREATE TABLE dm.child (requestid numeric REFERENCES dm.filerequests)" >/dev/null; run S08 "$(copy S08)" dm.filerequests
  echo "$(has S08 'foreign key constraint')|$(rows dm.filerequests)|$(backup)|$(code S08)"; }
scenario S08 "Foreign key: TRUNCATE fails, table rolled back" "yes|5000|no backup|1"

# S09 keep condition matching 0 rows: copy check fails
s_S09() { reset; local w; w=$(copy S09); sed -i '' 's/WHERE statusid IN (1, 2)/WHERE statusid IN (99)/' "$w/tables/dm.filerequests.sql"; run S09 "$w" dm.filerequests
  echo "$(has S09 'Copy check failed')|$(rows dm.filerequests)|$(backup)|$(code S09)"; }
scenario S09 "Keep condition matching 0 rows is refused" "yes|5000|no backup|1"

# S10 keep condition with a wrong column name
s_S10() { reset; local w; w=$(copy S10); sed -i '' 's/WHERE statusid IN (1, 2)/WHERE no_such_column = 1/' "$w/tables/dm.filerequests.sql"; run S10 "$w" dm.filerequests
  echo "$(has S10 'column "no_such_column" does not exist')|$(rows dm.filerequests)|$(backup)|$(code S10)"; }
scenario S10 "Invalid keep condition is rolled back" "yes|5000|no backup|1"

# S11 second run on the same day: dated maintenance table already exists
s_S11() { reset; local w; w=$(copy S11); run S11a "$w" dm.filerequests; run S11 "$w" dm.filerequests
  echo "$(has S11 'already exists')|$(rows dm.filerequests)|$(rows dm.maintenance_filerequests_$D)|$(code S11)"; }
scenario S11 "Second run same day fails safely" "yes|2000|2000|1"

# S12 no full read of the main table except the copy step
s_S12() { reset; sleep 2; local before after w; w=$(copy S12)
  before=$(Q "SELECT seq_scan FROM pg_stat_user_tables WHERE relid = 'dm.filerequests'::regclass")
  run S12 "$w" dm.filerequests; sleep 2
  after=$(Q "SELECT seq_scan FROM pg_stat_user_tables WHERE relid = 'dm.filerequests'::regclass")
  [[ "$before" =~ ^[0-9]+$ && "$after" =~ ^[0-9]+$ ]] && echo "$((after - before))|$(rows dm.filerequests)" || echo "psql: scan counter not read"; }
scenario S12 "No count(*) on the main table (scan counter)" "3|2000"

# S13 another session uses the table: lock_timeout (60 s) stops the run instead of waiting forever
s_S13() { reset; local w; w=$(copy S13)
  pg -q -d "dbname=$DB $KA" -c "BEGIN; LOCK TABLE dm.filerequests IN ACCESS SHARE MODE; SELECT pg_sleep(90); COMMIT;" >/dev/null 2>&1 &
  local holder=$!; sleep 3
  run S13 "$w" dm.filerequests; wait $holder
  echo "$(has S13 'canceling statement due to lock timeout')|$(rows dm.filerequests)|$(backup)|$(code S13)"; }
scenario S13 "Table in use: lock timeout after 60 s, nothing changed" "yes|5000|no backup|1"

Q "SELECT now()::timestamp(0)" > "$OUT/finished_at"
echo; echo "PASSED: $(grep -c $'\tPASS$' "$OUT/results.tsv")  FAILED: $(grep -c $'\tFAIL$' "$OUT/results.tsv")"

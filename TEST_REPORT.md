# Test report: DM maintenance scripts

| | |
|---|---|
| Scripts | `run_maintenance.sh`, `tables/dm.files.sql`, `tables/dm.filerequests.sql` |
| Server | Local Docker test container (PostgreSQL 16.15 (Debian)) |
| Database | `testdb` |
| Run | 2026-10-24 13:47:13 to 2026-10-24 13:48:50 (server time) |
| Result | **13 of 13 scenarios passed** |

Before every scenario `tests/reset_data.sql` recreates the dummy data, and any extra data for that scenario is inserted. `run_maintenance.sh` is then run, answering only the connection questions, and the real result is checked with SQL queries. Rerun everything with:

```bash
PGHOST=<server> PGUSER=postgres ./tests/run_tests.sh
```

## Summary

| ID | Scenario | Result |
|---|---|---|
| S01 | Full run: partition N emptied, filerequests keeps statusid 1, 2 | PASS |
| S02 | Table named on the command line: only that one runs | PASS |
| S03 | Table without a script is refused, nothing runs | PASS |
| S04 | Connection error is reported, nothing runs | PASS |
| S05 | Commented-out table is not touched | PASS |
| S06 | Partition missing: run stops, next table not run | PASS |
| S07 | Hard-coded partition: exactly the named partition is emptied | PASS |
| S08 | Foreign key: TRUNCATE fails, table rolled back | PASS |
| S09 | Keep condition matching 0 rows is refused | PASS |
| S10 | Invalid keep condition is rolled back | PASS |
| S11 | Second run same day fails safely | PASS |
| S12 | No count(*) on the main table (scan counter) | PASS |
| S13 | Table in use: lock timeout after 60 s, nothing changed | PASS |

## Scenarios

### S01. Full run: partition N emptied, filerequests keeps statusid 1, 2: PASS

- **Dummy data:** reset_data.sql: dm.files 5,000 rows LIST partitioned by is_removed (files_active 'N' 2,000, files_removed 'Y' 3,000); dm.filerequests 5,000 rows, statusid 1-5.
- **How it is run:** ./run_maintenance.sh (static list: dm.files, dm.filerequests)
- **Expected:** files_active ('N') emptied, files_removed ('Y') untouched; filerequests keeps 2,000 rows, all statusid 1 or 2; dated copy holds 2,000; exit code 0.
- **Checked (files_active | files_removed | filerequests | wrong statusid | rows in copy | exit code):** expected `0|3000|2000|0|2000|0`, actual `0|3000|2000|0|2000|0`, exit code 0

```
2026-10-24 19:17:13 START DM maintenance on postgres@localhost:55432/testdb: dm.files dm.filerequests
2026-10-24 19:17:13 START  dm.files
dm.files done: partition dm.files_active emptied
2026-10-24 19:17:13 DONE   dm.files (0 s)
2026-10-24 19:17:13 START  dm.filerequests
copy OK: 2000 rows
check OK: 2000 rows copied back
dm.filerequests done: kept 2000 rows, removed about 3000 rows, copy in dm.maintenance_filerequests_20261024
2026-10-24 19:17:13 DONE   dm.filerequests (0 s)
2026-10-24 19:17:13 COMPLETED DM maintenance: 2 table(s) in 0 s. Log: logs/dm_maintenance_20261024_191713.log
```

### S02. Table named on the command line: only that one runs: PASS

- **Dummy data:** reset_data.sql: dm.files 5,000 rows LIST partitioned by is_removed (files_active 'N' 2,000, files_removed 'Y' 3,000); dm.filerequests 5,000 rows, statusid 1-5.
- **How it is run:** ./run_maintenance.sh dm.filerequests
- **Expected:** dm.filerequests done (2,000 rows); dm.files never started (files_active still 2,000); exit code 0.
- **Checked (filerequests | files_active | dm.files started | exit code):** expected `2000|2000|no|0`, actual `2000|2000|no|0`, exit code 0

```
2026-10-24 19:17:13 START DM maintenance on postgres@localhost:55432/testdb: dm.filerequests
2026-10-24 19:17:13 START  dm.filerequests
copy OK: 2000 rows
check OK: 2000 rows copied back
dm.filerequests done: kept 2000 rows, removed about 3000 rows, copy in dm.maintenance_filerequests_20261024
2026-10-24 19:17:13 DONE   dm.filerequests (0 s)
2026-10-24 19:17:13 COMPLETED DM maintenance: 1 table(s) in 0 s. Log: logs/dm_maintenance_20261024_191713.log
```

### S03. Table without a script is refused, nothing runs: PASS

- **Dummy data:** reset_data.sql: dm.files 5,000 rows LIST partitioned by is_removed (files_active 'N' 2,000, files_removed 'Y' 3,000); dm.filerequests 5,000 rows, statusid 1-5.
- **How it is run:** ./run_maintenance.sh dm.no_such_table
- **Expected:** 'ERROR: no script tables/dm.no_such_table.sql' before the connection prompt; nothing changed; exit code 1.
- **Checked (message shown | filerequests | files_active | exit code):** expected `yes|5000|2000|1`, actual `yes|5000|2000|1`, exit code 1

```
ERROR: no script tables/dm.no_such_table.sql for table dm.no_such_table - nothing was run
```

### S04. Connection error is reported, nothing runs: PASS

- **Dummy data:** reset_data.sql: dm.files 5,000 rows LIST partitioned by is_removed (files_active 'N' 2,000, files_removed 'Y' 3,000); dm.filerequests 5,000 rows, statusid 1-5.
- **How it is run:** Connection prompt answered with database no_such_db.
- **Expected:** 'ERROR: cannot connect', nothing changed, exit code 1.
- **Checked (message shown | filerequests | exit code):** expected `yes|5000|1`, actual `yes|5000|1`, exit code 1

```
2026-10-24 19:17:14 ERROR: cannot connect to postgres@localhost:55432/no_such_db (details in logs/dm_maintenance_20261024_191714.log)
```

### S05. Commented-out table is not touched: PASS

- **Dummy data:** reset_data.sql: dm.files 5,000 rows LIST partitioned by is_removed (files_active 'N' 2,000, files_removed 'Y' 3,000); dm.filerequests 5,000 rows, statusid 1-5.
- **How it is run:** Copy of run_maintenance.sh with # in front of dm.filerequests in TABLES.
- **Expected:** dm.files done; dm.filerequests never started and still 5,000 rows; 'COMPLETED: 1 table(s)'.
- **Checked (files_active | filerequests | filerequests started | COMPLETED 1 table):** expected `0|5000|no|yes`, actual `0|5000|no|yes`, exit code 0

```
2026-10-24 19:17:14 START DM maintenance on postgres@localhost:55432/testdb: dm.files
2026-10-24 19:17:14 START  dm.files
dm.files done: partition dm.files_active emptied
2026-10-24 19:17:14 DONE   dm.files (0 s)
2026-10-24 19:17:14 COMPLETED DM maintenance: 1 table(s) in 0 s. Log: logs/dm_maintenance_20261024_191714.log
```

### S06. Partition missing: run stops, next table not run: PASS

- **Dummy data:** reset_data.sql: dm.files 5,000 rows LIST partitioned by is_removed (files_active 'N' 2,000, files_removed 'Y' 3,000); dm.filerequests 5,000 rows, statusid 1-5. Then partition files_active is dropped.
- **How it is run:** ./run_maintenance.sh
- **Expected:** 'relation "dm.files_active" does not exist', dm.files FAILED, dm.filerequests never started, exit code 1.
- **Checked (message shown | FAILED logged | next table started | filerequests | exit code):** expected `yes|yes|no|5000|1`, actual `yes|yes|no|5000|1`, exit code 1

```
2026-10-24 19:17:14 START DM maintenance on postgres@localhost:55432/testdb: dm.files dm.filerequests
2026-10-24 19:17:14 START  dm.files
ERROR:  relation "dm.files_active" does not exist
2026-10-24 19:17:14 FAILED dm.files after 0 s - maintenance stopped, the tables after it were not run (error above)
```

### S07. Hard-coded partition: exactly the named partition is emptied: PASS

- **Dummy data:** reset_data.sql: dm.files 5,000 rows LIST partitioned by is_removed (files_active 'N' 2,000, files_removed 'Y' 3,000); dm.filerequests 5,000 rows, statusid 1-5.
- **How it is run:** Copy of dm.files.sql with the TRUNCATE line changed to files_removed.
- **Expected:** Exactly the named partition (files_removed, 3,000 'Y' rows) is emptied, with no check; files_active and files_other untouched; exit code 0.
- **Checked (files_removed | files_active | files_other | exit code):** expected `0|2000|0|0`, actual `0|2000|0|0`, exit code 0

```
2026-10-24 19:17:14 START DM maintenance on postgres@localhost:55432/testdb: dm.files
2026-10-24 19:17:14 START  dm.files
dm.files done: partition dm.files_removed emptied
2026-10-24 19:17:14 DONE   dm.files (0 s)
2026-10-24 19:17:14 COMPLETED DM maintenance: 1 table(s) in 0 s. Log: logs/dm_maintenance_20261024_191714.log
```

### S08. Foreign key: TRUNCATE fails, table rolled back: PASS

- **Dummy data:** reset_data.sql: dm.files 5,000 rows LIST partitioned by is_removed (files_active 'N' 2,000, files_removed 'Y' 3,000); dm.filerequests 5,000 rows, statusid 1-5. Plus dm.child with a foreign key to dm.filerequests.
- **How it is run:** ./run_maintenance.sh dm.filerequests
- **Expected:** TRUNCATE refused, everything undone: 5,000 rows, no copy left, exit code 1.
- **Checked (message shown | filerequests | copy table | exit code):** expected `yes|5000|no backup|1`, actual `yes|5000|no backup|1`, exit code 1

```
2026-10-24 19:17:14 START DM maintenance on postgres@localhost:55432/testdb: dm.filerequests
2026-10-24 19:17:14 START  dm.filerequests
copy OK: 2000 rows
ERROR:  cannot truncate a table referenced in a foreign key constraint
2026-10-24 19:17:15 FAILED dm.filerequests after 1 s - maintenance stopped, the tables after it were not run (error above)
```

### S09. Keep condition matching 0 rows is refused: PASS

- **Dummy data:** reset_data.sql: dm.files 5,000 rows LIST partitioned by is_removed (files_active 'N' 2,000, files_removed 'Y' 3,000); dm.filerequests 5,000 rows, statusid 1-5.
- **How it is run:** Copy of dm.filerequests.sql with WHERE statusid IN (99).
- **Expected:** 'Copy check failed', table unchanged, no copy left, exit code 1.
- **Checked (message shown | filerequests | copy table | exit code):** expected `yes|5000|no backup|1`, actual `yes|5000|no backup|1`, exit code 1

```
2026-10-24 19:17:15 START DM maintenance on postgres@localhost:55432/testdb: dm.filerequests
2026-10-24 19:17:15 START  dm.filerequests
ERROR:  Copy check failed - nothing was changed
2026-10-24 19:17:15 FAILED dm.filerequests after 0 s - maintenance stopped, the tables after it were not run (error above)
```

### S10. Invalid keep condition is rolled back: PASS

- **Dummy data:** reset_data.sql: dm.files 5,000 rows LIST partitioned by is_removed (files_active 'N' 2,000, files_removed 'Y' 3,000); dm.filerequests 5,000 rows, statusid 1-5.
- **How it is run:** Copy of dm.filerequests.sql with WHERE no_such_column = 1.
- **Expected:** Error 'column does not exist', table unchanged, no copy left, exit code 1.
- **Checked (message shown | filerequests | copy table | exit code):** expected `yes|5000|no backup|1`, actual `yes|5000|no backup|1`, exit code 1

```
2026-10-24 19:17:15 START DM maintenance on postgres@localhost:55432/testdb: dm.filerequests
2026-10-24 19:17:15 START  dm.filerequests
ERROR:  column "no_such_column" does not exist
2026-10-24 19:17:15 FAILED dm.filerequests after 0 s - maintenance stopped, the tables after it were not run (error above)
```

### S11. Second run on the same day fails safely: PASS

- **Dummy data:** reset_data.sql: dm.files 5,000 rows LIST partitioned by is_removed (files_active 'N' 2,000, files_removed 'Y' 3,000); dm.filerequests 5,000 rows, statusid 1-5.
- **How it is run:** ./run_maintenance.sh dm.filerequests, twice
- **Expected:** Second run stops: today's maintenance table already exists; table and copy keep 2,000 rows; exit code 1.
- **Checked (message shown | filerequests | rows in copy | exit code):** expected `yes|2000|2000|1`, actual `yes|2000|2000|1`, exit code 1

```
2026-10-24 19:17:15 START DM maintenance on postgres@localhost:55432/testdb: dm.filerequests
2026-10-24 19:17:15 START  dm.filerequests
ERROR:  relation "maintenance_filerequests_20261024" already exists
2026-10-24 19:17:15 FAILED dm.filerequests after 0 s - maintenance stopped, the tables after it were not run (error above)
```

### S12. No count(*) on the main table: PASS

- **Dummy data:** reset_data.sql: dm.files 5,000 rows LIST partitioned by is_removed (files_active 'N' 2,000, files_removed 'Y' 3,000); dm.filerequests 5,000 rows, statusid 1-5. PostgreSQL's full-read counter (pg_stat_user_tables.seq_scan) is read before and after.
- **How it is run:** ./run_maintenance.sh dm.filerequests
- **Expected:** Counter +3: 1 = the copy step, 2 = TRUNCATE rebuilding the 2 indexes on the empty table. No count(*) on the table.
- **Checked (full reads | filerequests):** expected `3|2000`, actual `3|2000`, exit code 0

```
2026-10-24 19:17:17 START DM maintenance on postgres@localhost:55432/testdb: dm.filerequests
2026-10-24 19:17:17 START  dm.filerequests
copy OK: 2000 rows
check OK: 2000 rows copied back
dm.filerequests done: kept 2000 rows, removed about 3000 rows, copy in dm.maintenance_filerequests_20261024
2026-10-24 19:17:18 DONE   dm.filerequests (1 s)
2026-10-24 19:17:18 COMPLETED DM maintenance: 1 table(s) in 1 s. Log: logs/dm_maintenance_20261024_191717.log
```

### S13. Table in use: lock timeout after 60 s: PASS

- **Dummy data:** reset_data.sql: dm.files 5,000 rows LIST partitioned by is_removed (files_active 'N' 2,000, files_removed 'Y' 3,000); dm.filerequests 5,000 rows, statusid 1-5. Another session holds a lock on dm.filerequests for 90 seconds.
- **How it is run:** ./run_maintenance.sh dm.filerequests
- **Expected:** After 60 s 'canceling statement due to lock timeout'; nothing changed, no copy left, exit code 1.
- **Checked (message shown | filerequests | copy table | exit code):** expected `yes|5000|no backup|1`, actual `yes|5000|no backup|1`, exit code 1

```
2026-10-24 19:17:23 START DM maintenance on postgres@localhost:55432/testdb: dm.filerequests
2026-10-24 19:17:23 START  dm.filerequests
ERROR:  canceling statement due to lock timeout
2026-10-24 19:18:23 FAILED dm.filerequests after 60 s - maintenance stopped, the tables after it were not run (error above)
```

## Observations

- **Exit codes:** `run_maintenance.sh` ends with 0 when every table is done and 1 when a table fails; the failing table and the error are in the log.
- **The tests never change the real scripts:** each scenario runs a copy of `run_maintenance.sh` and `tables/` in `tests/results/`, changed only where the scenario says.
- **Where:** this run used a local Docker test container (PostgreSQL 16.15). The Ubuntu test server was not reachable at the time; rerun the same tests there with `PGHOST=<server> ./tests/run_tests.sh` when it is back.

## Not covered

- **Production-size data:** these runs use 5,000 rows. Timing for the outage window must be measured on a production-size copy.
- **Generated or GENERATED ALWAYS identity columns:** with `SELECT *` such a table fails at the copy-back step and is rolled back; not in the current table list.
- **Production partition names:** the partition to empty is hard-coded (`dm.files_active` for 'N') and not checked. Check the name against production before the run, e.g. with `\d+ dm.files` in psql.

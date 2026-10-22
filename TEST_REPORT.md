# Test report: DM maintenance scripts

| | |
|---|---|
| Scripts | `main.sql`, `scripta_partitioned.sql`, `scriptb_nonpartitioned.sql` |
| Server | Ubuntu test server (PostgreSQL 16.15 (Ubuntu)) |
| Database | `testdb` |
| Run | 2026-10-22 06:48:11 to 2026-10-22 06:55:14 (server time) |
| Result | **14 of 14 scenarios passed** |

Before every scenario `tests/reset_data.sql` recreates the dummy data, and any extra data for that scenario is inserted. `main.sql` is then run with the answers shown, and the real result is checked with SQL queries. Rerun everything with:

```bash
PGHOST=<server> PGUSER=postgres ./tests/run_tests.sh
```

## Summary

| ID | Scenario | Result |
|---|---|---|
| S01 | Normal table: keep statusid IN (1, 2) | PASS |
| S02 | Partitioned table: empty partition Y | PASS |
| S03 | Wrong database is refused | PASS |
| S04 | Table not found is refused | PASS |
| S05 | No YES = cancelled | PASS |
| S06 | Keep rule matching 0 rows is refused | PASS |
| S07 | Invalid keep rule is rolled back | PASS |
| S08 | Foreign key: TRUNCATE fails, all rolled back | PASS |
| S09 | Second run same day fails safely | PASS |
| S10 | Identity, generated column, index, trigger kept | PASS |
| S11 | Table name with a space | PASS |
| S12 | Partition value not found: nothing changed | PASS |
| S13 | RANGE-partitioned table: nothing changed | PASS |
| S14 | No count(*) on the main table (scan counter) | PASS |

## Scenarios

### S01. Normal table: keep rows - PASS

- **Dummy data:** reset_data.sql: dm.filerequests 5,000 rows, statusid 1-5 (2,000 with statusid 1 or 2).
- **Answers typed:** `dm / filerequests / statusid IN (1, 2) / YES`
- **Expected:** 2,000 rows left, none with another statusid; backup table holds 2,000; log SUCCESS.
- **Checked (rows left | rows with wrong statusid | rows in backup | log status):** expected `2000|0|2000|SUCCESS`, actual `2000|0|2000|SUCCESS`, exit code 0

```
NOTICE:  dm.filerequests: about 5000 rows, 2 indexes, 0 triggers
NOTICE:  dm.filerequests: kept 2000, removed about 3000, indexes and triggers OK
dm.filerequests | statusid IN (1, 2) | SUCCESS | 00:00:00.844129 | kept 2000, removed about 3000, backup in dm.maintenance_filerequests_20261022
```

### S02. Partitioned table: empty partition Y - PASS

- **Dummy data:** reset_data.sql: dm.files LIST partitioned by is_removed: files_removed ('Y') 3,000, files_active ('N') 2,000, files_other (DEFAULT) 0.
- **Answers typed:** `dm / files / Y / YES`
- **Expected:** files_removed emptied, files_active and files_other untouched; log SUCCESS.
- **Checked (files_removed | files_active | files_other | log status):** expected `0|2000|0|SUCCESS`, actual `0|2000|0|SUCCESS`, exit code 0

```
NOTICE:  dm.files_removed: emptied, about 3000 rows removed
dm.files | Y | SUCCESS | 00:00:01.090966 | emptied dm.files_removed (about 3000 rows)
```

### S03. Wrong database is refused - PASS

- **Dummy data:** reset_data.sql in testdb. The script is run while connected to database postgres.
- **Answers typed:** `(stops before any question)`
- **Expected:** Message 'STOP: not the TEST database', exit code 3, testdb unchanged, nothing logged.
- **Checked (message shown | rows in testdb | log):** expected `yes|5000|no log`, actual `yes|5000|no log`, exit code 3

```
*** STOP: not the TEST database ***
ERROR:  division by zero
```

### S04. Table not found is refused - PASS

- **Dummy data:** reset_data.sql.
- **Answers typed:** `dm / no_such_table`
- **Expected:** Message 'STOP: table not found', exit code 3, nothing changed or logged.
- **Checked (message shown | rows | log):** expected `yes|5000|no log`, actual `yes|5000|no log`, exit code 3

```
*** STOP: table not found ***
ERROR:  division by zero
```

### S05. No YES = cancelled - PASS

- **Dummy data:** reset_data.sql.
- **Answers typed:** `dm / filerequests / statusid IN (1, 2) / no`
- **Expected:** Message 'Cancelled - nothing was changed', no backup table, nothing logged.
- **Checked (message shown | rows | backup | log):** expected `yes|5000|no backup|no log`, actual `yes|5000|no backup|no log`, exit code 0

```
Cancelled - nothing was changed.
```

### S06. Keep rule matching 0 rows is refused - PASS

- **Dummy data:** reset_data.sql (no row has statusid 99).
- **Answers typed:** `dm / filerequests / statusid IN (99) / YES`
- **Expected:** 'Copy check failed: copied 0', table still 5,000 rows, no backup left, log FAILED.
- **Checked (message shown | rows | backup | log status):** expected `yes|5000|no backup|FAILED`, actual `yes|5000|no backup|FAILED`, exit code 0

```
NOTICE:  dm.filerequests: about 5000 rows, 2 indexes, 0 triggers
ERROR:  Copy check failed: copied 0, found 0 in dm.maintenance_filerequests_20261022
dm.filerequests | statusid IN (99) | FAILED | 00:00:00.845558 | Copy check failed: copied 0, found 0 in dm.maintenance_filerequests_20261022
```

### S07. Invalid keep rule is rolled back - PASS

- **Dummy data:** reset_data.sql.
- **Answers typed:** `dm / filerequests / no_such_column = 1 / YES`
- **Expected:** Error 'column does not exist', table unchanged, no backup left, log FAILED.
- **Checked (message shown | rows | backup | log status):** expected `yes|5000|no backup|FAILED`, actual `yes|5000|no backup|FAILED`, exit code 0

```
NOTICE:  dm.filerequests: about 5000 rows, 2 indexes, 0 triggers
ERROR:  column "no_such_column" does not exist
dm.filerequests | no_such_column = 1 | FAILED | 00:00:00.823988 | column "no_such_column" does not exist
```

### S08. Foreign key: TRUNCATE fails, all rolled back - PASS

- **Dummy data:** reset_data.sql + table dm.child with a foreign key to dm.filerequests.
- **Answers typed:** `dm / filerequests / statusid IN (1, 2) / YES`
- **Expected:** TRUNCATE refused, whole run undone: 5,000 rows, no backup left, log FAILED.
- **Checked (message shown | rows | backup | log status):** expected `yes|5000|no backup|FAILED`, actual `yes|5000|no backup|FAILED`, exit code 0

```
NOTICE:  dm.filerequests: about 5000 rows, 2 indexes, 0 triggers
ERROR:  cannot truncate a table referenced in a foreign key constraint
dm.filerequests | statusid IN (1, 2) | FAILED | 00:00:00.828507 | cannot truncate a table referenced in a foreign key constraint
```

### S09. Second run on the same day fails safely - PASS

- **Dummy data:** reset_data.sql, then a first successful run (2,000 rows kept).
- **Answers typed:** `dm / filerequests / statusid IN (1, 2) / YES (twice)`
- **Expected:** Second run stops: backup table already exists; table and backup keep 2,000 rows; log FAILED.
- **Checked (message shown | rows | rows in backup | log status):** expected `yes|2000|2000|FAILED`, actual `yes|2000|2000|FAILED`, exit code 0

```
NOTICE:  dm.filerequests: about 2000 rows, 2 indexes, 0 triggers
ERROR:  relation "maintenance_filerequests_20261022" already exists
dm.filerequests | statusid IN (1, 2) | FAILED | 00:00:01.066075 | relation "maintenance_filerequests_20261022" already exists
```

### S10. Identity, generated column, index, trigger preserved - PASS

- **Dummy data:** reset_data.sql + setup_orders.sql: dm.orders 1,000 rows with an identity id, generated column amount_x2, 2 indexes, a row trigger writing to dm.order_audit.
- **Answers typed:** `dm / orders / statusid = 1 / YES`
- **Expected:** 200 rows, original ids kept, generated values correct, 2 valid indexes, 1 trigger, trigger fired on reload (1,000 + 200 audit rows), next id 1001; log SUCCESS.
- **Checked (rows | ids kept | generated OK | valid indexes | triggers | audit rows | next id | log status):** expected `200|t|t|2|1|1200|1001|SUCCESS`, actual `200|t|t|2|1|1200|1001|SUCCESS`, exit code 0

```
NOTICE:  dm.orders: about 1000 rows, 2 indexes, 1 triggers
NOTICE:  dm.orders: kept 200, removed about 800, indexes and triggers OK
dm.orders | statusid = 1 | SUCCESS | 00:00:00.931559 | kept 200, removed about 800, backup in dm.maintenance_orders_20261022
```

### S11. Table name with a space - PASS

- **Dummy data:** reset_data.sql + dm."Order Items" 1,000 rows, statusid 1-5.
- **Answers typed:** `dm / Order Items / statusid IN (1, 2) / YES`
- **Expected:** 400 rows kept, backup dm."maintenance_Order Items_<date>" holds 400; log SUCCESS.
- **Checked (rows | rows in backup | log status):** expected `400|400|SUCCESS`, actual `400|400|SUCCESS`, exit code 0

```
NOTICE:  dm."Order Items": about 1000 rows, 1 indexes, 0 triggers
NOTICE:  dm."Order Items": kept 400, removed about 600, indexes and triggers OK
dm."Order Items" | statusid IN (1, 2) | SUCCESS | 00:00:00.830514 | kept 400, removed about 600, backup in dm."maintenance_Order Items_20261022"
```

### S12. Partition value not found: nothing changed - PASS

- **Dummy data:** reset_data.sql (no partition for 'X').
- **Answers typed:** `dm / files / X / YES`
- **Expected:** 'No partition ... FOR VALUES IN ('X')', all partitions unchanged, log FAILED.
- **Checked (message shown | files_removed | files_active | log status):** expected `yes|3000|2000|FAILED`, actual `yes|3000|2000|FAILED`, exit code 0

```
ERROR:  No partition of dm.files is defined as FOR VALUES IN ('X') - nothing changed
dm.files | X | FAILED | 00:00:00.866996 | No partition of dm.files is defined as FOR VALUES IN ('X') - nothing changed
```

### S13. RANGE-partitioned table: nothing changed - PASS

- **Dummy data:** reset_data.sql + dm.events 1,000 rows, PARTITION BY RANGE (created_on), 2 yearly partitions.
- **Answers typed:** `dm / events / Y / YES`
- **Expected:** No partition is defined by is_removed, so nothing is emptied; 1,000 rows; log FAILED.
- **Checked (message shown | rows | log status):** expected `yes|1000|FAILED`, actual `yes|1000|FAILED`, exit code 0

```
ERROR:  No partition of dm.events is defined as FOR VALUES IN ('Y') - nothing changed
dm.events | Y | FAILED | 00:00:00.822343 | No partition of dm.events is defined as FOR VALUES IN ('Y') - nothing changed
```

### S14. No count(*) on the main table - PASS

- **Dummy data:** reset_data.sql. PostgreSQL's full-read counter (pg_stat_user_tables.seq_scan) is read before and after.
- **Answers typed:** `dm / filerequests / statusid IN (1, 2) / YES`
- **Expected:** Counter +3: 1 = the copy step, 2 = TRUNCATE rebuilding the 2 indexes on the empty table. No count(*) on the table.
- **Checked (full reads | log status):** expected `3|SUCCESS`, actual `3|SUCCESS`, exit code 0

```
NOTICE:  dm.filerequests: about 5000 rows, 2 indexes, 0 triggers
NOTICE:  dm.filerequests: kept 2000, removed about 3000, indexes and triggers OK
dm.filerequests | statusid IN (1, 2) | SUCCESS | 00:00:00.871387 | kept 2000, removed about 3000, backup in dm.maintenance_filerequests_20261022
```

## Observations

- **Exit code on a failed run:** when the maintenance itself fails (S06-S09, S12, S13), psql still ends with exit code 0, because `main.sql` catches the error to write `FAILED` to `maint.maintenance_log`. Check the `status` in the final output or the log, not only the exit code. The safety stops before any change (S03, S04) end with exit code 3.
- **Network:** each connection to the server took about 2 seconds. The test runner uses keepalives, a 90-second limit per call and up to 3 attempts per scenario; no retry was needed in this run.

## Not covered

- **Table locked by another session:** the scripts have no lock timeout, so they wait until the other session finishes. Stop applications before a real run.
- **Production-size data:** these runs use 5,000 rows. Timing for the outage window must be measured on a production-size copy.
- **DBeaver:** these scripts use psql commands (`\prompt`, `\if`) and are tested with psql only.

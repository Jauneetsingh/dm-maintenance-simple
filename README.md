# DM Maintenance

A simple shell + psql script for the DM maintenance, which runs about every 6 months in an outage of at most 1 hour. It cleans a fixed list of large tables (over 100,000 rows), one after another, and stops at the first error.

## Files

```
run_maintenance.sh          <- run this. Asks for the connection, holds the static list of tables
tables/dm.files.sql         <- one plain SQL script per table, named <schema>.<table>.sql
tables/dm.filerequests.sql
```

## Run

```bash
./run_maintenance.sh                    # all tables in the list
./run_maintenance.sh dm.files           # only the tables you name
```

It asks only for the database connection:

```
Host: 10.0.0.5
Port [5432]:
Database: datamag
User: postgres
Password (press Enter to use ~/.pgpass):
```

For each table it runs `tables/<table>.sql`. A table without a script is refused before anything runs. Everything is printed and saved to `logs/dm_maintenance_<date_time>.log`:

```
2026-10-24 18:58:00 START DM maintenance on postgres@10.0.0.5:5432/datamag: dm.files dm.filerequests
2026-10-24 18:58:00 START  dm.files
2026-10-24 18:58:00   1. Empty the partition dm.files_removed (is_removed = Y)
dm.files done: partition dm.files_removed emptied
2026-10-24 18:58:00 DONE   dm.files (0 s)
2026-10-24 18:58:00 START  dm.filerequests
2026-10-24 18:58:00   0. Before: rows (from statistics), indexes and triggers
   rows: 5000  indexes: 2  triggers: 0
2026-10-24 18:58:00   1. Copy the rows to keep into dm.maintenance_filerequests_20261024
   copy OK: 2000 rows
2026-10-24 18:58:00   2. Empty the table
2026-10-24 18:58:00   3. Copy the rows back
2026-10-24 18:58:00   4. After: same rows as the copy, indexes valid, triggers still there
   check OK: 2000 rows copied back
dm.filerequests done: kept 2000 rows, removed about 3000 rows, copy in dm.maintenance_filerequests_20261024
2026-10-24 18:58:00 DONE   dm.filerequests (0 s)
2026-10-24 18:58:00 COMPLETED DM maintenance: 2 table(s) in 0 s. Log: logs/dm_maintenance_20261024_185800.log
```

If a table fails, its changes are undone, the run stops, and the tables after it are not touched:

```
2026-10-23 08:45:20 START  dm.filerequests
psql:tables/dm.filerequests.sql:32: ERROR:  cannot truncate a table referenced in a foreign key constraint
2026-10-23 08:45:20 FAILED dm.filerequests - maintenance stopped, the tables after it were not run (error above)
```

## What each table script does

The scripts are plain SQL (`ANALYZE`, `SELECT`, `BEGIN`, `LOCK`, `CREATE TABLE ... AS`, `TRUNCATE`, `INSERT`, `COMMIT`) with short `\echo` messages. A check that fails stops the script, and nothing is changed.

**`tables/dm.files.sql`** (partitioned table: empty the partition `is_removed = 'Y'`)
1. `TRUNCATE TABLE dm.files_removed;`: the partition to empty is hard-coded. It is the partition defined `FOR VALUES IN ('Y')`, so it holds only `is_removed = 'Y'` rows. Then `ANALYZE`.

**`tables/dm.filerequests.sql`** (normal table: keep `statusid IN (1, 2)`)
0. `ANALYZE`, then read the rows, indexes and triggers from the system tables.
1. Lock the table and copy the rows to keep (`SELECT * ... WHERE statusid IN (1, 2)`) into the dated table `dm.maintenance_filerequests_<yyyymmdd>`. Check the copy.
2. `TRUNCATE` the table.
3. Copy the rows back (`INSERT INTO ... SELECT *`).
4. Check the rows copied back, that the indexes are valid and that the triggers are still there. `COMMIT`, then `ANALYZE`.

## Changing things (every 6 months)

| To... | Do this |
|---|---|
| Skip a table | Put `#` in front of its line in the `TABLES` list in `run_maintenance.sh` |
| Change the rows to keep | Edit the `WHERE` line in step 1 of `tables/dm.filerequests.sql` |
| Change the partition | Edit the partition table name in the `TRUNCATE` line of `tables/dm.files.sql` (the partition is truncated by its name, as in the past) |
| Add a table | Copy a table script to `tables/<schema>.<table>.sql`, change the table name and the rule (`WHERE` line, or partition name and value), and add the table to `TABLES` |

## Safety

| | |
|---|---|
| Static table list | Only the tables in the list, each with its own script, are touched. Nothing is discovered automatically. |
| One table at a time | Each table runs in one transaction. An error undoes that table's changes and stops the run. |
| Clear log | START / DONE / FAILED for every table with its duration, a timestamp on every step, and any error |
| Busy table | `lock_timeout` 60 seconds: if another session is using a table, the run fails after 60 seconds instead of waiting forever |
| No heavy scans | Row numbers come from the system tables (`pg_class`) after `ANALYZE`. Only the copy step reads the table. |
| Hard-coded partition | `dm.files.sql` empties exactly the partition named in its `TRUNCATE` line, without a check. Check the name against the database before the run, e.g. with `\d+ dm.files` in psql. |
| `SELECT *` | The copy is made from the table in the same run, so the columns always match. A table with a generated column or a `GENERATED ALWAYS` identity column fails at the copy-back step and is rolled back. |

## Tests

`tests/run_tests.sh` runs 13 scenarios against a TEST database. Before every scenario it resets the dummy data with `tests/reset_data.sql`. The scenarios cover a full run, a single named table, a table with no script, a wrong connection, a commented-out table, a missing partition, the hard-coded partition, a foreign key, a wrong keep condition, a second run on the same day, no load on the main table, and a lock timeout. Results are in [`TEST_REPORT.md`](TEST_REPORT.md) and `TEST_REPORT.pdf`.

```bash
PGHOST=<server> PGUSER=postgres ./tests/run_tests.sh
```

**Warning:** the tests drop and recreate schema `dm` in `testdb`.

## Repeating tests: save and restore the test data

The maintenance removes data, so to test it again the tables must be put back first. Two scripts do this on a **TEST** database. Both ask the same connection questions and use the same table list as `run_maintenance.sh`, or the tables you name.

```bash
./tests/save_test_data.sh        # once, before the first run: copies each table into schema test_snapshot
./run_maintenance.sh             # the test run
./tests/restore_test_data.sh     # puts every table back exactly as saved; repeat the run as often as needed
```

| Script | What it does |
|---|---|
| `tests/save_test_data.sh` | `CREATE TABLE test_snapshot.<schema>_<table> AS SELECT * FROM <table>` for each table. A table already saved is **not** saved again, so a snapshot can't be overwritten by cleaned data. To save again, drop that snapshot table first. |
| `tests/restore_test_data.sh` | For each table, in one transaction: `TRUNCATE`, then `INSERT ... SELECT *` from the snapshot, then `COMMIT` and `ANALYZE`. It also drops the dated `maintenance_<table>_<date>` tables, so the next run works on the same day. Finally it checks the row count against the snapshot. |

```
2026-10-24 18:55:09 RESTORE test data on postgres@10.0.0.5:5432/testdb: dm.files dm.filerequests
  dm.files: 5000 rows restored, snapshot has 5000 - OK
  dm.filerequests: 5000 rows restored, snapshot has 5000 - OK
2026-10-24 18:55:10 RESTORE done
```

The snapshot is a full copy, so it needs about as much disk space as the tables. For a whole-database reset, a pgBackRest restore works too.

## Before the run

- [ ] A backup is taken and confirmed
- [ ] Applications are stopped (tables are locked during the run)
- [ ] The partition names and rules in `tables/` match the production tables
- [ ] Free disk space for a copy of the kept rows
- [ ] After checking the result, drop the dated `maintenance_<table>_<date>` tables once they are no longer needed

## Requirements

`bash` and `psql`, PostgreSQL 12 or later. A user that owns the tables, or a superuser.

## Performance

[`PARALLELISM_FINDINGS.md`](PARALLELISM_FINDINGS.md) has the results of testing PostgreSQL parallel workers on a 10-million-row table. Parallel workers help very little. Dropping the indexes before the copy-back and rebuilding them afterwards was about 2.5x faster. The scripts have not been changed to do this yet.

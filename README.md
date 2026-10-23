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
2026-10-23 08:45:20 START DM maintenance on postgres@10.0.0.5:5432/datamag: dm.files dm.filerequests
2026-10-23 08:45:20 START  dm.files
0. Partitions of dm.files and their rules
                  Partitioned table "dm.files"
   ...
Partition key: LIST (is_removed)
Partitions: dm.files_active FOR VALUES IN ('N'),
            dm.files_removed FOR VALUES IN ('Y'),
            dm.files_other DEFAULT
1. Check dm.files_active is the partition for is_removed = N
   check OK: about 2000 rows
2. Empty the partition
dm.files done: partition dm.files_active (is_removed = N) emptied, about 2000 rows removed
2026-10-23 08:45:20 DONE   dm.files
2026-10-23 08:45:20 START  dm.filerequests
0. Before: rows (from statistics), indexes and triggers
   rows: 5000  indexes: 2  triggers: 0
1. Copy the rows to keep into dm.maintenance_filerequests_20261023
   copy OK: 2000 rows
2. Empty the table
3. Copy the rows back
4. After: same rows as the copy, indexes valid, triggers still there
   check OK: 2000 rows copied back
dm.filerequests done: kept 2000 rows, removed about 3000 rows, copy in dm.maintenance_filerequests_20261023
2026-10-23 08:45:20 DONE   dm.filerequests
2026-10-23 08:45:20 COMPLETED DM maintenance: 2 table(s). Log: logs/dm_maintenance_20261023_084520.log
```

If a table fails, its changes are undone, the run stops, and the tables after it are not touched:

```
2026-10-23 08:45:20 START  dm.filerequests
psql:tables/dm.filerequests.sql:32: ERROR:  cannot truncate a table referenced in a foreign key constraint
2026-10-23 08:45:20 FAILED dm.filerequests - maintenance stopped, the tables after it were not run (error above)
```

## What each table script does

The scripts are plain SQL (`ANALYZE`, `SELECT`, `BEGIN`, `LOCK`, `CREATE TABLE ... AS`, `TRUNCATE`, `INSERT`, `COMMIT`) with short `\echo` messages. A check that fails stops the script, and nothing is changed.

**`tables/dm.files.sql`** (partitioned table: empty the partition `is_removed = 'N'`)
0. Show the table, its partition key and every partition with its rule (`\d+ dm.files`).
1. `ANALYZE`, then check that `dm.files_active` is the partition `FOR VALUES IN ('N')`.
2. Lock the partition and `TRUNCATE` it. Then `ANALYZE` again.

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
| Change the partition | Edit the partition name and rule in steps 1 and 2 of `tables/dm.files.sql` |
| Add a table | Copy a table script to `tables/<schema>.<table>.sql`, change the table name and the rule (`WHERE` line, or partition name and value), and add the table to `TABLES` |

## Safety

| | |
|---|---|
| Static table list | Only the tables in the list, each with its own script, are touched. Nothing is discovered automatically. |
| One table at a time | Each table runs in one transaction. An error undoes that table's changes and stops the run. |
| Clear log | START / DONE / FAILED with a timestamp for every table, plus every step and any error |
| Fits the outage | `lock_timeout` 60 seconds (it never waits forever for a busy table) and `statement_timeout` 55 minutes |
| No heavy scans | Row numbers come from the system tables (`pg_class`) after `ANALYZE`. Only the copy step reads the table. |
| Partition checked first | The partition rule is read from the system tables before `TRUNCATE` |
| `SELECT *` | The copy is made from the table in the same run, so the columns always match. A table with a generated column or a `GENERATED ALWAYS` identity column fails at the copy-back step and is rolled back. |

## Tests

`tests/run_tests.sh` runs 13 scenarios against a TEST database. Before every scenario it resets the dummy data with `tests/reset_data.sql`. The scenarios cover a full run, a single named table, a table with no script, a wrong connection, a commented-out table, a missing or wrong partition, a foreign key, a wrong keep condition, a second run on the same day, no load on the main table, and a lock timeout. Results are in [`TEST_REPORT.md`](TEST_REPORT.md) and `TEST_REPORT.pdf`.

```bash
PGHOST=<server> PGUSER=postgres ./tests/run_tests.sh
```

**Warning:** the tests drop and recreate schema `dm` in `testdb`.

## Before the run

- [ ] A backup is taken and confirmed
- [ ] Applications are stopped (tables are locked during the run)
- [ ] The partition names and rules in `tables/` match the production tables
- [ ] Free disk space for a copy of the kept rows
- [ ] After checking the result, drop the dated `maintenance_<table>_<date>` tables once they are no longer needed

## Requirements

`bash` and `psql`, PostgreSQL 12 or later. A user that owns the tables, or a superuser.

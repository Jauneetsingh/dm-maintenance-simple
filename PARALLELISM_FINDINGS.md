# Parallel workers: can they make the DM maintenance faster?

Tested on 24 Oct 2026 with PostgreSQL 16.15 in a Docker container (12 CPUs, 8 GB RAM, default settings). The Ubuntu test server was not reachable.

**Test table:** a copy of `dm.filerequests` with **10 million rows** (930 MB of data plus 504 MB in 2 indexes: the primary key and `fileid`). The rule `statusid IN (1, 2)` keeps 4 million rows (40%).

## Short answer

- **Parallel workers help very little here.** Only one step can use them (the copy), and it's a small part of the run.
- **The big win is dropping the indexes before copying the rows back, and rebuilding them afterwards.** That makes the whole table run about **2.5× faster** (9.2 s → 3.8 s). Parallel index builds add a little more on top.

## Where the time goes (current script, 10M rows)

| Step | Time | Can it run in parallel? |
|---|---|---|
| `ANALYZE` (before and after) | ~0.2 s each | No. It reads only a sample. |
| 1. Copy the rows to keep (`CREATE TABLE ... AS SELECT * ... WHERE`) | ~1.6 s | **Yes**, but only if the planner chooses it |
| 2. `TRUNCATE` | instant | Not needed |
| 3. Copy the rows back (`INSERT ... SELECT *`) | **~7.1 s** | **No.** PostgreSQL 16 never runs `INSERT ... SELECT` in parallel. |
| 4. Checks | instant | Not needed |
| **Whole table** | **~9.2 s** | |

Most of the time is step 3. While each row goes back in, PostgreSQL also updates both indexes, row by row.

## Test results

### Step 1: copy the rows to keep (3 rounds, average)

| Setting | Time | Notes |
|---|---|---|
| Serial (`max_parallel_workers_per_gather = 0`) | 1.58 s | |
| **Default settings (2 workers allowed)** | 1.59 s | The planner still chose **serial**: with 40% of the rows going out, it thinks a parallel plan costs more |
| 4 workers, and `parallel_tuple_cost = 0.01`, `parallel_setup_cost = 100` | 0.95 s (−40%) | 4 workers launched |
| 8 workers allowed | 0.92 s (−42%) | Only 5 launched; no better than 4 |
| `CREATE UNLOGGED TABLE` for the copy, serial | 1.08 s (−32%) | Writes no WAL for the copy |
| UNLOGGED + 4 workers | 0.49 s (−69%) | |

### Step 3: copy the rows back (2 rounds, average)

| Method | Time |
|---|---|
| `INSERT` with both indexes in place (**what the script does now**) | 7.1 s |
| Same, with `maintenance_work_mem = 1GB` | 7.0 s (no gain) |
| `INSERT` with no indexes, then rebuild both indexes (1 worker, 64 MB) | 3.2 s (−55%) |
| `INSERT` with no indexes, then rebuild both with `max_parallel_maintenance_workers = 4`, `maintenance_work_mem = 1GB` | **2.4 s (−66%)** |

### Whole table, end to end

These runs used the real `tables/dm.filerequests.sql` steps on the 10M-row table, rebuilt before every run (2 rounds, average).

| Variant | Time |
|---|---|
| E1: current script, current settings | **9.2 s** |
| E2: + parallel copy (4 workers, lower parallel costs) | 10.0 s (no gain: the copy is a small step and the difference is lost in the noise) |
| E3: + parallel copy + UNLOGGED copy table | 9.3 s (no gain) |
| E4: + UNLOGGED copy + **drop the 2 indexes before step 3, rebuild them after**, 4 index workers, 1 GB | **3.8 s (−59%)** |

All runs kept exactly 4,000,000 rows and passed every check in the script.

## Recommendation

**1. Worth doing: drop and rebuild the indexes around the copy-back.** It takes 4 plain SQL lines per table, with the index names written out:

```sql
TRUNCATE TABLE dm.filerequests;
ALTER TABLE dm.filerequests DROP CONSTRAINT filerequests_pkey;          -- new: drop the indexes
DROP INDEX dm.filerequests_fileid_idx;                                  -- new

INSERT INTO dm.filerequests SELECT * FROM dm.maintenance_filerequests_:today;
\set rows_back :ROW_COUNT

ALTER TABLE dm.filerequests ADD PRIMARY KEY (requestid);                -- new: rebuild the indexes
CREATE INDEX filerequests_fileid_idx ON dm.filerequests (fileid);      -- new
```

Then add two settings to `PGOPTIONS` in `run_maintenance.sh`, so the index rebuilds use 4 workers and more memory:

```bash
export PGOPTIONS="-c lock_timeout=60s -c max_parallel_maintenance_workers=4 -c maintenance_work_mem=1GB"
```

The existing check in step 4 still applies: it confirms afterwards that the same number of indexes exist and are all valid. Everything stays in one transaction, so if a rebuild fails, the indexes and the data are all put back as they were.

Before doing this on production:
- **Index definitions:** take the exact definitions from production (`\d dm.filerequests` or `SELECT indexdef FROM pg_indexes WHERE tablename = 'filerequests'`) and copy them into the script. A missed index would be caught by the index-count check, and the run would be rolled back.
- **Foreign keys:** if another table has a foreign key pointing to the primary key, the primary key can't be dropped. The `TRUNCATE` would fail in that case anyway.
- **Memory:** `maintenance_work_mem = 1GB` is used by each index build. Check that the server has the RAM to spare during the outage.

**2. Not worth it: parallel workers for the copy step.** They save under a second per 10 million rows, and the planner only uses them if the parallel cost settings are lowered as well. Nothing changes in the script.

**3. Not recommended: an UNLOGGED copy table.** It's faster to write, but an unlogged table is **emptied if the server crashes** and is **not copied to standby servers**. The dated copy is the safety copy of the kept rows, so it should stay a normal table.

## Rough estimate for production size

If the time grows in line with the number of rows (a rough assumption that must be checked on a production-size copy), a table with 2 billion rows (200× this test) would take roughly:

- **current script:** about 30 minutes for this table alone
- **with the indexes dropped and rebuilt:** about 13 minutes

Disk speed, the number of indexes, WAL and replicas on production can change this a lot. Measure it on the production-equivalent copy before the outage.

## How it was tested

The test SQL is plain: `\timing` around each step, with `EXPLAIN (ANALYZE)` to confirm how many workers were launched. Each test was repeated 2–3 times, with similar results each time. The test schema `perf` was dropped afterwards, and the `dm` test data was not touched.

-- dm.filerequests (normal table): keep only the rows with statusid IN (1, 2), remove the rest.
-- To change the rule, edit the WHERE line in step 1. If columns are added to the table, add them in steps 1 and 3.
-- :today (e.g. 20261023) is passed in by run_maintenance.sh.

\echo '0. Before: rows (from statistics), indexes and triggers'
ANALYZE dm.filerequests;
SELECT reltuples::bigint AS rows_before,
       (SELECT count(*) FROM pg_index   WHERE indrelid = 'dm.filerequests'::regclass) AS indexes_before,
       (SELECT count(*) FROM pg_trigger WHERE tgrelid  = 'dm.filerequests'::regclass AND NOT tgisinternal) AS triggers_before
  FROM pg_class WHERE oid = 'dm.filerequests'::regclass \gset
\echo '   rows:' :rows_before ' indexes:' :indexes_before ' triggers:' :triggers_before

BEGIN;
LOCK TABLE dm.filerequests IN ACCESS EXCLUSIVE MODE;

\echo '1. Copy the rows to keep into dm.maintenance_filerequests_':today
CREATE TABLE dm.maintenance_filerequests_:today AS
SELECT requestid, fileid, typeid, statusid, requested, achieved, bytes, datasetid, commandid, error, projectid, fromjob
  FROM dm.filerequests
 WHERE statusid IN (1, 2);
\set rows_copied :ROW_COUNT

-- Check the copy before deleting anything (counts the copy, not the main table).
SELECT count(*) = :rows_copied AND count(*) > 0 AS copy_ok FROM dm.maintenance_filerequests_:today \gset
\if :copy_ok
  \echo '   copy OK:' :rows_copied 'rows'
\else
  DO $$ BEGIN RAISE EXCEPTION 'Copy check failed - nothing was changed'; END $$;
\endif

\echo '2. Empty the table'
TRUNCATE TABLE dm.filerequests;

\echo '3. Copy the rows back'
INSERT INTO dm.filerequests (requestid, fileid, typeid, statusid, requested, achieved, bytes, datasetid, commandid, error, projectid, fromjob)
SELECT requestid, fileid, typeid, statusid, requested, achieved, bytes, datasetid, commandid, error, projectid, fromjob
  FROM dm.maintenance_filerequests_:today;
\set rows_back :ROW_COUNT

\echo '4. After: same rows as the copy, indexes valid, triggers still there'
SELECT :rows_back = :rows_copied
   AND (SELECT count(*) FROM pg_index   WHERE indrelid = 'dm.filerequests'::regclass AND indisvalid) = :indexes_before
   AND (SELECT count(*) FROM pg_trigger WHERE tgrelid  = 'dm.filerequests'::regclass AND NOT tgisinternal) = :triggers_before AS after_ok \gset
\if :after_ok
  \echo '   check OK:' :rows_back 'rows copied back'
\else
  DO $$ BEGIN RAISE EXCEPTION 'Check after copy back failed - nothing was changed'; END $$;
\endif
COMMIT;

ANALYZE dm.filerequests;
SELECT :rows_before - :rows_back AS rows_removed \gset
\echo 'dm.filerequests done: kept' :rows_back 'rows, removed about' :rows_removed 'rows, copy in dm.maintenance_filerequests_':today

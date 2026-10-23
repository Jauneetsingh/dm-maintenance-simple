-- dm.files (partitioned by is_removed): empty the partition that holds is_removed = 'N'.
-- The partition rule is checked in the system tables first. If the partition name changes, edit it in steps 1 and 2.

\echo '0. Partitions of dm.files and their rules (from the system tables)'
ANALYZE dm.files;
SELECT c.relname AS partition, pg_get_expr(c.relpartbound, c.oid) AS rule, c.reltuples::bigint AS rows
  FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
 WHERE i.inhparent = 'dm.files'::regclass
 ORDER BY 1;

\echo '1. Check dm.files_active is the partition for is_removed = N'
SELECT pg_get_partkeydef('dm.files'::regclass) = 'LIST (is_removed)'
   AND pg_get_expr(relpartbound, oid) = 'FOR VALUES IN (''N'')' AS rule_ok,
       reltuples::bigint AS rows_in_partition
  FROM pg_class WHERE oid = 'dm.files_active'::regclass \gset
\if :rule_ok
  \echo '   check OK: dm.files_active holds only is_removed = N, about' :rows_in_partition 'rows'
\else
  DO $$ BEGIN RAISE EXCEPTION 'dm.files_active is not the partition for is_removed = N - nothing was changed'; END $$;
\endif

\echo '2. Empty the partition'
BEGIN;
LOCK TABLE dm.files_active IN ACCESS EXCLUSIVE MODE;
TRUNCATE TABLE dm.files_active;
COMMIT;

ANALYZE dm.files;
\echo 'dm.files done: partition dm.files_active (is_removed = N) emptied, about' :rows_in_partition 'rows removed'

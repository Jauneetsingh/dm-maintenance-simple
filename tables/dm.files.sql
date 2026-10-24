-- dm.files (partitioned by is_removed): empty the partition that holds is_removed = 'N'.
-- For another partitioned table: copy this file to tables/<schema>.<table>.sql and change the table, partition and value.

\echo '0. Partitions of dm.files and their rules'
\d+ dm.files

\echo '1. Check dm.files_active is the partition for is_removed = Y'
ANALYZE dm.files;
SELECT pg_get_expr(relpartbound, oid) = 'FOR VALUES IN (''N'')' AS rule_ok,
       reltuples::bigint AS rows_in_partition
  FROM pg_class WHERE oid = 'dm.files_active'::regclass \gset
\if :rule_ok
  \echo '   check OK: about' :rows_in_partition 'rows'
\else
  DO $$ BEGIN RAISE EXCEPTION 'dm.files_active is not the partition for is_removed = Y - nothing was changed'; END $$;
\endif

\echo '2. Empty the partition'
BEGIN;
LOCK TABLE dm.files_active IN ACCESS EXCLUSIVE MODE;
TRUNCATE TABLE dm.files_active;
COMMIT;

ANALYZE dm.files;
\echo 'dm.files done: partition dm.files_active (is_removed = Y) emptied, about' :rows_in_partition 'rows removed'

-- dm.files (partitioned by is_removed): remove the rows with is_removed = 'Y'.
--
-- Condition:  is_removed = 'Y'
-- Partition:  dm.files_removed   (defined as FOR VALUES IN ('Y'), so it holds only rows with is_removed = 'Y')
--
-- The rows are removed by truncating that partition (fast, like the old Oracle
-- "ALTER TABLE ... TRUNCATE PARTITION p_removed"). To change it, edit the partition name below.

\echo `date '+%Y-%m-%d %H:%M:%S'` '  1. Condition of partition dm.files_removed (from the database):'
SELECT 'dm.files_removed' AS partition, pg_get_expr(relpartbound, oid) AS condition
  FROM pg_class WHERE oid = 'dm.files_removed'::regclass;

\echo `date '+%Y-%m-%d %H:%M:%S'` '  2. Remove rows with is_removed = Y: truncate partition dm.files_removed'
TRUNCATE TABLE dm.files_removed;     -- condition: is_removed = 'Y'

ANALYZE dm.files;
\echo `date '+%Y-%m-%d %H:%M:%S'` 'dm.files done: rows with is_removed = Y removed (partition dm.files_removed truncated)'

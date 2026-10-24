-- dm.files (partitioned by is_removed): empty the partition dm.files_removed (holds is_removed = 'Y').
-- The partition to empty is hard-coded. To change it, edit the partition table name in the TRUNCATE line.

\echo `date '+%Y-%m-%d %H:%M:%S'` '  1. Empty the partition dm.files_removed (is_removed = Y)'
TRUNCATE TABLE dm.files_removed;

ANALYZE dm.files;
\echo 'dm.files done: partition dm.files_removed emptied'

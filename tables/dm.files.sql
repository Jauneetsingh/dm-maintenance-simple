-- dm.files (partitioned by is_removed): empty the partition dm.files_active (holds is_removed = 'N').
-- The partition to empty is hard-coded below. To change it, edit the partition name in the TRUNCATE line.

\echo '0. Partitions of dm.files and their rules (for the log)'
\d+ dm.files

\echo '1. Empty the partition dm.files_active (is_removed = N)'
TRUNCATE TABLE dm.files_active;

ANALYZE dm.files;
\echo 'dm.files done: partition dm.files_active emptied'

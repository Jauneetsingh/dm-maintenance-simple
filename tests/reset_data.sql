-- =====================================================================
-- reset_data.sql (used by run_tests.sh before every scenario)
--
-- WHAT IT DOES
--   Creates test tables with 5000 rows each, to try the maintenance scripts.
--
-- WARNING
--   It DELETES schema dm and everything in it first. TEST database only!
--
-- HOW TO RUN
--   DBeaver: open and click Execute Script (Alt+X)
--   psql:    psql -h <server> -U <user> -d testdb -f reset_data.sql
-- =====================================================================

-- Start clean: delete the old test schema and create it again.
DROP SCHEMA IF EXISTS dm CASCADE;
CREATE SCHEMA dm;

-- Normal (non-partitioned) table: 5000 rows with statusid 1 to 5.
-- statusid 1 and 2 (2000 rows) should be kept, the other 3000 removed.
CREATE SEQUENCE dm.seqrequest;
CREATE TABLE dm.filerequests (
  requestid numeric   NOT NULL DEFAULT nextval('dm.seqrequest') PRIMARY KEY,
  fileid    numeric   NOT NULL,
  typeid    numeric   NOT NULL,
  statusid  numeric   NOT NULL,
  requested date      NOT NULL DEFAULT current_date,
  achieved  timestamp NOT NULL DEFAULT now(),
  bytes     numeric   NOT NULL DEFAULT 0,
  datasetid numeric,
  commandid numeric,
  error     numeric,
  projectid numeric   NOT NULL DEFAULT 0,
  fromjob   bool      NOT NULL DEFAULT false
);
CREATE INDEX filerequests_fileid_idx ON dm.filerequests (fileid);

INSERT INTO dm.filerequests (fileid, typeid, statusid, bytes, projectid)
SELECT g, g % 7, g % 5 + 1, g * 10, g % 20
  FROM generate_series(1, 5000) g;

-- Partitioned table: one partition per is_removed value.
-- 3000 rows are 'Y' (removed) and go to files_removed, 2000 are 'N'.
CREATE TABLE dm.files (
  fileid     bigint NOT NULL,
  filename   text   NOT NULL,
  is_removed char(1),
  created_on date   NOT NULL DEFAULT current_date
) PARTITION BY LIST (is_removed);
CREATE TABLE dm.files_removed PARTITION OF dm.files FOR VALUES IN ('Y');
CREATE TABLE dm.files_active  PARTITION OF dm.files FOR VALUES IN ('N');
CREATE TABLE dm.files_other   PARTITION OF dm.files DEFAULT;     -- anything else

INSERT INTO dm.files (fileid, filename, is_removed)
SELECT g, 'file_' || g, CASE WHEN g <= 3000 THEN 'Y' ELSE 'N' END
  FROM generate_series(1, 5000) g;

-- Update the statistics, because the maintenance scripts read row numbers from them.
ANALYZE dm.filerequests;
ANALYZE dm.files;

-- Real counts, to compare with the estimates the maintenance scripts show.
-- (count(*) is fine here: this is small test data, not production.)
SELECT 'dm.filerequests' AS table_name, count(*) AS total_rows,
       count(*) FILTER (WHERE statusid IN (1, 2)) AS rows_to_keep FROM dm.filerequests
UNION ALL
SELECT 'dm.files', count(*), count(*) FILTER (WHERE is_removed <> 'Y') FROM dm.files;

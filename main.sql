-- main.sql: asks which table to clean, then runs scripta (partitioned) or scriptb (normal table).
-- Run: psql -h <server> -U <user> -d testdb -f main.sql 2>&1 | tee maintenance.log
\set ON_ERROR_STOP on
SELECT current_database() = 'testdb' AS is_test \gset
\if :is_test
\else
  \echo '*** STOP: not the TEST database ***'
  SELECT 1/0;    -- forces an error so psql stops
\endif

-- Which table? Looked up in the system tables.
\prompt 'Schema name [e.g. dm]: ' schema_name
\prompt 'Table name [e.g. filerequests or files]: ' table_name
SELECT count(*) = 1 AS found, max(c.oid::regclass::text) AS full_name, bool_or(c.relkind = 'p') AS is_partitioned
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = :'schema_name' AND c.relname = :'table_name' AND c.relkind IN ('r', 'p') \gset
\if :found
\else
  \echo '*** STOP: table not found ***'
  SELECT 1/0;
\endif
\if :is_partitioned
  \prompt 'Partitioned table. Partition value to EMPTY [e.g. Y]: ' rule
\else
  \prompt 'Normal table. Rows to KEEP [e.g. statusid IN (1, 2)]: ' rule
\endif
\prompt 'Type YES to continue: ' confirm
SELECT :'confirm' = 'YES' AS confirmed \gset
\if :confirmed
\else
  \echo 'Cancelled - nothing was changed.'
  \quit
\endif

-- Logging: one row per run in maint.maintenance_log.
SET client_min_messages = warning;
CREATE SCHEMA IF NOT EXISTS maint;
CREATE TABLE IF NOT EXISTS maint.maintenance_log (log_id serial PRIMARY KEY, table_name text, rule text,
  started_at timestamptz DEFAULT now(), finished_at timestamptz, status text, message text);
RESET client_min_messages;
INSERT INTO maint.maintenance_log (table_name, rule, status) VALUES (:'full_name', :'rule', 'STARTED') RETURNING log_id \gset
SELECT set_config('maint.table', :'full_name', false) AS t, set_config('maint.rule', :'rule', false) AS r \gset

-- Run the right script. ON_ERROR_STOP is off here so an error can be logged below.
\set ON_ERROR_STOP off
\if :is_partitioned
  \ir scripta_partitioned.sql
\else
  \ir scriptb_nonpartitioned.sql
\endif
\set failed :ERROR
\set ON_ERROR_STOP on

-- Final output: save the result in the log and show it.
UPDATE maint.maintenance_log SET finished_at = now(),
       status  = CASE WHEN :'failed' THEN 'FAILED' ELSE 'SUCCESS' END,
       message = CASE WHEN :'failed' THEN :'LAST_ERROR_MESSAGE' ELSE current_setting('maint.result', true) END
 WHERE log_id = :log_id;
SELECT table_name, rule, status, finished_at - started_at AS duration, message FROM maint.maintenance_log WHERE log_id = :log_id;

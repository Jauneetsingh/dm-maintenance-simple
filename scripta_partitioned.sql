-- scripta_partitioned.sql: removes only the rows matching the condition (e.g. is_removed = 'Y').
-- Run through main.sql. All other rows stay, also in partitions that hold both kinds of rows.
-- One transaction: any error undoes everything. Row numbers come from the system tables.
DO $$
DECLARE
  tbl          regclass := current_setting('maint.table')::regclass;
  rule         text := '(' || current_setting('maint.rule') || ')';
  plan         json;
  rows_before  bigint;
  rows_to_go   bigint;
  rows_deleted bigint;
  table_empty  boolean;
BEGIN
  -- 0. Refresh statistics, then read the row numbers from them (no count on the table).
  EXECUTE 'ANALYZE ' || tbl;
  SELECT sum(greatest(c.reltuples, 0))::bigint INTO rows_before
    FROM pg_partition_tree(tbl) t JOIN pg_class c ON c.oid = t.relid WHERE t.isleaf;
  EXECUTE 'EXPLAIN (FORMAT JSON) SELECT 1 FROM ' || tbl || ' WHERE ' || rule INTO plan;   -- plans only, reads no rows
  rows_to_go := (plan -> 0 -> 'Plan' ->> 'Plan Rows')::bigint;
  RAISE NOTICE USING MESSAGE = tbl || ': about ' || rows_before || ' rows, about ' || rows_to_go || ' to remove';

  -- 1. Remove only the rows matching the condition.
  --    PostgreSQL only looks in the partitions that can hold matching rows.
  EXECUTE 'DELETE FROM ' || tbl || ' WHERE ' || rule;
  GET DIAGNOSTICS rows_deleted = ROW_COUNT;

  -- 2. Safety check: if no row is left at all, the condition was too wide (e.g. 1 = 1). Undo everything.
  --    (Reads at most one row.)
  EXECUTE 'SELECT NOT EXISTS (SELECT 1 FROM ' || tbl || ')' INTO table_empty;
  IF table_empty AND rows_deleted > 0 THEN
    RAISE EXCEPTION USING MESSAGE = 'The condition removes every row of ' || tbl || ' - all undone, nothing changed';
  END IF;

  -- 3. Refresh statistics after.
  EXECUTE 'ANALYZE ' || tbl;
  RAISE NOTICE USING MESSAGE = tbl || ': removed ' || rows_deleted || ' rows matching ' || rule;
  PERFORM set_config('maint.result', 'removed ' || rows_deleted || ' rows matching ' || rule, false);   -- message for the log
END $$;

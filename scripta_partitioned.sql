-- scripta_partitioned.sql: empties the partition that holds the removed rows (e.g. is_removed = 'Y').
-- Run through main.sql. The partition is found from its definition in the system tables:
-- a partition defined FOR VALUES IN ('Y') can only hold 'Y' rows, so no rows need to be read.
DO $$
DECLARE
  tbl       regclass := current_setting('maint.table')::regclass;
  wanted    text := format('FOR VALUES IN (%L)', current_setting('maint.rule'));
  part      regclass;
  part_rows bigint;
  emptied   text := '';
BEGIN
  EXECUTE format('ANALYZE %s', tbl);                              -- refresh statistics before

  -- Find the partition(s) with the wanted definition.
  FOR part IN SELECT c.oid::regclass FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
               WHERE i.inhparent = tbl AND pg_get_expr(c.relpartbound, c.oid) = wanted LOOP
    SELECT reltuples::bigint INTO part_rows FROM pg_class WHERE oid = part;   -- rows from statistics
    EXECUTE format('LOCK TABLE %s IN ACCESS EXCLUSIVE MODE', part);
    EXECUTE format('TRUNCATE TABLE %s', part);
    RAISE NOTICE '%: emptied, about % rows removed', part, part_rows;
    emptied := emptied || part || ' (about ' || part_rows || ' rows) ';
  END LOOP;

  IF emptied = '' THEN
    RAISE EXCEPTION 'No partition of % is defined as % - nothing changed', tbl, wanted;
  END IF;

  EXECUTE format('ANALYZE %s', tbl);                              -- refresh statistics after
  PERFORM set_config('maint.result', 'emptied ' || emptied, false);   -- message for the log
END $$;

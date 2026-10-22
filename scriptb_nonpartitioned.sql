-- scriptb_nonpartitioned.sql: keeps only the rows matching the rule, removes the rest.
-- Run through main.sql. One transaction: any error undoes everything.
-- Row numbers come from the system tables, so the main table is never counted.
DO $$
DECLARE
  tbl  regclass := current_setting('maint.table')::regclass;
  rule text := '(' || current_setting('maint.rule') || ')';
  copy_tbl text; cols text; rows_before bigint; rows_copied bigint; rows_in_copy bigint; rows_back bigint; idx int; trg int;
BEGIN
  -- 0. Validation before: rows (from statistics), indexes, triggers, column names (no SELECT *).
  EXECUTE 'ANALYZE ' || tbl;
  SELECT reltuples::bigint, relnamespace::regnamespace || '.' || quote_ident('maintenance_' || relname || '_' || to_char(now(), 'YYYYMMDD'))
    INTO rows_before, copy_tbl FROM pg_class WHERE oid = tbl;
  SELECT count(*) INTO idx FROM pg_index   WHERE indrelid = tbl;
  SELECT count(*) INTO trg FROM pg_trigger WHERE tgrelid  = tbl AND NOT tgisinternal;
  SELECT string_agg(quote_ident(attname), ', ' ORDER BY attnum) INTO cols
    FROM pg_attribute WHERE attrelid = tbl AND attnum > 0 AND NOT attisdropped AND attgenerated = '';
  RAISE NOTICE USING MESSAGE = tbl || ': about ' || rows_before || ' rows, ' || idx || ' indexes, ' || trg || ' triggers';
  EXECUTE 'LOCK TABLE ' || tbl || ' IN ACCESS EXCLUSIVE MODE';

  -- 1. Copy the rows to keep into the backup table, and check the copy (counts the copy only).
  EXECUTE 'CREATE TABLE ' || copy_tbl || ' AS SELECT ' || cols || ' FROM ' || tbl || ' WHERE ' || rule;
  GET DIAGNOSTICS rows_copied = ROW_COUNT;
  EXECUTE 'SELECT count(*) FROM ' || copy_tbl INTO rows_in_copy;
  IF rows_in_copy <> rows_copied OR rows_copied = 0 THEN
    RAISE EXCEPTION USING MESSAGE = 'Copy check failed: copied ' || rows_copied || ', found ' || rows_in_copy || ' in ' || copy_tbl;
  END IF;

  -- 2. Empty the original table.
  EXECUTE 'TRUNCATE TABLE ' || tbl;

  -- 3. Copy the rows back.
  EXECUTE 'INSERT INTO ' || tbl || ' (' || cols || ') OVERRIDING SYSTEM VALUE SELECT ' || cols || ' FROM ' || copy_tbl;
  GET DIAGNOSTICS rows_back = ROW_COUNT;

  -- 4. Validation after: same rows as the copy, indexes valid, triggers still there.
  IF rows_back <> rows_in_copy
  OR (SELECT count(*) FROM pg_index WHERE indrelid = tbl AND indisvalid) <> idx
  OR (SELECT count(*) FROM pg_trigger WHERE tgrelid = tbl AND NOT tgisinternal) <> trg THEN
    RAISE EXCEPTION USING MESSAGE = 'Check after copy back failed: ' || rows_back || ' of ' || rows_in_copy
                                    || ' rows, or an index/trigger is missing';
  END IF;
  EXECUTE 'ANALYZE ' || tbl;

  RAISE NOTICE USING MESSAGE = tbl || ': kept ' || rows_back || ', removed about ' || (rows_before - rows_back)
                               || ', indexes and triggers OK';
  PERFORM set_config('maint.result', 'kept ' || rows_back || ', removed about ' || (rows_before - rows_back)
                     || ', backup in ' || copy_tbl, false);   -- message for the log
END $$;

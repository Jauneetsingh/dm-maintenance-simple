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
  EXECUTE format('ANALYZE %s', tbl);
  SELECT reltuples::bigint, format('%I.%I', relnamespace::regnamespace, 'maintenance_' || relname || '_' || to_char(now(), 'YYYYMMDD'))
    INTO rows_before, copy_tbl FROM pg_class WHERE oid = tbl;
  SELECT count(*) INTO idx FROM pg_index   WHERE indrelid = tbl;
  SELECT count(*) INTO trg FROM pg_trigger WHERE tgrelid  = tbl AND NOT tgisinternal;
  SELECT string_agg(quote_ident(attname), ', ' ORDER BY attnum) INTO cols
    FROM pg_attribute WHERE attrelid = tbl AND attnum > 0 AND NOT attisdropped AND attgenerated = '';
  RAISE NOTICE '%: about % rows, % indexes, % triggers', tbl, rows_before, idx, trg;
  EXECUTE format('LOCK TABLE %s IN ACCESS EXCLUSIVE MODE', tbl);

  -- 1. Copy the rows to keep into the backup table, and check the copy (counts the copy only).
  EXECUTE format('CREATE TABLE %s AS SELECT %s FROM %s WHERE %s', copy_tbl, cols, tbl, rule);
  GET DIAGNOSTICS rows_copied = ROW_COUNT;
  EXECUTE format('SELECT count(*) FROM %s', copy_tbl) INTO rows_in_copy;
  IF rows_in_copy <> rows_copied OR rows_copied = 0 THEN
    RAISE EXCEPTION 'Copy check failed: copied %, found % in %', rows_copied, rows_in_copy, copy_tbl;
  END IF;

  -- 2. Empty the original table.
  EXECUTE format('TRUNCATE TABLE %s', tbl);

  -- 3. Copy the rows back.
  EXECUTE format('INSERT INTO %s (%s) OVERRIDING SYSTEM VALUE SELECT %s FROM %s', tbl, cols, cols, copy_tbl);
  GET DIAGNOSTICS rows_back = ROW_COUNT;

  -- 4. Validation after: same rows as the copy, indexes valid, triggers still there.
  IF rows_back <> rows_in_copy
  OR (SELECT count(*) FROM pg_index WHERE indrelid = tbl AND indisvalid) <> idx
  OR (SELECT count(*) FROM pg_trigger WHERE tgrelid = tbl AND NOT tgisinternal) <> trg THEN
    RAISE EXCEPTION 'Check after copy back failed: % of % rows, or an index/trigger is missing', rows_back, rows_in_copy;
  END IF;
  EXECUTE format('ANALYZE %s', tbl);

  RAISE NOTICE '%: kept %, removed about %, indexes and triggers OK', tbl, rows_back, rows_before - rows_back;
  PERFORM set_config('maint.result', format('kept %s, removed about %s, backup in %s',
                     rows_back, rows_before - rows_back, copy_tbl), false);   -- message for the log
END $$;

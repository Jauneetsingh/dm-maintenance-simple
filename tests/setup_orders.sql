-- setup_orders.sql: extra dummy data for scenario S10 (run after reset_data.sql).
-- dm.orders has an identity column, a generated column, an index and a row trigger,
-- to prove all of them survive the copy / truncate / copy back.
CREATE TABLE dm.orders (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,   -- identity: ids must not change
  statusid   int     NOT NULL,
  amount     numeric NOT NULL,
  amount_x2  numeric GENERATED ALWAYS AS (amount * 2) STORED   -- generated: PostgreSQL fills it in
);
CREATE INDEX orders_statusid_idx ON dm.orders (statusid);

-- Audit table + row trigger: one audit row for every row inserted into dm.orders.
CREATE TABLE dm.order_audit (order_id bigint);
CREATE FUNCTION dm.order_audit_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO dm.order_audit VALUES (NEW.id);
  RETURN NEW;
END $$;
CREATE TRIGGER orders_audit AFTER INSERT ON dm.orders FOR EACH ROW EXECUTE FUNCTION dm.order_audit_fn();

-- 1000 orders, statusid 1-5. statusid = 1 (200 rows, ids 5, 10, ... 1000) will be kept.
INSERT INTO dm.orders (statusid, amount) SELECT g % 5 + 1, g FROM generate_series(1, 1000) g;
ANALYZE dm.orders;

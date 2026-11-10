-- =====================================================================
-- test_procedures.sql  --  tests for the stored procedures
--
-- Everything runs inside one transaction that is rolled back at the
-- end, so the tests leave the database exactly as they found it.
-- Each check prints "ok - ..." or stops the script with an error.
-- =====================================================================

\set ON_ERROR_STOP on
\set QUIET on
SET client_min_messages TO notice;
SET search_path TO shop;

BEGIN;

-- Helper: fail unless the condition is true.
CREATE FUNCTION pg_temp.check_true(p_ok boolean, p_name text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF p_ok IS NOT TRUE THEN
        RAISE EXCEPTION 'FAILED - %', p_name;
    END IF;
    RAISE NOTICE 'ok - %', p_name;
END;
$$;

-- Helper: run a statement that is supposed to fail, and check that it
-- fails with the expected SQLSTATE.
CREATE FUNCTION pg_temp.expect_error(p_sql text, p_state text, p_name text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_state text := NULL;
BEGIN
    BEGIN
        EXECUTE p_sql;
    EXCEPTION WHEN OTHERS THEN
        v_state := SQLSTATE;
    END;
    IF v_state IS NULL THEN
        RAISE EXCEPTION 'FAILED - % (statement succeeded, expected %)', p_name, p_state;
    ELSIF v_state <> p_state THEN
        RAISE EXCEPTION 'FAILED - % (got %, expected %)', p_name, v_state, p_state;
    END IF;
    RAISE NOTICE 'ok - %', p_name;
END;
$$;

-- A session to stamp the test orders with.
SELECT fn_open_session('tester', 'test') AS sid \gset

-- ---------------------------------------------------------------------
-- Placing an order
-- ---------------------------------------------------------------------
SELECT fn_place_order(1, :sid, '[{"sku":"TEA-001","qty":2},{"sku":"KIT-002","qty":4}]') AS oid \gset

SELECT pg_temp.check_true(
    (SELECT (subtotal, tax_amount, total) = (29.00, 5.80, 34.80) FROM orders WHERE order_id = :oid),
    'order totals: 2 x 4.50 + 4 x 5.00 = 29.00, tax 5.80, total 34.80');

SELECT pg_temp.check_true(
    (SELECT stock_qty FROM products WHERE sku = 'TEA-001') = 118
    AND (SELECT stock_qty FROM products WHERE sku = 'KIT-002') = 196,
    'stock reduced by the quantities ordered');

SELECT pg_temp.check_true(
    (SELECT count(*) FROM stock_movements WHERE order_id = :oid AND reason = 'SALE') = 2,
    'one SALE ledger row per order line');

-- Lower-case SKUs and repeated lines are tidied up.
SELECT fn_place_order(1, :sid,
    '[{"sku":"sta-001","qty":1},{"sku":" STA-001 ","qty":2}]') AS oid2 \gset

SELECT pg_temp.check_true(
    (SELECT count(*) = 1 AND sum(quantity) = 3 FROM order_lines WHERE order_id = :oid2),
    'repeated SKU lines are merged into one line');

-- ---------------------------------------------------------------------
-- Refusals
-- ---------------------------------------------------------------------
SELECT pg_temp.expect_error(
    $$SELECT shop.fn_place_order(1, NULL, '[{"sku":"KIT-003","qty":2}]')$$,
    'OD003', 'not enough stock is refused');

SELECT pg_temp.expect_error(
    $$SELECT shop.fn_place_order(1, NULL, '[{"sku":"NOPE-1","qty":1}]')$$,
    'OD002', 'unknown product is refused');

SELECT pg_temp.expect_error(
    $$SELECT shop.fn_place_order(9999, NULL, '[{"sku":"TEA-001","qty":1}]')$$,
    'OD001', 'unknown customer is refused');

SELECT pg_temp.expect_error(
    $$SELECT shop.fn_place_order(1, NULL, '[]')$$,
    'OD004', 'empty cart is refused');

SELECT pg_temp.expect_error(
    $$SELECT shop.fn_place_order(1, NULL, '{"sku":"TEA-001","qty":1}')$$,
    'OD004', 'cart that is not a list is refused');

SELECT pg_temp.expect_error(
    $$SELECT shop.fn_place_order(1, NULL, '[{"sku":"TEA-001","qty":1.5}]')$$,
    'OD004', 'fractional quantity is refused');

SELECT pg_temp.expect_error(
    $$SELECT shop.fn_place_order(1, NULL, '[{"sku":"TEA-001","qty":0}]')$$,
    'OD004', 'zero quantity is refused');

SELECT pg_temp.expect_error(
    $$SELECT shop.fn_place_order(1, NULL, '[{"sku":"TEA-001","qty":"2"}]')$$,
    'OD004', 'quantity given as text is refused');

-- All or nothing: one good line plus one impossible line must leave
-- the good line's stock untouched.
SELECT stock_qty AS tea_before FROM products WHERE sku = 'TEA-001' \gset
SELECT count(*) AS orders_before FROM orders \gset

SELECT pg_temp.expect_error(
    $$SELECT shop.fn_place_order(1, NULL,
        '[{"sku":"TEA-001","qty":5},{"sku":"KIT-003","qty":99}]')$$,
    'OD003', 'order with one impossible line is refused');

SELECT pg_temp.check_true(
    (SELECT stock_qty FROM products WHERE sku = 'TEA-001') = :tea_before
    AND (SELECT count(*) FROM orders) = :orders_before,
    'a refused order changes nothing (all or nothing)');

-- ---------------------------------------------------------------------
-- Order life cycle
-- ---------------------------------------------------------------------
SELECT pg_temp.check_true(fn_advance_order(:oid) = 'PAID',    'PLACED moves to PAID');

SELECT fn_cancel_order(:oid, :sid);

SELECT pg_temp.check_true(
    (SELECT stock_qty FROM products WHERE sku = 'TEA-001') = 120
    AND (SELECT stock_qty FROM products WHERE sku = 'KIT-002') = 200,
    'cancelling returns the stock');

SELECT pg_temp.expect_error(
    format('SELECT shop.fn_cancel_order(%s, NULL)', :oid),
    'OD005', 'an order cannot be cancelled twice');

SELECT pg_temp.expect_error(
    format('SELECT shop.fn_advance_order(%s)', :oid),
    'OD005', 'a cancelled order cannot move forward');

SELECT pg_temp.check_true(fn_advance_order(:oid2) = 'PAID',    'second order: PLACED to PAID');
SELECT pg_temp.check_true(fn_advance_order(:oid2) = 'SHIPPED', 'second order: PAID to SHIPPED');

SELECT pg_temp.expect_error(
    format('SELECT shop.fn_cancel_order(%s, NULL)', :oid2),
    'OD005', 'a shipped order cannot be cancelled');

SELECT pg_temp.expect_error(
    $$SELECT shop.fn_cancel_order(987654, NULL)$$,
    'OD006', 'cancelling an unknown order is refused');

-- ---------------------------------------------------------------------
-- Stock adjustments
-- ---------------------------------------------------------------------
SELECT pg_temp.check_true(
    fn_adjust_stock('ele-003', 10, 'RECEIVE', :sid, 'delivery') = 10,
    'receiving stock returns the new figure');

SELECT pg_temp.expect_error(
    $$SELECT shop.fn_adjust_stock('ELE-003', -500, 'ADJUST', NULL)$$,
    'OD003', 'adjusting below zero is refused');

SELECT pg_temp.expect_error(
    $$SELECT shop.fn_adjust_stock('ELE-003', -1, 'RECEIVE', NULL)$$,
    'OD004', 'a negative delivery is refused');

SELECT pg_temp.expect_error(
    $$SELECT shop.fn_adjust_stock('NOPE-1', 1, 'RECEIVE', NULL)$$,
    'OD002', 'adjusting an unknown product is refused');

-- ---------------------------------------------------------------------
-- Constraints and triggers: the safety nets under the procedures
-- ---------------------------------------------------------------------
SELECT pg_temp.expect_error(
    $$UPDATE shop.products SET stock_qty = -1 WHERE sku = 'TEA-001'$$,
    '23514', 'CHECK constraint blocks negative stock even on a direct UPDATE');

SELECT pg_temp.expect_error(
    $$INSERT INTO shop.customers (email, full_name) VALUES ('ADA.OBI@example.com', 'Copy')$$,
    '23505', 'unique index blocks the same email in different case');

UPDATE products SET unit_price = 3.50 WHERE sku = 'STA-001';

SELECT pg_temp.check_true(
    (SELECT (old_price, new_price) = (3.25, 3.50) FROM price_history h
     JOIN products p USING (product_id) WHERE p.sku = 'STA-001'),
    'trigger records the price change');

SELECT pg_temp.check_true(
    (SELECT unit_price = 3.25 FROM order_lines WHERE order_id = :oid2),
    'an existing order keeps the price it was sold at');

-- ---------------------------------------------------------------------
-- Reports and integrity
-- ---------------------------------------------------------------------
SELECT pg_temp.check_true(
    (SELECT count(*) = 0 FROM fn_stock_discrepancies()),
    'stock ledger balances for every product');

SELECT pg_temp.check_true(
    (SELECT count(*) = 1 AND max(sku) = 'STA-001' AND max(share_pct) = 100.0
     FROM fn_sales_summary(current_date, current_date)),
    'sales summary leaves out the cancelled order');

SELECT pg_temp.check_true(
    (SELECT (subtotal, tax_amount, total) = (29.00, 5.80, 34.80)
     FROM fn_cart_totals('[{"sku":"TEA-001","qty":2},{"sku":"KIT-002","qty":4}]')),
    'preview totals match what the real order charged');

-- ---------------------------------------------------------------------
-- Sessions
-- ---------------------------------------------------------------------
-- A session whose database process no longer exists (process id 1 is
-- never a PostgreSQL backend) must be cleaned up at the next sign-on.
INSERT INTO sessions (operator, terminal, backend_pid) VALUES ('ghost', 'gone', 1)
RETURNING session_id AS ghost \gset

SELECT fn_open_session('second', 'test') AS sid2 \gset

SELECT pg_temp.check_true(
    (SELECT close_reason = 'REAPED' FROM sessions WHERE session_id = :ghost),
    'a dead session is reaped at the next sign-on');

SELECT pg_temp.check_true(
    (SELECT count(*) = 2 FROM v_active_sessions WHERE session_id IN (:sid, :sid2)),
    'live sessions appear in v_active_sessions');

SELECT fn_close_session(:sid2);

SELECT pg_temp.check_true(
    (SELECT close_reason = 'NORMAL' FROM sessions WHERE session_id = :sid2),
    'signing off closes the session');

ROLLBACK;

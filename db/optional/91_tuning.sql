-- =====================================================================
-- 91_tuning.sql  --  OPTIONAL: watch the query planner at work
--
-- Run 90_bulk_load.sql first. Then:   psql -f db/optional/91_tuning.sql
--
-- EXPLAIN shows the plan PostgreSQL chose for a query.
-- EXPLAIN ANALYZE also runs the query and reports what really happened:
-- rows found, time taken, and (with BUFFERS) how many 8 kB pages of
-- data it had to read. Fewer pages read is the real measure of a good
-- plan. Time follows from it.
--
-- Each "before" case drops an index inside a transaction and then
-- rolls back, so the script changes nothing permanently.
-- =====================================================================

\pset pager off
SET search_path TO shop;

-- A customer from the bulk data to use in the examples.
SELECT min(customer_id) + 5000 AS cust FROM customers WHERE email LIKE 'bulk%' \gset

\echo
\echo ============================================================
\echo CASE 1  Customer order history, newest 20
\echo ============================================================
\echo
\echo --- BEFORE: no index on customer_id -----------------------
BEGIN;
DROP INDEX orders_customer_placed_idx;
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT order_id, placed_at, status, total
FROM   orders
WHERE  customer_id = :cust
ORDER  BY placed_at DESC
LIMIT  20;
ROLLBACK;

\echo
\echo --- AFTER: index on (customer_id, placed_at DESC) ---------
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT order_id, placed_at, status, total
FROM   orders
WHERE  customer_id = :cust
ORDER  BY placed_at DESC
LIMIT  20;

\echo
\echo ============================================================
\echo CASE 2  Work queue: orders waiting for payment, oldest first
\echo ============================================================
\echo
\echo --- BEFORE: no partial index -------------------------------
BEGIN;
DROP INDEX orders_open_queue_idx;
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT order_id, placed_at, total
FROM   orders
WHERE  status = 'PLACED'
ORDER  BY placed_at
LIMIT  25;
ROLLBACK;

\echo
\echo --- AFTER: partial index WHERE status = 'PLACED' -----------
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT order_id, placed_at, total
FROM   orders
WHERE  status = 'PLACED'
ORDER  BY placed_at
LIMIT  25;

\echo
\echo --- Size of the partial index next to a full one ----------
SELECT relname AS index_name, pg_size_pretty(pg_relation_size(oid)) AS size
FROM   pg_class
WHERE  relname IN ('orders_open_queue_idx', 'orders_placed_idx')
ORDER  BY relname;

\echo
\echo ============================================================
\echo CASE 3  Same index, two ways of writing the question
\echo ============================================================
\echo
\echo --- BEFORE: the column is wrapped in a cast ---------------
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT count(*), sum(total)
FROM   orders
WHERE  placed_at::date = current_date - 200;

\echo
\echo --- AFTER: the column is left bare, compared to a range ---
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT count(*), sum(total)
FROM   orders
WHERE  placed_at >= current_date - 200
AND    placed_at <  current_date - 199;

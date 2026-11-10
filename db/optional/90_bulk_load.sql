-- =====================================================================
-- 90_bulk_load.sql  --  OPTIONAL: two years of made-up order history
--
-- The sample data in 03_seed.sql is tiny, and on a tiny table every
-- query is fast whatever you do. To study query plans you need volume.
-- This script adds 20,000 customers and 300,000 past orders.
--
-- Run it after the three main scripts:   psql -f db/optional/90_bulk_load.sql
-- It takes about twenty seconds. Re-run 01, 02 and 03 to remove the data.
--
-- The orders are inserted directly as finished history. They do not go
-- through fn_place_order and do not touch stock, so the stock ledger
-- still balances afterwards.
-- =====================================================================

SET search_path TO shop;

BEGIN;

INSERT INTO customers (email, full_name, city)
SELECT 'bulk' || g || '@example.com',
       'Bulk Customer ' || g,
       (ARRAY['Manchester', 'Salford', 'Bolton', 'Stockport', 'Oldham'])[1 + g % 5]
FROM   generate_series(1, 20000) AS g;

-- Orders. power(random(), 2) leans towards the low numbers, so a few
-- customers end up with many orders and most have a handful, which is
-- how real customer data tends to look.
INSERT INTO orders (customer_id, status, placed_at, cancelled_at)
SELECT b.first_id + floor(power(t.r_customer, 2) * 20000)::integer,
       t.status,
       t.placed_at,
       CASE WHEN t.status = 'CANCELLED' THEN t.placed_at + interval '1 hour' END
FROM  (SELECT min(customer_id) AS first_id FROM customers WHERE email LIKE 'bulk%') b,
      (SELECT u.placed_at,
              u.r_customer,
              CASE
                  -- recent orders are mostly still waiting for payment
                  WHEN u.placed_at > now() - interval '2 days' AND u.r < 0.60 THEN 'PLACED'
                  WHEN u.r < 0.04 THEN 'CANCELLED'
                  WHEN u.r < 0.05 THEN 'PAID'
                  ELSE 'SHIPPED'
              END AS status
       FROM  (SELECT now() - random() * interval '730 days' AS placed_at,
                     random() AS r,
                     random() AS r_customer
              FROM   generate_series(1, 300000)) u) t;

-- One to three lines per order, each for a different product.
CREATE TEMP TABLE bulk_pick ON COMMIT DROP AS
SELECT o.order_id,
       floor(random() * 13)::integer AS p1,       -- position of first product
       1 + floor(random() * 6)::integer AS step,  -- distance to the next one
       random() AS r
FROM   orders o
WHERE  o.session_id IS NULL
AND    o.total = 0;

CREATE TEMP TABLE bulk_prod ON COMMIT DROP AS
SELECT row_number() OVER (ORDER BY product_id) - 1 AS pos, product_id, unit_price
FROM   products;

INSERT INTO order_lines (order_id, line_no, product_id, quantity, unit_price)
SELECT k.order_id, n.line_no, p.product_id, 1 + (k.order_id + n.line_no) % 4, p.unit_price
FROM   bulk_pick k
JOIN   LATERAL (VALUES (1, 0.0), (2, 0.45), (3, 0.80)) AS n(line_no, min_r)
       ON k.r >= n.min_r
JOIN   bulk_prod p
       ON p.pos = (k.p1 + (n.line_no - 1) * k.step) % 13;

UPDATE orders o
SET    subtotal   = s.subtotal,
       tax_amount = round(s.subtotal * t.rate / 100, 2),
       total      = s.subtotal + round(s.subtotal * t.rate / 100, 2)
FROM  (SELECT order_id, sum(line_total) AS subtotal
       FROM   order_lines
       WHERE  order_id IN (SELECT order_id FROM bulk_pick)
       GROUP  BY order_id) s,
      (SELECT value::numeric AS rate FROM app_settings WHERE key = 'tax_rate_percent') t
WHERE  o.order_id = s.order_id;

COMMIT;

-- VACUUM clears out the old row versions left behind by the UPDATE
-- above. ANALYZE refreshes the statistics the query planner uses to
-- choose its plans. Both are normally done by autovacuum in the
-- background; after a bulk load it is worth doing them at once.
VACUUM (ANALYZE) customers;
VACUUM (ANALYZE) orders;
VACUUM (ANALYZE) order_lines;

SELECT (SELECT count(*) FROM customers)   AS customers,
       (SELECT count(*) FROM orders)      AS orders,
       (SELECT count(*) FROM order_lines) AS order_lines;

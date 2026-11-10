-- =====================================================================
-- 02_procedures.sql  --  business rules that live inside the database
--
-- Why put the rules here and not in the Pascal program?
--   * Every program that touches the data gets the same rules.
--   * One call from the client runs many statements in one round trip.
--   * Row locks are taken and released in one place, in one order,
--     which is what keeps parallel sessions from corrupting stock.
--
-- Error codes raised by these functions (SQLSTATE values):
--   OD001  customer does not exist
--   OD002  product does not exist or is not on sale
--   OD003  not enough stock
--   OD004  input is malformed
--   OD005  the order is in a state that does not allow the action
--   OD006  order does not exist
-- The Pascal program reads the SQLSTATE to decide what to tell the
-- operator, so it never has to parse error message text.
-- =====================================================================

SET search_path TO shop;

-- ---------------------------------------------------------------------
-- fn_normalise_items
-- Turns the cart sent by the client, for example
--     [{"sku":"tea-001","qty":2},{"sku":"TEA-001","qty":1}]
-- into clean rows: one row per SKU, upper case, quantities added up.
-- Rejects anything that is not a list of {sku, whole positive qty}.
-- ---------------------------------------------------------------------
CREATE FUNCTION fn_normalise_items(p_items jsonb)
RETURNS TABLE (sku text, quantity integer)
LANGUAGE plpgsql
STABLE
SET search_path = shop, pg_temp
AS $$
DECLARE
    v_elem jsonb;
    v_qty  numeric;
BEGIN
    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
        RAISE EXCEPTION 'The cart must be a JSON array'
              USING ERRCODE = 'OD004';
    END IF;

    IF jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'The cart is empty' USING ERRCODE = 'OD004';
    END IF;

    FOR v_elem IN SELECT e FROM jsonb_array_elements(p_items) AS t(e)
    LOOP
        IF jsonb_typeof(v_elem) <> 'object'
           OR jsonb_typeof(v_elem -> 'sku') IS DISTINCT FROM 'string'
           OR jsonb_typeof(v_elem -> 'qty') IS DISTINCT FROM 'number' THEN
            RAISE EXCEPTION 'Each cart line needs a text "sku" and a numeric "qty": %', v_elem
                  USING ERRCODE = 'OD004';
        END IF;

        v_qty := (v_elem ->> 'qty')::numeric;
        IF v_qty <> trunc(v_qty) OR v_qty < 1 OR v_qty > 100000 THEN
            RAISE EXCEPTION 'Quantity must be a whole number from 1 to 100000: %', v_elem
                  USING ERRCODE = 'OD004';
        END IF;

        IF btrim(v_elem ->> 'sku') = '' THEN
            RAISE EXCEPTION 'A cart line has a blank SKU' USING ERRCODE = 'OD004';
        END IF;
    END LOOP;

    RETURN QUERY
    SELECT upper(btrim(t.e ->> 'sku')),
           sum((t.e ->> 'qty')::integer)::integer
    FROM   jsonb_array_elements(p_items) AS t(e)
    GROUP  BY 1
    ORDER  BY 1;
END;
$$;

-- ---------------------------------------------------------------------
-- fn_price_cart
-- Read-only preview of a cart: prices each line and flags problems.
-- It takes no locks, so the answer can be out of date a moment later.
-- That is fine for a preview. fn_place_order checks again under lock.
-- ---------------------------------------------------------------------
CREATE FUNCTION fn_price_cart(p_items jsonb)
RETURNS TABLE (
    line_no     integer,
    sku         text,
    name        text,
    quantity    integer,
    unit_price  numeric,
    line_total  numeric,
    in_stock    integer,
    problem     text
)
LANGUAGE plpgsql
STABLE
SET search_path = shop, pg_temp
AS $$
#variable_conflict use_column
BEGIN
    RETURN QUERY
    SELECT (row_number() OVER (ORDER BY i.sku))::integer,
           i.sku,
           p.name,
           i.quantity,
           p.unit_price,
           (i.quantity * p.unit_price)::numeric(12,2),
           p.stock_qty,
           CASE
               WHEN p.product_id IS NULL    THEN 'unknown SKU'
               WHEN NOT p.is_active         THEN 'not on sale'
               WHEN p.stock_qty < i.quantity THEN 'only ' || p.stock_qty || ' in stock'
           END
    FROM   fn_normalise_items(p_items) AS i
    LEFT   JOIN products p ON p.sku = i.sku
    ORDER  BY i.sku;
END;
$$;

-- ---------------------------------------------------------------------
-- fn_tax_on
-- The one place where tax is calculated. The preview and the real
-- order both call it, so they cannot disagree.
-- ---------------------------------------------------------------------
CREATE FUNCTION fn_tax_on(p_amount numeric)
RETURNS numeric
LANGUAGE sql
STABLE
SET search_path = shop, pg_temp
AS $$
    SELECT round(coalesce(p_amount, 0)
                 * coalesce((SELECT s.value::numeric FROM app_settings s
                             WHERE  s.key = 'tax_rate_percent'), 0)
                 / 100, 2);
$$;

-- ---------------------------------------------------------------------
-- fn_cart_totals
-- Read-only totals for a cart, shown to the operator before confirming.
-- ---------------------------------------------------------------------
CREATE FUNCTION fn_cart_totals(p_items jsonb)
RETURNS TABLE (subtotal numeric, tax_amount numeric, total numeric)
LANGUAGE sql
STABLE
SET search_path = shop, pg_temp
AS $$
    SELECT t.subtotal, fn_tax_on(t.subtotal), t.subtotal + fn_tax_on(t.subtotal)
    FROM  (SELECT coalesce(sum(c.line_total), 0)::numeric(12,2) AS subtotal
           FROM   fn_price_cart(p_items) c) t;
$$;

-- ---------------------------------------------------------------------
-- fn_place_order
-- The core transaction. Either the whole order is stored and stock is
-- reduced for every line, or nothing changes at all.
--
-- Steps:
--   1. Check the customer and clean up the cart.
--   2. Lock the product rows, always in product_id order.
--   3. With the rows locked, check stock.
--   4. Insert the order and its lines, reduce stock, write the ledger.
--   5. Work out the totals.
--
-- About step 2. "SELECT ... FOR UPDATE" makes any other session that
-- wants the same rows wait until this transaction commits or rolls
-- back. When the other session gets its turn it re-reads the row and
-- sees the new, lower stock figure. Without the lock two sessions could
-- both read "1 left" and both sell it.
--
-- Locking in a fixed order prevents deadlocks. If session A locked
-- product 1 then 2 while session B locked 2 then 1, each could end up
-- waiting for the other forever. When everybody locks lowest id first,
-- that circle cannot form.
-- ---------------------------------------------------------------------
CREATE FUNCTION fn_place_order(
    p_customer_id  integer,
    p_session_id   bigint,
    p_items        jsonb
)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = shop, pg_temp
AS $$
DECLARE
    v_order_id  bigint;
    v_problem   text;
    v_subtotal  numeric(12,2);
    v_tax       numeric(12,2);
BEGIN
    -- 1. Customer and cart ------------------------------------------------
    IF NOT EXISTS (SELECT 1 FROM customers c WHERE c.customer_id = p_customer_id) THEN
        RAISE EXCEPTION 'Customer % does not exist', p_customer_id
              USING ERRCODE = 'OD001';
    END IF;

    SELECT string_agg(i.sku, ', ' ORDER BY i.sku)
    INTO   v_problem
    FROM   fn_normalise_items(p_items) i
    LEFT   JOIN products p ON p.sku = i.sku AND p.is_active
    WHERE  p.product_id IS NULL;

    IF v_problem IS NOT NULL THEN
        RAISE EXCEPTION 'Unknown or inactive product: %', v_problem
              USING ERRCODE = 'OD002';
    END IF;

    -- 2. Lock the product rows in a fixed order ---------------------------
    PERFORM 1
    FROM   products p
    WHERE  p.sku IN (SELECT i.sku FROM fn_normalise_items(p_items) i)
    ORDER  BY p.product_id
    FOR UPDATE;

    -- 3. Stock check, now that nobody else can change these rows ----------
    SELECT string_agg(format('%s (wanted %s, have %s)', p.sku, i.quantity, p.stock_qty),
                      '; ' ORDER BY p.sku)
    INTO   v_problem
    FROM   fn_normalise_items(p_items) i
    JOIN   products p ON p.sku = i.sku
    WHERE  p.stock_qty < i.quantity;

    IF v_problem IS NOT NULL THEN
        RAISE EXCEPTION 'Not enough stock: %', v_problem
              USING ERRCODE = 'OD003';
    END IF;

    -- 4. Write the order --------------------------------------------------
    INSERT INTO orders (customer_id, session_id)
    VALUES (p_customer_id, p_session_id)
    RETURNING order_id INTO v_order_id;

    INSERT INTO order_lines (order_id, line_no, product_id, quantity, unit_price)
    SELECT v_order_id,
           row_number() OVER (ORDER BY i.sku),
           p.product_id,
           i.quantity,
           p.unit_price          -- price is copied, so later price changes
    FROM   fn_normalise_items(p_items) i   -- do not alter old orders
    JOIN   products p ON p.sku = i.sku;

    -- Reduce stock and write the ledger rows in a single statement.
    WITH changed AS (
        UPDATE products p
        SET    stock_qty = p.stock_qty - i.quantity
        FROM   fn_normalise_items(p_items) i
        WHERE  p.sku = i.sku
        RETURNING p.product_id, i.quantity, p.stock_qty
    )
    INSERT INTO stock_movements (product_id, delta, reason, qty_after, order_id, session_id)
    SELECT c.product_id, -c.quantity, 'SALE', c.stock_qty, v_order_id, p_session_id
    FROM   changed c;

    -- 5. Totals -----------------------------------------------------------
    SELECT sum(l.line_total) INTO v_subtotal
    FROM   order_lines l WHERE l.order_id = v_order_id;

    v_tax := fn_tax_on(v_subtotal);

    UPDATE orders o
    SET    subtotal   = v_subtotal,
           tax_amount = v_tax,
           total      = v_subtotal + v_tax
    WHERE  o.order_id = v_order_id;

    RETURN v_order_id;
END;
$$;

-- ---------------------------------------------------------------------
-- fn_cancel_order
-- Puts the stock back and marks the order cancelled. The order row is
-- locked first so two operators cannot cancel the same order twice and
-- return the stock twice.
-- ---------------------------------------------------------------------
CREATE FUNCTION fn_cancel_order(p_order_id bigint, p_session_id bigint)
RETURNS void
LANGUAGE plpgsql
SET search_path = shop, pg_temp
AS $$
DECLARE
    v_status text;
BEGIN
    SELECT o.status INTO v_status
    FROM   orders o
    WHERE  o.order_id = p_order_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Order % does not exist', p_order_id
              USING ERRCODE = 'OD006';
    END IF;

    IF v_status NOT IN ('PLACED', 'PAID') THEN
        RAISE EXCEPTION 'Order % is % and cannot be cancelled', p_order_id, v_status
              USING ERRCODE = 'OD005';
    END IF;

    -- Same rule as fn_place_order: product rows are locked lowest id first.
    PERFORM 1
    FROM   products p
    WHERE  p.product_id IN (SELECT l.product_id FROM order_lines l
                            WHERE  l.order_id = p_order_id)
    ORDER  BY p.product_id
    FOR UPDATE;

    WITH changed AS (
        UPDATE products p
        SET    stock_qty = p.stock_qty + l.quantity
        FROM   order_lines l
        WHERE  l.order_id = p_order_id
        AND    l.product_id = p.product_id
        RETURNING p.product_id, l.quantity, p.stock_qty
    )
    INSERT INTO stock_movements (product_id, delta, reason, qty_after, order_id, session_id)
    SELECT c.product_id, c.quantity, 'CANCEL', c.stock_qty, p_order_id, p_session_id
    FROM   changed c;

    UPDATE orders o
    SET    status = 'CANCELLED', cancelled_at = now()
    WHERE  o.order_id = p_order_id;
END;
$$;

-- ---------------------------------------------------------------------
-- fn_advance_order
-- Moves an order one step forward: PLACED -> PAID -> SHIPPED.
-- Returns the new status.
-- ---------------------------------------------------------------------
CREATE FUNCTION fn_advance_order(p_order_id bigint)
RETURNS text
LANGUAGE plpgsql
SET search_path = shop, pg_temp
AS $$
DECLARE
    v_status text;
    v_next   text;
BEGIN
    SELECT o.status INTO v_status
    FROM   orders o
    WHERE  o.order_id = p_order_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Order % does not exist', p_order_id
              USING ERRCODE = 'OD006';
    END IF;

    v_next := CASE v_status WHEN 'PLACED' THEN 'PAID'
                            WHEN 'PAID'   THEN 'SHIPPED' END;

    IF v_next IS NULL THEN
        RAISE EXCEPTION 'Order % is % and cannot move forward', p_order_id, v_status
              USING ERRCODE = 'OD005';
    END IF;

    UPDATE orders o SET status = v_next WHERE o.order_id = p_order_id;
    RETURN v_next;
END;
$$;

-- ---------------------------------------------------------------------
-- fn_adjust_stock
-- Stock received from a supplier (RECEIVE) or a correction after a
-- count (ADJUST). Returns the new stock figure.
-- ---------------------------------------------------------------------
CREATE FUNCTION fn_adjust_stock(
    p_sku         text,
    p_delta       integer,
    p_reason      text,
    p_session_id  bigint,
    p_note        text DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
SET search_path = shop, pg_temp
AS $$
DECLARE
    v_product_id  integer;
    v_current     integer;
    v_new         integer;
BEGIN
    IF p_reason NOT IN ('RECEIVE', 'ADJUST') THEN
        RAISE EXCEPTION 'Reason must be RECEIVE or ADJUST' USING ERRCODE = 'OD004';
    END IF;

    IF p_delta IS NULL OR p_delta = 0 THEN
        RAISE EXCEPTION 'The change in quantity cannot be zero' USING ERRCODE = 'OD004';
    END IF;

    IF p_reason = 'RECEIVE' AND p_delta < 0 THEN
        RAISE EXCEPTION 'Stock received must be a positive number' USING ERRCODE = 'OD004';
    END IF;

    SELECT p.product_id, p.stock_qty
    INTO   v_product_id, v_current
    FROM   products p
    WHERE  p.sku = upper(btrim(p_sku))
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown product: %', upper(btrim(p_sku))
              USING ERRCODE = 'OD002';
    END IF;

    v_new := v_current + p_delta;

    IF v_new < 0 THEN
        RAISE EXCEPTION 'Not enough stock: % has %, cannot remove %',
                        upper(btrim(p_sku)), v_current, -p_delta
              USING ERRCODE = 'OD003';
    END IF;

    UPDATE products p SET stock_qty = v_new WHERE p.product_id = v_product_id;

    INSERT INTO stock_movements (product_id, delta, reason, qty_after, session_id, note)
    VALUES (v_product_id, p_delta, p_reason, v_new, p_session_id, p_note);

    RETURN v_new;
END;
$$;

-- ---------------------------------------------------------------------
-- Session handling
-- ---------------------------------------------------------------------

-- Registers the calling connection as a session and returns its id.
-- It first tidies up sessions whose connection has gone away without
-- signing off (program crashed, terminal closed, network dropped).
CREATE FUNCTION fn_open_session(p_operator text, p_terminal text)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = shop, pg_temp
AS $$
DECLARE
    v_session_id bigint;
BEGIN
    IF btrim(coalesce(p_operator, '')) = '' THEN
        RAISE EXCEPTION 'Operator name is required' USING ERRCODE = 'OD004';
    END IF;

    UPDATE sessions s
    SET    closed_at = now(), close_reason = 'REAPED'
    WHERE  s.closed_at IS NULL
    AND    NOT EXISTS (SELECT 1 FROM pg_stat_activity a WHERE a.pid = s.backend_pid);

    INSERT INTO sessions (operator, terminal, backend_pid)
    VALUES (btrim(p_operator), coalesce(nullif(btrim(p_terminal), ''), 'unknown'),
            pg_backend_pid())
    RETURNING session_id INTO v_session_id;

    RETURN v_session_id;
END;
$$;

CREATE FUNCTION fn_close_session(p_session_id bigint)
RETURNS void
LANGUAGE sql
SET search_path = shop, pg_temp
AS $$
    UPDATE sessions
    SET    closed_at = now(), close_reason = 'NORMAL'
    WHERE  session_id = p_session_id
    AND    closed_at IS NULL;
$$;

-- ---------------------------------------------------------------------
-- Reporting
-- ---------------------------------------------------------------------

-- Best sellers between two dates, with each product's share of revenue
-- and a running total. Uses window functions: rank(), and sum() OVER.
CREATE FUNCTION fn_sales_summary(p_from date, p_to date)
RETURNS TABLE (
    sales_rank   integer,
    sku          text,
    name         text,
    units        bigint,
    revenue      numeric,
    share_pct    numeric,
    running_pct  numeric
)
LANGUAGE plpgsql
STABLE
SET search_path = shop, pg_temp
AS $$
#variable_conflict use_column
BEGIN
    RETURN QUERY
    WITH sold AS (
        SELECT p.sku, p.name,
               sum(l.quantity)   AS units,
               sum(l.line_total) AS revenue
        FROM   orders o
        JOIN   order_lines l ON l.order_id = o.order_id
        JOIN   products p    ON p.product_id = l.product_id
        WHERE  o.status <> 'CANCELLED'
        AND    o.placed_at >= p_from
        AND    o.placed_at <  p_to + 1      -- include the whole end day
        GROUP  BY p.sku, p.name
    )
    SELECT (rank() OVER (ORDER BY s.revenue DESC))::integer,
           s.sku,
           s.name,
           s.units,
           s.revenue,
           round(100 * s.revenue / sum(s.revenue) OVER (), 1),
           round(100 * sum(s.revenue) OVER (ORDER BY s.revenue DESC, s.sku)
                     / sum(s.revenue) OVER (), 1)
    FROM   sold s
    ORDER  BY s.revenue DESC, s.sku;
END;
$$;

-- Integrity check used by the tests. For every product the ledger must
-- add up to the stock figure. Returns the products where it does not,
-- so an empty result means the books balance.
CREATE FUNCTION fn_stock_discrepancies()
RETURNS TABLE (sku text, stock_qty integer, ledger_total bigint)
LANGUAGE sql
STABLE
SET search_path = shop, pg_temp
AS $$
    SELECT p.sku, p.stock_qty, coalesce(sum(m.delta), 0) AS ledger_total
    FROM   products p
    LEFT   JOIN stock_movements m ON m.product_id = p.product_id
    GROUP  BY p.product_id, p.sku, p.stock_qty
    HAVING p.stock_qty <> coalesce(sum(m.delta), 0)
    ORDER  BY p.sku;
$$;

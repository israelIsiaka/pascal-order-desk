-- =====================================================================
-- 01_schema.sql  --  tables, constraints, indexes, views, triggers
--
-- Run order: 01_schema.sql, 02_procedures.sql, 03_seed.sql
-- The script is safe to re-run: it drops and recreates everything.
-- =====================================================================

DROP SCHEMA IF EXISTS shop CASCADE;
CREATE SCHEMA shop;
SET search_path TO shop;

-- ---------------------------------------------------------------------
-- Settings that would otherwise be hard-coded in the application.
-- ---------------------------------------------------------------------
CREATE TABLE app_settings (
    key    text PRIMARY KEY,
    value  text NOT NULL
);

-- ---------------------------------------------------------------------
-- Customers
-- ---------------------------------------------------------------------
CREATE TABLE customers (
    customer_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email        text        NOT NULL,
    full_name    text        NOT NULL,
    phone        text,
    city         text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT customers_email_format CHECK (email LIKE '%_@_%'),
    CONSTRAINT customers_name_not_blank CHECK (btrim(full_name) <> '')
);

-- Emails are compared without regard to case, so the unique rule is
-- placed on lower(email) and not on the raw column.
CREATE UNIQUE INDEX customers_email_uq ON customers (lower(email));

-- ---------------------------------------------------------------------
-- Catalogue
-- ---------------------------------------------------------------------
CREATE TABLE categories (
    category_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name         text NOT NULL UNIQUE
);

CREATE TABLE products (
    product_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku            text          NOT NULL UNIQUE,
    name           text          NOT NULL,
    category_id    integer       NOT NULL REFERENCES categories,
    unit_price     numeric(12,2) NOT NULL,
    stock_qty      integer       NOT NULL DEFAULT 0,
    reorder_level  integer       NOT NULL DEFAULT 5,
    is_active      boolean       NOT NULL DEFAULT true,
    created_at     timestamptz   NOT NULL DEFAULT now(),
    updated_at     timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT products_price_not_negative CHECK (unit_price >= 0),
    -- The last line of defence against overselling. Even if application
    -- code or a stored procedure had a bug, the database would refuse to
    -- store a negative stock figure.
    CONSTRAINT products_stock_not_negative CHECK (stock_qty >= 0),
    CONSTRAINT products_sku_upper CHECK (sku = upper(sku))
);

CREATE INDEX products_category_idx ON products (category_id);

-- Every price change is recorded by a trigger (see the end of this file).
CREATE TABLE price_history (
    price_history_id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id        integer       NOT NULL REFERENCES products,
    old_price         numeric(12,2) NOT NULL,
    new_price         numeric(12,2) NOT NULL,
    changed_at        timestamptz   NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- Sessions: one row per running copy of the order desk program.
-- backend_pid is the process id of the PostgreSQL server process that
-- serves that session, which lets us tell live sessions from dead ones.
-- ---------------------------------------------------------------------
CREATE TABLE sessions (
    session_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    operator     text        NOT NULL,
    terminal     text        NOT NULL,
    backend_pid  integer     NOT NULL,
    opened_at    timestamptz NOT NULL DEFAULT now(),
    closed_at    timestamptz,
    close_reason text,
    CONSTRAINT sessions_close_reason CHECK
        (close_reason IS NULL OR close_reason IN ('NORMAL', 'REAPED'))
);

CREATE INDEX sessions_open_idx ON sessions (backend_pid) WHERE closed_at IS NULL;

-- ---------------------------------------------------------------------
-- Orders and their lines
-- ---------------------------------------------------------------------
CREATE TABLE orders (
    order_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id   integer       NOT NULL REFERENCES customers,
    session_id    bigint        REFERENCES sessions,
    status        text          NOT NULL DEFAULT 'PLACED',
    subtotal      numeric(12,2) NOT NULL DEFAULT 0,
    tax_amount    numeric(12,2) NOT NULL DEFAULT 0,
    total         numeric(12,2) NOT NULL DEFAULT 0,
    placed_at     timestamptz   NOT NULL DEFAULT now(),
    cancelled_at  timestamptz,
    CONSTRAINT orders_status_valid CHECK
        (status IN ('PLACED', 'PAID', 'SHIPPED', 'CANCELLED')),
    CONSTRAINT orders_total_adds_up CHECK (total = subtotal + tax_amount),
    CONSTRAINT orders_cancelled_has_time CHECK
        ((status = 'CANCELLED') = (cancelled_at IS NOT NULL))
);

-- Customer order history: "this customer's orders, newest first".
CREATE INDEX orders_customer_placed_idx ON orders (customer_id, placed_at DESC);

-- Work queue: "orders still waiting for payment, oldest first".
-- A partial index only stores the rows that match the WHERE clause, so
-- it stays small even when the orders table holds years of history.
CREATE INDEX orders_open_queue_idx ON orders (placed_at) WHERE status = 'PLACED';

-- Reports by date range: "everything sold between two dates".
CREATE INDEX orders_placed_idx ON orders (placed_at);

CREATE TABLE order_lines (
    order_id    bigint        NOT NULL REFERENCES orders ON DELETE CASCADE,
    line_no     integer       NOT NULL,
    product_id  integer       NOT NULL REFERENCES products,
    quantity    integer       NOT NULL,
    unit_price  numeric(12,2) NOT NULL,
    -- Calculated by the database from the two columns above, so it can
    -- never disagree with them.
    line_total  numeric(12,2) GENERATED ALWAYS AS (quantity * unit_price) STORED,
    PRIMARY KEY (order_id, line_no),
    CONSTRAINT order_lines_one_row_per_product UNIQUE (order_id, product_id),
    CONSTRAINT order_lines_quantity_positive CHECK (quantity > 0),
    CONSTRAINT order_lines_price_not_negative CHECK (unit_price >= 0)
);

CREATE INDEX order_lines_product_idx ON order_lines (product_id);

-- ---------------------------------------------------------------------
-- Stock ledger: every change to products.stock_qty writes one row here.
-- Adding up delta for a product gives its current stock, which is how
-- the test suite checks that nothing was lost or double counted.
-- ---------------------------------------------------------------------
CREATE TABLE stock_movements (
    movement_id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id   integer     NOT NULL REFERENCES products,
    delta        integer     NOT NULL,
    reason       text        NOT NULL,
    qty_after    integer     NOT NULL,
    order_id     bigint      REFERENCES orders,
    session_id   bigint      REFERENCES sessions,
    note         text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT stock_movements_reason_valid CHECK
        (reason IN ('OPENING', 'SALE', 'CANCEL', 'RECEIVE', 'ADJUST')),
    CONSTRAINT stock_movements_delta_not_zero CHECK (delta <> 0),
    CONSTRAINT stock_movements_qty_after_ok CHECK (qty_after >= 0)
);

CREATE INDEX stock_movements_product_idx ON stock_movements (product_id, created_at DESC);

-- ---------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------

-- Sessions that are open AND whose database connection is still alive.
CREATE VIEW v_active_sessions AS
SELECT s.session_id,
       s.operator,
       s.terminal,
       s.backend_pid,
       s.opened_at,
       a.state,
       a.wait_event_type,
       (SELECT count(*) FROM orders o WHERE o.session_id = s.session_id) AS orders_placed
FROM   sessions s
JOIN   pg_stat_activity a ON a.pid = s.backend_pid
WHERE  s.closed_at IS NULL;

CREATE VIEW v_low_stock AS
SELECT p.sku, p.name, c.name AS category, p.stock_qty, p.reorder_level
FROM   products p
JOIN   categories c USING (category_id)
WHERE  p.is_active
AND    p.stock_qty <= p.reorder_level;

-- ---------------------------------------------------------------------
-- Trigger: keep updated_at current and record price changes.
-- ---------------------------------------------------------------------
CREATE FUNCTION trg_products_audit() RETURNS trigger
LANGUAGE plpgsql AS
$$
BEGIN
    NEW.updated_at := now();
    IF NEW.unit_price IS DISTINCT FROM OLD.unit_price THEN
        INSERT INTO shop.price_history (product_id, old_price, new_price)
        VALUES (OLD.product_id, OLD.unit_price, NEW.unit_price);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER products_audit
BEFORE UPDATE ON products
FOR EACH ROW EXECUTE FUNCTION trg_products_audit();

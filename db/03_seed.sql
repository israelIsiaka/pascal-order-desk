-- =====================================================================
-- 03_seed.sql  --  a small catalogue and a few customers to work with
-- =====================================================================

SET search_path TO shop;

INSERT INTO app_settings (key, value) VALUES
    ('tax_rate_percent', '20'),
    ('currency',         'GBP'),
    ('shop_name',        'Corner Shop Order Desk');

INSERT INTO categories (name) VALUES
    ('Tea and Coffee'), ('Kitchen'), ('Stationery'), ('Electronics');

INSERT INTO products (sku, name, category_id, unit_price, stock_qty, reorder_level)
SELECT v.sku, v.name, c.category_id, v.price, v.stock, v.reorder
FROM (VALUES
    ('TEA-001', 'English Breakfast Tea 80 bags', 'Tea and Coffee',  4.50, 120, 20),
    ('TEA-002', 'Green Tea 40 bags',             'Tea and Coffee',  3.80,  60, 15),
    ('COF-001', 'Ground Coffee 250g',            'Tea and Coffee',  6.20,  45, 10),
    ('COF-002', 'Coffee Beans 1kg',              'Tea and Coffee', 18.00,   8, 10),
    ('KIT-001', 'Stainless Steel Kettle',        'Kitchen',        24.99,  15,  5),
    ('KIT-002', 'Ceramic Mug',                   'Kitchen',         5.00, 200, 30),
    ('KIT-003', 'Cafetiere 8 cup',               'Kitchen',        16.50,   1,  3),
    ('STA-001', 'A5 Notebook',                   'Stationery',      3.25, 150, 25),
    ('STA-002', 'Ballpoint Pens pack of 10',     'Stationery',      2.10, 300, 50),
    ('STA-003', 'Desk Planner',                  'Stationery',      7.95,   4,  5),
    ('ELE-001', 'USB-C Cable 1m',                'Electronics',     6.99,  80, 15),
    ('ELE-002', 'Wireless Mouse',                'Electronics',    14.50,  25,  5),
    ('ELE-003', 'Power Bank 10000mAh',           'Electronics',    22.00,   0,  5)
) AS v(sku, name, category, price, stock, reorder)
JOIN categories c ON c.name = v.category;

-- Opening stock goes into the ledger too, so that for every product
-- sum(stock_movements.delta) equals products.stock_qty from day one.
INSERT INTO stock_movements (product_id, delta, reason, qty_after, note)
SELECT product_id, stock_qty, 'OPENING', stock_qty, 'Opening balance'
FROM   products
WHERE  stock_qty > 0;

INSERT INTO customers (email, full_name, phone, city) VALUES
    ('ada.obi@example.com',     'Ada Obi',      '0161 555 0101', 'Manchester'),
    ('tom.hughes@example.com',  'Tom Hughes',   '0161 555 0102', 'Salford'),
    ('zainab.bello@example.com','Zainab Bello', '0161 555 0103', 'Bolton'),
    ('li.wei@example.com',      'Li Wei',       '0161 555 0104', 'Stockport'),
    ('maria.silva@example.com', 'Maria Silva',  '0161 555 0105', 'Oldham');

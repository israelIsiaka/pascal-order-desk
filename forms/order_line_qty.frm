# Used with TRANSCEIVE: product details are sent, the quantity is received.
FORM   order_line_qty
TITLE  Quantity

FIELD  product     TEXT   "Product"     OPTIONAL
FIELD  unit_price  MONEY  "Unit price"  OPTIONAL
FIELD  in_stock    INT    "In stock"    OPTIONAL
FIELD  quantity    INT    "Quantity"    REQUIRED  MIN 1  MAX 100000  DEFAULT 1

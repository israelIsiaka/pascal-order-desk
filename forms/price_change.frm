FORM   price_change
TITLE  Change a price
HELP   The old price is kept in the price history automatically.

FIELD  sku        TEXT   "Product SKU"  REQUIRED  UPPER  MAXLEN 20
FIELD  new_price  MONEY  "New price"    REQUIRED

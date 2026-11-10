FORM   stock_adjust
TITLE  Stock adjustment
HELP   RECEIVE adds a delivery. ADJUST corrects a count and may be negative.

FIELD  sku       TEXT    "Product SKU"         REQUIRED  UPPER  MAXLEN 20
FIELD  reason    CHOICE  "Reason"              REQUIRED  VALUES RECEIVE,ADJUST  DEFAULT RECEIVE
FIELD  quantity  INT     "Change in quantity"  REQUIRED  MIN -100000  MAX 100000
FIELD  note      TEXT    "Note"                OPTIONAL  MAXLEN 80

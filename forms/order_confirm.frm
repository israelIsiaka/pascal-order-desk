# Used with TRANSCEIVE: the totals are sent, the answer is received.
FORM   order_confirm
TITLE  Confirm order

FIELD  subtotal  MONEY  "Subtotal"         OPTIONAL
FIELD  tax       MONEY  "Tax"              OPTIONAL
FIELD  total     MONEY  "Total to pay"     OPTIONAL
FIELD  confirm   YESNO  "Place this order" REQUIRED  DEFAULT N

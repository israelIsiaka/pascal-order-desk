FORM   order_action
TITLE  Order action
HELP   ADVANCE moves the order on one step (PLACED, then PAID, then SHIPPED).
HELP   CANCEL returns the goods to stock.

FIELD  action  CHOICE  "Action"  REQUIRED  VALUES NONE,ADVANCE,CANCEL  DEFAULT NONE

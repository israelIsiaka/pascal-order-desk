# The menu text itself is printed by orderdesk.pas. This form only
# collects and range-checks the option number.
FORM   main_menu
TITLE  Main menu

FIELD  option  INT  "Option"  REQUIRED  MIN 0  MAX 12

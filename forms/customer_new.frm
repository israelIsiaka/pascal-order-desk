# Used with TRANSCEIVE: the email is sent for display, the rest is received.
FORM   customer_new
TITLE  New customer
HELP   This email is not on file yet. Enter the customer's details.

FIELD  email      TEXT  "Email"         REQUIRED  MAXLEN 120
FIELD  full_name  TEXT  "Full name"     REQUIRED  MAXLEN 80
FIELD  phone      TEXT  "Phone"         OPTIONAL  MAXLEN 30
FIELD  city       TEXT  "Town or city"  OPTIONAL  MAXLEN 60

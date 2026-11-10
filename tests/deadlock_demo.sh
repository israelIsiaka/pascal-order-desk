#!/bin/sh
# ---------------------------------------------------------------------
# deadlock_demo.sh  --  shows what the lock ordering rule prevents
#
# Two sessions each lock two product rows by hand, in opposite orders:
#
#     session A:  lock TEA-001 ... wait ... lock KIT-002
#     session B:  lock KIT-002 ... wait ... lock TEA-001
#
# Each ends up waiting for a row the other holds. PostgreSQL notices
# the circle after about a second, cancels one of them with the error
# "deadlock detected" (SQLSTATE 40P01), and lets the other finish.
#
# fn_place_order never hits this, because it always locks rows in
# product_id order whatever order the cart lists them in.
# Nothing is changed in the database: both sessions roll back.
# ---------------------------------------------------------------------
cd "$(dirname "$0")/.."

export PGHOST="${PGHOST:-127.0.0.1}"
export PGPORT="${PGPORT:-5432}"
export PGDATABASE="${PGDATABASE:-orderdesk}"
export PGUSER="${PGUSER:-orderdesk}"
export PGPASSWORD="${PGPASSWORD:-orderdesk}"

lock_two() {   # $1 = label, $2 = first SKU, $3 = second SKU
    psql -q -t -v VERBOSITY=verbose <<SQL 2>&1 | sed "s/^/  [$1] /" | grep -v '^  \[.\] *$'
BEGIN;
SELECT 'locked ' || sku FROM shop.products WHERE sku = '$2' FOR UPDATE;
SELECT pg_sleep(1);
SELECT 'locked ' || sku FROM shop.products WHERE sku = '$3' FOR UPDATE;
ROLLBACK;
SQL
}

lock_two A TEA-001 KIT-002 &
lock_two B KIT-002 TEA-001 &
wait

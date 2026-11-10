#!/bin/sh
# ---------------------------------------------------------------------
# run_tests.sh  --  resets the database and runs every test
#
#   1. stored procedure tests        (tests/test_procedures.sql)
#   2. a scripted run of the forms   (tests/session_script.txt)
#   3. parallel session tests        (bin/stress)
#
# Stops at the first failure with a non-zero exit code.
# ---------------------------------------------------------------------
set -e
cd "$(dirname "$0")/.."

export PGHOST="${PGHOST:-127.0.0.1}"
export PGPORT="${PGPORT:-5432}"
export PGDATABASE="${PGDATABASE:-orderdesk}"
export PGUSER="${PGUSER:-orderdesk}"
export PGPASSWORD="${PGPASSWORD:-orderdesk}"
export ORDERDESK_DB="${ORDERDESK_DB:-host=$PGHOST port=$PGPORT dbname=$PGDATABASE user=$PGUSER password=$PGPASSWORD}"

PSQL="psql -v ON_ERROR_STOP=1 -q"
mkdir -p build

reset_db() {
    $PSQL -f db/01_schema.sql 2>/dev/null
    $PSQL -f db/02_procedures.sql
    $PSQL -f db/03_seed.sql
}

echo "== 1. Stored procedure tests"
reset_db
# The checks report through NOTICE messages, which psql writes to the
# error stream. Query output is not needed, so it is thrown away.
if ! $PSQL -f tests/test_procedures.sql >/dev/null 2>build/sql_tests.log; then
    cat build/sql_tests.log
    echo "Stored procedure tests FAILED"
    exit 1
fi
sed -n 's/.*NOTICE:  ok - /   ok  /p' build/sql_tests.log
echo "   $(grep -c 'NOTICE:  ok' build/sql_tests.log) checks passed"

echo "== 2. Scripted forms session"
reset_db
./bin/orderdesk < tests/session_script.txt > build/session_output.txt 2>&1
# Every line of session_expect.txt must appear somewhere in the output.
while IFS= read -r expected; do
    if grep -qF -- "$expected" build/session_output.txt; then
        echo "   ok  $expected"
    else
        echo "   MISSING: $expected"
        echo "Scripted session FAILED (full output in build/session_output.txt)"
        exit 1
    fi
done < tests/session_expect.txt

echo "== 3. Parallel sessions"
reset_db
./bin/stress oversell KIT-003 20
./bin/stress oversell COF-002 30 3
./bin/stress oversell TEA-001 40 2
# Top up every product so the mixed test spends its time placing
# orders and not being refused for lack of stock.
$PSQL -c "SELECT shop.fn_adjust_stock(sku, 5000, 'RECEIVE', NULL, 'test top-up') FROM shop.products" >/dev/null
./bin/stress mixed 12 40

echo
echo "ALL TESTS PASSED"

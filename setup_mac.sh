#!/bin/bash
# ---------------------------------------------------------------------
# setup_mac.sh  --  install what is missing on a Mac, then build and test
#
#   bash setup_mac.sh
#
# Steps: Homebrew packages (Free Pascal, PostgreSQL 16), start the
# database server, create the orderdesk user and database, compile,
# load the schema, run every test. Safe to run more than once.
# ---------------------------------------------------------------------
set -e
cd "$(dirname "$0")"

say() { printf '\n== %s\n' "$1"; }

if ! command -v brew >/dev/null 2>&1; then
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        [ -x "$b" ] && eval "$("$b" shellenv)"
    done
fi
if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew is not installed. Install it from https://brew.sh and run this script again."
    exit 1
fi

if ! xcode-select -p >/dev/null 2>&1; then
    echo "The Xcode command line tools are missing. Run:  xcode-select --install"
    echo "Then run this script again."
    exit 1
fi

say "Installing missing packages"
for pkg in fpc postgresql@16; do
    if brew list "$pkg" >/dev/null 2>&1; then
        echo "   $pkg already installed"
    else
        brew install "$pkg"
    fi
done

# postgresql@16 is not put on the PATH by Homebrew, so add it here.
export PATH="$(brew --prefix postgresql@16)/bin:$PATH"

say "Starting PostgreSQL"
if pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1; then
    echo "   a server is already accepting connections on port 5432"
else
    brew services start postgresql@16
    for i in $(seq 1 30); do
        pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1 && break
        sleep 1
    done
    pg_isready -h 127.0.0.1 -p 5432
fi

say "Creating the orderdesk user and database"
# On a Homebrew install the superuser is your own macOS account.
psql -h 127.0.0.1 -d postgres -v ON_ERROR_STOP=1 -q <<'SQL'
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'orderdesk') THEN
        CREATE ROLE orderdesk LOGIN PASSWORD 'orderdesk';
    END IF;
END
$$;
SELECT 'CREATE DATABASE orderdesk OWNER orderdesk'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'orderdesk') \gexec
SQL

say "Compiling"
make

say "Loading tables, procedures and sample data"
make db

say "Running the tests"
make test

make db >/dev/null 2>&1    # leave a clean sample database behind

cat <<MSG

Everything is set up. To start the order desk:

    cd "$(pwd)"
    export PATH="$(brew --prefix postgresql@16)/bin:\$PATH"
    ./bin/orderdesk

Open a second Terminal window and run it again to see two sessions.
MSG

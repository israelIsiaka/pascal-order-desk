# Pascal order desk

A small shop order system with three parts:

- a terminal program written in Pascal, where an operator fills in forms to look up products, take orders and adjust stock
- a forms manager that keeps screen definitions in separate files and validates what the operator types
- a PostgreSQL database whose stored procedures hold the business rules and keep stock correct when many operators work at once

It was built to practise three skills that often appear together in maintenance roles on older enterprise systems: forms-based terminal applications with many parallel sessions, advanced PostgreSQL, and Pascal on a server (compile, link, debug).

If you are reading the code for the first time, start with [docs/GUIDE.md](docs/GUIDE.md). It explains every file, the reasoning behind the design, and how to check each claim yourself.

## What it does

| Menu option | What happens |
|---|---|
| Product search | Finds products by part of a name or SKU |
| New order | Looks up or creates the customer, builds a cart line by line, shows totals, places the order |
| Order enquiry | Shows an order and lets you move it forward (PLACED, PAID, SHIPPED) or cancel it |
| Orders waiting for payment | Work queue, oldest first |
| Customer order history | A customer's 20 most recent orders |
| Stock adjustment | Records a delivery or a stock count correction |
| Stock ledger | Every change to a product's stock, with who made it |
| Low stock report | Products at or below their reorder level |
| Change a price | Updates a price; a trigger keeps the history |
| Sales summary | Best sellers between two dates with share of revenue |
| Active sessions | Every copy of the program connected right now |
| Integrity check | Confirms each stock figure equals the sum of its ledger |

## How the three skills show up in the code

| Skill | Where to look |
|---|---|
| Forms kept apart from program logic | `forms/*.frm` (definitions), `src/forms.pas` (the manager: enable, send, receive, transceive, disable) |
| Parallel sessions sharing back-end modules | `src/session.pas`, `src/orderapi.pas`, `src/stress.pas`, the `shop.sessions` table and `v_active_sessions` view |
| Complex stored procedures | `db/02_procedures.sql`, especially `fn_place_order` and `fn_cancel_order` |
| Transactional safety | Row locks in a fixed order, all-or-nothing orders, retry on deadlock (`src/orderapi.pas`), CHECK constraints as a backstop |
| Relational schema management | `db/01_schema.sql`: keys, constraints, a generated column, partial and expression indexes, a view, a trigger |
| Query optimisation | `db/optional/91_tuning.sql` and the measured results in `docs/tuning_output.txt` |
| Compiling and linking | `Makefile` (release and debug builds, every flag explained) |
| Run-time debugging | Guide chapter 12: SQL trace, gdb session, range checks, heap trace, lock inspection |

## Quick start on Ubuntu or Debian

```sh
sudo apt-get install fp-compiler fp-units-rtl fp-units-base fp-units-fcl fp-units-db \
                     libpq-dev postgresql postgresql-client make gdb

# one-off: create the database user and database
sudo -u postgres psql -c "CREATE ROLE orderdesk LOGIN PASSWORD 'orderdesk'" \
                      -c "CREATE DATABASE orderdesk OWNER orderdesk"

make          # compile
make db       # create tables, procedures and sample data
make run      # start the order desk
make test     # run every test
```

The password `orderdesk` is a local development default. Change it, and set `ORDERDESK_DB`, for anything that is not your own machine.

## Quick start on a Mac

```sh
bash setup_mac.sh
```

The script installs Free Pascal and PostgreSQL 16 with Homebrew if they are missing, starts the database, creates the `orderdesk` user and database, compiles, and runs the tests. It has been written but not yet run on a Mac.

## Quick start with Docker

```sh
docker compose up -d db
docker compose run --rm app
```

Open a second terminal and run the last command again to get a second session. The Docker files have not been run yet (the machine this was built on had no Docker daemon), so treat them as a first draft.

## Tests

`make test` resets the database and runs three groups of tests. This is the result from the last run:

| Group | What it checks | Result |
|---|---|---|
| Stored procedures | 36 checks: totals, refusals, all-or-nothing, cancel, life cycle, constraints, trigger, sessions | 36 passed |
| Scripted forms session | Drives the real program from a text file and checks 12 expected lines | 12 found |
| Oversell, 20 sessions, 1 in stock | Exactly 1 order placed, 19 refused, stock 0 | pass |
| Oversell, 30 sessions wanting 3 each, 8 in stock | Exactly 2 placed, stock 2 | pass |
| Mixed, 12 sessions x 40 random orders | 480 orders, 0 failures, 0 deadlocks, ledger balances | pass |

## Layout

```
Makefile                 build, database and test commands
src/                     Pascal source
  orderdesk.pas            main program: menu loop
  dbconn.pas               PostgreSQL access (wraps libpq)
  screen.pas               terminal input and output, tables
  forms.pas                forms manager
  session.pas              session sign-on and sign-off
  orderapi.pas             order back end shared by all front ends
  report.pas               query to on-screen table
  mod_products.pas         catalogue screens
  mod_orders.pas           order screens
  mod_stock.pas            stock screens
  mod_admin.pas            reports and monitoring
  stress.pas               parallel session test program
forms/                   one .frm file per form
db/                      schema, procedures, sample data
  optional/                bulk data and query tuning scripts
tests/                   SQL tests, scripted session, test runner, deadlock demo
examples/                small program showing run-time range checking
docs/GUIDE.md            the full walkthrough
```

## What this is not

It runs on Linux with Free Pascal. DEC Forms and VSI Pascal exist only on OpenVMS, and nothing here uses them. The design follows the same ideas (form definitions outside the program, a forms manager with send and receive requests, one session per terminal, shared back-end routines), and chapter 15 of the guide lists what carries over to OpenVMS and what does not.

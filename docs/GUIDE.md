# Guide to the Pascal order desk

This guide walks through the whole project: what each file does, why it is written that way, and how to check it yourself. It assumes you can program in some language and have used SQL. It does not assume you know Pascal, PostgreSQL internals or OpenVMS.

Read it with the code open. Every source file has comments at the top and beside the tricky lines, and this guide follows the same order.

## Contents

1. What you are looking at
2. Running it
3. Using it as an operator
4. Pascal, as much as this project needs
5. Compiling and linking
6. The Pascal source, file by file
7. Forms
8. Sessions and parallel execution
9. The database schema
10. The stored procedures
11. Transactions, locks and deadlocks
12. Debugging
13. Query tuning
14. Tests
15. How this relates to DEC Forms and Pascal on OpenVMS
16. Exercises
17. Glossary

## 1. What you are looking at

Picture a shop with several staff taking phone orders. Each sits at a terminal running the same program. They look up products, build an order, and confirm it. Stock is shared, so if two of them try to sell the last kettle at the same moment, exactly one must succeed.

The system has three layers.

```
  operator's terminal
        |
  +-----------------------------+
  | forms manager (forms.pas)   |   reads forms/*.frm, prompts, validates
  +-----------------------------+
  | screens (mod_*.pas)         |   decide which form to show next
  | back end (orderapi.pas)     |   builds the request to the database
  | database access (dbconn.pas)|   sends SQL, turns errors into exceptions
  +-----------------------------+
        |  one connection per running copy = one session
  +-----------------------------+
  | PostgreSQL                  |
  |   stored procedures         |   the business rules
  |   tables and constraints    |   the data and the last line of defence
  +-----------------------------+
```

Two ideas run through all of it.

The first is separation. The form files say what the operator sees. The Pascal screens say what happens in what order. The stored procedures say what is allowed. You can change a field label without recompiling, and you can change a stock rule without touching Pascal.

The second is that correctness under concurrency is the database's job. The Pascal program never reads a stock figure and then decides whether to sell. It asks the database to place the order, and the database checks and updates stock while holding a lock. Chapter 11 explains why the first approach is broken and the second is safe.

## 2. Running it

The README has the install commands. Once the tools are installed:

```sh
make          # compiles bin/orderdesk and bin/stress
make db       # runs db/01_schema.sql, 02_procedures.sql, 03_seed.sql
make run      # starts the program
```

The program finds its database through the `ORDERDESK_DB` environment variable, which holds a libpq connection string. If it is not set, the program uses `host=127.0.0.1 port=5432 dbname=orderdesk user=orderdesk password=orderdesk`.

To see parallel sessions, open two terminals and run `./bin/orderdesk` in each. Sign on with different names, then choose option 11 in either one. Both sessions are listed.

To look at the data directly:

```sh
PGPASSWORD=orderdesk psql -h 127.0.0.1 -U orderdesk orderdesk
orderdesk=> SET search_path TO shop;
orderdesk=> \dt                       -- list tables
orderdesk=> \df                       -- list functions
orderdesk=> SELECT * FROM products;
```

All tables and functions live in a schema called `shop`, which is why the SQL in the Pascal code says `shop.products`.

## 3. Using it as an operator

After signing on you get the menu. Type a number and press Enter. Inside any form, `/c` cancels and returns to the menu. Pressing Enter on an empty line accepts the value shown in square brackets.

This is a real run of option 2, with the menu removed to save space:

```
| NEW ORDER                                                   session 1  Omi |
  Start with the customer's email address. Type /c at any prompt to cancel.
  Customer email: ada.obi@example.com
  Customer: Ada Obi, Manchester

| ADD TO ORDER                                                session 1  Omi |
  Enter a product SKU. Leave it blank when the order is complete.
  Product SKU: tea-001

| QUANTITY                                                    session 1  Omi |
  Product    : English Breakfast Tea 80 bags
  Unit price : 4.50
  In stock   : 120
  Quantity [1]: 2

  Order so far:
  Line  SKU      Product                        Qty  Price  Total  Note
  ----  -------  -----------------------------  ---  -----  -----  ----
     1  TEA-001  English Breakfast Tea 80 bags    2   4.50   9.00

  ...

| CONFIRM ORDER                                               session 1  Omi |
  Subtotal         : 29.00
  Tax              : 5.80
  Total to pay     : 34.80
  Place this order (Y/N) [N]: y

| ORDER 1                                                     session 1  Omi |
  Status    : PLACED
  ...
  Order 1 placed.
```

Things to notice, because each one maps to a piece of code you will read later:

- `tea-001` was accepted in lower case and shown as `TEA-001`. The form file marks that field `UPPER`.
- The quantity screen displayed three values and asked for one. That is a transceive request: the program sends a record and receives another on the same form.
- If you type `abc` for the quantity, the forms manager answers `** Please enter a whole number` and asks again. The order code never sees the bad value.
- Nothing is written to the database until you answer Y. Until then no stock is held.

## 4. Pascal, as much as this project needs

Pascal reads close to English, and it is strict about declaring things before using them. If you know Java or Kotlin, this table covers most of what you will meet.

| Pascal | Java or Kotlin equivalent | Notes |
|---|---|---|
| `program orderdesk;` | the class holding `main` | One per executable |
| `unit dbconn;` | a class or file of static functions | Compiled separately |
| `uses SysUtils, dbconn;` | `import` | |
| `begin ... end` | `{ ... }` | |
| `:=` | `=` | Assignment |
| `=` | `==` | Comparison |
| `<>` | `!=` | |
| `procedure Foo;` | `void foo()` | Returns nothing |
| `function Foo: Integer;` | `int foo()` | Assign to `Result` to return |
| `var X: Integer;` | `int x;` | Declared before `begin`, never in the middle |
| `record ... end` | a class with only public fields | A value, copied on assignment |
| `array of string` | `ArrayList<String>` | Resized with `SetLength` |
| `array[1..5] of Integer` | `int[5]` | Fixed size; you choose the first index |
| `try ... except on E: T do` | `try ... catch (T e)` | |
| `try ... finally` | `try ... finally` | |
| `raise EDbError.Create(...)` | `throw new DbError(...)` | |
| `{ comment }` or `// comment` | `/* */` or `//` | |
| `'text'` | `"text"` | A quote inside a string is doubled: `'it''s'` |

### Programs and units

An executable starts from one `program` file. Everything else lives in `unit` files. A unit has two halves:

```pascal
unit session;

interface                 { what other files may use }

procedure SessionOpen(const OperatorName: string);
function  SessionId: string;

implementation            { how it works; private unless listed above }

var
  CurrentId: string = '';      { visible only inside this unit }

procedure SessionOpen(const OperatorName: string);
begin
  ...
end;

end.
```

The `interface` part is a promise to the rest of the program. The `implementation` part can change freely as long as the promise holds. `CurrentId` above is declared in the implementation, so no other unit can read or change it. They have to call `SessionId`. This is how the project keeps, for example, the raw database connection pointer inside `dbconn.pas` and nowhere else.

### Parameters

You will see three markers on parameters:

- `const S: string` means the routine only reads it.
- `var D: TFormData` means the routine may change the caller's variable. `FormReceive` fills in the caller's record this way.
- `out Line: string` means the routine sets it and ignores whatever was there.

With no marker, the routine gets its own copy.

### Returning a value

A function returns whatever was last assigned to the built-in variable `Result`. `Exit(Value)` returns immediately with that value.

```pascal
function DbIsRetryable(const SqlState: string): Boolean;
begin
  Result := (SqlState = ERR_DEADLOCK) or (SqlState = ERR_SERIALIZATION);
end;
```

### Records and dynamic arrays

A record groups fields. A dynamic array grows with `SetLength`. Indexes of dynamic arrays start at 0, and `High(A)` is the last valid index.

```pascal
type
  TCartLine = record
    Sku: string;
    Quantity: Integer;
  end;
  TCart = array of TCartLine;

procedure CartAdd(var Cart: TCart; const Sku: string; Quantity: Integer);
var
  N: Integer;
begin
  N := Length(Cart);
  SetLength(Cart, N + 1);
  Cart[N].Sku := Sku;
  Cart[N].Quantity := Quantity;
end;
```

### Two kinds of try

`try ... finally` runs the clean-up whether or not an error happened. It is used wherever something must be released:

```pascal
R := DbQuery('SELECT ...', []);
try
  { use R }
finally
  DbFree(R);        { always runs }
end;
```

`try ... except` catches an error so the program can react:

```pascal
try
  OrderId := PlaceOrder(CustomerId, SessionId, Cart);
except
  on E: EDbError do
    if E.SqlState = ERR_NO_STOCK then
      UiError(E.Message)
    else
      raise;        { not ours to handle: pass it up }
end;
```

A bare `raise` inside an `except` block passes the same error on to whoever called this routine.

### The two lines at the top of every file

```pascal
{$mode objfpc}{$H+}
```

These are compiler directives. `{$mode objfpc}` selects the Object Pascal dialect, which gives exceptions, `Result` and dynamic arrays. `{$H+}` makes `string` mean a long string that can hold any length and manages its own memory. Without it, `string` would be limited to 255 characters, which was the original Pascal rule.

## 5. Compiling and linking

Turning source into a running program takes two stages. Knowing which stage failed tells you where to look.

### Stage 1: compiling

The compiler reads one `.pas` file at a time and produces two files for each unit:

- a `.o` object file containing machine code
- a `.ppu` file describing the unit's interface, so other units can be checked against it without re-reading the source

When `orderdesk.pas` says `uses dbconn`, the compiler looks for `dbconn.ppu`. If it is missing or older than `dbconn.pas`, the compiler compiles `dbconn.pas` first. Units therefore get compiled in dependency order automatically.

Compile errors look like this, with file, line and column:

```
mod_orders.pas(238,14) Error: Identifier not found "PlaceOrdr"
```

### Stage 2: linking

The linker joins all the `.o` files into one executable and resolves references between them. It also connects the program to external libraries. `dbconn.pas` uses the unit `postgres3`, which declares functions such as:

```pascal
function PQconnectdb(conninfo: PChar): PPGconn; cdecl; external 'pq' name 'PQconnectdb';
```

That line contains no code. It tells the compiler that a C function called `PQconnectdb` exists in a library called `pq`, and the linker records that the program needs `libpq.so` at run time. You can see the result:

```
$ ldd bin/orderdesk
        libpq.so.5 => /lib/x86_64-linux-gnu/libpq.so.5
        libssl.so.3 => /lib/x86_64-linux-gnu/libssl.so.3
        libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6
        ...
```

Link errors look different from compile errors. They mention symbols and libraries, with no line numbers:

```
/usr/bin/ld: cannot find -lpq
```

That one means the PostgreSQL client library (`libpq-dev`) is not installed. The Pascal source is fine.

### What the Makefile does

`make` runs these two commands:

```
fpc -Mobjfpc -Sh -Fusrc -FEbin -FUbuild -vewn -O2 -Xs src/orderdesk.pas
fpc -Mobjfpc -Sh -Fusrc -FEbin -FUbuild -vewn -O2 -Xs src/stress.pas
```

| Flag | Meaning |
|---|---|
| `-Mobjfpc -Sh` | Same as the `{$mode objfpc}{$H+}` line, set for every file |
| `-Fusrc` | Look for units in `src/` |
| `-FEbin` | Put executables in `bin/` |
| `-FUbuild` | Put `.o` and `.ppu` files in `build/` |
| `-vewn` | Show errors, warnings and notes |
| `-O2` | Optimise |
| `-Xs` | Strip debugging symbols from the executable |

`make debug` swaps the last two for a set of checking flags:

| Flag | Meaning |
|---|---|
| `-g -gl -gw3` | Include debug information; print file and line numbers when the program crashes |
| `-O-` | No optimisation, so stepping in the debugger follows the source line by line |
| `-Cr` | Check every array index and subrange assignment |
| `-Co` | Check integer arithmetic for overflow |
| `-Ct` | Check for stack overflow |
| `-Ci` | Check the result of every file operation |
| `-Sa` | Keep `Assert` calls in the program |
| `-gh` | Report memory that was allocated and never freed |

The release build of `orderdesk` is about 580 kB and the debug build about 1.4 MB. Chapter 12 uses the debug build.

## 6. The Pascal source, file by file

The units form layers. A unit only uses units below it.

```
orderdesk.pas (program)          stress.pas (program)
     |                                |
mod_products  mod_orders  mod_stock  mod_admin
     |             |          |          |
   report      orderapi    session
     |             |          |
   forms        dbconn  <-----+
     |
   screen
```

### dbconn.pas

This is the only file that calls libpq. Everything else goes through its small set of routines.

`DbConnect` opens the connection and stores the pointer in a private variable. It then sets the `search_path` and an application name.

`DbQuery` is the centre of the unit. It takes SQL text containing placeholders (`$1`, `$2`) and an array of values:

```pascal
R := DbQuery('SELECT name, unit_price FROM shop.products WHERE sku = $1', [Sku]);
```

The values are sent to the server separately from the SQL text. The server never parses them as SQL, so nothing an operator types can change the meaning of the statement. Building the string by hand (`'... WHERE sku = ''' + Sku + '''' `) would allow SQL injection, and the project never does that.

When the server reports an error, `DbQuery` extracts three things with `PQresultErrorField`: the five-character SQLSTATE code, the message and the detail. It raises an `EDbError` carrying the code. Callers test the code, never the message text:

```pascal
if E.SqlState = ERR_NO_STOCK then ...
```

Results come back as memory owned by libpq. Whoever calls `DbQuery` must call `DbFree`, and the code always does it in a `finally` block. `DbScalar` and `DbExec` are shortcuts that free the result themselves.

`DbBegin`, `DbCommit` and `DbRollback` send the transaction commands. `DbRollback` checks whether a transaction is open first and swallows any error, because it is called from error handlers that are already dealing with a problem.

`SQL_NULL` is a marker value. Passing it as a parameter sends a real SQL NULL.

### screen.pas

All terminal reading and writing is here. `UiReadLine` reads one line and returns `False` when input has ended. `TTable` and its three routines print aligned tables: `TablePrint` makes one pass to find the widest value in each column and a second to print.

The unit asks the operating system, through `IsATTY`, whether input is a real terminal. If input is a file, it echoes each line it reads so that the output of a scripted run reads like a transcript. This is what makes the scripted test in chapter 14 possible.

### forms.pas

Chapter 7 covers this unit.

### session.pas

`SessionOpen` calls the stored procedure `fn_open_session` and remembers the session number it returns. It then sets the connection's application name to something like `orderdesk#3 Omi`, which a database administrator will see in `pg_stat_activity`. `SessionClose` calls `fn_close_session`. Chapter 8 has the details.

### orderapi.pas

This unit has no screen code. It defines the cart, converts it to JSON, and places the order:

```pascal
for Attempt := 1 to MAX_ATTEMPTS do
begin
  DbBegin;
  try
    Result := DbScalar(
      'SELECT shop.fn_place_order($1::integer, $2::bigint, $3::jsonb)',
      [CustomerId, SessionId, Json]);
    DbCommit;
    Exit;
  except
    on E: EDbError do
    begin
      DbRollback;
      if (not DbIsRetryable(E.SqlState)) or (Attempt = MAX_ATTEMPTS) then
        raise;
      Inc(Retries);
      Sleep(40 * Attempt);
    end;
  end;
end;
```

Read it as: begin a transaction, call the procedure, commit. If the database refuses, roll back. If the refusal was a deadlock or serialization failure, wait briefly and try again, up to four times. Any other refusal goes back to the caller.

Both the forms program and the stress test call `PlaceOrder`. That is the sense in which many sessions and different front ends share one back-end module.

### report.pas

`ShowQuery` runs a query and prints the result as a table. Most screens are one form followed by one `ShowQuery` call.

### mod_products.pas, mod_orders.pas, mod_stock.pas, mod_admin.pas

Each exports one procedure per menu option. They all have the same shape:

```pascal
procedure StockAdjust;
var
  D: TFormData;
begin
  RecordClear(D);
  if not FormReceive('stock_adjust', D) then     { 1. collect a validated record }
    Exit;
  NewQty := DbScalar(                             { 2. ask the database to act }
    'SELECT shop.fn_adjust_stock($1, $2::integer, $3, $4::bigint, $5)',
    [FieldGet(D, 'sku'), FieldGet(D, 'quantity'), ...]);
  UiInfo(FieldGet(D, 'sku') + ' now has ' + NewQty + ' in stock.');   { 3. report }
end;
```

`mod_orders.pas` is the longest because order entry has several steps: `FindOrCreateCustomer`, then `ReceiveLine` in a loop until the operator leaves the SKU blank, then the confirmation, then `PlaceOrder`.

One detail in `FindOrCreateCustomer` is worth reading closely. It looks the customer up, and if there is none it inserts one. Between the lookup and the insert, another session could insert the same email. The unique index on `lower(email)` rejects the second insert. The code catches SQLSTATE `23505` and reads the row that now exists, which is simpler than taking a lock for something that rarely happens.

### orderdesk.pas

The main program. The menu is a constant table of captions and procedure addresses:

```pascal
MENU: array[1..12] of TMenuItem = (
  (Caption: 'Product search';  Run: @ProductSearch),
  (Caption: 'New order';       Run: @OrderEntry),
  ...
```

`@ProductSearch` is the address of the procedure, and `MENU[Option].Run()` calls whichever one the operator chose. Adding a screen means writing a procedure and adding one line to the table.

The main loop wraps each screen in `try ... except`. A database error is rolled back, translated by `ReportDbError` into a message for the operator, and the loop continues. The program body wraps everything in `try ... finally` so that the session is closed and the connection released however the loop ends.

### stress.pas

Chapter 8 and chapter 14 cover this program.

## 7. Forms

### The form files

Each form is a text file in `forms/`. This is `forms/stock_adjust.frm`:

```
FORM   stock_adjust
TITLE  Stock adjustment
HELP   RECEIVE adds a delivery. ADJUST corrects a count and may be negative.

FIELD  sku       TEXT    "Product SKU"         REQUIRED  UPPER  MAXLEN 20
FIELD  reason    CHOICE  "Reason"              REQUIRED  VALUES RECEIVE,ADJUST  DEFAULT RECEIVE
FIELD  quantity  INT     "Change in quantity"  REQUIRED  MIN -100000  MAX 100000
FIELD  note      TEXT    "Note"                OPTIONAL  MAXLEN 80
```

A `FIELD` line has a name, a type, a label, and options.

| Type | Accepts | Stored as |
|---|---|---|
| `TEXT` | anything, up to `MAXLEN` | the text, upper-cased if `UPPER` |
| `INT` | a whole number between `MIN` and `MAX` | digits |
| `MONEY` | digits with at most two decimal places | the text as typed |
| `YESNO` | y, yes, n, no in any case | `Y` or `N` |
| `DATE` | a real calendar date as YYYY-MM-DD | the text |
| `CHOICE` | one of `VALUES`, or its first letter | the full word |

Try editing a file. Change `MAXLEN 20` to `MAXLEN 5` in `stock_adjust.frm`, run the program again without recompiling, and a six-character SKU is refused.

### The requests

The application talks to the forms manager through a record, `TFormData`, which is a list of field names and values. `FieldPut` sets a value and `FieldGet` reads one.

| Request | Purpose |
|---|---|
| `FormsEnable(dir)` | Load every `.frm` file. Called once at start-up. |
| `FormSend(form, rec)` | Display the record. No input. |
| `FormReceive(form, rec)` | Prompt for each field, validate, fill the record. Returns `False` if cancelled. |
| `FormTransceive(form, sent, received)` | Display the fields present in `sent`, prompt for the rest. |
| `FormsDisable` | Release the definitions. Called once at shut-down. |

A transceive in `mod_orders.pas`:

```pascal
RecordClear(Sent);
FieldPut(Sent, 'product',    DbValue(R, 0, 0));
FieldPut(Sent, 'unit_price', DbValue(R, 0, 1));
FieldPut(Sent, 'in_stock',   DbValue(R, 0, 2));

RecordClear(D);
if not FormTransceive('order_line_qty', Sent, D) then
  Exit;
CartAdd(Cart, Sku, StrToInt(FieldGet(D, 'quantity')));
```

By the time `StrToInt` runs, the forms manager has guaranteed that `quantity` is a whole number from 1 to 100000, because `order_line_qty.frm` says `INT ... MIN 1 MAX 100000`. The screen code does not validate again.

### Inside forms.pas

`LoadFormFile` reads a file line by line. `Tokenise` splits each line into words while keeping quoted text together, and `ParseField` turns the words into a `TFormField` record. A mistake in a form file produces an error naming the file and line, for example `forms/x.frm line 5: unknown field type "NUMBER"`.

`ReceiveField` is the loop that asks for one field:

1. Build the prompt from the label, a hint such as `(Y/N)`, and the current value in brackets.
2. Read a line. If input has ended or the operator typed `/c`, return `False`.
3. If the line is empty, use the value in brackets. If there is none and the field is required, complain and ask again.
4. Call `ValidateField`. If it returns a message, show it and ask again. Otherwise store the value.

`ValidateField` dispatches to one small function per type (`CheckInt`, `CheckMoney` and so on). Each returns an empty string for success or the message to show.

### Two kinds of validation

The forms manager checks the shape of the input: is it a number, is it in range, is it one of the allowed words. The database checks the business rules: does this product exist, is there enough stock, may this order be cancelled. A quantity of `-9999` on a stock adjustment passes the form (it is a whole number in range) and is refused by `fn_adjust_stock` with "Not enough stock: KIT-002 has 200, cannot remove 9999".

The split matters because form checks only protect this one program. Rules in the database protect the data from every program, including ones written later by someone else.

### Money never becomes a floating point number

`CheckMoney` validates the text and leaves it as text. The value goes to PostgreSQL as a string and is cast to `numeric(12,2)`, an exact decimal type. All totals and tax are calculated in SQL. Binary floating point cannot represent 0.10 exactly, and programs that add prices as floats eventually produce totals that are a penny out.

## 8. Sessions and parallel execution

### What a session is

Every running copy of `orderdesk` is a separate operating system process with its own connection to PostgreSQL. On the server side, PostgreSQL starts one process of its own for each connection, called a backend. So ten operators means ten `orderdesk` processes and ten backends. They share nothing except the tables.

```
 terminal 1: orderdesk (pid 866) ---- connection ---- backend (pid 867) --+
 terminal 2: orderdesk (pid 901) ---- connection ---- backend (pid 902) --+-- tables
 terminal 3: orderdesk (pid 917) ---- connection ---- backend (pid 918) --+
```

When an operator signs on, `fn_open_session` inserts a row into `shop.sessions` with the operator's name, the terminal name and `pg_backend_pid()`, which is the process id of the backend serving that connection. The function returns the new session number and the program keeps it. Every order and stock movement made afterwards carries that number, which is how the stock ledger can show who did what.

### Sessions that die

A session that signs off normally gets `closed_at` set and `close_reason = 'NORMAL'`. A session can also vanish: the program crashes, someone closes the terminal window, the network drops. Its row would stay open forever.

The fix uses the backend process id. PostgreSQL lists every live backend in the system view `pg_stat_activity`. A session row whose `backend_pid` is no longer in that view belongs to a dead connection. `fn_open_session` closes all such rows with `close_reason = 'REAPED'` each time anyone signs on:

```sql
UPDATE sessions s
SET    closed_at = now(), close_reason = 'REAPED'
WHERE  s.closed_at IS NULL
AND    NOT EXISTS (SELECT 1 FROM pg_stat_activity a WHERE a.pid = s.backend_pid);
```

The view `v_active_sessions` joins `sessions` to `pg_stat_activity`, so menu option 11 only ever shows sessions that are truly connected, even before a dead one has been reaped.

You can watch this happen. Start the program, sign on, and from another terminal run `kill -9` on its process. Then start a new copy, sign on, and look at `SELECT * FROM shop.sessions`. The killed session is marked REAPED.

Locks held by a dead session are released by PostgreSQL itself. When a backend exits, its open transaction is rolled back and its locks go with it. A crashed terminal cannot leave a product row locked.

### stress.pas: many sessions on purpose

A person cannot press Enter in twenty terminals at the same instant, so `stress.pas` does it. For the oversell test it:

1. Connects, reads the stock of the chosen product, and disconnects.
2. Picks a start time 1.5 seconds in the future.
3. Calls `FpFork` once per session. Fork makes a copy of the running process. In the copy (the child) `FpFork` returns 0, and in the original (the parent) it returns the child's process id.
4. Each child connects, opens a session, builds a one-line cart, sleeps until the start time, and calls `PlaceOrder`. It exits with code 0 if the order was placed, 3 if it was refused for lack of stock, and 1 for anything else.
5. The parent waits for every child with `FpWaitPid`, counts the exit codes, reconnects, and compares stock and ledger with what arithmetic says they must be.

Two details are easy to get wrong.

The parent disconnects before forking. A forked child inherits the parent's open files and sockets. If the parent's database connection were open, every child would hold the same socket, and their messages to the server would interleave into garbage.

The parent calls `Flush(Output)` before forking. Text written with `WriteLn` can sit in a buffer inside the process. A fork copies that buffer, and each child would print it again when it exits.

## 9. The database schema

`db/01_schema.sql` creates everything in the `shop` schema.

```
categories 1---* products 1---* order_lines *---1 orders *---1 customers
                    |                              |
                    +---* stock_movements *--------+   (order_id optional)
                    |            |
                    +---* price_history
                                 |
sessions 1---* orders,  sessions 1---* stock_movements
```

### customers

`email` has a CHECK that it contains an `@` with something on both sides. The uniqueness rule is an index on `lower(email)`, which is called an expression index. It makes `Ada@x.com` and `ada@x.com` the same customer. A plain `UNIQUE (email)` would treat them as two.

### products

Three CHECK constraints: price not negative, SKU in upper case, and

```sql
CONSTRAINT products_stock_not_negative CHECK (stock_qty >= 0)
```

This one is the backstop for the whole system. The stored procedures are written so that stock never goes negative. If one of them had a bug, or someone ran an `UPDATE` by hand, the database would still refuse to store a negative figure. The check named "CHECK constraint blocks negative stock even on a direct UPDATE" in `tests/test_procedures.sql` proves it by trying.

### orders

`status` is limited to four words by a CHECK. Two more CHECKs tie columns together:

```sql
CONSTRAINT orders_total_adds_up     CHECK (total = subtotal + tax_amount),
CONSTRAINT orders_cancelled_has_time CHECK ((status = 'CANCELLED') = (cancelled_at IS NOT NULL))
```

The second reads: an order is cancelled exactly when it has a cancellation time. It is impossible to store a cancelled order without a time, or a time on an order that is not cancelled.

The table has three indexes besides the primary key. Chapter 13 measures each one.

```sql
CREATE INDEX orders_customer_placed_idx ON orders (customer_id, placed_at DESC);
CREATE INDEX orders_open_queue_idx      ON orders (placed_at) WHERE status = 'PLACED';
CREATE INDEX orders_placed_idx          ON orders (placed_at);
```

The middle one is a partial index. It only contains rows where the status is PLACED.

### order_lines

The primary key is the pair `(order_id, line_no)`. `ON DELETE CASCADE` on the order reference means deleting an order deletes its lines.

```sql
line_total numeric(12,2) GENERATED ALWAYS AS (quantity * unit_price) STORED
```

A generated column is calculated by the database whenever the row is written. Nobody can insert a line total that disagrees with quantity times price.

`unit_price` is copied from the product when the order is placed. If the product's price changes next week, old orders keep the price they were sold at.

### stock_movements

Every change to `products.stock_qty` adds one row here: the product, the change (`delta`, positive or negative), the reason, and the stock figure afterwards. For any product, adding up `delta` must give the current `stock_qty`. The function `fn_stock_discrepancies` returns the products where it does not, and the tests require that list to be empty after every scenario.

### The trigger

`trg_products_audit` runs before every update of a product row. It sets `updated_at`, and if the price changed it inserts the old and new price into `price_history`. `IS DISTINCT FROM` is used for the comparison because it treats NULL sensibly, where `<>` would not.

A trigger is used here because the rule is "whenever a price changes, by any route". Putting it in a function would only cover callers of that function.

## 10. The stored procedures

`db/02_procedures.sql`. In PostgreSQL these are written as functions in the PL/pgSQL language and called with `SELECT`.

### Error codes

When a function refuses a request it raises an error with a custom SQLSTATE:

```sql
RAISE EXCEPTION 'Not enough stock: %', v_problem USING ERRCODE = 'OD003';
```

| Code | Meaning |
|---|---|
| OD001 | Customer does not exist |
| OD002 | Product does not exist or is not on sale |
| OD003 | Not enough stock |
| OD004 | Input is malformed |
| OD005 | The order's status does not allow this |
| OD006 | Order does not exist |

`dbconn.pas` has a constant for each. The Pascal code branches on the code and shows the message, so wording can change in SQL without breaking the program.

### fn_normalise_items

Input: the cart as JSON, such as `[{"sku":"tea-001","qty":2},{"sku":"TEA-001","qty":1}]`.
Output: rows of `(sku, quantity)`, upper-cased, one row per SKU with quantities added up. Here that is one row, `TEA-001, 3`.

It first loops over the elements and raises OD004 for anything that is not an object with a text `sku` and a whole-number `qty` from 1 to 100000. The checks are done one element at a time with `IF`, in a fixed order, so that a bad value is reported before any cast to a number is attempted.

Merging repeated SKUs matters for locking. Each product appears once, so each product row is locked and updated once.

### fn_price_cart and fn_cart_totals

Read-only previews for the screen. `fn_price_cart` joins the cart to the products and adds a `problem` column ("unknown SKU", "only 1 in stock"). `fn_cart_totals` adds the lines up and calls `fn_tax_on`.

Neither takes a lock. The figures can be out of date a second later, and that is acceptable for a preview because `fn_place_order` checks again properly.

`fn_tax_on` is the single place tax is calculated. Both the preview and the real order call it, so they always agree. One of the SQL tests compares the two.

### fn_place_order

This is the most important function in the project. Its steps, with the SQL for the two that matter most:

1. Check that the customer exists (OD001) and that every SKU is a product on sale (OD002).
2. Lock the product rows:

   ```sql
   PERFORM 1
   FROM   products p
   WHERE  p.sku IN (SELECT i.sku FROM fn_normalise_items(p_items) i)
   ORDER  BY p.product_id
   FOR UPDATE;
   ```

   `PERFORM` is PL/pgSQL for "run this query and throw the rows away". The point is the side effect of `FOR UPDATE`, which locks each row returned.

3. Check stock, now that the rows are locked. If any line wants more than there is, raise OD003 listing every short product.
4. Insert the order row and the lines. Then reduce stock and write the ledger in one statement:

   ```sql
   WITH changed AS (
       UPDATE products p
       SET    stock_qty = p.stock_qty - i.quantity
       FROM   fn_normalise_items(p_items) i
       WHERE  p.sku = i.sku
       RETURNING p.product_id, i.quantity, p.stock_qty
   )
   INSERT INTO stock_movements (product_id, delta, reason, qty_after, order_id, session_id)
   SELECT c.product_id, -c.quantity, 'SALE', c.stock_qty, v_order_id, p_session_id
   FROM   changed c;
   ```

   `UPDATE ... RETURNING` hands back the rows it changed, including the new stock figure. Wrapping it in `WITH` lets the `INSERT` use those rows. The ledger row is therefore built from the very values the update produced.

5. Add up the lines, calculate tax, and store the totals on the order.

If any step raises an error, everything the function did is undone. Chapter 11 explains the mechanism.

### fn_cancel_order

Locks the order row first, with `SELECT ... FOR UPDATE`. If two operators cancel the same order at once, the second waits, then sees status CANCELLED and gets OD005. Without that lock both could read PAID and both would return the stock.

Then it locks the product rows in `product_id` order, adds the quantities back, writes CANCEL rows to the ledger, and sets the status and `cancelled_at`.

### fn_advance_order

Locks the order row and moves it one step: PLACED to PAID, PAID to SHIPPED. Any other starting status raises OD005.

### fn_adjust_stock

For deliveries and corrections. It locks the product row, works out the new figure, raises OD003 if it would be negative, updates, and writes a ledger row.

### fn_open_session, fn_close_session

Covered in chapter 8.

### fn_sales_summary

Shows window functions. The inner query totals units and revenue per product. The outer query adds three columns without collapsing the rows:

```sql
rank() OVER (ORDER BY s.revenue DESC)                          -- position
round(100 * s.revenue / sum(s.revenue) OVER (), 1)             -- share of the total
round(100 * sum(s.revenue) OVER (ORDER BY s.revenue DESC, s.sku)
          / sum(s.revenue) OVER (), 1)                         -- running share
```

`sum(...) OVER ()` is the total across all rows, repeated on each row. `sum(...) OVER (ORDER BY ...)` is the total of this row and all rows before it.

### Three lines that appear on most functions

```sql
LANGUAGE plpgsql
STABLE
SET search_path = shop, pg_temp
```

`STABLE` is a promise that the function only reads data. It is on the preview and report functions and absent from the ones that write.

`SET search_path` pins which schema unqualified table names refer to while the function runs, whatever the caller's setting is.

`#variable_conflict use_column`, at the top of two function bodies, settles a naming clash. Those functions return a column called `sku` and also read a table column called `sku`. The directive tells PL/pgSQL that a bare `sku` in a query means the table column.

## 11. Transactions, locks and deadlocks

### Transactions

A transaction is a group of changes that the database treats as one. Either all of them are stored or none are. It starts with `BEGIN` and ends with `COMMIT` (keep everything) or `ROLLBACK` (undo everything). Until the commit, other sessions do not see any of the changes.

A single statement sent on its own is automatically its own transaction. That is why `mod_orders.pas` can call `fn_cancel_order` with no `BEGIN`: the one `SELECT` that runs the function is the transaction, and a function that raises an error undoes all its own work.

`PlaceOrder` in `orderapi.pas` uses an explicit `BEGIN` and `COMMIT` anyway. It makes the boundary visible in the code and gives the retry loop a clear unit to repeat.

One of the checks in `tests/test_procedures.sql` tests all-or-nothing directly. It places an order for 5 tea (plenty in stock) and 99 cafetieres (1 in stock). The order must be refused, the tea stock must be unchanged, and the number of orders must be unchanged.

### The problem locking solves

Suppose one cafetiere is left and two operators confirm an order for it at the same moment. Without locking, this can happen:

```
 time   session A                          session B
 ----   -------------------------------    -------------------------------
  1     read stock of KIT-003: 1
  2                                        read stock of KIT-003: 1
  3     1 >= 1, so go ahead
  4                                        1 >= 1, so go ahead
  5     write stock = 0, insert order
  6                                        write stock = 0, insert order
```

Two orders, one cafetiere. Each session did a check and then acted on it, and the fact it checked stopped being true in between.

### What FOR UPDATE does

`SELECT ... FOR UPDATE` locks the rows it reads until the transaction ends. Another transaction that tries to lock or change the same rows waits.

```
 time   session A                          session B
 ----   -------------------------------    -------------------------------
  1     lock KIT-003 row
  2                                        try to lock KIT-003 row: WAIT
  3     read stock: 1, enough
  4     write stock = 0, insert order
  5     COMMIT (lock released)
  6                                        lock acquired
  7                                        read stock: 0, not enough
  8                                        raise OD003, ROLLBACK
```

At step 7, session B sees 0. PostgreSQL's default isolation level is READ COMMITTED, under which each statement sees everything committed before that statement began. B's stock check is a new statement that starts after A's commit, so it sees A's change.

You can watch a session wait. This was captured while one session held a lock on KIT-003 and another called `fn_place_order` for it:

```
 pid  |    app    | state  | wait_type |  wait_event   | blocked_by |          query
------+-----------+--------+-----------+---------------+------------+--------------------------
 1601 | session A | active | Timeout   | PgSleep       | {}         | SELECT pg_sleep(3)
 1605 | session B | active | Lock      | transactionid | {1601}     | SELECT shop.fn_place_order(...
```

Session B is waiting on a lock, and `pg_blocking_pids` names process 1601 as the one holding it. The query that produced this is in chapter 12.

### Deadlocks and the fixed lock order

Locks create a new risk. Suppose session A's cart is tea then mugs, and session B's is mugs then tea, and each locks rows in cart order:

```
 A locks TEA-001          B locks KIT-002
 A wants KIT-002: WAIT    B wants TEA-001: WAIT
```

Each waits for the other and neither can ever continue. This is a deadlock. PostgreSQL checks for such circles after a lock wait has lasted about a second, picks one transaction, and cancels it with SQLSTATE `40P01`.

`tests/deadlock_demo.sh` creates exactly this situation with two hand-written transactions. Its real output:

```
  [B]  locked KIT-002
  [B] ERROR:  40P01: deadlock detected
  [B] DETAIL:  Process 1416 waits for ShareLock on transaction 2679; blocked by process 1417.
  [B] Process 1417 waits for ShareLock on transaction 2678; blocked by process 1416.
  [A]  locked TEA-001
  [A]  locked KIT-002
```

The cure is to make every transaction lock rows in the same order. `fn_place_order` and `fn_cancel_order` both use `ORDER BY p.product_id` on their locking query. With that rule, A and B both go for the lower product id first. One gets it, the other waits there, holding nothing the first one needs, and no circle can form.

The mixed stress test is the evidence. Twelve sessions each place 40 orders of two to four random products in random cart order, 480 orders in total, and the retry counter stays at zero for every worker. With the `ORDER BY` line removed from `fn_place_order`, the same test showed retries in 11 or 12 of the 12 workers on each run.

### Why there is still a retry loop

The lock order rule covers the code in this project. A real system gains other code over time: a nightly report, a manual fix by an administrator, a new feature that locks things in a different order. Any of those could cause a deadlock with order placement. A deadlock error means the request was fine and should be run again, so `PlaceOrder` retries on `40P01` and `40001` and passes every other error up. In the experiment above with the `ORDER BY` removed, the retry loop recovered every time and all 480 orders were stored.

### Three layers of protection

1. The stored procedure checks stock under a lock.
2. The CHECK constraint refuses negative stock whatever code asked.
3. The ledger makes any error visible afterwards, because stock and ledger would stop agreeing.

## 12. Debugging

### See every SQL statement

Set `ORDERDESK_TRACE=1` and `dbconn.pas` writes each statement and its parameters to the error stream before running it. Send that stream to a file to keep the screen clean:

```
$ ORDERDESK_TRACE=1 ./bin/orderdesk 2> trace.log
```

From a real run, signing on and placing one order:

```
[sql 13:40:07.194] SELECT shop.fn_open_session($1, $2)  $1='Omi'  $2='batch-1594'
[sql 13:40:07.198] SELECT set_config('application_name', $1, false)  $1='orderdesk#1 Omi'
[sql 13:40:07.203] BEGIN
[sql 13:40:07.203] SELECT shop.fn_place_order($1::integer, $2::bigint, $3::jsonb)  $1='1'  $2='1'  $3='[{"sku":"TEA-001","qty":2}]'
[sql 13:40:07.207] COMMIT
```

You can copy a statement from the trace, substitute the parameters, and run it in `psql` to reproduce a problem without the program.

### Step through the program with gdb

Build with `make debug`, then:

```
$ gdb ./bin/orderdesk
(gdb) break orderapi.pas:108
(gdb) run
```

Use the program normally. When it reaches the line that calls `fn_place_order`, gdb stops. This is a real session:

```
Breakpoint 1, PlaceOrder (CustomerId=..., SessionId=..., Cart=...) at src/orderapi.pas:108
108	      Result := DbScalar(
(gdb) backtrace
#0  PlaceOrder (CustomerId=..., SessionId=..., Cart=...) at src/orderapi.pas:108
#1  0x0000000000462cab in OrderEntry () at src/mod_orders.pas:238
#2  0x0000000000401968 in MainLoop () at src/orderdesk.pas:118
#3  0x0000000000401b24 in $main () at src/orderdesk.pas:143
(gdb) info locals
Attempt = 1
Json = '[{"sku":"TEA-001","qty":2}]'
(gdb) print CustomerId
$3 = '1'
```

The backtrace reads from the bottom up: the main program called `MainLoop`, which called `OrderEntry`, which called `PlaceOrder`. The line numbers will differ if the source has been edited since.

| gdb command | What it does |
|---|---|
| `break file.pas:N` | Stop when line N is reached |
| `run` | Start the program |
| `backtrace` or `bt` | Show the chain of calls that led here |
| `info locals` | Show local variables |
| `print X` | Show one variable |
| `next` | Run the current line, stepping over calls |
| `step` | Run the current line, stepping into calls |
| `finish` | Run until the current routine returns |
| `continue` | Run until the next breakpoint |
| `quit` | Leave gdb |

### Let the compiler catch bugs at run time

`examples/rangecheck.pas` has an off-by-one loop that writes to slot 6 of a 5-slot array. In memory the next field after the array is `Total`.

Compiled without checks, the program runs to the end and prints a wrong answer:

```
Total is 0 (it was set to 1000 and nothing meant to change it)
```

Compiled with `-g -gl -Cr`, it stops at the faulty line:

```
Runtime error 201 at $00000000004010E4
  $00000000004010E4  main,  line 34 of examples/rangecheck.pas
```

Runtime error 201 is a range check failure. The first version is the dangerous one, because the damage shows up somewhere else and later. This is the reason the debug build turns on `-Cr`, `-Co` and `-Ct`.

Some other runtime error numbers you may meet:

| Number | Meaning |
|---|---|
| 200 | Division by zero |
| 201 | Range check error |
| 202 | Stack overflow |
| 203 | Out of heap memory |
| 215 | Arithmetic overflow |
| 216 | Access violation (bad pointer, often a nil one) |
| 217 | Unhandled exception |

### Check for memory leaks

The `-gh` flag in the debug build links in a unit called heaptrc. When the program exits it reports every block of memory that was allocated and not freed. By default the report goes to the error stream; set `HEAPTRC="log=heap.log"` to send it to a file. From a real run of the debug build:

```
1442 memory blocks allocated : 170798/182944
1442 memory blocks freed     : 170798/182944
0 unfreed memory blocks : 0
```

heaptrc tracks memory allocated by Pascal code. Query results are allocated inside libpq, which is C, so heaptrc cannot see a forgotten `DbFree`. The code guards against that by putting every `DbFree` in a `finally` block.

### Debugging on the database side

See who is connected and who is waiting for whom:

```sql
SELECT a.pid, a.application_name AS app, a.state,
       a.wait_event_type AS wait_type, a.wait_event,
       pg_blocking_pids(a.pid) AS blocked_by,
       left(a.query, 45) AS query
FROM   pg_stat_activity a
WHERE  a.datname = current_database()
ORDER  BY a.pid;
```

A row with `wait_type = Lock` is stuck behind the processes in `blocked_by`. The application name set by `session.pas` tells you which operator each one is.

Print from inside a function while developing it:

```sql
RAISE NOTICE 'after lock: sku=% stock=%', v_sku, v_stock;
```

Notices appear in `psql` and in the server log. They do not interrupt the function.

Call a function by hand to see its exact error:

```
orderdesk=> SELECT shop.fn_place_order(1, NULL, '[{"sku":"KIT-003","qty":3}]');
ERROR:  Not enough stock: KIT-003 (wanted 3, have 1)
CONTEXT:  PL/pgSQL function fn_place_order(integer,bigint,jsonb) line 41 at RAISE
```

The CONTEXT line gives the line number inside the function body.

### Symptoms and where to look

| Symptom | Likely cause | First step |
|---|---|---|
| `Cannot connect to the database` at start | Server not running, or wrong `ORDERDESK_DB` | `pg_isready -h 127.0.0.1` |
| `relation "shop.products" does not exist` | Schema not loaded | `make db` |
| `No form definitions (*.frm) found` | Program run from an unexpected place | Set `ORDERDESK_FORMS` to the forms directory |
| `x.frm line N: unknown ...` | Typing mistake in a form file | Open the file at that line |
| A screen hangs after confirming | Waiting for another session's lock | Run the `pg_stat_activity` query above |
| `current transaction is aborted` | A statement failed and no rollback followed | Find the missing `DbRollback` |
| `cannot find -lpq` while building | `libpq-dev` not installed | Install it |
| `Runtime error 216` | A nil pointer was used | Run the debug build under gdb and read the backtrace |

## 13. Query tuning

With 13 products and a handful of orders, every query takes a fraction of a millisecond whatever you do. To see the planner make real choices you need volume. `db/optional/90_bulk_load.sql` adds 20,000 customers and 300,000 orders in about twenty seconds. `db/optional/91_tuning.sql` then runs three before-and-after comparisons. The full output from one run is saved in `docs/tuning_output.txt`.

```sh
make db
psql -f db/optional/90_bulk_load.sql
psql -f db/optional/91_tuning.sql
make db        # afterwards, to return to the small data set
```

### Reading EXPLAIN ANALYZE

`EXPLAIN (ANALYZE, BUFFERS)` runs the query and prints the plan as a tree. Read it from the most indented line outwards. The parts that matter most:

- The node type. `Seq Scan` reads the whole table. `Index Scan` and `Bitmap Index Scan` use an index to go straight to matching rows.
- `rows=` in the first bracket is the planner's estimate. `actual rows=` is what happened. A large gap between them means the planner was working from bad statistics.
- `Rows Removed by Filter` counts rows that were read and then thrown away. A large number means wasted work.
- `Buffers: shared hit=N` is the number of 8 kB pages the query touched. This is the most reliable measure of cost, because it does not depend on how busy the machine was.

### Case 1: a customer's recent orders

```sql
SELECT order_id, placed_at, status, total
FROM   orders
WHERE  customer_id = 5006
ORDER  BY placed_at DESC
LIMIT  20;
```

| | Plan | Pages read | Time |
|---|---|---|---|
| No index on `customer_id` | Parallel Seq Scan, 299,988 rows removed by filter | 6,210 | 16.6 ms |
| Index on `(customer_id, placed_at DESC)` | Bitmap Index Scan | 15 | 0.05 ms |

Without the index PostgreSQL reads every order to find this customer's 13. With it, the index leads straight to them. The index puts `customer_id` first because the query filters on it with `=`, and `placed_at` second because the query sorts on it.

### Case 2: the payment queue

```sql
SELECT order_id, placed_at, total
FROM   orders
WHERE  status = 'PLACED'
ORDER  BY placed_at
LIMIT  25;
```

| | Plan | Pages read | Time |
|---|---|---|---|
| Only the full `placed_at` index | Index Scan, 299,217 rows removed by filter | 301,223 | 148 ms |
| Partial index `WHERE status = 'PLACED'` | Index Scan on the partial index | 27 | 0.03 ms |

The "before" plan is a good example of the planner being misled. It reasoned that walking the `placed_at` index from the oldest order and stopping after 25 PLACED rows would be quick. That would be true if PLACED orders were spread evenly through time. They are all recent, so it walked through nearly 300,000 old orders first. The statistics PostgreSQL keeps do not record that status and date are related.

The partial index contains only the PLACED rows, already in date order, so the first 25 entries are the answer. It is also tiny: 48 kB, against 16 MB for the full index on the same column. Only a few hundred of the 300,000 orders are PLACED at any time.

### Case 3: the same question written two ways

Both versions count the orders placed on one day, and both have the `placed_at` index available.

```sql
-- version A
WHERE placed_at::date = current_date - 200

-- version B
WHERE placed_at >= current_date - 200
AND   placed_at <  current_date - 199
```

| | Plan | Pages read | Time |
|---|---|---|---|
| A: column wrapped in a cast | Parallel Seq Scan | 6,136 | 25.6 ms |
| B: bare column compared with a range | Bitmap Index Scan | 382 | 0.43 ms |

An index on `placed_at` is sorted by `placed_at`. Version A asks about `placed_at::date`, a value computed from the column, and the index is not sorted by that. PostgreSQL has to compute it for every row. Version B leaves the column alone and moves the arithmetic to the other side of the comparison, so the index applies. `fn_sales_summary` is written the second way for this reason.

### Habits that follow from these three cases

- Look at pages read, and at rows removed by filter, before looking at time.
- Index the columns you filter on with `=` first, then the column you sort or range on.
- When queries always want the same small subset of a big table, consider a partial index.
- Keep indexed columns bare in `WHERE` clauses. Put functions and casts on the other side.
- After loading or changing a lot of data, run `ANALYZE` so the planner's statistics are current.
- Each index slows down inserts and updates a little and takes space. Add one when a real query needs it.

## 14. Tests

`make test` runs `tests/run_tests.sh`, which resets the database before each group.

### Group 1: stored procedures

`tests/test_procedures.sql` runs 36 checks inside a single transaction and rolls it back at the end, so it leaves no data behind. Two helper functions do the work. `check_true` fails the script unless a condition holds. `expect_error` runs a statement that is supposed to fail and checks that it failed with a specific SQLSTATE.

The checks cover: correct totals; stock reduced; ledger rows written; repeated SKUs merged; each refusal code; eight kinds of malformed cart; all-or-nothing; cancel returns stock; no double cancel; the PLACED, PAID, SHIPPED sequence; stock adjustments; the CHECK constraint and unique index when bypassing the functions; the price trigger; old orders keeping their price; ledger balance; the sales summary leaving out cancelled orders; preview totals equal to real totals; dead sessions being reaped.

### Group 2: a scripted session

`tests/session_script.txt` holds the keystrokes for a full session: sign on, place an order, create a new customer, type a bad quantity, attempt an order that exceeds stock, advance an order, cancel it, attempt an impossible stock adjustment, view reports, sign off. The runner feeds it to the real program and checks that each line of `tests/session_expect.txt` appears in the output.

This tests the compiled program end to end, including the forms manager, without anyone at a keyboard.

### Group 3: parallel sessions

Results from the last run:

```
Oversell test: 20 sessions each ordering 1 x KIT-003 (stock 1)
  orders placed        1   expected   1   ok
  refused, no stock   19   expected  19   ok
  stock afterwards     0   expected   0   ok
  ledger mismatches    0   expected   0   ok

Oversell test: 30 sessions each ordering 3 x COF-002 (stock 8)
  orders placed        2   expected   2   ok
  refused, no stock   28   expected  28   ok
  stock afterwards     2   expected   2   ok

Mixed test: 12 sessions x 40 random multi-product orders
  orders stored      480
  workers failed       0   expected   0   ok
  negative stock       0   expected   0   ok
  ledger mismatches    0   expected   0   ok
```

The second oversell case is the sharper one. Eight in stock and each order wants three, so two orders fit and two units are left over. An implementation that handled "last one" correctly but miscounted partial fits would fail here.

### What is not tested

The Docker files and the GitHub Actions workflow have not been run. The forms manager has no unit tests of its own; it is exercised through the scripted session. There is no test that kills a session mid-transaction, although the reaping logic is tested with a fake dead session.

## 15. How this relates to DEC Forms and Pascal on OpenVMS

This project runs on Linux. If the systems you will work on run on OpenVMS, the ideas transfer and the tools differ. This chapter is written from general knowledge of those products, so check each point against the documentation and conventions at the site.

### Forms

| This project | DEC Forms |
|---|---|
| `.frm` text file per form | Form source written in IFDL (Independent Form Description Language) and translated into a binary form file |
| `FormsEnable` / `FormsDisable` | `FORMS$ENABLE` / `FORMS$DISABLE` |
| `FormSend`, `FormReceive`, `FormTransceive` | `FORMS$SEND`, `FORMS$RECEIVE`, `FORMS$TRANSCEIVE` |
| `TFormData` record of names and values | Records declared in the form and matched to records in the program |
| Field types and options checked in `ValidateField` | Field validation declared in the form and enforced by the Form Manager |
| One line prompt at a time | Full-screen panels with cursor movement, function keys and help text |
| No session id needed, one process one terminal | `FORMS$ENABLE` returns a session identifier that every later request passes back |

The core discipline is the same: the program exchanges records with a form and does not draw the screen itself. DEC Forms does far more than this project's forms manager, including multiple panels per form, layouts for different devices, and procedural responses written inside the form.

### Pascal

| This project (Free Pascal on Linux) | VSI Pascal on OpenVMS |
|---|---|
| `fpc file.pas` compiles and links | `PASCAL file` compiles, `LINK file` links, `RUN file` runs |
| `unit` with `interface` and `implementation`; `uses` | `MODULE`, with `[ENVIRONMENT]` to export declarations and `[INHERIT]` to import them |
| `string` of any length | `VARYING [n] OF CHAR` and fixed `PACKED ARRAY OF CHAR` |
| `-g` and gdb | `PASCAL /DEBUG /NOOPTIMIZE`, `LINK /DEBUG`, then the OpenVMS Debugger |
| `-Cr -Co` run-time checks | `/CHECK` qualifier |
| Exceptions with `try ... except` | Condition handlers (`ESTABLISH`) and status values |
| Shared library `libpq.so` found at run time | Shareable images, named in link options files |
| Environment variables | Logical names |

Standard Pascal syntax (`begin`, `end`, `record`, `procedure`, `function`, `var` parameters, `case`, sets) is the same in both. Code in this project that uses `Result`, dynamic arrays, `try ... finally` or long strings would need rewriting.

### Sessions

On OpenVMS each terminal user typically runs in their own process, much like each `orderdesk` copy here, or under a transaction monitor that manages many users in fewer processes. Either way the problems in chapters 8 and 11 are the same ones: identifying who did what, cleaning up after a session that ended badly, and stopping concurrent sessions from corrupting shared data. The PostgreSQL side of this project (procedures, locks, constraints, `pg_stat_activity`) applies unchanged wherever the client runs.

## 16. Exercises

These are ordered roughly from easiest to hardest. Each one can be checked with the existing tests or by using the program.

1. In `forms/order_line_qty.frm`, change the maximum quantity to 50. Confirm that 51 is refused without recompiling.
2. Add an optional `postcode` field to new customers. You will need a column in `01_schema.sql`, a line in `customer_new.frm`, and a change to the `INSERT` in `mod_orders.pas`.
3. Add a menu option that lists a product's price history. Write the procedure in `mod_products.pas`, export it in the interface, and add a line to `MENU` (remember to change the array bound and the `MAX` in `main_menu.frm`).
4. Start the program in one terminal and `psql` in another. In `psql` type `BEGIN; SELECT * FROM shop.products WHERE sku = 'TEA-001' FOR UPDATE;`. In the program, place an order for TEA-001 and confirm it. Watch it hang. Run the `pg_stat_activity` query from chapter 12 in a third terminal. Then type `ROLLBACK;` in `psql` and watch the order complete.
5. In `fn_place_order`, remove the line `ORDER BY p.product_id` from the locking query, reload with `make db`, and top up the stock (the command is in `tests/run_tests.sh`), and run `./bin/stress mixed 12 40`. Look at the retries column: most workers will now show some. The test still passes because the retry loop recovers. Then put the line back.
6. Remove the whole locking `PERFORM` from `fn_place_order` and run `./bin/stress oversell KIT-003 20`. Read the result carefully and work out which of the three layers of protection in chapter 11 caught the problem. (When this was tried, one order was placed, stock ended at 0, and 18 workers failed with SQLSTATE `23514`.)
7. Write a new stored procedure `fn_customer_summary(p_email)` returning the number of orders, total spent and date of last order. Add a test for it in `test_procedures.sql`.
8. Add a `RETURNED` status that is allowed only from SHIPPED and puts stock back. Decide which function it belongs in and which CHECK constraints need to change.

## 17. Glossary

| Term | Meaning |
|---|---|
| Backend | The PostgreSQL server process that serves one connection |
| CHECK constraint | A condition every row must satisfy; the database refuses rows that break it |
| Commit | End a transaction and keep its changes |
| Deadlock | Two or more transactions each waiting for a lock another one holds |
| Expression index | An index on a computed value, such as `lower(email)` |
| Foreign key | A column that must match a row in another table |
| Fork | Create a copy of the running process |
| Generated column | A column whose value the database calculates from other columns |
| Isolation level | The rule for what a transaction can see of other transactions' work |
| libpq | PostgreSQL's client library, written in C |
| Linker | The tool that joins compiled files and libraries into an executable |
| Partial index | An index covering only the rows that match a condition |
| PL/pgSQL | PostgreSQL's built-in language for stored procedures |
| Rollback | End a transaction and undo its changes |
| Row lock | A hold on one row that makes other transactions wait before changing or locking it |
| Schema | A named group of tables and functions inside a database (here, `shop`) |
| Session | One running copy of the program with its database connection |
| SKU | Stock keeping unit: a product's code |
| SQL injection | An attack where typed input is interpreted as SQL; prevented by parameters |
| SQLSTATE | The five-character code attached to every PostgreSQL error |
| Stored procedure | Code stored and run inside the database |
| Transaction | A group of changes that succeed or fail together |
| Trigger | Code the database runs automatically when a table changes |
| Unit | A separately compiled Pascal source file with an interface and an implementation |
| Window function | A function that calculates across related rows without merging them |

{ =====================================================================
  stress.pas  --  proves that parallel sessions cannot corrupt stock

  This program starts many sessions at once, each a separate operating
  system process with its own database connection, and has them all
  place orders at the same instant. It then checks the books.

  Two tests:

    stress oversell <SKU> <sessions> [quantity]
        Every session tries to buy the same product at the same moment.
        If the product has 5 in stock and 20 sessions each want 1, then
        exactly 5 must succeed, 15 must be refused, and stock must end
        at 0. One more or one less means the locking is wrong.

    stress mixed <sessions> <orders-each>
        Every session places a series of random multi-product orders.
        Different sessions want overlapping products in different
        orders, which is the classic recipe for deadlocks. The test
        passes if no session fails and the stock ledger still balances.

  The program uses the same back-end unit (orderapi.pas) as the forms
  program, so it tests the real code path and not a copy of it.
  ===================================================================== }
program stress;

{$mode objfpc}{$H+}

uses
  SysUtils, BaseUnix, dbconn, session, orderapi;

const
  EXIT_PLACED   = 0;
  EXIT_FAILED   = 1;
  EXIT_NO_STOCK = 3;

var
  ConnInfo: string;
  StartAt: TDateTime;

procedure Usage;
begin
  WriteLn('Usage:');
  WriteLn('  stress oversell <SKU> <sessions> [quantity]');
  WriteLn('  stress mixed <sessions> <orders-each>');
  Halt(2);
end;

{ All workers connect first and then wait for the same clock time, so
  their requests reach the database together. }
procedure WaitForStart;
begin
  while Now < StartAt do
    Sleep(5);
end;

{ ---------------------------------------------------------------------
  Worker bodies. Each runs in a child process and ends by calling Halt
  with an exit code that the parent collects.
  --------------------------------------------------------------------- }

procedure OversellWorker(Number: Integer; const Sku: string; Quantity: Integer);
var
  Cart: TCart;
  Code: Integer;
begin
  Code := EXIT_FAILED;
  try
    DbConnect(ConnInfo);
    SessionOpen('stress-' + IntToStr(Number));
    CartClear(Cart);
    CartAdd(Cart, Sku, Quantity);
    WaitForStart;
    try
      PlaceOrder(DbScalar('SELECT min(customer_id) FROM shop.customers', []),
                 SessionId, Cart);
      Code := EXIT_PLACED;
    except
      on E: EDbError do
        if E.SqlState = ERR_NO_STOCK then
          Code := EXIT_NO_STOCK
        else
          WriteLn(Format('  worker %d: unexpected error %s: %s',
                         [Number, E.SqlState, E.Message]));
    end;
    SessionClose;
    DbDisconnect;
  except
    on E: Exception do
      WriteLn(Format('  worker %d: %s', [Number, E.Message]));
  end;
  Halt(Code);
end;

procedure MixedWorker(Number, OrdersEach: Integer);
var
  Skus: array of string;
  R: TDbResult;
  Cart: TCart;
  CustomerId: string;
  I, J, Lines, Pick, Placed, Refused, Retried, Code: Integer;
  Used: array of Boolean;
begin
  Code := EXIT_FAILED;
  Placed := 0;
  Refused := 0;
  Retried := 0;
  try
    DbConnect(ConnInfo);
    SessionOpen('stress-' + IntToStr(Number));
    CustomerId := DbScalar('SELECT min(customer_id) FROM shop.customers', []);

    Skus := nil;
    R := DbQuery('SELECT sku FROM shop.products WHERE is_active ORDER BY sku', []);
    try
      SetLength(Skus, DbRowCount(R));
      for I := 0 to High(Skus) do
        Skus[I] := DbValue(R, I, 0);
    finally
      DbFree(R);
    end;

    { Each process needs its own random sequence. Seeding from the
      process id guarantees they differ. }
    RandSeed := FpGetPid;
    Code := EXIT_PLACED;
    WaitForStart;

    for I := 1 to OrdersEach do
    begin
      { Build a cart of 2 to 4 different products, in random order. }
      CartClear(Cart);
      Used := nil;
      SetLength(Used, Length(Skus));
      Lines := 2 + Random(3);
      for J := 1 to Lines do
      begin
        repeat
          Pick := Random(Length(Skus));
        until not Used[Pick];
        Used[Pick] := True;
        CartAdd(Cart, Skus[Pick], 1 + Random(3));
      end;

      try
        PlaceOrder(CustomerId, SessionId, Cart);
        Inc(Placed);
      except
        on E: EDbError do
          if E.SqlState = ERR_NO_STOCK then
            Inc(Refused)            { a correct refusal, not a failure }
          else
          begin
            WriteLn(Format('  worker %d: unexpected error %s: %s',
                           [Number, E.SqlState, E.Message]));
            Code := EXIT_FAILED;
          end;
      end;
      Retried := Retried + LastRetryCount;
    end;

    WriteLn(Format('  worker %2d: placed %3d, refused for stock %3d, retries %d',
                   [Number, Placed, Refused, Retried]));
    SessionClose;
    DbDisconnect;
  except
    on E: Exception do
    begin
      WriteLn(Format('  worker %d: %s', [Number, E.Message]));
      Code := EXIT_FAILED;
    end;
  end;
  Halt(Code);
end;

{ ---------------------------------------------------------------------
  Parent side
  --------------------------------------------------------------------- }

type
  TTally = record
    Placed, NoStock, Failed: Integer;
  end;

{ Waits for every child process and counts their exit codes. }
function CollectWorkers(const Pids: array of TPid): TTally;
var
  I: Integer;
  Status: cint;
begin
  Result.Placed := 0;
  Result.NoStock := 0;
  Result.Failed := 0;
  for I := 0 to High(Pids) do
  begin
    Status := 0;
    FpWaitPid(Pids[I], Status, 0);
    if wifexited(Status) and (wexitstatus(Status) = EXIT_PLACED) then
      Inc(Result.Placed)
    else if wifexited(Status) and (wexitstatus(Status) = EXIT_NO_STOCK) then
      Inc(Result.NoStock)
    else
      Inc(Result.Failed);
  end;
end;

function Verdict(Ok: Boolean): string;
begin
  if Ok then
    Result := 'ok'
  else
    Result := 'WRONG';
end;

function RunOversell(const Sku: string; Sessions, Quantity: Integer): Boolean;
var
  Pids: array of TPid;
  I, Before, After, Expected, Bad: Integer;
  Value: string;
  T: TTally;
begin
  DbConnect(ConnInfo);
  Value := DbScalar('SELECT stock_qty FROM shop.products WHERE sku = $1', [Sku]);
  { The parent closes its connection before starting children. A
    connection must never be shared across a fork: two processes
    writing to one socket would scramble the protocol. }
  DbDisconnect;
  if Value = '' then
  begin
    WriteLn('No product with SKU ', Sku);
    Exit(False);
  end;
  Before := StrToInt(Value);

  Expected := Before div Quantity;
  if Expected > Sessions then
    Expected := Sessions;

  WriteLn(Format('Oversell test: %d sessions each ordering %d x %s (stock %d)',
                 [Sessions, Quantity, Sku, Before]));

  StartAt := Now + 1.5 / SecsPerDay;
  Pids := nil;
  SetLength(Pids, Sessions);
  Flush(Output);                 { or each child would inherit and
                                   reprint whatever is still buffered }
  for I := 0 to Sessions - 1 do
  begin
    Pids[I] := FpFork;
    if Pids[I] = 0 then
      OversellWorker(I + 1, Sku, Quantity);   { child: never returns }
    if Pids[I] < 0 then
    begin
      WriteLn('fork failed');
      Exit(False);
    end;
  end;

  T := CollectWorkers(Pids);

  DbConnect(ConnInfo);
  After := StrToInt(DbScalar('SELECT stock_qty FROM shop.products WHERE sku = $1', [Sku]));
  Bad := StrToInt(DbScalar('SELECT count(*) FROM shop.fn_stock_discrepancies()', []));
  DbDisconnect;

  WriteLn(Format('  orders placed      %3d   expected %3d   %s',
                 [T.Placed, Expected, Verdict(T.Placed = Expected)]));
  WriteLn(Format('  refused, no stock  %3d   expected %3d   %s',
                 [T.NoStock, Sessions - Expected, Verdict(T.NoStock = Sessions - Expected)]));
  WriteLn(Format('  workers failed     %3d   expected %3d   %s',
                 [T.Failed, 0, Verdict(T.Failed = 0)]));
  WriteLn(Format('  stock afterwards   %3d   expected %3d   %s',
                 [After, Before - Expected * Quantity,
                  Verdict(After = Before - Expected * Quantity)]));
  WriteLn(Format('  ledger mismatches  %3d   expected %3d   %s',
                 [Bad, 0, Verdict(Bad = 0)]));

  Result := (T.Placed = Expected) and (T.NoStock = Sessions - Expected) and
            (T.Failed = 0) and (After = Before - Expected * Quantity) and (Bad = 0);
end;

function RunMixed(Sessions, OrdersEach: Integer): Boolean;
var
  Pids: array of TPid;
  I, Bad, Negative: Integer;
  T: TTally;
  OrdersBefore, OrdersAfter: Int64;
begin
  DbConnect(ConnInfo);
  OrdersBefore := StrToInt64(DbScalar('SELECT count(*) FROM shop.orders', []));
  DbDisconnect;

  WriteLn(Format('Mixed test: %d sessions x %d random multi-product orders',
                 [Sessions, OrdersEach]));

  StartAt := Now + 1.5 / SecsPerDay;
  Pids := nil;
  SetLength(Pids, Sessions);
  Flush(Output);
  for I := 0 to Sessions - 1 do
  begin
    Pids[I] := FpFork;
    if Pids[I] = 0 then
      MixedWorker(I + 1, OrdersEach);
    if Pids[I] < 0 then
    begin
      WriteLn('fork failed');
      Exit(False);
    end;
  end;

  T := CollectWorkers(Pids);

  DbConnect(ConnInfo);
  OrdersAfter := StrToInt64(DbScalar('SELECT count(*) FROM shop.orders', []));
  Bad := StrToInt(DbScalar('SELECT count(*) FROM shop.fn_stock_discrepancies()', []));
  Negative := StrToInt(DbScalar('SELECT count(*) FROM shop.products WHERE stock_qty < 0', []));
  DbDisconnect;

  WriteLn(Format('  orders stored      %d', [OrdersAfter - OrdersBefore]));
  WriteLn(Format('  workers failed     %3d   expected %3d   %s',
                 [T.Failed + T.NoStock, 0, Verdict(T.Failed + T.NoStock = 0)]));
  WriteLn(Format('  negative stock     %3d   expected %3d   %s',
                 [Negative, 0, Verdict(Negative = 0)]));
  WriteLn(Format('  ledger mismatches  %3d   expected %3d   %s',
                 [Bad, 0, Verdict(Bad = 0)]));

  Result := (T.Failed + T.NoStock = 0) and (Negative = 0) and (Bad = 0);
end;

var
  Mode: string;
  Quantity: Integer;
  Passed: Boolean;
begin
  ConnInfo := DbDefaultConnInfo;
  Mode := LowerCase(ParamStr(1));
  Passed := False;
  try
    if (Mode = 'oversell') and (ParamCount >= 3) then
    begin
      Quantity := 1;
      if ParamCount >= 4 then
        Quantity := StrToInt(ParamStr(4));
      Passed := RunOversell(UpperCase(ParamStr(2)), StrToInt(ParamStr(3)), Quantity);
    end
    else if (Mode = 'mixed') and (ParamCount >= 3) then
      Passed := RunMixed(StrToInt(ParamStr(2)), StrToInt(ParamStr(3)))
    else
      Usage;
  except
    on E: Exception do
      WriteLn('stress: ', E.Message);
  end;

  if Passed then
    WriteLn('RESULT: PASS')
  else
    WriteLn('RESULT: FAIL');
  if not Passed then
    Halt(1);
end.

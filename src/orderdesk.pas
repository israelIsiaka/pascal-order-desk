{ =====================================================================
  orderdesk.pas  --  main program

  Start-up:   load the forms, connect to PostgreSQL, sign the operator
              on (which opens a session).
  Main loop:  show the menu, run the chosen screen, report any error.
  Shut-down:  close the session and the connection, even if the loop
              ended because of an error.

  Settings come from environment variables:
    ORDERDESK_DB      libpq connection string
    ORDERDESK_FORMS   directory holding the .frm files
    ORDERDESK_TRACE   set to 1 to log every SQL statement to stderr
  ===================================================================== }
program orderdesk;

{$mode objfpc}{$H+}

uses
  SysUtils,
  dbconn, screen, forms, session,
  mod_products, mod_orders, mod_stock, mod_admin;

type
  TScreenProc = procedure;

  TMenuItem = record
    Caption: string;
    Run: TScreenProc;
  end;

const
  { Option numbers are positions in this table, starting at 1.
    To add a screen, write the procedure and add one line here. }
  MENU: array[1..12] of TMenuItem = (
    (Caption: 'Product search';              Run: @ProductSearch),
    (Caption: 'New order';                   Run: @OrderEntry),
    (Caption: 'Order enquiry / advance / cancel'; Run: @OrderEnquiry),
    (Caption: 'Orders waiting for payment';  Run: @OpenOrders),
    (Caption: 'Customer order history';      Run: @CustomerHistory),
    (Caption: 'Stock adjustment';            Run: @StockAdjust),
    (Caption: 'Stock ledger';                Run: @StockLedger),
    (Caption: 'Low stock report';            Run: @LowStockReport),
    (Caption: 'Change a price';              Run: @PriceChange),
    (Caption: 'Sales summary';               Run: @SalesSummary),
    (Caption: 'Active sessions';             Run: @ActiveSessions),
    (Caption: 'Integrity check';             Run: @IntegrityCheck)
  );

function FormsDirectory: string;
begin
  Result := GetEnvironmentVariable('ORDERDESK_FORMS');
  if Result = '' then
  begin
    { The program lives in bin/, the forms in forms/ next to it. }
    Result := ExtractFilePath(ExpandFileName(ParamStr(0))) + '..' + PathDelim + 'forms';
    if not DirectoryExists(Result) then
      Result := 'forms';
  end;
end;

{ Turns a database error into something an operator can act on. }
procedure ReportDbError(E: EDbError);
begin
  if Copy(E.SqlState, 1, 2) = 'OD' then
    { One of our own business-rule refusals: the message was written
      for people, so show it as it is. }
    UiError(E.Message)
  else if Copy(E.SqlState, 1, 2) = '08' then
    UiError('The connection to the database was lost: ' + E.Message)
  else if DbIsRetryable(E.SqlState) then
    UiError('The system is busy. Please try that again.')
  else
    UiError('Database error ' + E.SqlState + ': ' + E.Message);
end;

function SignOn: Boolean;
var
  D: TFormData;
begin
  RecordClear(D);
  FieldPut(D, 'operator', GetEnvironmentVariable('ORDERDESK_OPERATOR'));
  if not FormReceive('sign_on', D) then
    Exit(False);
  SessionOpen(FieldGet(D, 'operator'));
  UiSetStatus('session ' + SessionId + '  ' + SessionOperator);
  Result := True;
end;

{ Shows the menu and returns the option chosen, or 0 to sign off. }
function ChooseOption: Integer;
var
  D: TFormData;
  I: Integer;
begin
  UiTitle(DbScalar('SELECT value FROM shop.app_settings WHERE key = ''shop_name''', []));
  for I := Low(MENU) to High(MENU) do
    WriteLn(Format('  %2d  %s', [I, MENU[I].Caption]));
  WriteLn('   0  Sign off');
  WriteLn;

  RecordClear(D);
  if not FormReceiveBelow('main_menu', D) then
    Exit(0);
  Result := StrToInt(FieldGet(D, 'option'));
end;

procedure MainLoop;
var
  Option: Integer;
begin
  repeat
    Option := ChooseOption;
    if Option = 0 then
      Break;

    try
      MENU[Option].Run();
    except
      on E: EDbError do
      begin
        { A failed statement can leave a transaction open in the
          "aborted" state. Rolling back makes the connection usable
          again for the next screen. }
        DbRollback;
        ReportDbError(E);
        if not DbIsConnected then
          Break;
      end;
    end;

    UiPause;
  until InputClosed;
end;

begin
  ExitCode := 0;
  try
    FormsEnable(FormsDirectory);
    DbConnect(DbDefaultConnInfo);
    try
      if SignOn then
        MainLoop;
    finally
      { Runs however the block above ended, so the session row is
        closed and the connection released. }
      SessionClose;
      DbDisconnect;
      FormsDisable;
    end;
    WriteLn;
    WriteLn('  Signed off.');
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'orderdesk: ', E.Message);
      ExitCode := 1;
    end;
  end;
end.

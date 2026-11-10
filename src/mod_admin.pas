{ =====================================================================
  mod_admin.pas  --  reports and monitoring screens
  ===================================================================== }
unit mod_admin;

{$mode objfpc}{$H+}

interface

procedure SalesSummary;
procedure ActiveSessions;
procedure IntegrityCheck;

implementation

uses
  SysUtils, dbconn, forms, screen, report;

procedure SalesSummary;
var
  D: TFormData;
begin
  { Pre-fill the form with the last 30 days. The dates come from the
    database server's clock so every terminal agrees on "today". }
  RecordClear(D);
  FieldPut(D, 'date_from', DbScalar('SELECT (current_date - 30)::text', []));
  FieldPut(D, 'date_to',   DbScalar('SELECT current_date::text', []));
  if not FormReceive('date_range', D) then
    Exit;

  UiInfo('Cancelled orders are left out.');
  ShowQuery(['Rank', 'SKU', 'Product', 'Units', 'Revenue', 'Share %', 'Running %'],
            [0, 3, 4, 5, 6],
            'SELECT sales_rank, sku, name, units, revenue, share_pct, running_pct ' +
            'FROM   shop.fn_sales_summary($1::date, $2::date)',
            [FieldGet(D, 'date_from'), FieldGet(D, 'date_to')]);
end;

procedure ActiveSessions;
begin
  UiTitle('Active sessions');
  UiInfo('Every copy of the order desk that is connected right now.');
  ShowQuery(['Session', 'Operator', 'Terminal', 'DB process', 'Signed on', 'Orders'],
            [0, 3, 5],
            'SELECT session_id, operator, terminal, backend_pid, ' +
            '       to_char(opened_at, ''YYYY-MM-DD HH24:MI:SS''), orders_placed ' +
            'FROM   shop.v_active_sessions ORDER BY session_id',
            []);
end;

procedure IntegrityCheck;
var
  Bad: Integer;
begin
  UiTitle('Integrity check');
  UiInfo('Compares each product''s stock figure with the total of its ledger.');
  Bad := StrToInt(DbScalar('SELECT count(*) FROM shop.fn_stock_discrepancies()', []));
  if Bad = 0 then
  begin
    UiInfo('All ' + DbScalar('SELECT count(*) FROM shop.products', []) +
           ' products balance.');
    Exit;
  end;
  UiError(IntToStr(Bad) + ' product(s) do not balance:');
  ShowQuery(['SKU', 'Stock figure', 'Ledger total'], [1, 2],
            'SELECT sku, stock_qty, ledger_total FROM shop.fn_stock_discrepancies()', []);
end;

end.

{ =====================================================================
  mod_stock.pas  --  stock screens
  ===================================================================== }
unit mod_stock;

{$mode objfpc}{$H+}

interface

procedure StockAdjust;
procedure StockLedger;

implementation

uses
  SysUtils, dbconn, forms, screen, report, session;

procedure StockAdjust;
var
  D: TFormData;
  Note, NewQty: string;
begin
  RecordClear(D);
  if not FormReceive('stock_adjust', D) then
    Exit;

  Note := FieldGet(D, 'note');
  if Note = '' then
    Note := SQL_NULL;

  { The form has already checked that quantity is a whole number in
    range. Whether the change is allowed (no negative stock, RECEIVE
    must be positive) is a business rule, so the database decides. }
  NewQty := DbScalar(
    'SELECT shop.fn_adjust_stock($1, $2::integer, $3, $4::bigint, $5)',
    [FieldGet(D, 'sku'), FieldGet(D, 'quantity'), FieldGet(D, 'reason'),
     SessionId, Note]);

  UiInfo(FieldGet(D, 'sku') + ' now has ' + NewQty + ' in stock.');
end;

procedure StockLedger;
var
  D: TFormData;
begin
  RecordClear(D);
  if not FormReceive('stock_ledger', D) then
    Exit;

  if DbScalar('SELECT 1 FROM shop.products WHERE sku = $1', [FieldGet(D, 'sku')]) = '' then
  begin
    UiError('No product with SKU ' + FieldGet(D, 'sku'));
    Exit;
  end;

  UiInfo('Most recent 15 movements, newest first:');
  ShowQuery(['When', 'Reason', 'Change', 'Stock after', 'Order', 'Operator', 'Note'],
            [2, 3, 4],
            'SELECT to_char(m.created_at, ''YYYY-MM-DD HH24:MI:SS''), m.reason, ' +
            '       CASE WHEN m.delta > 0 THEN ''+'' ELSE '''' END || m.delta, m.qty_after, ' +
            '       coalesce(m.order_id::text, ''''), coalesce(s.operator, ''''), ' +
            '       coalesce(m.note, '''') ' +
            'FROM   shop.stock_movements m ' +
            'JOIN   shop.products p USING (product_id) ' +
            'LEFT   JOIN shop.sessions s ON s.session_id = m.session_id ' +
            'WHERE  p.sku = $1 ' +
            'ORDER  BY m.created_at DESC, m.movement_id DESC LIMIT 15',
            [FieldGet(D, 'sku')]);
end;

end.

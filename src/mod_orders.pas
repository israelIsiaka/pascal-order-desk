{ =====================================================================
  mod_orders.pas  --  order entry and order enquiry screens

  This is the forms side of ordering. The rules themselves (stock
  checks, totals, what may be cancelled) are in the database and are
  reached through orderapi.pas and the fn_ functions.
  ===================================================================== }
unit mod_orders;

{$mode objfpc}{$H+}

interface

procedure OrderEntry;
procedure OrderEnquiry;
procedure OpenOrders;
procedure CustomerHistory;

implementation

uses
  SysUtils, dbconn, forms, screen, report, session, orderapi;

{ ---------------------------------------------------------------------
  Shared display routines
  --------------------------------------------------------------------- }

{ Prints one order. Returns its status, or '' if there is no such order. }
function ShowOrder(const OrderId: string): string;
var
  R: TDbResult;
begin
  Result := '';
  R := DbQuery(
    'SELECT o.status, c.full_name, c.email, ' +
    '       to_char(o.placed_at, ''YYYY-MM-DD HH24:MI''), ' +
    '       o.subtotal, o.tax_amount, o.total, coalesce(s.operator, ''-'') ' +
    'FROM   shop.orders o ' +
    'JOIN   shop.customers c USING (customer_id) ' +
    'LEFT   JOIN shop.sessions s ON s.session_id = o.session_id ' +
    'WHERE  o.order_id = $1::bigint',
    [OrderId]);
  try
    if DbRowCount(R) = 0 then
      Exit;
    Result := DbValue(R, 0, 0);
    UiTitle('Order ' + OrderId);
    UiInfo('Status    : ' + DbValue(R, 0, 0));
    UiInfo('Customer  : ' + DbValue(R, 0, 1) + ' <' + DbValue(R, 0, 2) + '>');
    UiInfo('Placed    : ' + DbValue(R, 0, 3) + ' by ' + DbValue(R, 0, 7));
    WriteLn;
    ShowQuery(['Line', 'SKU', 'Product', 'Qty', 'Price', 'Total'], [0, 3, 4, 5],
              'SELECT l.line_no, p.sku, p.name, l.quantity, l.unit_price, l.line_total ' +
              'FROM   shop.order_lines l JOIN shop.products p USING (product_id) ' +
              'WHERE  l.order_id = $1::bigint ORDER BY l.line_no',
              [OrderId]);
    WriteLn;
    UiInfo('Subtotal  : ' + DbValue(R, 0, 4));
    UiInfo('Tax       : ' + DbValue(R, 0, 5));
    UiInfo('Total     : ' + DbValue(R, 0, 6));
  finally
    DbFree(R);
  end;
end;

procedure ShowCart(const Cart: TCart);
begin
  WriteLn;
  UiInfo('Order so far:');
  ShowQuery(['Line', 'SKU', 'Product', 'Qty', 'Price', 'Total', 'Note'], [0, 3, 4, 5],
            'SELECT line_no, sku, coalesce(name, ''''), quantity, ' +
            '       coalesce(unit_price::text, ''''), coalesce(line_total::text, ''''), ' +
            '       coalesce(problem, '''') ' +
            'FROM   shop.fn_price_cart($1::jsonb)',
            [CartToJson(Cart)]);
end;

{ ---------------------------------------------------------------------
  Order entry
  --------------------------------------------------------------------- }

{ Returns the customer id for the email, creating the customer if the
  operator supplies the details. Returns '' if the operator cancels. }
function FindOrCreateCustomer(const Email: string): string;
const
  FIND_SQL = 'SELECT customer_id FROM shop.customers WHERE lower(email) = lower($1)';
var
  Sent, D: TFormData;
  Phone, City: string;
begin
  Result := DbScalar(FIND_SQL, [Email]);
  if Result <> '' then
  begin
    UiInfo('Customer: ' + DbScalar(
      'SELECT full_name || '', '' || coalesce(city, ''-'') ' +
      'FROM shop.customers WHERE customer_id = $1::integer', [Result]));
    Exit;
  end;

  RecordClear(Sent);
  FieldPut(Sent, 'email', Email);
  RecordClear(D);
  if not FormTransceive('customer_new', Sent, D) then
    Exit;

  { An optional field left blank is stored as NULL, not as an empty
    string, so "no phone number" has one meaning in the database. }
  Phone := FieldGet(D, 'phone');
  if Phone = '' then
    Phone := SQL_NULL;
  City := FieldGet(D, 'city');
  if City = '' then
    City := SQL_NULL;

  try
    Result := DbScalar(
      'INSERT INTO shop.customers (email, full_name, phone, city) ' +
      'VALUES ($1, $2, $3, $4) RETURNING customer_id',
      [Email, FieldGet(D, 'full_name'), Phone, City]);
    UiInfo('Customer created.');
  except
    on E: EDbError do
    begin
      { Another session may have added the same customer between our
        lookup and our insert. The unique index stops the duplicate,
        and we simply use the row that is now there. }
      if E.SqlState <> ERR_UNIQUE_VIOLATION then
        raise;
      Result := DbScalar(FIND_SQL, [Email]);
    end;
  end;
end;

{ Asks for one order line. Returns False when the operator has finished
  (blank SKU) or cancelled; Cancelled tells the two apart. }
function ReceiveLine(var Cart: TCart; out Cancelled: Boolean): Boolean;
var
  D, Sent: TFormData;
  R: TDbResult;
  Sku: string;
begin
  Result := False;
  Cancelled := False;

  RecordClear(D);
  if not FormReceive('order_line', D) then
  begin
    Cancelled := True;
    Exit;
  end;

  Sku := FieldGet(D, 'sku');
  if Sku = '' then
    Exit;                       { blank SKU: the order is complete }

  Result := True;               { from here on, keep asking for lines }

  RecordClear(Sent);
  R := DbQuery('SELECT name, unit_price, stock_qty, is_active ' +
               'FROM shop.products WHERE sku = $1', [Sku]);
  try
    if DbRowCount(R) = 0 then
    begin
      UiError('No product with SKU ' + Sku);
      Exit;
    end;
    if DbValue(R, 0, 3) <> 't' then
    begin
      UiError(Sku + ' is not on sale');
      Exit;
    end;
    FieldPut(Sent, 'product', DbValue(R, 0, 0));
    FieldPut(Sent, 'unit_price', DbValue(R, 0, 1));
    FieldPut(Sent, 'in_stock', DbValue(R, 0, 2));
  finally
    DbFree(R);
  end;

  RecordClear(D);
  if not FormTransceive('order_line_qty', Sent, D) then
    Exit;                       { /c here drops just this line }

  CartAdd(Cart, Sku, StrToInt(FieldGet(D, 'quantity')));
  ShowCart(Cart);
end;

procedure OrderEntry;
var
  D, Sent: TFormData;
  R: TDbResult;
  Cart: TCart;
  CustomerId, OrderId: string;
  Cancelled: Boolean;
begin
  RecordClear(D);
  if not FormReceive('order_customer', D) then
    Exit;

  CustomerId := FindOrCreateCustomer(FieldGet(D, 'email'));
  if CustomerId = '' then
    Exit;

  CartClear(Cart);
  while ReceiveLine(Cart, Cancelled) do
    ;
  if Cancelled then
  begin
    UiInfo('Order abandoned. Nothing was saved.');
    Exit;
  end;
  if Length(Cart) = 0 then
  begin
    UiInfo('No lines were entered. Nothing was saved.');
    Exit;
  end;

  { Show the totals and ask for confirmation. Up to this point nothing
    has been written and no stock is held. }
  RecordClear(Sent);
  R := DbQuery('SELECT subtotal, tax_amount, total FROM shop.fn_cart_totals($1::jsonb)',
               [CartToJson(Cart)]);
  try
    FieldPut(Sent, 'subtotal', DbValue(R, 0, 0));
    FieldPut(Sent, 'tax', DbValue(R, 0, 1));
    FieldPut(Sent, 'total', DbValue(R, 0, 2));
  finally
    DbFree(R);
  end;

  RecordClear(D);
  if (not FormTransceive('order_confirm', Sent, D)) or (FieldGet(D, 'confirm') <> 'Y') then
  begin
    UiInfo('Order not placed. Nothing was saved.');
    Exit;
  end;

  try
    OrderId := PlaceOrder(CustomerId, SessionId, Cart);
  except
    on E: EDbError do
    begin
      { These are refusals the operator can act on, so they get a plain
        explanation. Anything else goes up to the main program. }
      if (E.SqlState = ERR_NO_STOCK) or (E.SqlState = ERR_UNKNOWN_PRODUCT) then
      begin
        UiError(E.Message);
        UiInfo('Another session may have taken the stock while this order was');
        UiInfo('being entered. The order was not placed and nothing was saved.');
        Exit;
      end;
      raise;
    end;
  end;

  ShowOrder(OrderId);
  WriteLn;
  UiInfo('Order ' + OrderId + ' placed.');
end;

{ ---------------------------------------------------------------------
  Enquiry screens
  --------------------------------------------------------------------- }

procedure OrderEnquiry;
var
  D: TFormData;
  OrderId, Status, Action: string;
begin
  RecordClear(D);
  if not FormReceive('order_lookup', D) then
    Exit;
  OrderId := FieldGet(D, 'order_id');

  Status := ShowOrder(OrderId);
  if Status = '' then
  begin
    UiError('There is no order ' + OrderId);
    Exit;
  end;

  if (Status <> 'PLACED') and (Status <> 'PAID') then
    Exit;   { shipped and cancelled orders cannot be changed }

  RecordClear(D);
  if not FormReceive('order_action', D) then
    Exit;
  Action := FieldGet(D, 'action');

  { Each call below is a single statement. PostgreSQL runs a single
    statement as its own transaction, so no explicit BEGIN/COMMIT is
    needed: the function either finishes completely or changes nothing. }
  if Action = 'ADVANCE' then
    UiInfo('Order ' + OrderId + ' is now ' +
           DbScalar('SELECT shop.fn_advance_order($1::bigint)', [OrderId]) + '.')
  else if Action = 'CANCEL' then
  begin
    DbExec('SELECT shop.fn_cancel_order($1::bigint, $2::bigint)', [OrderId, SessionId]);
    UiInfo('Order ' + OrderId + ' cancelled and stock returned.');
  end;
end;

procedure OpenOrders;
begin
  UiTitle('Orders waiting for payment');
  UiInfo('Oldest first.');
  ShowQuery(['Order', 'Placed', 'Customer', 'Total'], [0, 3],
            'SELECT o.order_id, to_char(o.placed_at, ''YYYY-MM-DD HH24:MI''), ' +
            '       c.full_name, o.total ' +
            'FROM   shop.orders o JOIN shop.customers c USING (customer_id) ' +
            'WHERE  o.status = ''PLACED'' ' +
            'ORDER  BY o.placed_at LIMIT 25',
            []);
end;

procedure CustomerHistory;
var
  D: TFormData;
  CustomerId: string;
begin
  RecordClear(D);
  if not FormReceive('customer_lookup', D) then
    Exit;

  CustomerId := DbScalar(
    'SELECT customer_id FROM shop.customers WHERE lower(email) = lower($1)',
    [FieldGet(D, 'email')]);
  if CustomerId = '' then
  begin
    UiError('No customer with that email address');
    Exit;
  end;

  UiInfo('Most recent 20 orders:');
  ShowQuery(['Order', 'Placed', 'Status', 'Lines', 'Total'], [0, 3, 4],
            'SELECT o.order_id, to_char(o.placed_at, ''YYYY-MM-DD HH24:MI''), o.status, ' +
            '       (SELECT count(*) FROM shop.order_lines l WHERE l.order_id = o.order_id), ' +
            '       o.total ' +
            'FROM   shop.orders o ' +
            'WHERE  o.customer_id = $1::integer ' +
            'ORDER  BY o.placed_at DESC LIMIT 20',
            [CustomerId]);
end;

end.

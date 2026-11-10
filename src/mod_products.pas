{ =====================================================================
  mod_products.pas  --  catalogue screens
  ===================================================================== }
unit mod_products;

{$mode objfpc}{$H+}

interface

procedure ProductSearch;
procedure LowStockReport;
procedure PriceChange;

implementation

uses
  SysUtils, dbconn, forms, screen, report;

procedure ProductSearch;
var
  D: TFormData;
begin
  RecordClear(D);
  if not FormReceive('product_search', D) then
    Exit;

  { ILIKE is a case-insensitive match. The search term is wrapped in
    % signs on the database side, so "tea" finds "Green Tea 40 bags". }
  ShowQuery(['SKU', 'Product', 'Category', 'Price', 'In stock', 'On sale'],
            [3, 4],
            'SELECT p.sku, p.name, c.name, p.unit_price, p.stock_qty, ' +
            '       CASE WHEN p.is_active THEN ''yes'' ELSE ''no'' END ' +
            'FROM   shop.products p ' +
            'JOIN   shop.categories c USING (category_id) ' +
            'WHERE  p.name ILIKE ''%'' || $1 || ''%'' ' +
            '   OR  p.sku  ILIKE ''%'' || $1 || ''%'' ' +
            'ORDER  BY p.sku',
            [FieldGet(D, 'term')]);
end;

procedure LowStockReport;
begin
  UiTitle('Low stock report');
  UiInfo('Products at or below their reorder level.');
  ShowQuery(['SKU', 'Product', 'Category', 'In stock', 'Reorder at'],
            [3, 4],
            'SELECT sku, name, category, stock_qty, reorder_level ' +
            'FROM   shop.v_low_stock ORDER BY stock_qty, sku',
            []);
end;

procedure PriceChange;
var
  D: TFormData;
  OldPrice: string;
begin
  RecordClear(D);
  if not FormReceive('price_change', D) then
    Exit;

  { UPDATE ... RETURNING hands back a value from the changed row, so we
    learn whether the SKU existed without running a second query. The
    trigger on shop.products writes the price history row for us. }
  OldPrice := DbScalar(
    'UPDATE shop.products p SET unit_price = $2::numeric ' +
    'FROM  (SELECT product_id, unit_price FROM shop.products WHERE sku = $1) old ' +
    'WHERE  p.product_id = old.product_id ' +
    'RETURNING old.unit_price',
    [FieldGet(D, 'sku'), FieldGet(D, 'new_price')]);

  if OldPrice = '' then
  begin
    UiError('No product with SKU ' + FieldGet(D, 'sku'));
    Exit;
  end;

  UiInfo('Price changed from ' + OldPrice + ' to ' +
         DbScalar('SELECT unit_price FROM shop.products WHERE sku = $1',
                  [FieldGet(D, 'sku')]) + '.');
  UiInfo('Price history for this product:');
  ShowQuery(['When', 'Old price', 'New price'], [1, 2],
            'SELECT to_char(h.changed_at, ''YYYY-MM-DD HH24:MI''), h.old_price, h.new_price ' +
            'FROM   shop.price_history h ' +
            'JOIN   shop.products p USING (product_id) ' +
            'WHERE  p.sku = $1 ORDER BY h.changed_at DESC LIMIT 10',
            [FieldGet(D, 'sku')]);
end;

end.

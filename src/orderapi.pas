{ =====================================================================
  orderapi.pas  --  back-end module for orders

  This unit has no screen code in it at all. It is called by the forms
  program (mod_orders.pas) and by the load test (stress.pas), which is
  the point: many sessions, and different front ends, share one set of
  back-end routines.
  ===================================================================== }
unit orderapi;

{$mode objfpc}{$H+}

interface

type
  TCartLine = record
    Sku: string;
    Quantity: Integer;
  end;

  TCart = array of TCartLine;

const
  MAX_ATTEMPTS = 4;

procedure CartClear(var Cart: TCart);
procedure CartAdd(var Cart: TCart; const Sku: string; Quantity: Integer);
function  CartToJson(const Cart: TCart): string;

{ Places the order inside a transaction and returns the new order
  number. Raises EDbError if the order is refused. }
function  PlaceOrder(const CustomerId, SessionId: string; const Cart: TCart): string;

{ How many times the last PlaceOrder call had to be re-run because the
  database picked it as a deadlock or serialization victim. }
function  LastRetryCount: Integer;

implementation

uses
  SysUtils, dbconn;

var
  Retries: Integer = 0;

procedure CartClear(var Cart: TCart);
begin
  Cart := nil;
end;

procedure CartAdd(var Cart: TCart; const Sku: string; Quantity: Integer);
var
  N: Integer;
begin
  N := Length(Cart);
  SetLength(Cart, N + 1);
  Cart[N].Sku := Sku;
  Cart[N].Quantity := Quantity;
end;

{ Makes a string safe to place between double quotes in JSON. }
function JsonEscape(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    case S[I] of
      '"':  Result := Result + '\"';
      '\':  Result := Result + '\\';
      #0..#31: Result := Result + '\u' + IntToHex(Ord(S[I]), 4);
    else
      Result := Result + S[I];
    end;
end;

(* The cart travels to the database as one JSON value, for example
     [{"sku":"TEA-001","qty":2},{"sku":"KIT-002","qty":4}]
   so an order of any size is a single call to fn_place_order. *)
function CartToJson(const Cart: TCart): string;
var
  I: Integer;
begin
  Result := '[';
  for I := 0 to High(Cart) do
  begin
    if I > 0 then
      Result := Result + ',';
    Result := Result + '{"sku":"' + JsonEscape(Cart[I].Sku) +
              '","qty":' + IntToStr(Cart[I].Quantity) + '}';
  end;
  Result := Result + ']';
end;

function PlaceOrder(const CustomerId, SessionId: string; const Cart: TCart): string;
var
  Attempt: Integer;
  Json: string;
begin
  Result := '';
  Retries := 0;
  Json := CartToJson(Cart);

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
        { After any error PostgreSQL refuses further work in the
          transaction until it is rolled back. }
        DbRollback;

        { Business refusals (no stock, unknown product) are final and
          go straight back to the caller. A deadlock or serialization
          failure means "nothing was wrong with your request, another
          session got in the way, try again", so we do. }
        if (not DbIsRetryable(E.SqlState)) or (Attempt = MAX_ATTEMPTS) then
          raise;

        Inc(Retries);
        Sleep(40 * Attempt);   { brief, growing pause before retrying }
      end;
    end;
  end;
end;

function LastRetryCount: Integer;
begin
  Result := Retries;
end;

end.

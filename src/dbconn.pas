{ =====================================================================
  dbconn.pas  --  the only unit that talks to PostgreSQL directly

  PostgreSQL ships a C library called libpq. Free Pascal's "postgres3"
  unit declares the functions in that library so Pascal code can call
  them. This unit wraps those raw C calls in a small, safer interface:

    DbConnect / DbDisconnect      open and close the connection
    DbQuery                       run SQL with parameters, get rows back
    DbExec / DbScalar             shortcuts built on DbQuery
    DbBegin / DbCommit / DbRollback   transaction control
    EDbError                      the exception raised when SQL fails

  Every other unit goes through here, so there is one place to look
  when a database call misbehaves.
  ===================================================================== }
unit dbconn;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, postgres3;

const
  { Pass this as a parameter value to send a real SQL NULL. }
  SQL_NULL = #1'NULL'#1;

  { Error codes raised by the stored procedures in db/02_procedures.sql }
  ERR_UNKNOWN_CUSTOMER = 'OD001';
  ERR_UNKNOWN_PRODUCT  = 'OD002';
  ERR_NO_STOCK         = 'OD003';
  ERR_BAD_INPUT        = 'OD004';
  ERR_ORDER_STATE      = 'OD005';
  ERR_UNKNOWN_ORDER    = 'OD006';

  { Standard PostgreSQL codes we care about }
  ERR_SERIALIZATION    = '40001';
  ERR_DEADLOCK         = '40P01';
  ERR_UNIQUE_VIOLATION = '23505';

type
  { Raised whenever the server rejects a statement. SqlState holds the
    five character error code, which is what callers should test. }
  EDbError = class(Exception)
  private
    FSqlState: string;
  public
    constructor CreateDb(const Msg, State: string);
    property SqlState: string read FSqlState;
  end;

  { A result set. It is memory owned by libpq, so every result that is
    obtained from DbQuery must be handed back with DbFree. }
  TDbResult = PPGresult;

procedure DbConnect(const ConnInfo: string);
procedure DbDisconnect;
function  DbIsConnected: Boolean;
function  DbBackendPid: Integer;

function  DbQuery(const Sql: string; const Params: array of string): TDbResult;
procedure DbFree(var R: TDbResult);
function  DbRowCount(R: TDbResult): Integer;
function  DbColCount(R: TDbResult): Integer;
function  DbValue(R: TDbResult; Row, Col: Integer): string;
function  DbIsNull(R: TDbResult; Row, Col: Integer): Boolean;

procedure DbExec(const Sql: string; const Params: array of string);
function  DbScalar(const Sql: string; const Params: array of string): string;

procedure DbBegin;
procedure DbCommit;
procedure DbRollback;
function  DbInTransaction: Boolean;

{ True for errors where simply running the transaction again is the
  right response (deadlock victim, serialization failure). }
function  DbIsRetryable(const SqlState: string): Boolean;

{ Reads the connection string from the ORDERDESK_DB environment
  variable, or falls back to the local development default. }
function  DbDefaultConnInfo: string;

implementation

var
  Conn: PPGconn = nil;
  TraceOn: Boolean = False;

constructor EDbError.CreateDb(const Msg, State: string);
begin
  inherited Create(Msg);
  FSqlState := State;
end;

{ When ORDERDESK_TRACE=1 every statement is written to standard error
  before it runs. Standard error is separate from the screen output, so
  it can be sent to a file:   ./bin/orderdesk 2> trace.log }
procedure Trace(const Sql: string; const Params: array of string);
var
  I: Integer;
begin
  if not TraceOn then
    Exit;
  Write(StdErr, '[sql ', FormatDateTime('hh:nn:ss.zzz', Now), '] ', Sql);
  for I := 0 to High(Params) do
    if Params[I] = SQL_NULL then
      Write(StdErr, '  $', I + 1, '=NULL')
    else
      Write(StdErr, '  $', I + 1, '=''', Params[I], '''');
  WriteLn(StdErr);
end;

function DbDefaultConnInfo: string;
begin
  Result := GetEnvironmentVariable('ORDERDESK_DB');
  if Result = '' then
    Result := 'host=127.0.0.1 port=5432 dbname=orderdesk user=orderdesk password=orderdesk';
end;

procedure DbConnect(const ConnInfo: string);
var
  Msg: string;
begin
  if Conn <> nil then
    DbDisconnect;

  TraceOn := GetEnvironmentVariable('ORDERDESK_TRACE') = '1';

  Conn := PQconnectdb(PChar(ConnInfo));
  if (Conn = nil) or (PQstatus(Conn) <> CONNECTION_OK) then
  begin
    if Conn = nil then
      Msg := 'out of memory'
    else
      Msg := Trim(string(PQerrorMessage(Conn)));
    if Conn <> nil then
      PQfinish(Conn);
    Conn := nil;
    raise EDbError.CreateDb('Cannot connect to the database: ' + Msg, '08001');
  end;

  { Table and function names in this program are written with the
    "shop." prefix, but setting the search path as well means ad hoc
    queries typed during debugging work without it. }
  DbExec('SET search_path TO shop, public', []);
  DbExec('SET application_name TO ''orderdesk''', []);
end;

procedure DbDisconnect;
begin
  if Conn <> nil then
  begin
    PQfinish(Conn);
    Conn := nil;
  end;
end;

function DbIsConnected: Boolean;
begin
  Result := (Conn <> nil) and (PQstatus(Conn) = CONNECTION_OK);
end;

function DbBackendPid: Integer;
begin
  if Conn = nil then
    Result := 0
  else
    Result := PQbackendPID(Conn);
end;

{ Runs one SQL statement.

  Values are never pasted into the SQL text. The statement contains
  placeholders ($1, $2, ...) and the values travel separately, so a
  value such as   '; DROP TABLE orders; --   is only ever treated as
  data. This is what protects the program from SQL injection. }
function DbQuery(const Sql: string; const Params: array of string): TDbResult;
var
  Values: array of PChar;
  I: Integer;
  Status: TExecStatusType;
  State, Msg, Detail: string;
begin
  if Conn = nil then
    raise EDbError.CreateDb('Not connected to the database', '08003');

  Trace(Sql, Params);

  Values := nil;
  SetLength(Values, Length(Params));
  for I := 0 to High(Params) do
    if Params[I] = SQL_NULL then
      Values[I] := nil
    else
      Values[I] := PChar(Params[I]);

  if Length(Params) = 0 then
    Result := PQexecParams(Conn, PChar(Sql), 0, nil, nil, nil, nil, 0)
  else
    Result := PQexecParams(Conn, PChar(Sql), Length(Params), nil,
                           @Values[0], nil, nil, 0);

  if Result = nil then
    raise EDbError.CreateDb(Trim(string(PQerrorMessage(Conn))), '08006');

  Status := PQresultStatus(Result);
  if (Status <> PGRES_COMMAND_OK) and (Status <> PGRES_TUPLES_OK) then
  begin
    { PQresultErrorField picks one part of the error apart from the
      rest: 'C' is the SQLSTATE code, 'M' the message, 'D' the detail. }
    State  := string(PQresultErrorField(Result, Ord('C')));
    Msg    := string(PQresultErrorField(Result, Ord('M')));
    Detail := string(PQresultErrorField(Result, Ord('D')));
    if Msg = '' then
      Msg := Trim(string(PQerrorMessage(Conn)));
    if State = '' then
      State := '08006';
    if Detail <> '' then
      Msg := Msg + ' (' + Detail + ')';
    PQclear(Result);
    Result := nil;
    if TraceOn then
      WriteLn(StdErr, '[sql error ', State, '] ', Msg);
    raise EDbError.CreateDb(Msg, State);
  end;
end;

procedure DbFree(var R: TDbResult);
begin
  if R <> nil then
  begin
    PQclear(R);
    R := nil;
  end;
end;

function DbRowCount(R: TDbResult): Integer;
begin
  Result := PQntuples(R);
end;

function DbColCount(R: TDbResult): Integer;
begin
  Result := PQnfields(R);
end;

function DbValue(R: TDbResult; Row, Col: Integer): string;
begin
  Result := string(PQgetvalue(R, Row, Col));
end;

function DbIsNull(R: TDbResult; Row, Col: Integer): Boolean;
begin
  Result := PQgetisnull(R, Row, Col) = 1;
end;

procedure DbExec(const Sql: string; const Params: array of string);
var
  R: TDbResult;
begin
  R := DbQuery(Sql, Params);
  DbFree(R);
end;

{ Returns the first column of the first row, or '' when there is none. }
function DbScalar(const Sql: string; const Params: array of string): string;
var
  R: TDbResult;
begin
  Result := '';
  R := DbQuery(Sql, Params);
  try
    if (DbRowCount(R) > 0) and (DbColCount(R) > 0) then
      Result := DbValue(R, 0, 0);
  finally
    DbFree(R);
  end;
end;

procedure DbBegin;
begin
  DbExec('BEGIN', []);
end;

procedure DbCommit;
begin
  DbExec('COMMIT', []);
end;

{ True between BEGIN and COMMIT/ROLLBACK, including the "aborted" state
  a transaction enters after one of its statements has failed. }
function DbInTransaction: Boolean;
begin
  Result := (Conn <> nil) and
            (PQtransactionStatus(Conn) in [PQTRANS_INTRANS, PQTRANS_INERROR]);
end;

{ Rollback is called from error handlers, so it must not raise a second
  error on top of the one being handled. It does nothing when no
  transaction is open. }
procedure DbRollback;
begin
  try
    if DbInTransaction then
      DbExec('ROLLBACK', []);
  except
    on EDbError do
      ; { nothing useful can be done here }
  end;
end;

function DbIsRetryable(const SqlState: string): Boolean;
begin
  Result := (SqlState = ERR_DEADLOCK) or (SqlState = ERR_SERIALIZATION);
end;

end.

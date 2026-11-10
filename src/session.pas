{ =====================================================================
  session.pas  --  one running copy of the program is one session

  Many operators can run the order desk at the same time. Each copy
  opens its own database connection and registers itself in the
  shop.sessions table. From then on every order and stock change it
  makes is stamped with its session number, so there is a record of
  which terminal did what.

  If a copy dies without signing off (crash, closed window, lost
  network link) its row would be left looking "open". The stored
  procedure fn_open_session clears those up the next time anyone signs
  on, by checking which database connections still exist.
  ===================================================================== }
unit session;

{$mode objfpc}{$H+}

interface

procedure SessionOpen(const OperatorName: string);
procedure SessionClose;
function  SessionId: string;
function  SessionOperator: string;
function  SessionIsOpen: Boolean;

implementation

uses
  SysUtils, BaseUnix, termio, dbconn;

var
  CurrentId: string = '';
  CurrentOperator: string = '';

{ The name of the terminal this copy is attached to, for example
  /dev/pts/3. When input is a script there is no terminal, so the
  process id is used to tell batch runs apart. }
function TerminalName: string;
begin
  if IsATTY(Input) = 1 then
    Result := TTYName(Input)
  else
    Result := 'batch-' + IntToStr(FpGetPid);
end;

procedure SessionOpen(const OperatorName: string);
begin
  CurrentId := DbScalar('SELECT shop.fn_open_session($1, $2)',
                        [OperatorName, TerminalName]);
  CurrentOperator := OperatorName;
  { Shows up in pg_stat_activity, so a database administrator can see
    which connection belongs to which operator. }
  DbExec('SELECT set_config(''application_name'', $1, false)',
         ['orderdesk#' + CurrentId + ' ' + OperatorName]);
end;

procedure SessionClose;
begin
  if (CurrentId <> '') and DbIsConnected then
    try
      DbExec('SELECT shop.fn_close_session($1::bigint)', [CurrentId]);
    except
      on EDbError do
        ; { the session will be reaped on the next sign-on }
    end;
  CurrentId := '';
  CurrentOperator := '';
end;

function SessionId: string;
begin
  Result := CurrentId;
end;

function SessionOperator: string;
begin
  Result := CurrentOperator;
end;

function SessionIsOpen: Boolean;
begin
  Result := CurrentId <> '';
end;

end.

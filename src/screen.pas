{ =====================================================================
  screen.pas  --  everything that reads the keyboard or writes the
                  terminal

  The program reads whole lines from standard input and writes plain
  text to standard output. That keeps it usable over any terminal or
  remote connection, and it means a test can drive the program by
  feeding it a text file:    ./bin/orderdesk < tests/session.txt
  ===================================================================== }
unit screen;

{$mode objfpc}{$H+}

interface

const
  SCREEN_WIDTH = 78;

type
  { A simple text table: headings, rows of cells, and a note of which
    columns hold numbers (those are lined up on the right). }
  TTable = record
    Headers:    array of string;
    RightAlign: array of Boolean;
    Rows:       array of array of string;
  end;

{ True once standard input has ended (end of a script, or Ctrl-D). The
  main loop checks this so the program can never spin waiting for
  input that will not come. }
function  InputClosed: Boolean;

function  UiReadLine(const Prompt: string; out Line: string): Boolean;
procedure UiTitle(const Title: string);
procedure UiRule;
procedure UiInfo(const Msg: string);
procedure UiError(const Msg: string);
procedure UiPause;
procedure UiSetStatus(const Status: string);

procedure TableInit(var T: TTable; const Headers: array of string;
                    const RightAlignedColumns: array of Integer);
procedure TableAddRow(var T: TTable; const Cells: array of string);
procedure TablePrint(const T: TTable);

implementation

uses
  SysUtils, termio;

var
  Closed: Boolean = False;
  Interactive: Boolean = True;
  StatusText: string = '';

function InputClosed: Boolean;
begin
  Result := Closed;
end;

{ Shown on the right of every title bar: session number and operator. }
procedure UiSetStatus(const Status: string);
begin
  StatusText := Status;
end;

{ Reads one line. Returns False when there is no more input. }
function UiReadLine(const Prompt: string; out Line: string): Boolean;
begin
  Line := '';
  Write(Prompt);
  Flush(Output);
  if Closed or EOF(Input) then
  begin
    Closed := True;
    WriteLn;
    Exit(False);
  end;
  ReadLn(Input, Line);
  { When input comes from a file nothing is echoed by the terminal, so
    the typed value is printed here to keep the transcript readable. }
  if not Interactive then
    WriteLn(Line);
  Result := True;
end;

procedure UiRule;
begin
  WriteLn('+', StringOfChar('-', SCREEN_WIDTH - 2), '+');
end;

procedure UiTitle(const Title: string);
var
  Left, Right: string;
  Gap: Integer;
begin
  Left := ' ' + UpperCase(Title);
  Right := StatusText + ' ';
  Gap := SCREEN_WIDTH - 2 - Length(Left) - Length(Right);
  if Gap < 1 then
  begin
    Right := '';
    Gap := SCREEN_WIDTH - 2 - Length(Left);
    if Gap < 0 then
      Gap := 0;
  end;
  WriteLn;
  UiRule;
  WriteLn('|', Left, StringOfChar(' ', Gap), Right, '|');
  UiRule;
end;

procedure UiInfo(const Msg: string);
begin
  WriteLn('  ', Msg);
end;

procedure UiError(const Msg: string);
begin
  WriteLn('  ** ', Msg);
end;

procedure UiPause;
var
  Dummy: string;
begin
  if Interactive and not Closed then
    UiReadLine('  Press Enter to continue ', Dummy);
end;

procedure TableInit(var T: TTable; const Headers: array of string;
                    const RightAlignedColumns: array of Integer);
var
  I: Integer;
begin
  T.Rows := nil;
  T.Headers := nil;
  T.RightAlign := nil;
  SetLength(T.Headers, Length(Headers));
  SetLength(T.RightAlign, Length(Headers));
  for I := 0 to High(Headers) do
  begin
    T.Headers[I] := Headers[I];
    T.RightAlign[I] := False;
  end;
  for I := 0 to High(RightAlignedColumns) do
    if (RightAlignedColumns[I] >= 0) and (RightAlignedColumns[I] <= High(Headers)) then
      T.RightAlign[RightAlignedColumns[I]] := True;
end;

procedure TableAddRow(var T: TTable; const Cells: array of string);
var
  Row, I: Integer;
begin
  Row := Length(T.Rows);
  SetLength(T.Rows, Row + 1);
  SetLength(T.Rows[Row], Length(T.Headers));
  for I := 0 to High(T.Headers) do
    if I <= High(Cells) then
      T.Rows[Row][I] := Cells[I]
    else
      T.Rows[Row][I] := '';
end;

procedure TablePrint(const T: TTable);
var
  Widths: array of Integer;
  R, C: Integer;

  function Cell(const S: string; Col: Integer): string;
  begin
    if T.RightAlign[Col] then
      Result := StringOfChar(' ', Widths[Col] - Length(S)) + S
    else
      Result := S + StringOfChar(' ', Widths[Col] - Length(S));
  end;

begin
  { First pass: find the widest value in each column. }
  Widths := nil;
  SetLength(Widths, Length(T.Headers));
  for C := 0 to High(T.Headers) do
    Widths[C] := Length(T.Headers[C]);
  for R := 0 to High(T.Rows) do
    for C := 0 to High(T.Headers) do
      if Length(T.Rows[R][C]) > Widths[C] then
        Widths[C] := Length(T.Rows[R][C]);

  { Second pass: print. }
  Write('  ');
  for C := 0 to High(T.Headers) do
    Write(Cell(T.Headers[C], C), '  ');
  WriteLn;
  Write('  ');
  for C := 0 to High(T.Headers) do
    Write(StringOfChar('-', Widths[C]), '  ');
  WriteLn;
  for R := 0 to High(T.Rows) do
  begin
    Write('  ');
    for C := 0 to High(T.Headers) do
      Write(Cell(T.Rows[R][C], C), '  ');
    WriteLn;
  end;
end;

initialization
  { IsATTY asks the operating system whether standard input is a real
    terminal (a person typing) or a file or pipe (a script). }
  Interactive := IsATTY(Input) = 1;
end.

{ =====================================================================
  report.pas  --  run a query and print the rows as a table

  Most screens in the program are "ask a question, show a list". This
  unit joins the database layer (dbconn) to the display layer (screen)
  so each module can do that in one call.
  ===================================================================== }
unit report;

{$mode objfpc}{$H+}

interface

{ Runs Sql and prints the result under the given headings.
  RightAlignedColumns lists the columns (counting from 0) that hold
  numbers. Returns the number of rows printed. }
function ShowQuery(const Headers: array of string;
                   const RightAlignedColumns: array of Integer;
                   const Sql: string;
                   const Params: array of string): Integer;

implementation

uses
  dbconn, screen;

function ShowQuery(const Headers: array of string;
                   const RightAlignedColumns: array of Integer;
                   const Sql: string;
                   const Params: array of string): Integer;
var
  R: TDbResult;
  T: TTable;
  Cells: array of string;
  Row, Col: Integer;
begin
  R := DbQuery(Sql, Params);
  try
    Result := DbRowCount(R);
    if Result = 0 then
    begin
      UiInfo('(nothing to show)');
      Exit;
    end;

    TableInit(T, Headers, RightAlignedColumns);
    Cells := nil;
    SetLength(Cells, DbColCount(R));
    for Row := 0 to Result - 1 do
    begin
      for Col := 0 to High(Cells) do
        Cells[Col] := DbValue(R, Row, Col);
      TableAddRow(T, Cells);
    end;
    TablePrint(T);
  finally
    { The result is released even if printing raised an error. }
    DbFree(R);
  end;
end;

end.

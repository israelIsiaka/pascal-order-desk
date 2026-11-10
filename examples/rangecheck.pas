{ =====================================================================
  rangecheck.pas  --  what the -Cr compiler switch does

  The loop below has a classic off-by-one bug: the array has slots
  1 to 5, but the loop runs to 6. In memory the Total field sits
  directly after the array, so "slot 6" is really Total.

  Compile it twice and compare:

    fpc -O- examples/rangecheck.pas -FEbuild -FUbuild && ./build/rangecheck
        No checks. The loop writes past the end of the array and
        wipes out Total. No error, no warning, just a wrong answer.

    fpc -g -gl -Cr examples/rangecheck.pas -FEbuild -FUbuild && ./build/rangecheck
        Range checking on. The program stops at the faulty line with
        "Runtime error 201" and prints the file name and line number.
  ===================================================================== }
program rangecheck;

{$mode objfpc}{$H+}

type
  TShelf = record
    Stock: array[1..5] of Integer;
    Total: Integer;
  end;

var
  Shelf: TShelf;
  I: Integer;
begin
  Shelf.Total := 1000;
  for I := 1 to 6 do        { bug: should be 1 to 5 }
    Shelf.Stock[I] := 0;
  WriteLn('Total is ', Shelf.Total, ' (it was set to 1000 and nothing meant to change it)');
end.

{ =====================================================================
  forms.pas  --  a small forms manager

  The idea is the same one DEC Forms is built on: keep the description
  of what the operator sees apart from the program logic.

    * Each form lives in its own text file in the forms/ directory.
      It lists the fields, their types and their validation rules.
    * The application never prompts for input itself. It hands the
      forms manager a record (a set of named values) and asks it to
      SEND the record to the screen, RECEIVE a filled-in record from
      the operator, or do both (TRANSCEIVE).
    * All validation of what was typed happens here, before the
      application sees the data.

  Request      What it does
  -----------  ------------------------------------------------------
  FormsEnable  load every form definition (done once at start-up)
  FormSend     display a record, no input
  FormReceive  collect and validate a record from the operator
  FormReceiveBelow  the same, without redrawing the title bar
  FormTransceive  display one record, then collect another
  FormsDisable release the definitions (done once at shut-down)

  Changing a label, a maximum length or a default is a change to a
  .frm file. The Pascal code does not need to be recompiled.
  ===================================================================== }
unit forms;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  { The record passed between the application and the forms manager:
    a list of field names with a value for each. }
  TFormData = record
    Names:  array of string;
    Values: array of string;
  end;

  EFormError = class(Exception);

procedure FormsEnable(const Directory: string);
procedure FormsDisable;
function  FormsLoaded: Integer;

procedure RecordClear(var D: TFormData);
procedure FieldPut(var D: TFormData; const Name, Value: string);
function  FieldGet(const D: TFormData; const Name: string): string;

procedure FormSend(const FormName: string; const D: TFormData);
function  FormReceive(const FormName: string; var D: TFormData): Boolean;
function  FormReceiveBelow(const FormName: string; var D: TFormData): Boolean;
function  FormTransceive(const FormName: string; const SendData: TFormData;
                         var ReceiveData: TFormData): Boolean;

implementation

uses
  screen;

type
  TFieldKind = (fkText, fkInt, fkMoney, fkYesNo, fkDate, fkChoice);

  TFormField = record
    Name:       string;
    Caption:    string;
    Kind:       TFieldKind;
    Required:   Boolean;
    ForceUpper: Boolean;
    HasMin:     Boolean;
    HasMax:     Boolean;
    MinValue:   Int64;
    MaxValue:   Int64;
    MaxLen:     Integer;
    DefaultVal: string;
    Choices:    array of string;
  end;

  TFormDef = record
    Name:   string;
    Title:  string;
    Help:   array of string;
    Fields: array of TFormField;
  end;

var
  Defs: array of TFormDef;

{ ---------------------------------------------------------------------
  Form records
  --------------------------------------------------------------------- }

procedure RecordClear(var D: TFormData);
begin
  D.Names := nil;
  D.Values := nil;
end;

procedure FieldPut(var D: TFormData; const Name, Value: string);
var
  I: Integer;
begin
  for I := 0 to High(D.Names) do
    if D.Names[I] = Name then
    begin
      D.Values[I] := Value;
      Exit;
    end;
  I := Length(D.Names);
  SetLength(D.Names, I + 1);
  SetLength(D.Values, I + 1);
  D.Names[I] := Name;
  D.Values[I] := Value;
end;

function FieldGet(const D: TFormData; const Name: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(D.Names) do
    if D.Names[I] = Name then
      Exit(D.Values[I]);
end;

{ ---------------------------------------------------------------------
  Reading .frm files
  --------------------------------------------------------------------- }

type
  TTokens = array of string;

{ Splits a line into words. Text inside double quotes stays together,
  so   FIELD city TEXT "Town or city"   gives four tokens. }
function Tokenise(const Line: string): TTokens;
var
  I, N: Integer;
  Current: string;
  InQuotes, HaveToken: Boolean;

  procedure Push;
  begin
    N := Length(Result);
    SetLength(Result, N + 1);
    Result[N] := Current;
    Current := '';
    HaveToken := False;
  end;

begin
  Result := nil;
  Current := '';
  InQuotes := False;
  HaveToken := False;
  for I := 1 to Length(Line) do
  begin
    if Line[I] = '"' then
    begin
      InQuotes := not InQuotes;
      HaveToken := True;
    end
    else if (Line[I] in [' ', #9]) and not InQuotes then
    begin
      if HaveToken then
        Push;
    end
    else
    begin
      Current := Current + Line[I];
      HaveToken := True;
    end;
  end;
  if HaveToken then
    Push;
end;

{ Everything after the first word of the line, trimmed. }
function RestOfLine(const Line: string): string;
var
  P: Integer;
  S: string;
begin
  S := TrimLeft(Line);
  P := 1;
  while (P <= Length(S)) and not (S[P] in [' ', #9]) do
    Inc(P);
  Result := Trim(Copy(S, P, MaxInt));
end;

function SplitCommas(const S: string): TTokens;
var
  Rest: string;
  P, N: Integer;
begin
  Result := nil;
  Rest := S;
  repeat
    P := Pos(',', Rest);
    N := Length(Result);
    SetLength(Result, N + 1);
    if P = 0 then
    begin
      Result[N] := Trim(Rest);
      Rest := '';
    end
    else
    begin
      Result[N] := Trim(Copy(Rest, 1, P - 1));
      Delete(Rest, 1, P);
    end;
  until P = 0;
end;

function ParseField(const T: TTokens; const FileName: string; LineNo: Integer): TFormField;
var
  I: Integer;
  Kind, Opt: string;

  procedure Fail(const Msg: string);
  begin
    raise EFormError.CreateFmt('%s line %d: %s', [FileName, LineNo, Msg]);
  end;

  function NextValue: string;
  begin
    Inc(I);
    if I > High(T) then
      Fail('"' + Opt + '" needs a value after it');
    Result := T[I];
  end;

begin
  if Length(T) < 4 then
    Fail('expected: FIELD name TYPE "Label" [options]');

  Result.Name := LowerCase(T[1]);
  Result.Caption := T[3];
  Result.Required := False;
  Result.ForceUpper := False;
  Result.HasMin := False;
  Result.HasMax := False;
  Result.MinValue := 0;
  Result.MaxValue := 0;
  Result.MaxLen := 0;
  Result.DefaultVal := '';
  Result.Choices := nil;

  Kind := UpperCase(T[2]);
  if      Kind = 'TEXT'   then Result.Kind := fkText
  else if Kind = 'INT'    then Result.Kind := fkInt
  else if Kind = 'MONEY'  then Result.Kind := fkMoney
  else if Kind = 'YESNO'  then Result.Kind := fkYesNo
  else if Kind = 'DATE'   then Result.Kind := fkDate
  else if Kind = 'CHOICE' then Result.Kind := fkChoice
  else Fail('unknown field type "' + T[2] + '"');

  I := 4;
  while I <= High(T) do
  begin
    Opt := UpperCase(T[I]);
    if      Opt = 'REQUIRED' then Result.Required := True
    else if Opt = 'OPTIONAL' then Result.Required := False
    else if Opt = 'UPPER'    then Result.ForceUpper := True
    else if Opt = 'MIN'      then
    begin
      Result.HasMin := True;
      Result.MinValue := StrToInt64(NextValue);
    end
    else if Opt = 'MAX'      then
    begin
      Result.HasMax := True;
      Result.MaxValue := StrToInt64(NextValue);
    end
    else if Opt = 'MAXLEN'   then Result.MaxLen := StrToInt(NextValue)
    else if Opt = 'DEFAULT'  then Result.DefaultVal := NextValue
    else if Opt = 'VALUES'   then Result.Choices := SplitCommas(UpperCase(NextValue))
    else Fail('unknown option "' + T[I] + '"');
    Inc(I);
  end;

  if (Result.Kind = fkChoice) and (Length(Result.Choices) = 0) then
    Fail('a CHOICE field needs VALUES a,b,c');
end;

procedure LoadFormFile(const FileName: string);
var
  F: TextFile;
  Line, Keyword: string;
  T: TTokens;
  Def: TFormDef;
  LineNo, N: Integer;
begin
  Def.Name := '';
  Def.Title := '';
  Def.Help := nil;
  Def.Fields := nil;
  LineNo := 0;

  AssignFile(F, FileName);
  Reset(F);
  try
    while not EOF(F) do
    begin
      ReadLn(F, Line);
      Inc(LineNo);
      Line := Trim(Line);
      if (Line = '') or (Line[1] = '#') then
        Continue;

      T := Tokenise(Line);
      Keyword := UpperCase(T[0]);

      if Keyword = 'FORM' then
        Def.Name := LowerCase(RestOfLine(Line))
      else if Keyword = 'TITLE' then
        Def.Title := RestOfLine(Line)
      else if Keyword = 'HELP' then
      begin
        N := Length(Def.Help);
        SetLength(Def.Help, N + 1);
        Def.Help[N] := RestOfLine(Line);
      end
      else if Keyword = 'FIELD' then
      begin
        N := Length(Def.Fields);
        SetLength(Def.Fields, N + 1);
        Def.Fields[N] := ParseField(T, FileName, LineNo);
      end
      else
        raise EFormError.CreateFmt('%s line %d: unknown keyword "%s"',
                                   [FileName, LineNo, T[0]]);
    end;
  finally
    CloseFile(F);
  end;

  if Def.Name = '' then
    raise EFormError.CreateFmt('%s: the file has no FORM line', [FileName]);
  if Def.Title = '' then
    Def.Title := Def.Name;

  N := Length(Defs);
  SetLength(Defs, N + 1);
  Defs[N] := Def;
end;

procedure FormsEnable(const Directory: string);
var
  Info: TSearchRec;
  Dir: string;
begin
  Defs := nil;
  Dir := IncludeTrailingPathDelimiter(Directory);
  if FindFirst(Dir + '*.frm', faAnyFile, Info) = 0 then
  begin
    repeat
      LoadFormFile(Dir + Info.Name);
    until FindNext(Info) <> 0;
    FindClose(Info);
  end;
  if Length(Defs) = 0 then
    raise EFormError.Create('No form definitions (*.frm) found in ' + Directory);
end;

procedure FormsDisable;
begin
  Defs := nil;
end;

function FormsLoaded: Integer;
begin
  Result := Length(Defs);
end;

function FindForm(const FormName: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(Defs) do
    if Defs[I].Name = LowerCase(FormName) then
      Exit(I);
  raise EFormError.Create('Form "' + FormName + '" is not loaded');
end;

{ ---------------------------------------------------------------------
  Validation: one function per field type. Each returns '' when the
  value is acceptable, or the message to show the operator.
  On success Value may be tidied (upper-cased, "yes" turned into "Y").
  --------------------------------------------------------------------- }

function CheckInt(const Fld: TFormField; var Value: string): string;
var
  N: Int64;
begin
  Result := '';
  if not TryStrToInt64(Value, N) then
    Exit('Please enter a whole number');
  if Fld.HasMin and (N < Fld.MinValue) then
    Exit('Must be at least ' + IntToStr(Fld.MinValue));
  if Fld.HasMax and (N > Fld.MaxValue) then
    Exit('Must be at most ' + IntToStr(Fld.MaxValue));
  Value := IntToStr(N);
end;

{ Money is checked as text and stays as text. It is never converted to
  a floating point number, because binary floating point cannot hold
  values like 0.10 exactly. All arithmetic on money happens in the
  database, in the exact NUMERIC type. }
function CheckMoney(const Value: string): string;
var
  I, Dots, Decimals: Integer;
begin
  Result := '';
  Dots := 0;
  Decimals := 0;
  for I := 1 to Length(Value) do
    if Value[I] = '.' then
      Inc(Dots)
    else if Value[I] in ['0'..'9'] then
    begin
      if Dots > 0 then
        Inc(Decimals);
    end
    else
      Exit('Please enter an amount such as 12.50');
  if (Dots > 1) or (Decimals > 2) or (Value = '.') then
    Exit('Please enter an amount such as 12.50');
  if Length(Value) - Dots - Decimals > 9 then
    Exit('That amount is too large');
end;

function CheckYesNo(var Value: string): string;
var
  U: string;
begin
  Result := '';
  U := UpperCase(Value);
  if (U = 'Y') or (U = 'YES') then
    Value := 'Y'
  else if (U = 'N') or (U = 'NO') then
    Value := 'N'
  else
    Result := 'Please answer Y or N';
end;

function CheckDate(var Value: string): string;
var
  Y, M, D: Integer;
  Dt: TDateTime;
begin
  Result := 'Please enter a date as YYYY-MM-DD';
  if (Length(Value) <> 10) or (Value[5] <> '-') or (Value[8] <> '-') then
    Exit;
  if not (TryStrToInt(Copy(Value, 1, 4), Y) and
          TryStrToInt(Copy(Value, 6, 2), M) and
          TryStrToInt(Copy(Value, 9, 2), D)) then
    Exit;
  if not TryEncodeDate(Y, M, D, Dt) then
    Exit;
  Result := '';
end;

function CheckChoice(const Fld: TFormField; var Value: string): string;
var
  I: Integer;
  U, List: string;
begin
  U := UpperCase(Value);
  List := '';
  for I := 0 to High(Fld.Choices) do
  begin
    { The full word or just its first letter is accepted. }
    if (Fld.Choices[I] = U) or
       ((Length(U) = 1) and (Fld.Choices[I] <> '') and (Fld.Choices[I][1] = U[1])) then
    begin
      Value := Fld.Choices[I];
      Exit('');
    end;
    if List <> '' then
      List := List + ', ';
    List := List + Fld.Choices[I];
  end;
  Result := 'Please choose one of: ' + List;
end;

function CheckText(const Fld: TFormField; var Value: string): string;
begin
  Result := '';
  if Fld.ForceUpper then
    Value := UpperCase(Value);
  if (Fld.MaxLen > 0) and (Length(Value) > Fld.MaxLen) then
    Result := 'At most ' + IntToStr(Fld.MaxLen) + ' characters';
end;

function ValidateField(const Fld: TFormField; var Value: string): string;
begin
  case Fld.Kind of
    fkInt:    Result := CheckInt(Fld, Value);
    fkMoney:  Result := CheckMoney(Value);
    fkYesNo:  Result := CheckYesNo(Value);
    fkDate:   Result := CheckDate(Value);
    fkChoice: Result := CheckChoice(Fld, Value);
  else
    Result := CheckText(Fld, Value);
  end;
end;

{ A short reminder of what the field accepts, shown inside the prompt. }
function FieldHint(const Fld: TFormField): string;
var
  I: Integer;
begin
  Result := '';
  case Fld.Kind of
    fkYesNo: Result := 'Y/N';
    fkDate:  Result := 'YYYY-MM-DD';
    fkChoice:
      for I := 0 to High(Fld.Choices) do
      begin
        if I > 0 then
          Result := Result + '/';
        Result := Result + Fld.Choices[I];
      end;
  end;
end;

{ ---------------------------------------------------------------------
  The three requests
  --------------------------------------------------------------------- }

procedure ShowHeader(const Def: TFormDef);
var
  I: Integer;
begin
  UiTitle(Def.Title);
  for I := 0 to High(Def.Help) do
    UiInfo(Def.Help[I]);
end;

{ SEND: display the record. Nothing is read from the operator. }
procedure FormSend(const FormName: string; const D: TFormData);
var
  Def: TFormDef;
  I, Width: Integer;
begin
  Def := Defs[FindForm(FormName)];
  ShowHeader(Def);
  Width := 0;
  for I := 0 to High(Def.Fields) do
    if Length(Def.Fields[I].Caption) > Width then
      Width := Length(Def.Fields[I].Caption);
  for I := 0 to High(Def.Fields) do
    WriteLn('  ', Def.Fields[I].Caption,
            StringOfChar(' ', Width - Length(Def.Fields[I].Caption)),
            ' : ', FieldGet(D, Def.Fields[I].Name));
end;

{ Asks for one field until the value is valid.
  Returns False if the operator cancels the form. }
function ReceiveField(const Fld: TFormField; var Value: string): Boolean;
var
  Prompt, Hint, Line, Problem: string;
begin
  Hint := FieldHint(Fld);
  repeat
    Prompt := '  ' + Fld.Caption;
    if Hint <> '' then
      Prompt := Prompt + ' (' + Hint + ')';
    if Value <> '' then
      Prompt := Prompt + ' [' + Value + ']';
    Prompt := Prompt + ': ';

    if not UiReadLine(Prompt, Line) then
      Exit(False);
    Line := Trim(Line);

    if LowerCase(Line) = '/c' then
      Exit(False);

    { An empty answer keeps the value shown in square brackets. }
    if Line = '' then
      Line := Value;

    if Line = '' then
    begin
      if Fld.Required then
      begin
        UiError('This field is required. Type /c to cancel.');
        Continue;
      end;
      Value := '';
      Exit(True);
    end;

    Problem := ValidateField(Fld, Line);
    if Problem = '' then
    begin
      Value := Line;
      Exit(True);
    end;
    UiError(Problem);
  until False;
end;

function ReceiveFields(const Def: TFormDef; var D: TFormData): Boolean;
var
  I: Integer;
  Value: string;
begin
  for I := 0 to High(Def.Fields) do
  begin
    { Start from the value already in the record, if the application
      supplied one, otherwise from the DEFAULT in the form file. }
    Value := FieldGet(D, Def.Fields[I].Name);
    if Value = '' then
      Value := Def.Fields[I].DefaultVal;
    if not ReceiveField(Def.Fields[I], Value) then
      Exit(False);
    FieldPut(D, Def.Fields[I].Name, Value);
  end;
  Result := True;
end;

{ RECEIVE: collect a validated record from the operator.
  Returns False if the operator typed /c or input ended. }
function FormReceive(const FormName: string; var D: TFormData): Boolean;
var
  Def: TFormDef;
begin
  Def := Defs[FindForm(FormName)];
  ShowHeader(Def);
  Result := ReceiveFields(Def, D);
end;

{ RECEIVE without drawing the title bar. Used when the application has
  already displayed something (the main menu) and only wants the
  form's fields prompted and validated underneath it. }
function FormReceiveBelow(const FormName: string; var D: TFormData): Boolean;
begin
  Result := ReceiveFields(Defs[FindForm(FormName)], D);
end;

{ TRANSCEIVE: show SendData, then collect ReceiveData on the same form.
  Fields that appear in SendData are displayed and not asked for again;
  the remaining fields are prompted. }
function FormTransceive(const FormName: string; const SendData: TFormData;
                        var ReceiveData: TFormData): Boolean;
var
  Def, Ask: TFormDef;
  I, J, N, Width: Integer;
  Sent: Boolean;
begin
  Def := Defs[FindForm(FormName)];
  ShowHeader(Def);

  Ask := Def;
  Ask.Fields := nil;
  Width := 0;
  for I := 0 to High(Def.Fields) do
    if Length(Def.Fields[I].Caption) > Width then
      Width := Length(Def.Fields[I].Caption);

  for I := 0 to High(Def.Fields) do
  begin
    Sent := False;
    for J := 0 to High(SendData.Names) do
      if SendData.Names[J] = Def.Fields[I].Name then
        Sent := True;
    if Sent then
      WriteLn('  ', Def.Fields[I].Caption,
              StringOfChar(' ', Width - Length(Def.Fields[I].Caption)),
              ' : ', FieldGet(SendData, Def.Fields[I].Name))
    else
    begin
      N := Length(Ask.Fields);
      SetLength(Ask.Fields, N + 1);
      Ask.Fields[N] := Def.Fields[I];
    end;
  end;

  Result := ReceiveFields(Ask, ReceiveData);
end;

end.

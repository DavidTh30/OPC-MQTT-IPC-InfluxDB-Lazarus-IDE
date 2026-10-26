{ ============================================================================
  ulineproto - InfluxDB line protocol
      measurement[,tag=value...] field=value[,field=value...] [timestamp]
    - escapes: \, \space \= in names and tags, \" \\ in string fields
    - field values: 1.5 (float), 1i (integer), 1u (unsigned, kept as integer),
      "text" (string), t / true / f / false ... (boolean)
    - timestamp in the precision of the request (ns, u, ms, s, m, h),
      missing = the time of the server
  Also writes points back as line protocol (WAL and snapshot files).
  ============================================================================ }
unit ulineproto;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math;

type
  TFieldKind = (fkFloat, fkInteger, fkString, fkBoolean);

  TFieldValue = record
    Kind: TFieldKind;
    D: Double;                    // float
    I: Int64;                     // integer, boolean (0 / 1)
    S: string;                    // string
  end;

  TLinePoint = record
    Measurement: string;
    TagKeys, TagValues: array of string;   // sorted by key
    FieldKeys: array of string;
    FieldValues: array of TFieldValue;
    Time: Int64;                  // ns since 1970 (UTC)
  end;

const
  FieldKindName: array[TFieldKind] of string = ('float', 'integer', 'string', 'boolean');

{ ns per unit of a precision ("ns", "n", "u", "us", "ms", "s", "m", "h"), 0 = unknown }
function PrecisionFactor(const P: string): Int64;
{ one line; False = error (Err) }
function ParseLine(const Line: string; Factor: Int64; NowNs: Int64; out P: TLinePoint;
  out Err: string): Boolean;
function FormatLine(const P: TLinePoint): string;
function EscapeName(const S: string; Equals: Boolean): string;
function FieldValueText(const V: TFieldValue): string;
{ the time now in ns since 1970 UTC (100 ns resolution) }
function NowNs: Int64;

implementation

{$IFDEF WINDOWS}
uses
  Windows;
{$ENDIF}

var
  FS: TFormatSettings;

function NowNs: Int64;
{$IFDEF WINDOWS}
var
  FT: TFileTime;
begin
  GetSystemTimeAsFileTime(FT);
  Result := (((Int64(FT.dwHighDateTime) shl 32) or FT.dwLowDateTime) - 116444736000000000) * 100;
end;
{$ELSE}
begin
  Result := Round((Now - UnixDateDelta) * Double(86400000)) * 1000000;
end;
{$ENDIF}

function PrecisionFactor(const P: string): Int64;
begin
  case LowerCase(P) of
    '', 'n', 'ns': Result := 1;
    'u', 'us', #$C2#$B5: Result := 1000;
    'ms': Result := 1000000;
    's': Result := 1000000000;
    'm': Result := 60000000000;
    'h': Result := 3600000000000;
  else
    Result := 0;
  end;
end;

{ read up to an unescaped character of Stops; P moves to that character }
function ReadEscaped(const L: string; var P: Integer; const Stops: TSysCharSet): string;
begin
  Result := '';
  while P <= Length(L) do
  begin
    if (L[P] = '\') and (P < Length(L)) and (L[P + 1] in Stops + ['\']) then
    begin
      Result := Result + L[P + 1];
      Inc(P, 2);
      Continue;
    end;
    if L[P] in Stops then Break;
    Result := Result + L[P];
    Inc(P);
  end;
end;

function ParseFieldValue(const L: string; var P: Integer; out V: TFieldValue; out Err: string): Boolean;
var
  Start: Integer;
  T: string;
  C: Integer;
begin
  Result := False;
  V := Default(TFieldValue);
  if P > Length(L) then
  begin
    Err := 'missing field value';
    Exit;
  end;
  if L[P] = '"' then                              // string, may hold spaces and commas
  begin
    Inc(P);
    T := '';
    while (P <= Length(L)) and (L[P] <> '"') do
    begin
      if (L[P] = '\') and (P < Length(L)) and (L[P + 1] in ['"', '\']) then
        Inc(P);
      T := T + L[P];
      Inc(P);
    end;
    if P > Length(L) then
    begin
      Err := 'unterminated string';
      Exit;
    end;
    Inc(P);
    V.Kind := fkString;
    V.S := T;
    Exit(True);
  end;
  Start := P;
  while (P <= Length(L)) and not (L[P] in [',', ' ']) do Inc(P);
  T := Copy(L, Start, P - Start);
  if T = '' then
  begin
    Err := 'missing field value';
    Exit;
  end;
  case T of
    't', 'T', 'true', 'True', 'TRUE':
      begin
        V.Kind := fkBoolean;
        V.I := 1;
        Exit(True);
      end;
    'f', 'F', 'false', 'False', 'FALSE':
      begin
        V.Kind := fkBoolean;
        V.I := 0;
        Exit(True);
      end;
  end;
  if T[Length(T)] in ['i', 'u'] then
  begin
    Val(Copy(T, 1, Length(T) - 1), V.I, C);
    if (C <> 0) or ((T[Length(T)] = 'u') and (V.I < 0)) then
    begin
      Err := 'invalid integer ' + T;
      Exit;
    end;
    V.Kind := fkInteger;
    Exit(True);
  end;
  if not TryStrToFloat(T, V.D, FS) or (T[1] in ['e', 'E']) then
  begin
    Err := 'invalid number ' + T;
    Exit;
  end;
  V.Kind := fkFloat;
  Result := True;
end;

function ParseLine(const Line: string; Factor: Int64; NowNs: Int64; out P: TLinePoint;
  out Err: string): Boolean;
var
  I, J, N: Integer;
  K, V, TS: string;
  FV: TFieldValue;
  Code: Integer;
  T: Int64;
begin
  Result := False;
  P := Default(TLinePoint);
  Err := '';
  I := 1;
  P.Measurement := ReadEscaped(Line, I, [',', ' ']);
  if P.Measurement = '' then
  begin
    Err := 'missing measurement';
    Exit;
  end;
  { tags }
  while (I <= Length(Line)) and (Line[I] = ',') do
  begin
    Inc(I);
    K := ReadEscaped(Line, I, ['=', ',', ' ']);
    if (I > Length(Line)) or (Line[I] <> '=') or (K = '') then
    begin
      Err := 'missing tag value';
      Exit;
    end;
    Inc(I);
    V := ReadEscaped(Line, I, [',', ' ']);
    if V = '' then
    begin
      Err := 'missing tag value for ' + K;
      Exit;
    end;
    { insert sorted (a key twice: the last one counts) }
    N := Length(P.TagKeys);
    J := 0;
    while (J < N) and (P.TagKeys[J] < K) do Inc(J);
    if (J < N) and (P.TagKeys[J] = K) then
      P.TagValues[J] := V
    else
    begin
      Insert(K, P.TagKeys, J);
      Insert(V, P.TagValues, J);
    end;
  end;
  if (I > Length(Line)) or (Line[I] <> ' ') then
  begin
    Err := 'missing fields';
    Exit;
  end;
  while (I <= Length(Line)) and (Line[I] = ' ') do Inc(I);
  { fields }
  repeat
    K := ReadEscaped(Line, I, ['=', ',', ' ']);
    if (I > Length(Line)) or (Line[I] <> '=') or (K = '') then
    begin
      Err := 'invalid field format';
      Exit;
    end;
    Inc(I);
    if not ParseFieldValue(Line, I, FV, Err) then Exit;
    N := Length(P.FieldKeys);
    J := 0;
    while (J < N) and (P.FieldKeys[J] <> K) do Inc(J);
    if J < N then
      P.FieldValues[J] := FV
    else
    begin
      SetLength(P.FieldKeys, N + 1);
      SetLength(P.FieldValues, N + 1);
      P.FieldKeys[N] := K;
      P.FieldValues[N] := FV;
    end;
    if (I <= Length(Line)) and (Line[I] = ',') then
      Inc(I)
    else
      Break;
  until False;
  { timestamp }
  while (I <= Length(Line)) and (Line[I] = ' ') do Inc(I);
  TS := Trim(Copy(Line, I, MaxInt));
  if TS = '' then
    P.Time := NowNs
  else
  begin
    Val(TS, T, Code);
    if Code <> 0 then
    begin
      Err := 'invalid timestamp ' + TS;
      Exit;
    end;
    if (Factor > 1) and ((T > High(Int64) div Factor) or (T < Low(Int64) div Factor)) then
    begin
      Err := 'timestamp out of range ' + TS;
      Exit;
    end;
    P.Time := T * Factor;
  end;
  Result := True;
end;

function EscapeName(const S: string; Equals: Boolean): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    if (S[I] in [',', ' ', '\']) or (Equals and (S[I] = '=')) then
      Result := Result + '\';
    Result := Result + S[I];
  end;
end;

function FloatText(D: Double): string;
begin
  if IsNan(D) or IsInfinite(D) then
    Exit('0');
  Result := FloatToStrF(D, ffGeneral, 15, 0, FS);
  if StrToFloat(Result, FS) <> D then
    Result := FloatToStrF(D, ffGeneral, 17, 0, FS);   // keep every bit
end;

function FieldValueText(const V: TFieldValue): string;
var
  I: Integer;
begin
  case V.Kind of
    fkFloat: Result := FloatText(V.D);
    fkInteger: Result := IntToStr(V.I) + 'i';
    fkBoolean: if V.I <> 0 then Result := 'true' else Result := 'false';
  else
    Result := '"';
    for I := 1 to Length(V.S) do
    begin
      if V.S[I] in ['"', '\'] then Result := Result + '\';
      Result := Result + V.S[I];
    end;
    Result := Result + '"';
  end;
end;

function FormatLine(const P: TLinePoint): string;
var
  I: Integer;
begin
  Result := EscapeName(P.Measurement, False);
  for I := 0 to High(P.TagKeys) do
    Result := Result + ',' + EscapeName(P.TagKeys[I], True) + '=' + EscapeName(P.TagValues[I], True);
  for I := 0 to High(P.FieldKeys) do
  begin
    if I = 0 then Result := Result + ' ' else Result := Result + ',';
    Result := Result + EscapeName(P.FieldKeys[I], True) + '=' + FieldValueText(P.FieldValues[I]);
  end;
  Result := Result + ' ' + IntToStr(P.Time);
end;

initialization
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  FS.ThousandSeparator := #0;
end.

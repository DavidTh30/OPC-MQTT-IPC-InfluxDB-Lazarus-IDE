{ ============================================================================
  uqueryexec - runs InfluxQL statements (uinfluxql) on the store (utsdb) and
  writes the JSON of the InfluxDB 1.x /query API: results[] -> statement_id,
    series[] -> name, tags, columns ["time","mean"], values [["2026-10-26T08:00:00Z",1.5], ...]
  SELECT
    - raw: fields, tags, arithmetic (+ - * / %), * = all fields and tags
    - aggregates: count sum mean median min max first last spread stddev mode
      percentile(x, N), also as mean(*) and in arithmetic (mean(a) * 2)
    - transforms of a raw field or an aggregate: derivative, non_negative_derivative
      (unit, default 1s), difference, non_negative_difference, cumulative_sum,
      moving_average(x, N), elapsed(x, unit)
    - GROUP BY time(i[, offset]) with fill, GROUP BY tags / *
    - WHERE: time with now() - 1h, '2026-10-26T08:00:00Z', 1698000000000ms;
      tags and fields with = != < <= > >=, =~ !~ /regex/, AND, OR, ( )
    - GROUP BY time without an upper time bound ends at now()
  ============================================================================ }
unit uqueryexec;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  Classes, SysUtils, Math, ulineproto, utsdb, uinfluxql;

{ EpochFactor: 0 = RFC3339 times, else ns per unit of the epoch parameter }
function ExecuteQuery(Store: TStore; const Q, DefaultDb: string; EpochFactor: Int64;
  out HttpCode: Integer): string;
function JsonString(const S: string): string;

implementation

const
  MAX_ROWS = 2000000;
  MAX_CELLS = 5000000;         // buckets x aggregate calls per output series
  SLOT_TAG = -1;
  SLOT_TIME = -2;

type
  TQKind = (qkNull, qkFloat, qkInt, qkString, qkBool);

  TQValue = record
    Kind: TQKind;
    D: Double;
    I: Int64;
    S: string;
  end;
  TQValues = array of TQValue;
  TDoubleArray = array of Double;

  TAggState = record
    Count: Int64;
    Mean, M2, Sum: Double;
    AllInt: Boolean;
    Min, Max: Double;
    MinT, MaxT: Int64;
    First, Last: TQValue;
    FirstT, LastT: Int64;
    Vals: array of Double;
    NV: Integer;
  end;
  PAggState = ^TAggState;

  TItem = record
    Expr: TExpr;                  // the value (of a transform: its argument)
    Owned: Boolean;               // made by a * expansion, freed after the measurement
    Name: string;
    Transform: string;            // '' or derivative, difference, ...
    TUnit: Int64;                 // derivative / elapsed unit (ns)
    TN: Integer;                  // moving_average window
  end;

  TCall = record
    Expr: TExpr;
    Fn: string;
    Pct: Double;
    NeedVals: Boolean;
  end;

  { TGroup - one output series }

  TGroup = class
    TagKeys, TagValues: array of string;
    Times: array of Int64;
    Rows: array of TQValues;
    N: Integer;
    States: array of TAggState;   // bucket * calls
    Used: array of Boolean;       // the bucket has points
    procedure AddRow(T: Int64; const V: TQValues);
  end;

  TRow = record
    T: Int64;
    Series: TSeries;
    Vals: TQValues;               // per needed field
  end;

  { TOut - growing string }

  TOut = record
    Buf: string;
    Len: Integer;
    procedure Add(const S: string);
    function Text: string;
  end;

  { TExec }

  TExec = class
  private
    FStore: TStore;
    FDefaultDb: string;
    FEpoch: Int64;
    FNow: Int64;
    FOut: TOut;
    FSeriesCount, FRowsInSeries: Integer;
    FSkip, FLeft: Integer;        // SOFFSET / SLIMIT still to apply
    FCond: TExpr;                 // SeriesMatch: condition and the measurement it is resolved for
    FMeas: TMeasurement;
    function Db(S: TStatement; Required: Boolean): TDatabase;
    function TimeText(T: Int64): string;
    function ValueText(const V: TQValue): string;
    procedure BeginSeries(const Name: string; const TagK, TagV: array of string;
      const Cols: array of string);
    procedure EndSeries;
    procedure Row(const Vals: array of string);
    procedure Measurements(D: TDatabase; S: TStatement; L: TList);
    function SeriesMatch(M: TMeasurement; Ser: TSeries): Boolean;
    procedure OutputGroup(S: TStatement; M: TMeasurement; G: TGroup; const Items: array of TItem;
      Raw: Boolean);
    procedure SelectMeasurement(S: TStatement; M: TMeasurement; T0, T1: Int64);
    procedure RunSelect(S: TStatement);
    procedure RunShow(S: TStatement);
    procedure RunDelete(S: TStatement);
    procedure Statement(S: TStatement; Id: Integer);
  public
    constructor Create(AStore: TStore; const ADefaultDb: string; AEpoch: Int64);
    function Run(const Q: string; out Code: Integer): string;
  end;

var
  FS: TFormatSettings;

{ ---------------------------------------------------------------------------- }
{ values }

function QNull: TQValue;
begin
  Result := Default(TQValue);
end;

function QFloat(D: Double): TQValue;
begin
  Result := Default(TQValue);
  if IsNan(D) or IsInfinite(D) then Exit;
  Result.Kind := qkFloat;
  Result.D := D;
end;

function QInt(I: Int64): TQValue;
begin
  Result := Default(TQValue);
  Result.Kind := qkInt;
  Result.I := I;
  Result.D := I;
end;

function QStr(const S: string): TQValue;
begin
  Result := Default(TQValue);
  Result.Kind := qkString;
  Result.S := S;
end;

function QBool(B: Boolean): TQValue;
begin
  Result := Default(TQValue);
  Result.Kind := qkBool;
  Result.I := Ord(B);
end;

function IsNum(const V: TQValue): Boolean;
begin
  Result := V.Kind in [qkFloat, qkInt];
end;

function NumOf(const V: TQValue): Double;
begin
  if V.Kind = qkInt then Result := V.I else Result := V.D;
end;

function FromField(const F: TFieldValue): TQValue;
begin
  case F.Kind of
    fkFloat: Result := QFloat(F.D);
    fkInteger: Result := QInt(F.I);
    fkBoolean: Result := QBool(F.I <> 0);
  else
    Result := QStr(F.S);
  end;
end;

function MaybeInt(D: Double; AllInt: Boolean): TQValue;
begin
  if AllInt and (Abs(D) < 9e18) then Result := QInt(Round(D)) else Result := QFloat(D);
end;

function JsonString(const S: string): string;
var
  I: Integer;
begin
  Result := '"';
  for I := 1 to Length(S) do
    case S[I] of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #10: Result := Result + '\n';
      #13: Result := Result + '\r';
      #9: Result := Result + '\t';
      #0..#8, #11, #12, #14..#31: Result := Result + '\u' + IntToHex(Ord(S[I]), 4);
    else
      Result := Result + S[I];
    end;
  Result := Result + '"';
end;

function FloatJson(D: Double): string;
begin
  if IsNan(D) or IsInfinite(D) then Exit('null');
  if (Frac(D) = 0) and (Abs(D) < 1e15) then
    Exit(IntToStr(Trunc(D)));                    // 5, not 5.0 (as InfluxDB)
  Result := FloatToStrF(D, ffGeneral, 15, 0, FS);
  if StrToFloat(Result, FS) <> D then
    Result := FloatToStrF(D, ffGeneral, 17, 0, FS);
end;

{ ---------------------------------------------------------------------------- }
{ expressions }

function CloneExpr(E: TExpr): TExpr;
var
  I: Integer;
begin
  if E = nil then Exit(nil);
  Result := TExpr.Create;
  Result.Kind := E.Kind;
  Result.Name := E.Name;
  Result.Num := E.Num;
  Result.Int := E.Int;
  Result.Cast := E.Cast;
  Result.Slot := E.Slot;
  SetLength(Result.Args, Length(E.Args));
  for I := 0 to High(E.Args) do
    Result.Args[I] := CloneExpr(E.Args[I]);
  Result.Left := CloneExpr(E.Left);
  Result.Right := CloneExpr(E.Right);
end;

function NewIdent(const Name, Cast: string): TExpr;
begin
  Result := TExpr.Create;
  Result.Kind := ekIdent;
  Result.Name := Name;
  Result.Cast := Cast;
  Result.Slot := -3;
end;

function EvalTime(E: TExpr; NowT: Int64): Int64;
var
  R: Int64;
begin
  case E.Kind of
    ekCall:
      if E.Name = 'now' then Exit(NowT);
    ekInteger, ekDuration: Exit(E.Int);
    ekNumber: Exit(Round(E.Num));
    ekString:
      if ParseTimeString(E.Name, Result) then Exit
      else raise EInfluxQL.Create('invalid time ''' + E.Name + '''');
    ekBinary:
      if (E.Name = '+') or (E.Name = '-') then
      begin
        R := EvalTime(E.Right, NowT);
        if E.Name = '+' then Exit(EvalTime(E.Left, NowT) + R)
        else Exit(EvalTime(E.Left, NowT) - R);
      end;
  end;
  raise EInfluxQL.Create('invalid time expression');
end;

function IsTimeIdent(E: TExpr): Boolean;
begin
  Result := (E <> nil) and (E.Kind = ekIdent) and SameText(E.Name, 'time');
end;

function FlipOp(const Op: string): string;
begin
  case Op of
    '<': Result := '>';
    '<=': Result := '>=';
    '>': Result := '<';
    '>=': Result := '<=';
  else
    Result := Op;
  end;
end;

{ time bounds from the ANDs of a condition (an OR keeps the whole range) }
procedure TimeRange(E: TExpr; NowT: Int64; var T0, T1: Int64);
var
  Op: string;
  V: Int64;
  Other: TExpr;
begin
  if (E = nil) or (E.Kind <> ekBinary) then Exit;
  if E.Name = 'AND' then
  begin
    TimeRange(E.Left, NowT, T0, T1);
    TimeRange(E.Right, NowT, T0, T1);
    Exit;
  end;
  if IsTimeIdent(E.Left) then
  begin
    Op := E.Name;
    Other := E.Right;
  end
  else if IsTimeIdent(E.Right) then
  begin
    Op := FlipOp(E.Name);
    Other := E.Left;
  end
  else
    Exit;
  V := EvalTime(Other, NowT);
  case Op of
    '>': T0 := Max(T0, V + 1);
    '>=': T0 := Max(T0, V);
    '<': T1 := Min(T1, V - 1);
    '<=': T1 := Min(T1, V);
    '=': begin T0 := Max(T0, V); T1 := Min(T1, V); end;
  end;
end;

{ identifiers -> slots for this measurement: time, tag, or an index into Needed }
procedure Resolve(E: TExpr; M: TMeasurement; Needed: TStringList);
var
  A: TExpr;
  K: TFieldKind;
  I: Integer;
begin
  if E = nil then Exit;
  if E.Kind = ekIdent then
  begin
    if SameText(E.Name, 'time') then
      E.Slot := SLOT_TIME
    else if (E.Cast <> 'tag') and ((E.Cast = 'field') or M.FieldKind(E.Name, K)) then
    begin
      I := Needed.IndexOf(E.Name);
      if I < 0 then I := Needed.Add(E.Name);
      E.Slot := I;
    end
    else
      E.Slot := SLOT_TAG;
  end;
  for A in E.Args do Resolve(A, M, Needed);
  Resolve(E.Left, M, Needed);
  Resolve(E.Right, M, Needed);
end;

function IdentValue(E: TExpr; const R: TRow): TQValue;
var
  V: string;
begin
  case E.Slot of
    SLOT_TIME: Result := QInt(R.T);
    SLOT_TAG:
      begin
        if R.Series <> nil then V := R.Series.TagValue(E.Name) else V := '';
        if V <> '' then Result := QStr(V) else Result := QNull;
      end;
  else
    if (E.Slot >= 0) and (E.Slot <= High(R.Vals)) then
      Result := R.Vals[E.Slot]
    else
      Result := QNull;
  end;
end;

function Arith(const Op: string; const A, B: TQValue): TQValue;
var
  X, Y: Double;
begin
  if not (IsNum(A) and IsNum(B)) then
  begin
    if (Op = '+') and (A.Kind = qkString) and (B.Kind = qkString) then
      Exit(QStr(A.S + B.S));
    Exit(QNull);
  end;
  if (A.Kind = qkInt) and (B.Kind = qkInt) and (Op <> '/') then
    case Op of
      '+': Exit(QInt(A.I + B.I));
      '-': Exit(QInt(A.I - B.I));
      '*': Exit(QInt(A.I * B.I));
      '%': if B.I <> 0 then Exit(QInt(A.I mod B.I)) else Exit(QNull);
    end;
  X := NumOf(A);
  Y := NumOf(B);
  case Op of
    '+': Result := QFloat(X + Y);
    '-': Result := QFloat(X - Y);
    '*': Result := QFloat(X * Y);
    '/': if Y <> 0 then Result := QFloat(X / Y) else Result := QNull;
    '%': if Y <> 0 then Result := QFloat(X - Y * Int(X / Y)) else Result := QNull;
  else
    Result := QNull;
  end;
end;

{ the value of a select expression for one raw row }
function EvalRow(E: TExpr; const R: TRow): TQValue;
begin
  case E.Kind of
    ekIdent: Result := IdentValue(E, R);
    ekNumber: Result := QFloat(E.Num);
    ekInteger, ekDuration: Result := QInt(E.Int);
    ekString: Result := QStr(E.Name);
    ekBool: Result := QBool(E.Int <> 0);
    ekBinary: Result := Arith(E.Name, EvalRow(E.Left, R), EvalRow(E.Right, R));
  else
    Result := QNull;
  end;
end;

function Compare(const Op: string; const A, B: TQValue): Boolean;
var
  C: Integer;
  X, Y: Double;
begin
  if (A.Kind = qkNull) or (B.Kind = qkNull) then Exit(False);
  if IsNum(A) and IsNum(B) then
  begin
    if (A.Kind = qkInt) and (B.Kind = qkInt) then
    begin
      if A.I < B.I then C := -1 else if A.I > B.I then C := 1 else C := 0;
    end
    else
    begin
      X := NumOf(A);
      Y := NumOf(B);
      if X < Y then C := -1 else if X > Y then C := 1 else C := 0;
    end;
  end
  else if (A.Kind = qkBool) and (B.Kind = qkBool) then
    C := Sign(A.I - B.I)
  else if (A.Kind = qkString) and (B.Kind = qkString) then
    C := CompareStr(A.S, B.S)
  else
    Exit(False);
  case Op of
    '=': Result := C = 0;
    '!=': Result := C <> 0;
    '<': Result := C < 0;
    '<=': Result := C <= 0;
    '>': Result := C > 0;
    '>=': Result := C >= 0;
  else
    Result := False;
  end;
end;

{ WHERE for one row. TagsOnly: time and field conditions count as true (series filters) }
function EvalCond(E: TExpr; const R: TRow; TagsOnly: Boolean; NowT: Int64): Boolean;
var
  L, Rt: TQValue;
  Op: string;
  Other: TExpr;
begin
  if (E = nil) or (E.Kind <> ekBinary) then Exit(True);
  if E.Name = 'AND' then
    Exit(EvalCond(E.Left, R, TagsOnly, NowT) and EvalCond(E.Right, R, TagsOnly, NowT));
  if E.Name = 'OR' then
    Exit(EvalCond(E.Left, R, TagsOnly, NowT) or EvalCond(E.Right, R, TagsOnly, NowT));
  if TagsOnly and (((E.Left.Kind = ekIdent) and (E.Left.Slot <> SLOT_TAG)) or
    ((E.Right.Kind = ekIdent) and (E.Right.Slot <> SLOT_TAG))) then
    Exit(True);
  { regex }
  if (E.Name = '=~') or (E.Name = '!~') then
  begin
    if E.Right.Kind <> ekRegex then Exit(False);
    L := EvalRow(E.Left, R);
    if (L.Kind = qkNull) and (E.Left.Kind = ekIdent) and (E.Left.Slot = SLOT_TAG) then
      L := QStr('');                             // a missing tag is ''
    if L.Kind <> qkString then Exit(False);
    Result := E.Right.Regex.Exec(L.S);
    if E.Name = '!~' then Result := not Result;
    Exit;
  end;
  { time against a time literal }
  if IsTimeIdent(E.Left) or IsTimeIdent(E.Right) then
  begin
    if IsTimeIdent(E.Left) then
    begin
      Other := E.Right;
      Op := E.Name;
    end
    else
    begin
      Other := E.Left;
      Op := FlipOp(E.Name);
    end;
    Exit(Compare(Op, QInt(R.T), QInt(EvalTime(Other, NowT))));
  end;
  L := EvalRow(E.Left, R);
  Rt := EvalRow(E.Right, R);
  { a missing tag compares as '' (host != 'a' is true without a host tag) }
  if (L.Kind = qkNull) and (E.Left.Kind = ekIdent) and (E.Left.Slot = SLOT_TAG) then L := QStr('');
  if (Rt.Kind = qkNull) and (E.Right.Kind = ekIdent) and (E.Right.Slot = SLOT_TAG) then Rt := QStr('');
  Result := Compare(E.Name, L, Rt);
end;

{ ---------------------------------------------------------------------------- }
{ aggregates }

procedure AggInit(var A: TAggState);
begin
  A := Default(TAggState);
  A.AllInt := True;
end;

procedure AggFeed(var A: TAggState; const V: TQValue; T: Int64; NeedVals: Boolean);
var
  X, Delta: Double;
begin
  if V.Kind = qkNull then Exit;
  if A.Count = 0 then
  begin
    A.First := V;
    A.FirstT := T;
    A.Last := V;
    A.LastT := T;
  end
  else
  begin
    if T < A.FirstT then begin A.First := V; A.FirstT := T; end;
    if T >= A.LastT then begin A.Last := V; A.LastT := T; end;
  end;
  if IsNum(V) or (V.Kind = qkBool) then
  begin
    if V.Kind = qkBool then X := V.I else X := NumOf(V);
    if V.Kind <> qkInt then A.AllInt := False;
    if (A.Count = 0) or (X < A.Min) then begin A.Min := X; A.MinT := T; end;
    if (A.Count = 0) or (X > A.Max) then begin A.Max := X; A.MaxT := T; end;
    A.Sum := A.Sum + X;
    Delta := X - A.Mean;                          // Welford: mean and variance in one pass
    A.Mean := A.Mean + Delta / (A.Count + 1);
    A.M2 := A.M2 + Delta * (X - A.Mean);
    if NeedVals then
    begin
      if A.NV >= Length(A.Vals) then SetLength(A.Vals, Max(16, A.NV * 2));
      A.Vals[A.NV] := X;
      Inc(A.NV);
    end;
  end
  else
    A.AllInt := False;
  Inc(A.Count);
end;

{ shell sort of the collected values (median, percentile, mode) }
function SortedVals(const A: TAggState): TDoubleArray;
var
  I, J, Gap: Integer;
  X: Double;
begin
  Result := Copy(A.Vals, 0, A.NV);
  Gap := 1;
  while Gap < Length(Result) div 3 do Gap := Gap * 3 + 1;
  while Gap >= 1 do
  begin
    for I := Gap to High(Result) do
    begin
      X := Result[I];
      J := I;
      while (J >= Gap) and (Result[J - Gap] > X) do
      begin
        Result[J] := Result[J - Gap];
        Dec(J, Gap);
      end;
      Result[J] := X;
    end;
    Gap := Gap div 3;
  end;
end;

function AggResult(const C: TCall; const A: TAggState): TQValue;
var
  V: TDoubleArray;
  N, I, Best, Run: Integer;
begin
  if A.Count = 0 then Exit(QNull);
  case C.Fn of
    'count': Result := QInt(A.Count);
    'sum': Result := MaybeInt(A.Sum, A.AllInt);
    'mean': Result := QFloat(A.Mean);
    'min': Result := MaybeInt(A.Min, A.AllInt);
    'max': Result := MaybeInt(A.Max, A.AllInt);
    'spread': Result := MaybeInt(A.Max - A.Min, A.AllInt);
    'first': Result := A.First;
    'last': Result := A.Last;
    'stddev':
      if A.Count < 2 then Result := QNull
      else Result := QFloat(Sqrt(A.M2 / (A.Count - 1)));
    'median':
      begin
        V := SortedVals(A);
        N := Length(V);
        if N = 0 then Exit(QNull);
        if Odd(N) then Result := QFloat(V[N div 2])
        else Result := QFloat((V[N div 2 - 1] + V[N div 2]) / 2);
      end;
    'percentile':
      begin
        V := SortedVals(A);
        N := Length(V);
        I := Floor(N * C.Pct / 100 + 0.5) - 1;   // nearest rank, as InfluxDB
        if (I < 0) or (I >= N) then Exit(QNull);
        Result := MaybeInt(V[I], A.AllInt);
      end;
    'mode':
      begin
        V := SortedVals(A);
        if Length(V) = 0 then Exit(QNull);
        Best := 0;
        Run := 0;
        Result := MaybeInt(V[0], A.AllInt);
        for I := 0 to High(V) do
        begin
          if (I > 0) and (V[I] = V[I - 1]) then Inc(Run) else Run := 1;
          if Run > Best then
          begin
            Best := Run;
            Result := MaybeInt(V[I], A.AllInt);
          end;
        end;
      end;
  else
    Result := QNull;
  end;
end;

{ the value of an aggregate select expression for one bucket }
function EvalAgg(E: TExpr; const Calls: array of TCall; States: PAggState): TQValue;
begin
  case E.Kind of
    ekCall:
      if (E.Slot >= 0) and (E.Slot <= High(Calls)) then
        Result := AggResult(Calls[E.Slot], States[E.Slot])
      else
        Result := QNull;
    ekNumber: Result := QFloat(E.Num);
    ekInteger: Result := QInt(E.Int);
    ekBinary: Result := Arith(E.Name, EvalAgg(E.Left, Calls, States), EvalAgg(E.Right, Calls, States));
  else
    Result := QNull;
  end;
end;

procedure CollectCalls(E: TExpr; var Calls: array of TCall; var N: Integer; Fill: Boolean);
var
  A: TExpr;
begin
  if E = nil then Exit;
  if (E.Kind = ekCall) and IsAggregate(E.Name) then
  begin
    if Fill then
    begin
      E.Slot := N;
      Calls[N].Expr := E;
      Calls[N].Fn := E.Name;
      Calls[N].NeedVals := (E.Name = 'median') or (E.Name = 'percentile') or (E.Name = 'mode');
      Calls[N].Pct := 50;
      if (E.Name = 'percentile') and (Length(E.Args) >= 2) then
        Calls[N].Pct := E.Args[1].Num;
    end;
    Inc(N);
    Exit;                                         // no aggregate inside an aggregate
  end;
  for A in E.Args do CollectCalls(A, Calls, N, Fill);
  CollectCalls(E.Left, Calls, N, Fill);
  CollectCalls(E.Right, Calls, N, Fill);
end;

{ an identifier outside of an aggregate (not allowed in an aggregate query) }
function RawIdent(E: TExpr): Boolean;
var
  A: TExpr;
begin
  if E = nil then Exit(False);
  if (E.Kind = ekCall) and IsAggregate(E.Name) then Exit(False);
  if E.Kind = ekIdent then Exit(True);
  for A in E.Args do
    if RawIdent(A) then Exit(True);
  Result := RawIdent(E.Left) or RawIdent(E.Right);
end;

function ExprName(E: TExpr): string;
var
  L, R: string;
begin
  case E.Kind of
    ekIdent, ekCall: Result := E.Name;
    ekBinary:
      begin
        L := ExprName(E.Left);
        R := ExprName(E.Right);
        if (L <> '') and (R <> '') and (L <> R) then Result := L + '_' + R
        else if L <> '' then Result := L
        else Result := R;
      end;
  else
    Result := '';
  end;
end;

function BucketStart(T, Interval, Offset: Int64): Int64;
var
  B: Int64;
begin
  B := (T - Offset) div Interval;
  if (T - Offset) mod Interval < 0 then Dec(B);
  Result := B * Interval + Offset;
end;

{ ---------------------------------------------------------------------------- }

procedure TGroup.AddRow(T: Int64; const V: TQValues);
begin
  if N >= Length(Times) then
  begin
    SetLength(Times, Max(64, N * 2));
    SetLength(Rows, Max(64, N * 2));
  end;
  Times[N] := T;
  Rows[N] := V;
  Inc(N);
end;

procedure TOut.Add(const S: string);
begin
  if S = '' then Exit;
  if Len + Length(S) > Length(Buf) then
    SetLength(Buf, Max(Length(Buf) * 2, Len + Length(S) + 4096));
  Move(S[1], Buf[Len + 1], Length(S));
  Inc(Len, Length(S));
end;

function TOut.Text: string;
begin
  Result := Copy(Buf, 1, Len);
end;

{ ---------------------------------------------------------------------------- }
{ TExec }

constructor TExec.Create(AStore: TStore; const ADefaultDb: string; AEpoch: Int64);
begin
  FStore := AStore;
  FDefaultDb := ADefaultDb;
  FEpoch := AEpoch;
  FNow := NowNs;
end;

function TExec.TimeText(T: Int64): string;
var
  Sec, Fr: Int64;
  F: string;
begin
  if FEpoch > 0 then
    Exit(IntToStr(T div FEpoch));
  Sec := T div 1000000000;
  Fr := T mod 1000000000;
  if Fr < 0 then
  begin
    Dec(Sec);
    Inc(Fr, 1000000000);
  end;
  Result := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', UnixDateDelta + Sec / Double(86400));
  if Fr <> 0 then
  begin
    F := Format('%.9d', [Fr]);
    while F[Length(F)] = '0' do SetLength(F, Length(F) - 1);
    Result := Result + '.' + F;
  end;
  Result := '"' + Result + 'Z"';
end;

function TExec.ValueText(const V: TQValue): string;
begin
  case V.Kind of
    qkFloat: Result := FloatJson(V.D);
    qkInt: Result := IntToStr(V.I);
    qkString: Result := JsonString(V.S);
    qkBool: if V.I <> 0 then Result := 'true' else Result := 'false';
  else
    Result := 'null';
  end;
end;

procedure TExec.BeginSeries(const Name: string; const TagK, TagV: array of string;
  const Cols: array of string);
var
  I: Integer;
begin
  if FSeriesCount = 0 then FOut.Add(',"series":[') else FOut.Add(',');
  Inc(FSeriesCount);
  FOut.Add('{');
  if Name <> '' then
    FOut.Add('"name":' + JsonString(Name) + ',');
  if Length(TagK) > 0 then
  begin
    FOut.Add('"tags":{');
    for I := 0 to High(TagK) do
    begin
      if I > 0 then FOut.Add(',');
      FOut.Add(JsonString(TagK[I]) + ':' + JsonString(TagV[I]));
    end;
    FOut.Add('},');
  end;
  FOut.Add('"columns":[');
  for I := 0 to High(Cols) do
  begin
    if I > 0 then FOut.Add(',');
    FOut.Add(JsonString(Cols[I]));
  end;
  FOut.Add(']');
  FRowsInSeries := 0;
end;

procedure TExec.EndSeries;
begin
  if FRowsInSeries > 0 then FOut.Add(']');
  FOut.Add('}');
end;

procedure TExec.Row(const Vals: array of string);
var
  I: Integer;
begin
  if FRowsInSeries = 0 then FOut.Add(',"values":[') else FOut.Add(',');
  Inc(FRowsInSeries);
  FOut.Add('[');
  for I := 0 to High(Vals) do
  begin
    if I > 0 then FOut.Add(',');
    FOut.Add(Vals[I]);
  end;
  FOut.Add(']');
end;

function TExec.Db(S: TStatement; Required: Boolean): TDatabase;
var
  N: string;
begin
  N := S.OnDb;
  if N = '' then N := S.SourceDb;
  if N = '' then N := FDefaultDb;
  if N = '' then
  begin
    if Required then raise EInfluxQL.Create('database name required');
    Exit(nil);
  end;
  Result := FStore.Find(N);
  if (Result = nil) and Required then
    raise EInfluxQL.Create('database not found: ' + N);
end;

{ the measurements of the FROM clause (all without FROM) }
procedure TExec.Measurements(D: TDatabase; S: TStatement; L: TList);
var
  I: Integer;
  M: TMeasurement;
begin
  for I := 0 to D.Measurements.Count - 1 do
  begin
    M := TMeasurement(D.Measurements.Objects[I]);
    if (S.SourceName <> '') and (M.Name <> S.SourceName) then Continue;
    if (S.SourceRegex <> nil) and not S.SourceRegex.Regex.Exec(M.Name) then Continue;
    L.Add(M);
  end;
end;

{ series filter (SHOW, DELETE): the tag part of FCond, resolved again for each measurement }
function TExec.SeriesMatch(M: TMeasurement; Ser: TSeries): Boolean;
var
  R: TRow;
  Dummy: TStringList;
begin
  if FCond = nil then Exit(True);
  if M <> FMeas then
  begin
    Dummy := TStringList.Create;
    try
      Resolve(FCond, M, Dummy);
    finally
      Dummy.Free;
    end;
    FMeas := M;
  end;
  R := Default(TRow);
  R.Series := Ser;
  Result := EvalCond(FCond, R, True, FNow);
end;

{ ---- SELECT ---- }

{ transforms, empty rows, order, OFFSET / LIMIT, SLIMIT, then the JSON series }
procedure TExec.OutputGroup(S: TStatement; M: TMeasurement; G: TGroup; const Items: array of TItem;
  Raw: Boolean);
var
  I, J, K, N, Lo, Hi, Cnt: Integer;
  HasTransform: Boolean;
  PT: Int64;
  PV, Acc: Double;
  HavePrev: Boolean;
  Win: array of Double;
  WN, WP: Integer;
  V: TQValue;
  Order: array of Integer;
  Cols: array of string;
  Vals: array of string;
  TagK, TagV: array of string;
  Tmp: Integer;
begin
  N := G.N;
  if N = 0 then Exit;
  SetLength(Order, N);
  for I := 0 to N - 1 do Order[I] := I;
  { raw rows of several series: sort by time (stable) }
  if Raw then
  begin
    for I := 1 to N - 1 do
    begin
      Tmp := Order[I];
      J := I - 1;
      while (J >= 0) and (G.Times[Order[J]] > G.Times[Tmp]) do
      begin
        Order[J + 1] := Order[J];
        Dec(J);
      end;
      Order[J + 1] := Tmp;
    end;
  end;
  { transforms, in time order }
  HasTransform := False;
  for K := 0 to High(Items) do
  begin
    if Items[K].Transform = '' then Continue;
    HasTransform := True;
    HavePrev := False;
    PT := 0;
    PV := 0;
    Acc := 0;
    SetLength(Win, Items[K].TN);
    WN := 0;
    WP := 0;
    for I := 0 to N - 1 do
    begin
      V := G.Rows[Order[I]][K];
      G.Rows[Order[I]][K] := QNull;
      if not IsNum(V) then Continue;
      case Items[K].Transform of
        'derivative', 'non_negative_derivative':
          if HavePrev and (G.Times[Order[I]] > PT) then
          begin
            Acc := (NumOf(V) - PV) / (Double(G.Times[Order[I]] - PT) / Double(Items[K].TUnit));
            if (Items[K].Transform = 'derivative') or (Acc >= 0) then
              G.Rows[Order[I]][K] := QFloat(Acc);
          end;
        'difference', 'non_negative_difference':
          if HavePrev then
          begin
            Acc := NumOf(V) - PV;
            if (Items[K].Transform = 'difference') or (Acc >= 0) then
              G.Rows[Order[I]][K] := MaybeInt(Acc, V.Kind = qkInt);
          end;
        'cumulative_sum':
          begin
            Acc := Acc + NumOf(V);
            G.Rows[Order[I]][K] := MaybeInt(Acc, V.Kind = qkInt);
          end;
        'moving_average':
          begin
            Win[WP] := NumOf(V);
            WP := (WP + 1) mod Length(Win);
            if WN < Length(Win) then Inc(WN);
            if WN = Length(Win) then
            begin
              Acc := 0;
              for J := 0 to High(Win) do Acc := Acc + Win[J];
              G.Rows[Order[I]][K] := QFloat(Acc / Length(Win));
            end;
          end;
        'elapsed':
          if HavePrev then
            G.Rows[Order[I]][K] := QInt((G.Times[Order[I]] - PT) div Items[K].TUnit);
      end;
      HavePrev := True;
      PT := G.Times[Order[I]];
      PV := NumOf(V);
    end;
  end;
  { rows without any value are left out (raw queries and transforms) }
  if Raw or HasTransform then
  begin
    J := 0;
    for I := 0 to N - 1 do
    begin
      Cnt := 0;
      for K := 0 to High(Items) do
        if G.Rows[Order[I]][K].Kind <> qkNull then Inc(Cnt);
      if Cnt > 0 then
      begin
        Order[J] := Order[I];
        Inc(J);
      end;
    end;
    N := J;
  end;
  if S.OrderDesc then
    for I := 0 to N div 2 - 1 do
    begin
      Tmp := Order[I];
      Order[I] := Order[N - 1 - I];
      Order[N - 1 - I] := Tmp;
    end;
  Lo := Min(Max(S.Offset, 0), N);
  Hi := N;
  if S.Limit > 0 then Hi := Min(N, Lo + S.Limit);
  if Hi <= Lo then Exit;
  { SOFFSET / SLIMIT count output series }
  if FSkip > 0 then
  begin
    Dec(FSkip);
    Exit;
  end;
  if FLeft = 0 then Exit;
  if FLeft > 0 then Dec(FLeft);
  SetLength(Cols, Length(Items) + 1);
  Cols[0] := 'time';
  for K := 0 to High(Items) do Cols[K + 1] := Items[K].Name;
  if S.GroupAllTags or (S.GroupTags.Count > 0) then
  begin
    TagK := G.TagKeys;
    TagV := G.TagValues;
  end
  else
  begin
    TagK := nil;
    TagV := nil;
  end;
  BeginSeries(M.Name, TagK, TagV, Cols);
  SetLength(Vals, Length(Items) + 1);
  for I := Lo to Hi - 1 do
  begin
    Vals[0] := TimeText(G.Times[Order[I]]);
    for K := 0 to High(Items) do
      Vals[K + 1] := ValueText(G.Rows[Order[I]][K]);
    Row(Vals);
  end;
  EndSeries;
end;

procedure TExec.SelectMeasurement(S: TStatement; M: TMeasurement; T0, T1: Int64);
var
  Items: array of TItem;
  Calls: array of TCall;
  NCalls, I, J, K, B, NB, Si, Cnt, SeriesRows, RowCap: Integer;
  Needed, TagList, Names, Groups: TStringList;
  F: TSelectField;
  E, Arg: TExpr;
  Agg, SingleSelector: Boolean;
  Ser: TSeries;
  Cols: array of TColumn;
  It: TRowIter;
  R: TRow;
  G: TGroup;
  GKey, Nm: string;
  GK, GV: array of string;
  Vals, Prev: TQValues;
  FirstB, LastB, MinT, Interval, Offs: Int64;
  Kind: TFieldKind;
  St: PAggState;

  procedure AddItem(AExpr: TExpr; Owned: Boolean; const AName: string);
  var
    N: Integer;
  begin
    N := Length(Items);
    SetLength(Items, N + 1);
    Items[N] := Default(TItem);
    Items[N].Expr := AExpr;
    Items[N].Owned := Owned;
    Items[N].Name := AName;
    Items[N].TUnit := 1000000000;
    Items[N].TN := 1;
  end;

begin
  Items := nil;
  Calls := nil;
  Needed := TStringList.Create;
  TagList := TStringList.Create;
  Names := TStringList.Create;
  Groups := TStringList.Create;
  Groups.Sorted := True;
  Groups.CaseSensitive := True;
  try
    M.TagKeys(TagList);
    { ---- select items: * expansion, transforms, names ---- }
    for F in S.Fields do
    begin
      E := F.Expr;
      if E.Kind = ekWildcard then
      begin
        Names.Clear;
        Names.Sorted := True;
        for I := 0 to M.FieldKinds.Count - 1 do Names.Add(M.FieldKinds[I]);
        for I := 0 to TagList.Count - 1 do
          if not S.GroupAllTags and (S.GroupTags.IndexOf(TagList[I]) < 0) then
            Names.Add(TagList[I]);
        for I := 0 to Names.Count - 1 do
          if TagList.IndexOf(Names[I]) >= 0 then
            AddItem(NewIdent(Names[I], 'tag'), True, Names[I])
          else
            AddItem(NewIdent(Names[I], 'field'), True, Names[I]);
        Names.Sorted := False;
        Continue;
      end;
      if (E.Kind = ekCall) and IsAggregate(E.Name) and (Length(E.Args) > 0) and
        (E.Args[0].Kind = ekWildcard) then
      begin
        for I := 0 to M.FieldKinds.Count - 1 do      // mean(*) -> mean_<field>
        begin
          Kind := TFieldKind(PtrInt(M.FieldKinds.Objects[I]));
          if (Kind in [fkString, fkBoolean]) and (E.Name <> 'count') and (E.Name <> 'first') and
            (E.Name <> 'last') then Continue;
          Arg := CloneExpr(E);
          Arg.Args[0].Free;
          Arg.Args[0] := NewIdent(M.FieldKinds[I], 'field');
          AddItem(Arg, True, E.Name + '_' + M.FieldKinds[I]);
        end;
        Continue;
      end;
      if (E.Kind = ekCall) and IsTransform(E.Name) then
      begin
        if Length(E.Args) = 0 then raise EInfluxQL.Create(E.Name + '() expects an argument');
        AddItem(E.Args[0], False, E.Name);
        if (Length(E.Args) >= 2) and (E.Args[1].Kind = ekDuration) then
          Items[High(Items)].TUnit := Max(E.Args[1].Int, 1);
        if (Length(E.Args) >= 2) and (E.Args[1].Kind = ekInteger) then
          Items[High(Items)].TN := Max(E.Args[1].Int, 1);
        if (E.Name = 'moving_average') and (Length(E.Args) < 2) then
          raise EInfluxQL.Create('moving_average() expects 2 arguments');
        Items[High(Items)].Transform := E.Name;
      end
      else
      begin
        Nm := ExprName(E);
        if Nm = '' then Nm := 'value';
        AddItem(E, False, Nm);
      end;
      if F.Alias <> '' then Items[High(Items)].Name := F.Alias;
    end;
    if Length(Items) = 0 then Exit;
    Names.Clear;                                    // mean, mean_1, ...
    for I := 0 to High(Items) do
    begin
      Nm := Items[I].Name;
      J := 0;
      while Names.IndexOf(Nm) >= 0 do
      begin
        Inc(J);
        Nm := Items[I].Name + '_' + IntToStr(J);
      end;
      Items[I].Name := Nm;
      Names.Add(Nm);
    end;

    { ---- aggregate calls ---- }
    NCalls := 0;
    for I := 0 to High(Items) do CollectCalls(Items[I].Expr, Calls, NCalls, False);
    SetLength(Calls, NCalls);
    NCalls := 0;
    for I := 0 to High(Items) do CollectCalls(Items[I].Expr, Calls, NCalls, True);
    Agg := NCalls > 0;
    if Agg then
      for I := 0 to High(Items) do
        if RawIdent(Items[I].Expr) then
          raise EInfluxQL.Create('mixing aggregate and non-aggregate queries is not supported');
    if (S.GroupInterval > 0) and not Agg then
      raise EInfluxQL.Create('GROUP BY requires at least one aggregate function');
    for I := 0 to High(Items) do Resolve(Items[I].Expr, M, Needed);
    Resolve(S.Where, M, Needed);
    { a selector alone (first, last, min, max) keeps the time of its point }
    SingleSelector := Agg and (S.GroupInterval = 0) and (Length(Items) = 1) and
      (Items[0].Expr.Kind = ekCall) and (Items[0].Transform = '') and
      ((Items[0].Expr.Name = 'first') or (Items[0].Expr.Name = 'last') or
       (Items[0].Expr.Name = 'min') or (Items[0].Expr.Name = 'max'));

    { ---- buckets ---- }
    Interval := S.GroupInterval;
    Offs := 0;
    FirstB := 0;
    NB := 1;
    if Agg and (Interval > 0) then
    begin
      Offs := S.GroupOffset mod Interval;
      if T0 = Low(Int64) then
      begin
        MinT := High(Int64);                        // no lower bound: from the first point
        for Si := 0 to M.Series.Count - 1 do
        begin
          Ser := TSeries(M.Series.Objects[Si]);
          for J := 0 to Needed.Count - 1 do
            if (Ser.Column(Needed[J]) <> nil) and (Ser.Column(Needed[J]).Count > 0) then
              MinT := Min(MinT, Ser.Column(Needed[J]).Times[0]);
        end;
        if MinT = High(Int64) then Exit;
        T0 := MinT;
      end;
      if T1 < T0 then Exit;
      FirstB := BucketStart(T0, Interval, Offs);
      LastB := BucketStart(T1, Interval, Offs);
      if (LastB - FirstB) div Interval + 1 > MAX_CELLS div Max(NCalls, 1) then
        raise EInfluxQL.Create('max-select-buckets limit exceeded: use a longer GROUP BY time() or a shorter range');
      NB := (LastB - FirstB) div Interval + 1;
    end;

    { ---- rows of every series ---- }
    RowCap := 0;
    if not Agg and (S.Limit > 0) and not S.OrderDesc then
    begin
      RowCap := Max(S.Offset, 0) + S.Limit;
      for I := 0 to High(Items) do
        if Items[I].Transform <> '' then RowCap := 0;   // a transform needs the rows before
    end;
    SetLength(Cols, Needed.Count);
    for Si := 0 to M.Series.Count - 1 do
    begin
      Ser := TSeries(M.Series.Objects[Si]);
      if S.GroupAllTags then
      begin
        GK := Copy(Ser.TagKeys);
        GV := Copy(Ser.TagValues);
      end
      else
      begin
        Names.Clear;
        Names.Sorted := True;
        for J := 0 to S.GroupTags.Count - 1 do Names.Add(S.GroupTags[J]);
        SetLength(GK, Names.Count);
        SetLength(GV, Names.Count);
        for J := 0 to Names.Count - 1 do
        begin
          GK[J] := Names[J];
          GV[J] := Ser.TagValue(Names[J]);
        end;
        Names.Sorted := False;
      end;
      GKey := '';
      for J := 0 to High(GK) do GKey := GKey + GK[J] + #0 + GV[J] + #1;
      for J := 0 to Needed.Count - 1 do
        Cols[J] := Ser.Column(Needed[J]);
      R := Default(TRow);
      R.Series := Ser;
      { the tags alone (fields and time count as true) already rule the series out }
      if (S.Where <> nil) and not EvalCond(S.Where, R, True, FNow) then Continue;
      It.Init(Cols, T0, T1);
      SetLength(R.Vals, Needed.Count);
      G := nil;
      SeriesRows := 0;
      while It.Next do
      begin
        R.T := It.T;
        for J := 0 to Needed.Count - 1 do
          if It.Has[J] then R.Vals[J] := FromField(Cols[J].Value(It.Idx(J)))
          else R.Vals[J] := QNull;
        if not EvalCond(S.Where, R, False, FNow) then Continue;
        if G = nil then
        begin
          if Groups.Find(GKey, K) then
            G := TGroup(Groups.Objects[K])
          else
          begin
            G := TGroup.Create;
            G.TagKeys := Copy(GK);
            G.TagValues := Copy(GV);
            Groups.AddObject(GKey, G);
            if Agg then
            begin
              SetLength(G.States, NB * NCalls);
              for K := 0 to High(G.States) do AggInit(G.States[K]);
              SetLength(G.Used, NB);
            end;
          end;
        end;
        if Agg then
        begin
          if Interval > 0 then
            B := (BucketStart(R.T, Interval, Offs) - FirstB) div Interval
          else
            B := 0;
          if (B < 0) or (B >= NB) then Continue;
          G.Used[B] := True;
          for K := 0 to NCalls - 1 do
            if Length(Calls[K].Expr.Args) > 0 then
              AggFeed(G.States[B * NCalls + K], EvalRow(Calls[K].Expr.Args[0], R), R.T,
                Calls[K].NeedVals);
        end
        else
        begin
          SetLength(Vals, Length(Items));
          Cnt := 0;
          for K := 0 to High(Items) do
          begin
            Vals[K] := EvalRow(Items[K].Expr, R);
            if Vals[K].Kind <> qkNull then Inc(Cnt);
          end;
          if Cnt = 0 then Continue;                 // none of the selected values at this time
          if G.N >= MAX_ROWS then
            raise EInfluxQL.Create('too many rows, use LIMIT or a shorter time range');
          G.AddRow(R.T, Copy(Vals));
          Inc(SeriesRows);
          { the first OFFSET + LIMIT rows of the group are among the first of each series }
          if (RowCap > 0) and (SeriesRows >= RowCap) then Break;
        end;
      end;
    end;

    { ---- groups -> rows -> JSON ---- }
    for I := 0 to Groups.Count - 1 do
    begin
      G := TGroup(Groups.Objects[I]);
      if Agg then
      begin
        SetLength(Prev, Length(Items));
        for K := 0 to High(Prev) do Prev[K] := QNull;
        for B := 0 to NB - 1 do
        begin
          if not G.Used[B] and (S.Fill = fmNone) then Continue;
          SetLength(Vals, Length(Items));
          St := @G.States[B * NCalls];
          for K := 0 to High(Items) do
          begin
            if G.Used[B] then
              Vals[K] := EvalAgg(Items[K].Expr, Calls, St)
            else
              case S.Fill of
                fmValue: Vals[K] := MaybeInt(S.FillValue, Frac(S.FillValue) = 0);
                fmPrevious: Vals[K] := Prev[K];
              else
                Vals[K] := QNull;
              end;
            if Vals[K].Kind <> qkNull then Prev[K] := Vals[K];
          end;
          if Interval > 0 then
            G.AddRow(FirstB + Int64(B) * Interval, Copy(Vals))
          else if SingleSelector then
            case Items[0].Expr.Name of
              'first': G.AddRow(St^.FirstT, Copy(Vals));
              'last': G.AddRow(St^.LastT, Copy(Vals));
              'min': G.AddRow(St^.MinT, Copy(Vals));
            else
              G.AddRow(St^.MaxT, Copy(Vals));
            end
          else if T0 = Low(Int64) then
            G.AddRow(0, Copy(Vals))
          else
            G.AddRow(T0, Copy(Vals));
        end;
        if (S.Fill = fmLinear) and (Interval > 0) then
          for K := 0 to High(Items) do
          begin
            J := -1;                                  // the last row with a value
            for B := 0 to G.N - 1 do
              if IsNum(G.Rows[B][K]) then
              begin
                if (J >= 0) and (B - J > 1) then
                  for Si := J + 1 to B - 1 do
                    G.Rows[Si][K] := QFloat(NumOf(G.Rows[J][K]) + (NumOf(G.Rows[B][K]) -
                      NumOf(G.Rows[J][K])) * (Si - J) / (B - J));
                J := B;
              end;
          end;
        G.States := nil;
      end;
      OutputGroup(S, M, G, Items, not Agg);
    end;
  finally
    for I := 0 to High(Items) do
      if Items[I].Owned then Items[I].Expr.Free;
    FreeObjects(Groups);
    Groups.Free;
    Needed.Free;
    TagList.Free;
    Names.Free;
  end;
end;

procedure TExec.RunSelect(S: TStatement);
var
  D: TDatabase;
  L: TList;
  I: Integer;
  T0, T1: Int64;
begin
  D := Db(S, True);
  T0 := Low(Int64);
  T1 := High(Int64);
  TimeRange(S.Where, FNow, T0, T1);
  if (S.GroupInterval > 0) and (T1 = High(Int64)) then
    T1 := FNow;                                     // GROUP BY time ends now(), like InfluxDB
  FSkip := Max(S.SOffset, 0);
  FLeft := S.SLimit;
  L := TList.Create;
  try
    Measurements(D, S, L);
    for I := 0 to L.Count - 1 do
      SelectMeasurement(S, TMeasurement(L[I]), T0, T1);
  finally
    L.Free;
  end;
end;

{ ---- SHOW ---- }

procedure TExec.RunShow(S: TStatement);
var
  D: TDatabase;
  L: TList;
  Vals: TStringList;
  I, J, K, N, Lo: Integer;
  M: TMeasurement;
  Ser: TSeries;
  Ok: Boolean;
  Key: string;

  procedure ShowList(const Name, Col: string; List: TStrings);
  var
    X: Integer;
  begin
    BeginSeries(Name, [], [], [Col]);
    Lo := Max(S.Offset, 0);
    N := 0;
    for X := Lo to List.Count - 1 do
    begin
      if (S.Limit > 0) and (N >= S.Limit) then Break;
      Row([JsonString(List[X])]);
      Inc(N);
    end;
    EndSeries;
  end;

  function KeyWanted(const K: string): Boolean;
  begin
    case S.KeyOp of
      '=': Result := K = S.Name;
      '!=': Result := K <> S.Name;
      '=~': Result := S.KeyRegex.Regex.Exec(K);
      '!~': Result := not S.KeyRegex.Regex.Exec(K);
      'IN': Result := S.KeyList.IndexOf(K) >= 0;
    else
      Result := False;
    end;
  end;

begin
  if S.Kind = skShowDatabases then
  begin
    ShowList('databases', 'name', FStore.Databases);
    Exit;
  end;
  if S.Kind = skShowUsers then
  begin
    BeginSeries('', [], [], ['user', 'admin']);
    EndSeries;
    Exit;
  end;
  D := Db(S, True);
  if S.Kind = skShowRetention then
  begin
    BeginSeries('', [], [], ['name', 'duration', 'shardGroupDuration', 'replicaN', 'default']);
    Row(['"autogen"', JsonString(FormatDuration(D.RetentionNs)), '"168h0m0s"', '1', 'true']);
    EndSeries;
    Exit;
  end;
  FCond := S.Where;
  FMeas := nil;
  L := TList.Create;
  Vals := TStringList.Create;
  try
    Measurements(D, S, L);
    case S.Kind of
      skShowMeasurements:
        begin
          Vals.Sorted := True;
          for I := 0 to L.Count - 1 do
          begin
            M := TMeasurement(L[I]);
            if (S.MeasOp = '=') and (M.Name <> S.MeasName) then Continue;
            if (S.MeasOp = '!=') and (M.Name = S.MeasName) then Continue;
            if (S.MeasRegex <> nil) and (S.MeasRegex.Regex.Exec(M.Name) = (S.MeasOp = '!~')) then Continue;
            Ok := FCond = nil;
            for J := 0 to M.Series.Count - 1 do
              if not Ok and SeriesMatch(M, TSeries(M.Series.Objects[J])) then Ok := True;
            if Ok then Vals.Add(M.Name);
          end;
          if Vals.Count > 0 then ShowList('measurements', 'name', Vals);
        end;
      skShowTagKeys, skShowFieldKeys:
        for I := 0 to L.Count - 1 do
        begin
          M := TMeasurement(L[I]);
          if S.Kind = skShowTagKeys then
          begin
            Vals.Sorted := False;
            M.TagKeys(Vals);
            if Vals.Count > 0 then ShowList(M.Name, 'tagKey', Vals);
          end
          else
          begin
            BeginSeries(M.Name, [], [], ['fieldKey', 'fieldType']);
            for J := 0 to M.FieldKinds.Count - 1 do
              Row([JsonString(M.FieldKinds[J]),
                JsonString(FieldKindName[TFieldKind(PtrInt(M.FieldKinds.Objects[J]))])]);
            EndSeries;
          end;
        end;
      skShowTagValues:
        for I := 0 to L.Count - 1 do
        begin
          M := TMeasurement(L[I]);
          Vals.Clear;
          Vals.Sorted := True;
          Vals.Duplicates := dupIgnore;
          for J := 0 to M.Series.Count - 1 do
          begin
            Ser := TSeries(M.Series.Objects[J]);
            if not SeriesMatch(M, Ser) then Continue;
            for K := 0 to High(Ser.TagKeys) do
              if KeyWanted(Ser.TagKeys[K]) then
                Vals.Add(Ser.TagKeys[K] + #0 + Ser.TagValues[K]);
          end;
          if Vals.Count = 0 then Continue;
          BeginSeries(M.Name, [], [], ['key', 'value']);
          N := 0;
          for J := Max(S.Offset, 0) to Vals.Count - 1 do
          begin
            if (S.Limit > 0) and (N >= S.Limit) then Break;
            K := Pos(#0, Vals[J]);
            Row([JsonString(Copy(Vals[J], 1, K - 1)), JsonString(Copy(Vals[J], K + 1, MaxInt))]);
            Inc(N);
          end;
          EndSeries;
        end;
      skShowSeries:
        begin
          Vals.Sorted := True;
          for I := 0 to L.Count - 1 do
          begin
            M := TMeasurement(L[I]);
            for J := 0 to M.Series.Count - 1 do
            begin
              Ser := TSeries(M.Series.Objects[J]);
              if not SeriesMatch(M, Ser) then Continue;
              Key := EscapeName(M.Name, False);
              if Ser.Key <> '' then Key := Key + ',' + Ser.Key;
              Vals.Add(Key);
            end;
          end;
          if Vals.Count > 0 then ShowList('', 'key', Vals);
        end;
    end;
  finally
    Vals.Free;
    L.Free;
    FCond := nil;
  end;
end;

{ ---- DELETE / DROP SERIES (the write lock is held) ---- }

procedure TExec.RunDelete(S: TStatement);
var
  D: TDatabase;
  L: TList;
  I: Integer;
  T0, T1, N: Int64;
begin
  D := Db(S, True);
  T0 := Low(Int64);
  T1 := High(Int64);
  if S.Kind = skDelete then
    TimeRange(S.Where, FNow, T0, T1);
  FCond := S.Where;
  FMeas := nil;
  L := TList.Create;
  try
    Measurements(D, S, L);
    N := 0;
    for I := 0 to L.Count - 1 do
      Inc(N, D.DeleteData(TMeasurement(L[I]).Name, @SeriesMatch, T0, T1));
    if N > 0 then D.Compact;                       // keep the deletion on disk
  finally
    L.Free;
    FCond := nil;
  end;
end;

procedure TExec.Statement(S: TStatement; Id: Integer);
var
  Err: string;
  D: TDatabase;
  Mark: Integer;
begin
  if Id > 0 then FOut.Add(',');
  FOut.Add('{"statement_id":' + IntToStr(Id));
  FSeriesCount := 0;
  Mark := FOut.Len;
  try
    case S.Kind of
      skSelect, skShowDatabases, skShowMeasurements, skShowTagKeys, skShowTagValues,
      skShowFieldKeys, skShowSeries, skShowRetention, skShowUsers:
        begin
          FStore.Lock.BeginRead;
          try
            if S.Kind = skSelect then RunSelect(S) else RunShow(S);
          finally
            FStore.Lock.EndRead;
          end;
        end;
      skCreateDb, skDropDb, skDropMeasurement, skDelete, skDropSeries:
        begin
          FStore.Lock.BeginWrite;
          try
            case S.Kind of
              skCreateDb:
                if FStore.CreateDb(S.Name, Err) = nil then raise EInfluxQL.Create(Err);
              skDropDb: FStore.DropDb(S.Name);
              skDropMeasurement:
                begin
                  D := Db(S, True);
                  D.DropMeasurement(S.Name);
                  D.Compact;
                end;
            else
              RunDelete(S);
            end;
          finally
            FStore.Lock.EndWrite;
          end;
        end;
    end;
    if FSeriesCount > 0 then FOut.Add(']');
  except
    on E: Exception do
    begin
      FOut.Len := Mark;                            // drop a half written series
      FOut.Add(',"error":' + JsonString(E.Message));
    end;
  end;
  FOut.Add('}');
end;

function TExec.Run(const Q: string; out Code: Integer): string;
var
  Stmts: TStatements;
  Err: string;
  I: Integer;
begin
  if not ParseQuery(Q, Stmts, Err) then
  begin
    Code := 400;
    Exit('{"error":' + JsonString('error parsing query: ' + Err) + '}');
  end;
  try
    Code := 200;
    FOut.Add('{"results":[');
    for I := 0 to High(Stmts) do
      Statement(Stmts[I], I);
    FOut.Add(']}');
    Result := FOut.Text;
  finally
    FreeStatements(Stmts);
  end;
end;

function ExecuteQuery(Store: TStore; const Q, DefaultDb: string; EpochFactor: Int64;
  out HttpCode: Integer): string;
var
  X: TExec;
begin
  X := TExec.Create(Store, DefaultDb, EpochFactor);
  try
    Result := X.Run(Q, HttpCode);
  finally
    X.Free;
  end;
end;

initialization
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  FS.ThousandSeparator := #0;
end.

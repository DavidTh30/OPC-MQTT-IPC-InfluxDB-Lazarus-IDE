{ ============================================================================
  uinfluxql - InfluxQL lexer and parser (the subset of InfluxDB 1.x that
  Grafana, Chronograf, the influx CLI and the client libraries send)
    SELECT <expr> [AS name], ... FROM <m> | "db"."rp"."m" | /regex/
           [WHERE <cond>] [GROUP BY time(<dur>[, <offset>]), <tag>, * ]
           [fill(null | none | previous | linear | <number>)]
           [ORDER BY time [ASC | DESC]] [LIMIT n] [OFFSET n] [SLIMIT n] [SOFFSET n] [tz('...')]
    SHOW DATABASES | MEASUREMENTS | TAG KEYS | TAG VALUES WITH KEY ... |
         FIELD KEYS | SERIES | RETENTION POLICIES | USERS  [ON db] [FROM m] [WHERE] [LIMIT]
    CREATE DATABASE, DROP DATABASE, DROP MEASUREMENT, DROP SERIES, DELETE
    (CREATE / ALTER / DROP RETENTION POLICY, users, grants: accepted, no effect)
  Several statements separated by ';'.
  ============================================================================ }
unit uinfluxql;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, RegExpr;

type
  EInfluxQL = class(Exception);

  TExprKind = (ekNumber, ekInteger, ekString, ekRegex, ekBool, ekIdent, ekWildcard, ekCall,
    ekBinary, ekDuration);

  { TExpr }

  TExpr = class
    Kind: TExprKind;
    Name: string;                 // identifier, function, string, regex text, operator (ekBinary)
    Num: Double;
    Int: Int64;                   // integer value; ns for durations
    Cast: string;                 // 'tag' / 'field' / '' from ident::tag
    Args: array of TExpr;         // ekCall
    Left, Right: TExpr;           // ekBinary
    Slot: Integer;                // set by the executor: field index, -1 tag, -2 time
    Re: TRegExpr;
    destructor Destroy; override;
    function Regex: TRegExpr;
  end;

  TSelectField = record
    Expr: TExpr;
    Alias: string;
  end;

  TStatementKind = (skSelect, skShowDatabases, skShowMeasurements, skShowTagKeys,
    skShowTagValues, skShowFieldKeys, skShowSeries, skShowRetention, skShowUsers, skCreateDb,
    skDropDb, skDropMeasurement, skDropSeries, skDelete, skNoop);

  TFillMode = (fmNull, fmNone, fmPrevious, fmLinear, fmValue);

  { TStatement }

  TStatement = class
    Kind: TStatementKind;
    Fields: array of TSelectField;
    SourceDb, SourceName: string;
    SourceRegex: TExpr;
    Where: TExpr;
    GroupInterval, GroupOffset: Int64;    // ns, 0 = no GROUP BY time
    GroupTags: TStringList;
    GroupAllTags: Boolean;
    Fill: TFillMode;
    FillValue: Double;
    OrderDesc: Boolean;
    Limit, Offset, SLimit, SOffset: Integer;
    Name: string;                          // CREATE / DROP name, SHOW TAG VALUES key
    KeyOp: string;                         // SHOW TAG VALUES: '=', '!=', '=~', '!~', 'IN'
    KeyList: TStringList;
    KeyRegex: TExpr;
    OnDb: string;
    MeasOp: string;                        // SHOW MEASUREMENTS WITH MEASUREMENT = / =~
    MeasName: string;
    MeasRegex: TExpr;
    Text: string;                          // the statement text (log)
    constructor Create;
    destructor Destroy; override;
  end;

  TStatements = array of TStatement;

function ParseQuery(const Q: string; out Stmts: TStatements; out Err: string): Boolean;
procedure FreeStatements(var Stmts: TStatements);
{ duration text: 10s, 1h30m, 500ms, 2d, 1w -> ns }
function FormatDuration(Ns: Int64): string;
{ '2026-10-26T08:00:00Z', '2026-10-26 08:00:00.5', '...+02:00' -> ns since 1970 UTC }
function ParseTimeString(const S: string; out Ns: Int64): Boolean;

const
  AGGREGATES: array[0..11] of string = ('count', 'sum', 'mean', 'median', 'min', 'max', 'first',
    'last', 'spread', 'stddev', 'mode', 'percentile');
  TRANSFORMS: array[0..6] of string = ('derivative', 'non_negative_derivative', 'difference',
    'non_negative_difference', 'cumulative_sum', 'moving_average', 'elapsed');

function IsAggregate(const Fn: string): Boolean;
function IsTransform(const Fn: string): Boolean;

implementation

type
  TTokKind = (tkEOF, tkIdent, tkQIdent, tkString, tkNumber, tkInteger, tkDuration, tkRegex, tkOp,
    tkComma, tkLParen, tkRParen, tkSemicolon, tkDot, tkStar, tkCast);

  TToken = record
    Kind: TTokKind;
    Text: string;                 // ident / op text / string value
    Num: Double;
    Int: Int64;
    Pos: Integer;
  end;

  { TParser }

  TParser = class
  private
    FSrc: string;
    FPos: Integer;
    FTok: TToken;
    FPrev: TToken;
    FStmtStart: Integer;
    procedure Scan;
    procedure Fail(const Msg: string);
    function IsKw(const K: string): Boolean;
    procedure ExpectKw(const K: string);
    function AcceptKw(const K: string): Boolean;
    procedure Expect(K: TTokKind; const What: string);
    function IdentName: string;
    function ParseExpr: TExpr;
    function ParseOr: TExpr;
    function ParseAnd: TExpr;
    function ParseCompare: TExpr;
    function ParseAdd: TExpr;
    function ParseMul: TExpr;
    function ParseUnary: TExpr;
    function ParsePrimary: TExpr;
    procedure ParseSource(S: TStatement);
    procedure ParseTail(S: TStatement);
    function ParseInt: Integer;
    function ParseSelect: TStatement;
    function ParseShow: TStatement;
    function ParseStatement: TStatement;
    procedure SkipStatement;
  public
    constructor Create(const Src: string);
    function ParseAll: TStatements;
  end;

var
  FS: TFormatSettings;

function IsAggregate(const Fn: string): Boolean;
var
  S: string;
begin
  for S in AGGREGATES do
    if SameText(S, Fn) then Exit(True);
  Result := False;
end;

function IsTransform(const Fn: string): Boolean;
var
  S: string;
begin
  for S in TRANSFORMS do
    if SameText(S, Fn) then Exit(True);
  Result := False;
end;

function UnitNs(const U: string): Int64;
begin
  case U of
    'ns': Result := 1;
    'u', #$C2#$B5: Result := 1000;
    'ms': Result := 1000000;
    's': Result := 1000000000;
    'm': Result := 60000000000;
    'h': Result := 3600000000000;
    'd': Result := 86400000000000;
    'w': Result := 604800000000000;
  else
    Result := 0;
  end;
end;

function FormatDuration(Ns: Int64): string;
var
  H, M, S: Int64;
begin
  if Ns <= 0 then Exit('0s');
  H := Ns div 3600000000000;
  M := (Ns div 60000000000) mod 60;
  S := (Ns div 1000000000) mod 60;
  Result := Format('%dh%dm%ds', [H, M, S]);
end;

function ParseTimeString(const S: string; out Ns: Int64): Boolean;
var
  Y, Mo, D, H, Mi, Sec, Code, P, OffSign, OffH, OffM: Integer;
  Frac: string;
  FracNs: Int64;
  DT: TDateTime;
  T: string;
begin
  Result := False;
  Ns := 0;
  T := Trim(S);
  if Length(T) < 10 then Exit;
  Val(Copy(T, 1, 4), Y, Code); if Code <> 0 then Exit;
  Val(Copy(T, 6, 2), Mo, Code); if Code <> 0 then Exit;
  Val(Copy(T, 9, 2), D, Code); if Code <> 0 then Exit;
  H := 0; Mi := 0; Sec := 0; FracNs := 0; OffSign := 0; OffH := 0; OffM := 0;
  P := 11;
  if (Length(T) >= 19) and (T[11] in ['T', ' ']) then
  begin
    Val(Copy(T, 12, 2), H, Code); if Code <> 0 then Exit;
    Val(Copy(T, 15, 2), Mi, Code); if Code <> 0 then Exit;
    Val(Copy(T, 18, 2), Sec, Code); if Code <> 0 then Exit;
    P := 20;
    if (P <= Length(T)) and (T[P] = '.') then
    begin
      Inc(P);
      Frac := '';
      while (P <= Length(T)) and (T[P] in ['0'..'9']) do
      begin
        Frac := Frac + T[P];
        Inc(P);
      end;
      Frac := Copy(Frac + '000000000', 1, 9);
      FracNs := StrToInt64(Frac);
    end;
  end;
  if P <= Length(T) then
    case T[P] of
      'Z', 'z': ;
      '+', '-':
        begin
          if T[P] = '+' then OffSign := 1 else OffSign := -1;
          Val(Copy(T, P + 1, 2), OffH, Code); if Code <> 0 then Exit;
          Val(Copy(T, P + 4, 2), OffM, Code); if Code <> 0 then OffM := 0;
        end;
    else
      Exit;
    end;
  if not TryEncodeDate(Y, Mo, D, DT) then Exit;
  if (H > 23) or (Mi > 59) or (Sec > 60) then Exit;
  Ns := (Round((DT - UnixDateDelta)) * 86400 + H * 3600 + Mi * 60 + Sec -
    OffSign * (OffH * 3600 + OffM * 60)) * Int64(1000000000) + FracNs;
  Result := True;
end;

{ TExpr }

destructor TExpr.Destroy;
var
  A: TExpr;
begin
  for A in Args do A.Free;
  Left.Free;
  Right.Free;
  Re.Free;
  inherited Destroy;
end;

function TExpr.Regex: TRegExpr;
begin
  if Re = nil then
  begin
    Re := TRegExpr.Create(Name);
    Re.Compile;
  end;
  Result := Re;
end;

{ TStatement }

constructor TStatement.Create;
begin
  GroupTags := TStringList.Create;
  KeyList := TStringList.Create;
  Limit := -1;
  SLimit := -1;
end;

destructor TStatement.Destroy;
var
  F: TSelectField;
begin
  for F in Fields do F.Expr.Free;
  SourceRegex.Free;
  Where.Free;
  KeyRegex.Free;
  MeasRegex.Free;
  GroupTags.Free;
  KeyList.Free;
  inherited Destroy;
end;

procedure FreeStatements(var Stmts: TStatements);
var
  S: TStatement;
begin
  for S in Stmts do S.Free;
  Stmts := nil;
end;

function NewExpr(K: TExprKind): TExpr;
begin
  Result := TExpr.Create;
  Result.Kind := K;
  Result.Slot := -3;
end;

{ TParser }

constructor TParser.Create(const Src: string);
begin
  FSrc := Src;
  FPos := 1;
  Scan;
end;

procedure TParser.Fail(const Msg: string);
begin
  raise EInfluxQL.CreateFmt('%s at line 1, char %d', [Msg, FTok.Pos]);
end;

procedure TParser.Scan;
var
  C: Char;
  Start: Integer;
  S, U: string;
  Total, N: Int64;
  IsFloat, RegexOk: Boolean;
  Code: Integer;
begin
  FPrev := FTok;
  while (FPos <= Length(FSrc)) and (FSrc[FPos] in [' ', #9, #10, #13]) do Inc(FPos);
  FTok := Default(TToken);
  FTok.Pos := FPos;
  if FPos > Length(FSrc) then
  begin
    FTok.Kind := tkEOF;
    Exit;
  end;
  C := FSrc[FPos];
  { a regex can only follow =~ / !~ / FROM / =  (SHOW ... WITH MEASUREMENT =~ /x/) }
  RegexOk := ((FPrev.Kind = tkOp) and ((FPrev.Text = '=~') or (FPrev.Text = '!~'))) or
    ((FPrev.Kind = tkIdent) and SameText(FPrev.Text, 'FROM'));
  case C of
    'A'..'Z', 'a'..'z', '_':
      begin
        Start := FPos;
        while (FPos <= Length(FSrc)) and (FSrc[FPos] in ['A'..'Z', 'a'..'z', '0'..'9', '_']) do
          Inc(FPos);
        FTok.Kind := tkIdent;
        FTok.Text := Copy(FSrc, Start, FPos - Start);
      end;
    '"', '''':
      begin
        Inc(FPos);
        S := '';
        while (FPos <= Length(FSrc)) and (FSrc[FPos] <> C) do
        begin
          if (FSrc[FPos] = '\') and (FPos < Length(FSrc)) then Inc(FPos);
          S := S + FSrc[FPos];
          Inc(FPos);
        end;
        if FPos > Length(FSrc) then Fail('unterminated ' + C);
        Inc(FPos);
        if C = '"' then FTok.Kind := tkQIdent else FTok.Kind := tkString;
        FTok.Text := S;
      end;
    '0'..'9':
      begin
        { number, or duration (also 1698000000000ms, 1h30m) }
        Start := FPos;
        IsFloat := False;
        while (FPos <= Length(FSrc)) and (FSrc[FPos] in ['0'..'9']) do Inc(FPos);
        if (FPos < Length(FSrc)) and (FSrc[FPos] = '.') and (FSrc[FPos + 1] in ['0'..'9']) then
        begin
          IsFloat := True;
          Inc(FPos);
          while (FPos <= Length(FSrc)) and (FSrc[FPos] in ['0'..'9']) do Inc(FPos);
        end;
        if (FPos <= Length(FSrc)) and (FSrc[FPos] in ['e', 'E']) and (FPos < Length(FSrc)) and
          (FSrc[FPos + 1] in ['0'..'9', '+', '-']) then
        begin
          IsFloat := True;
          Inc(FPos, 2);
          while (FPos <= Length(FSrc)) and (FSrc[FPos] in ['0'..'9']) do Inc(FPos);
        end;
        S := Copy(FSrc, Start, FPos - Start);
        if not IsFloat and (FPos <= Length(FSrc)) and (FSrc[FPos] in ['n', 'u', 'm', 's', 'h', 'd', 'w', #$C2]) then
        begin
          Total := 0;
          repeat
            Val(S, N, Code);
            if Code <> 0 then Fail('bad duration');
            U := '';
            while (FPos <= Length(FSrc)) and (FSrc[FPos] in ['a'..'z', #$C2, #$B5]) do
            begin
              U := U + FSrc[FPos];
              Inc(FPos);
            end;
            if UnitNs(U) = 0 then Fail('invalid duration unit ' + U);
            if N > High(Int64) div UnitNs(U) then Fail('duration too large');
            Inc(Total, N * UnitNs(U));
            if (FPos > Length(FSrc)) or not (FSrc[FPos] in ['0'..'9']) then Break;
            Start := FPos;
            while (FPos <= Length(FSrc)) and (FSrc[FPos] in ['0'..'9']) do Inc(FPos);
            S := Copy(FSrc, Start, FPos - Start);
          until False;
          FTok.Kind := tkDuration;
          FTok.Int := Total;
        end
        else if IsFloat then
        begin
          FTok.Kind := tkNumber;
          FTok.Num := StrToFloat(S, FS);
        end
        else
        begin
          FTok.Kind := tkInteger;
          Val(S, FTok.Int, Code);
          if Code <> 0 then
          begin
            FTok.Kind := tkNumber;
            FTok.Num := StrToFloat(S, FS);
          end;
          FTok.Num := FTok.Int;
        end;
      end;
    '/':
      if RegexOk then
      begin
        Inc(FPos);
        S := '';
        while (FPos <= Length(FSrc)) and (FSrc[FPos] <> '/') do
        begin
          if (FSrc[FPos] = '\') and (FPos < Length(FSrc)) and (FSrc[FPos + 1] = '/') then Inc(FPos);
          S := S + FSrc[FPos];
          Inc(FPos);
        end;
        if FPos > Length(FSrc) then Fail('unterminated regex');
        Inc(FPos);
        FTok.Kind := tkRegex;
        FTok.Text := S;
      end
      else
      begin
        Inc(FPos);
        FTok.Kind := tkOp;
        FTok.Text := '/';
      end;
    ',': begin Inc(FPos); FTok.Kind := tkComma; end;
    '(': begin Inc(FPos); FTok.Kind := tkLParen; end;
    ')': begin Inc(FPos); FTok.Kind := tkRParen; end;
    ';': begin Inc(FPos); FTok.Kind := tkSemicolon; end;
    '.': begin Inc(FPos); FTok.Kind := tkDot; end;
    '*': begin Inc(FPos); FTok.Kind := tkStar; FTok.Text := '*'; end;
    ':':
      begin
        if (FPos < Length(FSrc)) and (FSrc[FPos + 1] = ':') then
        begin
          Inc(FPos, 2);
          FTok.Kind := tkCast;
        end
        else
          Fail('unexpected :');
      end;
    '=', '!', '<', '>', '+', '-', '%':
      begin
        S := C;
        Inc(FPos);
        if (FPos <= Length(FSrc)) and (C in ['=', '!', '<', '>']) and (FSrc[FPos] in ['=', '~', '>']) then
        begin
          S := S + FSrc[FPos];
          Inc(FPos);
        end;
        if S = '<>' then S := '!=';
        if S = '==' then S := '=';
        if not ((S = '=') or (S = '!=') or (S = '<') or (S = '<=') or (S = '>') or (S = '>=') or
          (S = '=~') or (S = '!~') or (S = '+') or (S = '-') or (S = '%')) then
          Fail('unexpected ' + S);
        FTok.Kind := tkOp;
        FTok.Text := S;
      end;
  else
    Fail('unexpected character ' + C);
  end;
end;

function TParser.IsKw(const K: string): Boolean;
begin
  Result := (FTok.Kind = tkIdent) and SameText(FTok.Text, K);
end;

function TParser.AcceptKw(const K: string): Boolean;
begin
  Result := IsKw(K);
  if Result then Scan;
end;

procedure TParser.ExpectKw(const K: string);
begin
  if not AcceptKw(K) then
    Fail('found ' + FTok.Text + ', expected ' + K);
end;

procedure TParser.Expect(K: TTokKind; const What: string);
begin
  if FTok.Kind <> K then
    Fail('found ' + FTok.Text + ', expected ' + What);
  Scan;
end;

function TParser.IdentName: string;
begin
  if not (FTok.Kind in [tkIdent, tkQIdent, tkString]) then
    Fail('found ' + FTok.Text + ', expected identifier');
  Result := FTok.Text;
  Scan;
end;

function TParser.ParseInt: Integer;
begin
  if FTok.Kind <> tkInteger then Fail('expected integer');
  Result := FTok.Int;
  Scan;
end;

function TParser.ParseExpr: TExpr;
begin
  Result := ParseOr;
end;

function Binary(const Op: string; L, R: TExpr): TExpr;
begin
  Result := NewExpr(ekBinary);
  Result.Name := Op;
  Result.Left := L;
  Result.Right := R;
end;

function TParser.ParseOr: TExpr;
begin
  Result := ParseAnd;
  while AcceptKw('OR') do
    Result := Binary('OR', Result, ParseAnd);
end;

function TParser.ParseAnd: TExpr;
begin
  Result := ParseCompare;
  while AcceptKw('AND') do
    Result := Binary('AND', Result, ParseCompare);
end;

function TParser.ParseCompare: TExpr;
var
  Op: string;
begin
  Result := ParseAdd;
  while (FTok.Kind = tkOp) and ((FTok.Text = '=') or (FTok.Text = '!=') or (FTok.Text = '<') or
    (FTok.Text = '<=') or (FTok.Text = '>') or (FTok.Text = '>=') or (FTok.Text = '=~') or
    (FTok.Text = '!~')) do
  begin
    Op := FTok.Text;
    Scan;
    Result := Binary(Op, Result, ParseAdd);
  end;
end;

function TParser.ParseAdd: TExpr;
var
  Op: string;
begin
  Result := ParseMul;
  while (FTok.Kind = tkOp) and ((FTok.Text = '+') or (FTok.Text = '-')) do
  begin
    Op := FTok.Text;
    Scan;
    Result := Binary(Op, Result, ParseMul);
  end;
end;

function TParser.ParseMul: TExpr;
var
  Op: string;
begin
  Result := ParseUnary;
  while ((FTok.Kind = tkOp) and ((FTok.Text = '/') or (FTok.Text = '%'))) or (FTok.Kind = tkStar) do
  begin
    if FTok.Kind = tkStar then Op := '*' else Op := FTok.Text;
    Scan;
    Result := Binary(Op, Result, ParseUnary);
  end;
end;

function TParser.ParseUnary: TExpr;
var
  E: TExpr;
begin
  Result := nil;
  if (FTok.Kind = tkOp) and (FTok.Text = '-') then
  begin
    Scan;
    E := ParseUnary;
    case E.Kind of
      ekNumber: begin E.Num := -E.Num; Exit(E); end;
      ekInteger: begin E.Int := -E.Int; E.Num := -E.Num; Exit(E); end;
      ekDuration: begin E.Int := -E.Int; Exit(E); end;
    end;
    Result := NewExpr(ekInteger);                       // 0 - x
    Result := Binary('-', Result, E);
    Exit;
  end;
  Result := ParsePrimary;
end;

function TParser.ParsePrimary: TExpr;
var
  N: Integer;
begin
  case FTok.Kind of
    tkNumber:
      begin
        Result := NewExpr(ekNumber);
        Result.Num := FTok.Num;
        Scan;
      end;
    tkInteger:
      begin
        Result := NewExpr(ekInteger);
        Result.Int := FTok.Int;
        Result.Num := FTok.Int;
        Scan;
      end;
    tkDuration:
      begin
        Result := NewExpr(ekDuration);
        Result.Int := FTok.Int;
        Scan;
      end;
    tkString:
      begin
        Result := NewExpr(ekString);
        Result.Name := FTok.Text;
        Scan;
      end;
    tkRegex:
      begin
        Result := NewExpr(ekRegex);
        Result.Name := FTok.Text;
        Scan;
      end;
    tkStar:
      begin
        Result := NewExpr(ekWildcard);
        Scan;
      end;
    tkLParen:
      begin
        Scan;
        Result := ParseExpr;
        Expect(tkRParen, ')');
      end;
    tkIdent, tkQIdent:
      begin
        if (FTok.Kind = tkIdent) and (SameText(FTok.Text, 'true') or SameText(FTok.Text, 'false')) then
        begin
          Result := NewExpr(ekBool);
          Result.Int := Ord(SameText(FTok.Text, 'true'));
          Scan;
          Exit;
        end;
        Result := NewExpr(ekIdent);
        Result.Name := FTok.Text;
        Scan;
        if (FPrev.Kind = tkIdent) and (FTok.Kind = tkLParen) then
        begin
          { function call }
          Result.Kind := ekCall;
          Result.Name := LowerCase(Result.Name);
          Scan;
          N := 0;
          if FTok.Kind <> tkRParen then
            repeat
              SetLength(Result.Args, N + 1);
              Result.Args[N] := ParseExpr;
              Inc(N);
              if FTok.Kind <> tkComma then Break;
              Scan;
            until False;
          Expect(tkRParen, ')');
          Exit;
        end;
        while FTok.Kind = tkDot do                   // "m"."field": the last part counts
        begin
          Scan;
          Result.Name := IdentName;
        end;
        if FTok.Kind = tkCast then
        begin
          Scan;
          Result.Cast := LowerCase(IdentName);
        end;
      end;
  else
    Fail('found ' + FTok.Text + ', expected expression');
    Result := nil;
  end;
end;

{ m | "m" | db.rp.m | "db".."m" | /regex/ }
procedure TParser.ParseSource(S: TStatement);
var
  Parts: TStringList;
begin
  if FTok.Kind = tkRegex then
  begin
    S.SourceRegex := NewExpr(ekRegex);
    S.SourceRegex.Name := FTok.Text;
    Scan;
    Exit;
  end;
  Parts := TStringList.Create;
  try
    Parts.Add(IdentName);
    while FTok.Kind = tkDot do
    begin
      Scan;
      if FTok.Kind = tkDot then
        Parts.Add('')                               // db..m
      else if FTok.Kind = tkRegex then
      begin
        S.SourceRegex := NewExpr(ekRegex);
        S.SourceRegex.Name := FTok.Text;
        Scan;
        Break;
      end
      else
        Parts.Add(IdentName);
    end;
    if S.SourceRegex = nil then
      S.SourceName := Parts[Parts.Count - 1];
    if (Parts.Count >= 3) or ((S.SourceRegex <> nil) and (Parts.Count >= 2)) then
      S.SourceDb := Parts[0];
  finally
    Parts.Free;
  end;
end;

{ WHERE, GROUP BY, fill, ORDER BY, LIMIT, OFFSET, SLIMIT, SOFFSET, tz, in any order }
procedure TParser.ParseTail(S: TStatement);
var
  E: TExpr;
begin
  repeat
    if AcceptKw('WHERE') then
      S.Where := ParseExpr
    else if AcceptKw('GROUP') then
    begin
      ExpectKw('BY');
      repeat
        if IsKw('time') then
        begin
          Scan;
          Expect(tkLParen, '(');
          if FTok.Kind <> tkDuration then Fail('expected duration in time()');
          S.GroupInterval := FTok.Int;
          Scan;
          if FTok.Kind = tkComma then
          begin
            Scan;
            E := ParseExpr;
            try
              if E.Kind = ekDuration then S.GroupOffset := E.Int
              else if E.Kind = ekCall then S.GroupOffset := 0     // now(): ignored
              else Fail('expected offset duration');
            finally
              E.Free;
            end;
          end;
          Expect(tkRParen, ')');
          if S.GroupInterval <= 0 then Fail('time() interval must be > 0');
        end
        else if FTok.Kind = tkStar then
        begin
          S.GroupAllTags := True;
          Scan;
        end
        else if FTok.Kind = tkRegex then
        begin
          S.GroupAllTags := True;                     // GROUP BY /regex/: all tags
          Scan;
        end
        else
        begin
          S.GroupTags.Add(IdentName);
          if FTok.Kind = tkCast then
          begin
            Scan;
            IdentName;
          end;
        end;
        if FTok.Kind <> tkComma then Break;
        Scan;
      until False;
    end
    else if AcceptKw('fill') then
    begin
      Expect(tkLParen, '(');
      if AcceptKw('null') then S.Fill := fmNull
      else if AcceptKw('none') then S.Fill := fmNone
      else if AcceptKw('previous') then S.Fill := fmPrevious
      else if AcceptKw('linear') then S.Fill := fmLinear
      else
      begin
        E := ParseExpr;
        try
          if not (E.Kind in [ekNumber, ekInteger]) then Fail('fill() expects null, none, previous, linear or a number');
          S.Fill := fmValue;
          S.FillValue := E.Num;
        finally
          E.Free;
        end;
      end;
      Expect(tkRParen, ')');
    end
    else if AcceptKw('ORDER') then
    begin
      ExpectKw('BY');
      if not IsKw('time') then Fail('only ORDER BY time is supported');
      Scan;
      if AcceptKw('DESC') then S.OrderDesc := True
      else AcceptKw('ASC');
    end
    else if AcceptKw('LIMIT') then S.Limit := ParseInt
    else if AcceptKw('OFFSET') then S.Offset := ParseInt
    else if AcceptKw('SLIMIT') then S.SLimit := ParseInt
    else if AcceptKw('SOFFSET') then S.SOffset := ParseInt
    else if AcceptKw('tz') then
    begin
      Expect(tkLParen, '(');
      Expect(tkString, 'time zone string');
      Expect(tkRParen, ')');
    end
    else
      Break;
  until False;
end;

function TParser.ParseSelect: TStatement;
var
  N: Integer;
begin
  Result := TStatement.Create;
  try
    Result.Kind := skSelect;
    N := 0;
    repeat
      SetLength(Result.Fields, N + 1);
      Result.Fields[N].Expr := ParseExpr;
      Inc(N);
      if AcceptKw('AS') then
        Result.Fields[N - 1].Alias := IdentName;
      if FTok.Kind <> tkComma then Break;
      Scan;
    until False;
    if AcceptKw('INTO') then Fail('SELECT INTO is not supported');
    ExpectKw('FROM');
    ParseSource(Result);
    if FTok.Kind = tkComma then Fail('only one measurement per SELECT is supported (use a regex)');
    ParseTail(Result);
  except
    Result.Free;
    raise;
  end;
end;

function TParser.ParseShow: TStatement;
begin
  Result := TStatement.Create;
  try
    if AcceptKw('DATABASES') then
      Result.Kind := skShowDatabases
    else if AcceptKw('MEASUREMENTS') then
      Result.Kind := skShowMeasurements
    else if AcceptKw('TAG') then
    begin
      if AcceptKw('KEYS') then Result.Kind := skShowTagKeys
      else
      begin
        ExpectKw('VALUES');
        Result.Kind := skShowTagValues;
      end;
    end
    else if AcceptKw('FIELD') then
    begin
      ExpectKw('KEYS');
      Result.Kind := skShowFieldKeys;
    end
    else if AcceptKw('SERIES') then
      Result.Kind := skShowSeries
    else if AcceptKw('RETENTION') then
    begin
      ExpectKw('POLICIES');
      Result.Kind := skShowRetention;
    end
    else if AcceptKw('USERS') then
      Result.Kind := skShowUsers
    else
    begin
      Result.Kind := skNoop;                          // SHOW STATS, DIAGNOSTICS, ...
      SkipStatement;
      Exit;
    end;
    if AcceptKw('ON') then Result.OnDb := IdentName;
    if AcceptKw('FROM') then ParseSource(Result);
    if (Result.Kind = skShowMeasurements) and AcceptKw('WITH') then
    begin
      ExpectKw('MEASUREMENT');
      if FTok.Kind <> tkOp then Fail('expected = or =~');
      Result.MeasOp := FTok.Text;
      Scan;
      if FTok.Kind = tkRegex then
      begin
        Result.MeasRegex := NewExpr(ekRegex);
        Result.MeasRegex.Name := FTok.Text;
        Scan;
      end
      else
        Result.MeasName := IdentName;
    end;
    if (Result.Kind = skShowTagValues) then
    begin
      ExpectKw('WITH');
      ExpectKw('KEY');
      if AcceptKw('IN') then
      begin
        Result.KeyOp := 'IN';
        Expect(tkLParen, '(');
        repeat
          Result.KeyList.Add(IdentName);
          if FTok.Kind <> tkComma then Break;
          Scan;
        until False;
        Expect(tkRParen, ')');
      end
      else
      begin
        if FTok.Kind <> tkOp then Fail('expected =, !=, =~, !~ or IN');
        Result.KeyOp := FTok.Text;
        Scan;
        if FTok.Kind = tkRegex then
        begin
          Result.KeyRegex := NewExpr(ekRegex);
          Result.KeyRegex.Name := FTok.Text;
          Scan;
        end
        else
          Result.Name := IdentName;
      end;
    end;
    ParseTail(Result);
  except
    Result.Free;
    raise;
  end;
end;

procedure TParser.SkipStatement;
begin
  while not (FTok.Kind in [tkEOF, tkSemicolon]) do Scan;
end;

function TParser.ParseStatement: TStatement;
begin
  Result := nil;
  FStmtStart := FTok.Pos;
  if AcceptKw('SELECT') then
    Result := ParseSelect
  else if AcceptKw('SHOW') then
    Result := ParseShow
  else if AcceptKw('CREATE') then
  begin
    Result := TStatement.Create;
    if AcceptKw('DATABASE') then
    begin
      Result.Kind := skCreateDb;
      Result.Name := IdentName;
    end
    else
      Result.Kind := skNoop;                          // RETENTION POLICY, USER, CONTINUOUS QUERY
    SkipStatement;
  end
  else if AcceptKw('DROP') then
  begin
    Result := TStatement.Create;
    try
      if AcceptKw('DATABASE') then
      begin
        Result.Kind := skDropDb;
        Result.Name := IdentName;
      end
      else if AcceptKw('MEASUREMENT') then
      begin
        Result.Kind := skDropMeasurement;
        Result.Name := IdentName;
      end
      else if AcceptKw('SERIES') then
      begin
        Result.Kind := skDropSeries;
        if AcceptKw('FROM') then ParseSource(Result);
        ParseTail(Result);
      end
      else
      begin
        Result.Kind := skNoop;
        SkipStatement;
      end;
    except
      Result.Free;
      raise;
    end;
  end
  else if AcceptKw('DELETE') then
  begin
    Result := TStatement.Create;
    try
      Result.Kind := skDelete;
      if AcceptKw('FROM') then ParseSource(Result);
      ParseTail(Result);
    except
      Result.Free;
      raise;
    end;
  end
  else if IsKw('ALTER') or IsKw('GRANT') or IsKw('REVOKE') or IsKw('SET') or IsKw('KILL') then
  begin
    Result := TStatement.Create;
    Result.Kind := skNoop;
    SkipStatement;
  end
  else
  begin
    Fail('found ' + FTok.Text + ', expected SELECT, DELETE, SHOW, CREATE, DROP');
    Result := nil;
  end;
  Result.Text := Trim(Copy(FSrc, FStmtStart, FTok.Pos - FStmtStart));
end;

function TParser.ParseAll: TStatements;
var
  N: Integer;
begin
  Result := nil;
  N := 0;
  try
    repeat
      while FTok.Kind = tkSemicolon do Scan;
      if FTok.Kind = tkEOF then Break;
      SetLength(Result, N + 1);
      Result[N] := ParseStatement;
      Inc(N);
      if not (FTok.Kind in [tkEOF, tkSemicolon]) then
        Fail('found ' + FTok.Text + ', expected ;');
    until False;
  except
    FreeStatements(Result);
    raise;
  end;
end;

function ParseQuery(const Q: string; out Stmts: TStatements; out Err: string): Boolean;
var
  P: TParser;
begin
  Stmts := nil;
  Err := '';
  P := nil;
  try
    P := TParser.Create(Q);
    Stmts := P.ParseAll;
    if Length(Stmts) = 0 then
    begin
      Err := 'empty query';
      Exit(False);
    end;
    Result := True;
  except
    on E: Exception do
    begin
      Err := E.Message;
      Result := False;
    end;
  end;
  P.Free;
end;

initialization
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  FS.ThousandSeparator := #0;
end.

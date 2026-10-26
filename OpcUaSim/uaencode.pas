{ ============================================================================
  uaencode - OPC UA binary encoding (OPC 10000-6, chapter 5.2)
  Little endian writer / reader for the built-in types: numbers, String,
  DateTime, NodeId, QualifiedName, LocalizedText, Variant, DataValue,
  ExtensionObject and DiagnosticInfo (skipped).
  ============================================================================ }
unit uaencode;

{$mode objfpc}{$H+}

interface

uses
  SysUtils {$IFDEF WINDOWS}, Windows{$ENDIF};

type
  EUADecode = class(Exception);

  TUANodeId = record
    Ns: Word;
    IdType: Byte;      // 0 numeric, 1 string, 2 guid, 3 opaque
    Num: Cardinal;
    Str: string;       // string id, 16 guid bytes or opaque bytes
  end;

  TUAQName = record
    Ns: Word;
    Name: string;
  end;

const
  { built-in type ids (Variant type) }
  vtNull = 0; vtBoolean = 1; vtSByte = 2; vtByte = 3; vtInt16 = 4; vtUInt16 = 5;
  vtInt32 = 6; vtUInt32 = 7; vtInt64 = 8; vtUInt64 = 9; vtFloat = 10; vtDouble = 11;
  vtString = 12; vtDateTime = 13; vtGuid = 14; vtByteString = 15; vtXml = 16;
  vtNodeId = 17; vtExpNodeId = 18; vtStatusCode = 19; vtQName = 20; vtLText = 21;
  vtExtObj = 22; vtDataValue = 23; vtVariant = 24; vtDiag = 25;

  idNumeric = 0; idString = 1; idGuid = 2; idOpaque = 3;

type
  { Variant value: numbers / Boolean / DateTime (100 ns ticks) in D, text in S,
    every other type kept as its encoded bytes in Raw (array length included) }
  TUAVariant = record
    VType: Byte;
    IsArray: Boolean;
    D: array of Double;
    S: array of string;
    Raw: TBytes;
  end;

  TUADataValue = record
    HasValue: Boolean;
    Value: TUAVariant;
    Status: Cardinal;
    SrcTime, SrvTime: Int64;    // 0 = not sent
  end;

  { TUAWriter }

  TUAWriter = class
  private
    FBuf: TBytes;
    FLen: Integer;
    procedure Need(N: Integer);
    procedure Elem(T: Byte; X: Double);
  public
    procedure Clear;
    procedure Bytes(const B; N: Integer);
    procedure AddBytes(const B: TBytes);
    procedure U8(V: Byte);
    procedure Bool(V: Boolean);
    procedure U16(V: Word);
    procedure U32(V: Cardinal);
    procedure I32(V: LongInt);
    procedure I64(V: Int64);
    procedure F32(V: Single);
    procedure F64(V: Double);
    procedure Str(const S: string);         // '' is written as an empty string
    procedure NullStr;                      // null String / ByteString / array (-1)
    procedure ByteStr(const B: TBytes);
    procedure NodeId(const N: TUANodeId);
    procedure NumId(Id: Cardinal);          // ns=0 numeric NodeId
    procedure QName(const Q: TUAQName);
    procedure LText(const S: string);
    procedure DateTime(T: Int64);
    procedure Variant(const V: TUAVariant);
    procedure DataValue(const V: TUADataValue);
    procedure NullExtObj;
    procedure PatchI32(Ofs: Integer; V: LongInt);
    function Data: TBytes;
    property Len: Integer read FLen;
  end;

  { TUAReader }

  TUAReader = class
  private
    FData: TBytes;
    FPos: Integer;
    procedure Check(N: Integer);
    function NodeIdBody(B: Byte): TUANodeId;
    function Elem(T: Byte): Double;
    procedure SkipElem(T: Byte);
  public
    constructor Create(const AData: TBytes; AStart: Integer = 0);
    procedure Skip(N: Integer);
    function U8: Byte;
    function Bool: Boolean;
    function U16: Word;
    function U32: Cardinal;
    function I32: LongInt;
    function I64: Int64;
    function F32: Single;
    function F64: Double;
    function Str: string;                   // null -> ''
    function ByteStr: TBytes;
    function ArrLen: Integer;               // null array -> 0
    function NodeId: TUANodeId;
    function ExpNodeId: TUANodeId;          // namespace uri / server index dropped
    function QName: TUAQName;
    function LText: string;
    function Variant: TUAVariant;
    function DataValue: TUADataValue;
    procedure ExtObj(out TypeId: TUANodeId; out Body: TBytes);
    procedure SkipExtObj;
    procedure SkipDiag;
    function Remaining: Integer;
    property Pos: Integer read FPos;
  end;

function NumNodeId(Ns: Word; Num: Cardinal): TUANodeId;
function StrNodeId(Ns: Word; const S: string): TUANodeId;
function NullNodeId: TUANodeId;
function IsNullNodeId(const N: TUANodeId): Boolean;
function SameNodeId(const A, B: TUANodeId): Boolean;
{ unique key for lookups, e.g. '2|1|DB_HMI.Enable' }
function NodeIdKey(const N: TUANodeId): string;
{ text like 'i=85' or 'ns=2;s=DB_HMI.Enable' }
function NodeIdText(const N: TUANodeId): string;
function QN(Ns: Word; const Name: string): TUAQName;

{ UTC now as OPC UA DateTime (100 ns since 1601-01-01) }
function UANow: Int64;
function UATimeToLocal(T: Int64): TDateTime;

function VarScalar(T: Byte; X: Double): TUAVariant;
function VarArray(T: Byte; const X: array of Double): TUAVariant;
function VarString(const S: string): TUAVariant;
function VarStrings(const S: array of string): TUAVariant;
function VarRaw(T: Byte; const B: TBytes): TUAVariant;
function VarIsNumeric(const V: TUAVariant): Boolean;
function VarTypeName(T: Byte): string;
function VarText(const V: TUAVariant): string;

implementation

const
  NumericTypes = [vtBoolean..vtDouble, vtDateTime, vtStatusCode];
  TextTypes = [vtString, vtByteString, vtXml, vtLText];

{ ---------------------------------------------------------------------------- }

function NumNodeId(Ns: Word; Num: Cardinal): TUANodeId;
begin
  Result.Ns := Ns;
  Result.IdType := idNumeric;
  Result.Num := Num;
  Result.Str := '';
end;

function StrNodeId(Ns: Word; const S: string): TUANodeId;
begin
  Result.Ns := Ns;
  Result.IdType := idString;
  Result.Num := 0;
  Result.Str := S;
end;

function NullNodeId: TUANodeId;
begin
  Result := NumNodeId(0, 0);
end;

function IsNullNodeId(const N: TUANodeId): Boolean;
begin
  Result := (N.Ns = 0) and (((N.IdType = idNumeric) and (N.Num = 0)) or
    ((N.IdType <> idNumeric) and (N.Str = '')));
end;

function SameNodeId(const A, B: TUANodeId): Boolean;
begin
  Result := (A.Ns = B.Ns) and (A.IdType = B.IdType) and (A.Num = B.Num) and (A.Str = B.Str);
end;

function NodeIdKey(const N: TUANodeId): string;
begin
  if N.IdType = idNumeric then
    Result := IntToStr(N.Ns) + '|0|' + IntToStr(N.Num)
  else
    Result := IntToStr(N.Ns) + '|' + IntToStr(N.IdType) + '|' + N.Str;
end;

function NodeIdText(const N: TUANodeId): string;
const
  Pre: array[0..3] of string = ('i=', 's=', 'g=', 'b=');
begin
  if N.IdType = idNumeric then
    Result := 'i=' + IntToStr(N.Num)
  else if N.IdType = idString then
    Result := 's=' + N.Str
  else
    Result := Pre[N.IdType] + '(' + IntToStr(Length(N.Str)) + ' bytes)';
  if N.Ns <> 0 then
    Result := 'ns=' + IntToStr(N.Ns) + ';' + Result;
end;

function QN(Ns: Word; const Name: string): TUAQName;
begin
  Result.Ns := Ns;
  Result.Name := Name;
end;

{ ---------------------------------------------------------------------------- }

const
  { days from 1601-01-01 to 1899-12-30 (TDateTime 0) }
  DAYS_1601 = 109205;
  TICKS_PER_DAY: Int64 = 864000000000;

function UANow: Int64;
{$IFDEF WINDOWS}
var
  FT: TFileTime;
begin
  GetSystemTimeAsFileTime(FT);     // already 100 ns since 1601, UTC
  Result := Int64(FT.dwHighDateTime) shl 32 or FT.dwLowDateTime;
end;
{$ELSE}
begin
  { GetLocalTimeOffset: minutes, UTC = local + offset }
  Result := Round((Double(Now) + GetLocalTimeOffset / 1440 + DAYS_1601) * Double(TICKS_PER_DAY));
end;
{$ENDIF}

function UATimeToLocal(T: Int64): TDateTime;
begin
  Result := Double(T) / Double(TICKS_PER_DAY) - DAYS_1601 - GetLocalTimeOffset / 1440;
end;

{ ---------------------------------------------------------------------------- }

function VarScalar(T: Byte; X: Double): TUAVariant;
begin
  Result := Default(TUAVariant);
  Result.VType := T;
  SetLength(Result.D, 1);
  Result.D[0] := X;
end;

function VarArray(T: Byte; const X: array of Double): TUAVariant;
var
  I: Integer;
begin
  Result := Default(TUAVariant);
  Result.VType := T;
  Result.IsArray := True;
  SetLength(Result.D, Length(X));
  for I := 0 to High(X) do
    Result.D[I] := X[I];
end;

function VarString(const S: string): TUAVariant;
begin
  Result := Default(TUAVariant);
  Result.VType := vtString;
  SetLength(Result.S, 1);
  Result.S[0] := S;
end;

function VarStrings(const S: array of string): TUAVariant;
var
  I: Integer;
begin
  Result := Default(TUAVariant);
  Result.VType := vtString;
  Result.IsArray := True;
  SetLength(Result.S, Length(S));
  for I := 0 to High(S) do
    Result.S[I] := S[I];
end;

function VarRaw(T: Byte; const B: TBytes): TUAVariant;
begin
  Result := Default(TUAVariant);
  Result.VType := T;
  Result.Raw := B;
end;

function VarIsNumeric(const V: TUAVariant): Boolean;
begin
  Result := (V.VType in NumericTypes) and (V.VType <> vtDateTime);
end;

function VarTypeName(T: Byte): string;
const
  Names: array[0..25] of string = ('Null', 'Boolean', 'SByte', 'Byte', 'Int16', 'UInt16',
    'Int32', 'UInt32', 'Int64', 'UInt64', 'Float', 'Double', 'String', 'DateTime', 'Guid',
    'ByteString', 'XmlElement', 'NodeId', 'ExpandedNodeId', 'StatusCode', 'QualifiedName',
    'LocalizedText', 'ExtensionObject', 'DataValue', 'Variant', 'DiagnosticInfo');
begin
  if T <= 25 then
    Result := Names[T]
  else
    Result := 'type ' + IntToStr(T);
end;

function ElemText(const V: TUAVariant; I: Integer): string;
var
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  case V.VType of
    vtBoolean: Result := BoolToStr(V.D[I] <> 0, 'True', 'False');
    vtFloat: Result := FloatToStrF(V.D[I], ffGeneral, 7, 0, FS);
    vtDouble: Result := FloatToStrF(V.D[I], ffGeneral, 15, 0, FS);
    vtDateTime: Result := FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', UATimeToLocal(Round(V.D[I])));
    vtStatusCode: Result := '0x' + IntToHex(Round(V.D[I]), 8);
  else
    Result := IntToStr(Round(V.D[I]));
  end;
end;

function VarText(const V: TUAVariant): string;
var
  I: Integer;
begin
  if V.VType = vtNull then
    Exit('(null)');
  if V.VType in NumericTypes then
  begin
    if not V.IsArray then
      Exit(ElemText(V, 0));
    Result := '[';
    for I := 0 to High(V.D) do
    begin
      if I > 0 then Result := Result + ', ';
      Result := Result + ElemText(V, I);
    end;
    Exit(Result + ']');
  end;
  if V.VType in TextTypes then
  begin
    if not V.IsArray then
      Exit(V.S[0]);
    Result := '[';
    for I := 0 to High(V.S) do
    begin
      if I > 0 then Result := Result + ', ';
      Result := Result + V.S[I];
    end;
    Exit(Result + ']');
  end;
  Result := VarTypeName(V.VType) + ' (' + IntToStr(Length(V.Raw)) + ' bytes)';
end;

{ ---------------------------------------------------------------------------- }
{ TUAWriter }

procedure TUAWriter.Need(N: Integer);
var
  L: Integer;
begin
  if FLen + N <= Length(FBuf) then Exit;
  L := Length(FBuf) * 2;
  if L < 256 then L := 256;
  while L < FLen + N do L := L * 2;
  SetLength(FBuf, L);
end;

procedure TUAWriter.Clear;
begin
  FLen := 0;
end;

procedure TUAWriter.Bytes(const B; N: Integer);
begin
  if N <= 0 then Exit;
  Need(N);
  Move(B, FBuf[FLen], N);
  Inc(FLen, N);
end;

procedure TUAWriter.AddBytes(const B: TBytes);
begin
  if Length(B) > 0 then
    Bytes(B[0], Length(B));
end;

procedure TUAWriter.U8(V: Byte);
begin
  Bytes(V, 1);
end;

procedure TUAWriter.Bool(V: Boolean);
begin
  U8(Ord(V));
end;

procedure TUAWriter.U16(V: Word);
begin
  V := NtoLE(V);
  Bytes(V, 2);
end;

procedure TUAWriter.U32(V: Cardinal);
begin
  V := NtoLE(V);
  Bytes(V, 4);
end;

procedure TUAWriter.I32(V: LongInt);
begin
  V := NtoLE(V);
  Bytes(V, 4);
end;

procedure TUAWriter.I64(V: Int64);
begin
  V := NtoLE(V);
  Bytes(V, 8);
end;

procedure TUAWriter.F32(V: Single);
begin
  U32(PCardinal(@V)^);
end;

procedure TUAWriter.F64(V: Double);
begin
  I64(PInt64(@V)^);
end;

procedure TUAWriter.Str(const S: string);
begin
  I32(Length(S));
  if S <> '' then
    Bytes(S[1], Length(S));
end;

procedure TUAWriter.NullStr;
begin
  I32(-1);
end;

procedure TUAWriter.ByteStr(const B: TBytes);
begin
  I32(Length(B));
  AddBytes(B);
end;

procedure TUAWriter.NodeId(const N: TUANodeId);
begin
  case N.IdType of
    idNumeric:
      if (N.Ns = 0) and (N.Num <= 255) then
      begin
        U8(0);
        U8(N.Num);
      end
      else if (N.Ns <= 255) and (N.Num <= 65535) then
      begin
        U8(1);
        U8(N.Ns);
        U16(N.Num);
      end
      else
      begin
        U8(2);
        U16(N.Ns);
        U32(N.Num);
      end;
    idString:
      begin
        U8(3);
        U16(N.Ns);
        Str(N.Str);
      end;
    idGuid:
      begin
        U8(4);
        U16(N.Ns);
        Bytes(N.Str[1], 16);
      end;
  else
    U8(5);
    U16(N.Ns);
    Str(N.Str);
  end;
end;

procedure TUAWriter.NumId(Id: Cardinal);
begin
  NodeId(NumNodeId(0, Id));
end;

procedure TUAWriter.QName(const Q: TUAQName);
begin
  U16(Q.Ns);
  Str(Q.Name);
end;

procedure TUAWriter.LText(const S: string);
begin
  if S = '' then
    U8(0)
  else
  begin
    U8(2);           // text only, no locale
    Str(S);
  end;
end;

procedure TUAWriter.DateTime(T: Int64);
begin
  I64(T);
end;

procedure TUAWriter.Elem(T: Byte; X: Double);
begin
  case T of
    vtBoolean: Bool(X <> 0);
    vtSByte: U8(Byte(ShortInt(Round(X))));
    vtByte: U8(Byte(Round(X)));
    vtInt16: U16(Word(SmallInt(Round(X))));
    vtUInt16: U16(Word(Round(X)));
    vtInt32: I32(LongInt(Round(X)));
    vtUInt32, vtStatusCode: U32(Cardinal(Round(X)));
    vtInt64, vtUInt64, vtDateTime: I64(Round(X));
    vtFloat: F32(X);
    vtDouble: F64(X);
  end;
end;

procedure TUAWriter.Variant(const V: TUAVariant);
var
  M: Byte;
  I, N: Integer;
begin
  if V.VType = vtNull then
  begin
    U8(0);
    Exit;
  end;
  M := V.VType;
  if V.IsArray then M := M or $80;
  U8(M);
  if V.VType in NumericTypes then
  begin
    if V.IsArray then
    begin
      I32(Length(V.D));
      for I := 0 to High(V.D) do Elem(V.VType, V.D[I]);
    end
    else if Length(V.D) > 0 then
      Elem(V.VType, V.D[0])
    else
      Elem(V.VType, 0);
  end
  else if V.VType in TextTypes then
  begin
    N := Length(V.S);
    if V.IsArray then I32(N) else N := 1;
    for I := 0 to N - 1 do
      if V.VType = vtLText then
      begin
        if I < Length(V.S) then LText(V.S[I]) else LText('');
      end
      else if I < Length(V.S) then
        Str(V.S[I])
      else
        Str('');
  end
  else
    AddBytes(V.Raw);
end;

procedure TUAWriter.DataValue(const V: TUADataValue);
var
  M: Byte;
begin
  M := 0;
  if V.HasValue then M := M or $01;
  if V.Status <> 0 then M := M or $02;
  if V.SrcTime <> 0 then M := M or $04;
  if V.SrvTime <> 0 then M := M or $08;
  U8(M);
  if V.HasValue then Variant(V.Value);
  if V.Status <> 0 then U32(V.Status);
  if V.SrcTime <> 0 then I64(V.SrcTime);
  if V.SrvTime <> 0 then I64(V.SrvTime);
end;

procedure TUAWriter.NullExtObj;
begin
  U8(0);       // NodeId i=0 (two byte)
  U8(0);
  U8(0);       // no body
end;

procedure TUAWriter.PatchI32(Ofs: Integer; V: LongInt);
begin
  V := NtoLE(V);
  Move(V, FBuf[Ofs], 4);
end;

function TUAWriter.Data: TBytes;
begin
  Result := Copy(FBuf, 0, FLen);
end;

{ ---------------------------------------------------------------------------- }
{ TUAReader }

constructor TUAReader.Create(const AData: TBytes; AStart: Integer);
begin
  FData := AData;
  FPos := AStart;
end;

procedure TUAReader.Check(N: Integer);
begin
  if (N < 0) or (FPos + N > Length(FData)) then
    raise EUADecode.Create('message too short');
end;

procedure TUAReader.Skip(N: Integer);
begin
  Check(N);
  Inc(FPos, N);
end;

function TUAReader.Remaining: Integer;
begin
  Result := Length(FData) - FPos;
end;

function TUAReader.U8: Byte;
begin
  Check(1);
  Result := FData[FPos];
  Inc(FPos);
end;

function TUAReader.Bool: Boolean;
begin
  Result := U8 <> 0;
end;

function TUAReader.U16: Word;
begin
  Check(2);
  Move(FData[FPos], Result, 2);
  Result := LEtoN(Result);
  Inc(FPos, 2);
end;

function TUAReader.U32: Cardinal;
begin
  Check(4);
  Move(FData[FPos], Result, 4);
  Result := LEtoN(Result);
  Inc(FPos, 4);
end;

function TUAReader.I32: LongInt;
begin
  Result := LongInt(U32);
end;

function TUAReader.I64: Int64;
begin
  Check(8);
  Move(FData[FPos], Result, 8);
  Result := LEtoN(Result);
  Inc(FPos, 8);
end;

function TUAReader.F32: Single;
var
  C: Cardinal;
begin
  C := U32;
  Result := PSingle(@C)^;
end;

function TUAReader.F64: Double;
var
  C: Int64;
begin
  C := I64;
  Result := PDouble(@C)^;
end;

function TUAReader.Str: string;
var
  N: LongInt;
begin
  N := I32;
  if N <= 0 then
    Exit('');
  Check(N);
  SetString(Result, PChar(@FData[FPos]), N);
  Inc(FPos, N);
end;

function TUAReader.ByteStr: TBytes;
var
  N: LongInt;
begin
  Result := nil;
  N := I32;
  if N <= 0 then Exit;
  Check(N);
  Result := Copy(FData, FPos, N);
  Inc(FPos, N);
end;

function TUAReader.ArrLen: Integer;
begin
  Result := I32;
  if Result < 0 then
    Result := 0
  else if Result > Remaining then     // every element takes at least 1 byte
    raise EUADecode.Create('bad array length');
end;

function TUAReader.NodeIdBody(B: Byte): TUANodeId;
begin
  Result := NullNodeId;
  case B and $3F of
    0: Result.Num := U8;
    1:
      begin
        Result.Ns := U8;
        Result.Num := U16;
      end;
    2:
      begin
        Result.Ns := U16;
        Result.Num := U32;
      end;
    3:
      begin
        Result.Ns := U16;
        Result.IdType := idString;
        Result.Str := Str;
      end;
    4:
      begin
        Result.Ns := U16;
        Result.IdType := idGuid;
        Check(16);
        SetString(Result.Str, PChar(@FData[FPos]), 16);
        Inc(FPos, 16);
      end;
    5:
      begin
        Result.Ns := U16;
        Result.IdType := idOpaque;
        Result.Str := Str;
      end;
  else
    raise EUADecode.Create('bad NodeId encoding');
  end;
end;

function TUAReader.NodeId: TUANodeId;
begin
  Result := NodeIdBody(U8);
end;

function TUAReader.ExpNodeId: TUANodeId;
var
  B: Byte;
begin
  B := U8;
  Result := NodeIdBody(B);
  if B and $80 <> 0 then Str;      // namespace uri
  if B and $40 <> 0 then U32;      // server index
end;

function TUAReader.QName: TUAQName;
begin
  Result.Ns := U16;
  Result.Name := Str;
end;

function TUAReader.LText: string;
var
  M: Byte;
begin
  Result := '';
  M := U8;
  if M and 1 <> 0 then Str;        // locale
  if M and 2 <> 0 then Result := Str;
end;

function TUAReader.Elem(T: Byte): Double;
begin
  case T of
    vtBoolean: Result := Ord(U8 <> 0);
    vtSByte: Result := ShortInt(U8);
    vtByte: Result := U8;
    vtInt16: Result := SmallInt(U16);
    vtUInt16: Result := U16;
    vtInt32: Result := I32;
    vtUInt32, vtStatusCode: Result := U32;
    vtInt64, vtDateTime: Result := I64;
    vtUInt64: Result := QWord(I64);
    vtFloat: Result := F32;
    vtDouble: Result := F64;
  else
    Result := 0;
  end;
end;

procedure TUAReader.SkipElem(T: Byte);
begin
  case T of
    vtGuid: Skip(16);
    vtString, vtByteString, vtXml: Str;
    vtNodeId: NodeId;
    vtExpNodeId: ExpNodeId;
    vtQName: QName;
    vtLText: LText;
    vtExtObj: SkipExtObj;
    vtDataValue: DataValue;
    vtVariant: Variant;
    vtDiag: SkipDiag;
  else
    raise EUADecode.Create('bad Variant type');
  end;
end;

function TUAReader.Variant: TUAVariant;
var
  M: Byte;
  I, N, Start: Integer;
begin
  Result := Default(TUAVariant);
  M := U8;
  Result.VType := M and $3F;
  Result.IsArray := M and $80 <> 0;
  if Result.VType = vtNull then Exit;
  if Result.VType > vtDiag then
    raise EUADecode.Create('bad Variant type');
  Start := FPos;
  if Result.IsArray then N := ArrLen else N := 1;
  if Result.VType in NumericTypes then
  begin
    SetLength(Result.D, N);
    for I := 0 to N - 1 do Result.D[I] := Elem(Result.VType);
  end
  else if Result.VType in TextTypes then
  begin
    SetLength(Result.S, N);
    for I := 0 to N - 1 do
      if Result.VType = vtLText then Result.S[I] := LText else Result.S[I] := Str;
  end
  else
  begin
    for I := 0 to N - 1 do SkipElem(Result.VType);
    Result.Raw := Copy(FData, Start, FPos - Start);
  end;
  if M and $40 <> 0 then          // array dimensions (ignored)
  begin
    N := ArrLen;
    Skip(4 * N);
  end;
end;

function TUAReader.DataValue: TUADataValue;
var
  M: Byte;
begin
  Result := Default(TUADataValue);
  M := U8;
  if M and $01 <> 0 then
  begin
    Result.HasValue := True;
    Result.Value := Variant;
  end;
  if M and $02 <> 0 then Result.Status := U32;
  if M and $04 <> 0 then Result.SrcTime := I64;
  if M and $10 <> 0 then U16;
  if M and $08 <> 0 then Result.SrvTime := I64;
  if M and $20 <> 0 then U16;
end;

procedure TUAReader.ExtObj(out TypeId: TUANodeId; out Body: TBytes);
var
  Enc: Byte;
begin
  TypeId := NodeId;
  Enc := U8;
  if Enc in [1, 2] then
    Body := ByteStr
  else
    Body := nil;
end;

procedure TUAReader.SkipExtObj;
var
  T: TUANodeId;
  B: TBytes;
begin
  ExtObj(T, B);
end;

procedure TUAReader.SkipDiag;
var
  M: Byte;
begin
  M := U8;
  if M and $01 <> 0 then I32;      // symbolic id
  if M and $02 <> 0 then I32;      // namespace uri
  if M and $04 <> 0 then I32;      // localized text
  if M and $08 <> 0 then I32;      // locale
  if M and $10 <> 0 then Str;      // additional info
  if M and $20 <> 0 then U32;      // inner status code
  if M and $40 <> 0 then SkipDiag; // inner diagnostic info
end;

end.

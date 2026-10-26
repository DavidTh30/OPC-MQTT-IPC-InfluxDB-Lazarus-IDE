{ ============================================================================
  utsdb - the time series store of the InfluxDB server
    store -> databases -> measurements -> series (one per tag set)
          -> columns (one per field, times sorted, typed values)
    - a field keeps its first type in a measurement (like InfluxDB); a point
      with another type is refused ("field type conflict")
    - same series + field + time = the value is replaced
    - persistence per database in <data>\<db>\:
        wal.lp       every accepted write, line protocol with ns times (append only)
        snapshot.lp  the whole database, written by Compact; the WAL starts again
      loading = snapshot + WAL; replaying twice gives the same data
    - retention per database (0 = keep everything), purged once per minute
    - one reader / writer lock for the store: many queries at once, writes alone
  ============================================================================ }
unit utsdb;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  Classes, SysUtils, Math, ulineproto;

type

  { TColumn }

  TColumn = class
    Kind: TFieldKind;
    Times: array of Int64;
    D: array of Double;           // fkFloat
    I: array of Int64;            // fkInteger, fkBoolean
    S: array of string;           // fkString
    Count: Integer;
    procedure Put(T: Int64; const V: TFieldValue);
    { first index with Times >= T }
    function LowerBound(T: Int64): Integer;
    function Value(Idx: Integer): TFieldValue;
    function AsFloat(Idx: Integer): Double;
    { removes the times T0..T1, returns how many }
    function DeleteRange(T0, T1: Int64): Integer;
  end;

  { TSeries }

  TSeries = class
    Key: string;                  // tag1=v1,tag2=v2 (sorted, escaped), '' = no tags
    TagKeys, TagValues: array of string;
    Fields: TStringList;          // sorted, field name -> TColumn
    constructor Create;
    destructor Destroy; override;
    function TagValue(const K: string): string;
    function Column(const F: string): TColumn;
    function PointCount: Int64;
  end;

  { TMeasurement }

  TMeasurement = class
    Name: string;
    FieldKinds: TStringList;      // sorted, field name -> kind (PtrInt in Objects)
    Series: TStringList;          // sorted by key -> TSeries
    constructor Create;
    destructor Destroy; override;
    function FieldKind(const F: string; out K: TFieldKind): Boolean;
    procedure TagKeys(Dest: TStrings);
    function PointCount: Int64;
  end;

  TSeriesFilter = function(M: TMeasurement; S: TSeries): Boolean of object;

  { TDatabase }

  TDatabase = class
  private
    FWal: TFileStream;
    procedure OpenWal;
  public
    Name, Dir: string;
    Measurements: TStringList;    // sorted -> TMeasurement
    RetentionNs: Int64;           // 0 = forever
    Dirty: Boolean;               // deleted data not compacted yet
    WalBytes: Int64;
    constructor Create(const AName, ADir: string);
    destructor Destroy; override;
    function Measurement(const M: string): TMeasurement;
    { into memory (no WAL); False = field type conflict }
    function Put(const P: TLinePoint; out Err: string): Boolean;
    procedure AppendWal(const Lines: string);
    procedure Load(out Points: Int64; out Err: string);
    procedure Compact;
    { deletes points of the measurement (all if M = '') whose series pass Filter (nil = all) }
    function DeleteData(const M: string; Filter: TSeriesFilter; T0, T1: Int64): Int64;
    procedure DropMeasurement(const M: string);
    function PointCount: Int64;
    function SeriesCount: Integer;
  end;

  { TRowIter - the rows of one series: every time where any of the columns has a value }

  TRowIter = record
    Cols: array of TColumn;       // nil = this field is not in the series
    Pos, Stop: array of Integer;
    Has: array of Boolean;        // column c has a value at T (index Pos[c] - 1)
    T: Int64;
    procedure Init(const ACols: array of TColumn; T0, T1: Int64);
    function Next: Boolean;
    function Idx(C: Integer): Integer;
  end;

  { TStore }

  TStore = class
  public
    Lock: TMultiReadExclusiveWriteSynchronizer;
    DataDir: string;
    Databases: TStringList;       // sorted -> TDatabase
    AutoCreate: Boolean;
    DefaultRetentionNs: Int64;
    constructor Create(const ADataDir: string);
    destructor Destroy; override;
    function ValidName(const Name: string): Boolean;
    function Find(const Name: string): TDatabase;
    { call with the write lock }
    function CreateDb(const Name: string; out Err: string): TDatabase;
    procedure DropDb(const Name: string);
    procedure LoadAll(Log: TStrings);
    { line protocol body -> HTTP status (204 / 400 / 404), Err = InfluxDB error text }
    function Write(const DbName, Body: string; Factor: Int64; out Points: Integer;
      out Err: string): Integer;
    procedure CompactAll;
    procedure Purge(Log: TStrings);
  end;

{ nil-safe free of all objects of a TStringList }
procedure FreeObjects(L: TStringList);
function SeriesKey(const Keys, Values: array of string): string;

implementation

procedure FreeObjects(L: TStringList);
var
  I: Integer;
begin
  for I := 0 to L.Count - 1 do
    L.Objects[I].Free;
  L.Clear;
end;

function SortedList: TStringList;
begin
  Result := TStringList.Create;
  Result.CaseSensitive := True;
  Result.Sorted := True;
  Result.Duplicates := dupIgnore;
end;

function SeriesKey(const Keys, Values: array of string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(Keys) do
  begin
    if I > 0 then Result := Result + ',';
    Result := Result + EscapeName(Keys[I], True) + '=' + EscapeName(Values[I], True);
  end;
end;

{ TColumn }

function TColumn.LowerBound(T: Int64): Integer;
var
  L, H, M: Integer;
begin
  L := 0;
  H := Count;
  while L < H do
  begin
    M := (L + H) div 2;
    if Times[M] < T then L := M + 1 else H := M;
  end;
  Result := L;
end;

procedure TColumn.Put(T: Int64; const V: TFieldValue);
var
  P, N: Integer;
begin
  if (Count > 0) and (T <= Times[Count - 1]) then
  begin
    P := LowerBound(T);
    if Times[P] <> T then
      P := -P - 1                                 // insert before P
  end
  else
    P := -Count - 1;                              // append (the usual case)
  if P < 0 then
  begin
    P := -P - 1;
    if Count >= Length(Times) then
    begin
      N := Max(16, Length(Times) * 2);
      SetLength(Times, N);
      case Kind of
        fkFloat: SetLength(D, N);
        fkString: SetLength(S, N);
      else
        SetLength(I, N);
      end;
    end;
    if P < Count then
    begin
      Move(Times[P], Times[P + 1], (Count - P) * SizeOf(Int64));
      case Kind of
        fkFloat: Move(D[P], D[P + 1], (Count - P) * SizeOf(Double));
        fkString:
          begin
            for N := Count downto P + 1 do        // managed strings: no Move
              S[N] := S[N - 1];
          end;
      else
        Move(I[P], I[P + 1], (Count - P) * SizeOf(Int64));
      end;
    end;
    Inc(Count);
  end;
  Times[P] := T;
  case Kind of
    fkFloat: D[P] := V.D;
    fkString: S[P] := V.S;
  else
    I[P] := V.I;
  end;
end;

function TColumn.Value(Idx: Integer): TFieldValue;
begin
  Result := Default(TFieldValue);
  Result.Kind := Kind;
  case Kind of
    fkFloat: Result.D := D[Idx];
    fkString: Result.S := S[Idx];
  else
    Result.I := I[Idx];
  end;
end;

function TColumn.AsFloat(Idx: Integer): Double;
begin
  case Kind of
    fkFloat: Result := D[Idx];
    fkInteger, fkBoolean: Result := I[Idx];
  else
    Result := NaN;
  end;
end;

function TColumn.DeleteRange(T0, T1: Int64): Integer;
var
  A, B, K: Integer;
begin
  A := LowerBound(T0);
  if T1 = High(Int64) then
    B := Count
  else
    B := LowerBound(T1 + 1);
  Result := B - A;
  if Result <= 0 then Exit(0);
  for K := B to Count - 1 do
  begin
    Times[K - Result] := Times[K];
    case Kind of
      fkFloat: D[K - Result] := D[K];
      fkString: S[K - Result] := S[K];
    else
      I[K - Result] := I[K];
    end;
  end;
  Dec(Count, Result);
  if Kind = fkString then
    for K := Count to Count + Result - 1 do S[K] := '';
end;

{ TSeries }

constructor TSeries.Create;
begin
  Fields := SortedList;
end;

destructor TSeries.Destroy;
begin
  FreeObjects(Fields);
  Fields.Free;
  inherited Destroy;
end;

function TSeries.TagValue(const K: string): string;
var
  I: Integer;
begin
  for I := 0 to High(TagKeys) do
    if TagKeys[I] = K then Exit(TagValues[I]);
  Result := '';
end;

function TSeries.Column(const F: string): TColumn;
var
  I: Integer;
begin
  if Fields.Find(F, I) then
    Result := TColumn(Fields.Objects[I])
  else
    Result := nil;
end;

function TSeries.PointCount: Int64;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to Fields.Count - 1 do
    Inc(Result, TColumn(Fields.Objects[I]).Count);
end;

{ TMeasurement }

constructor TMeasurement.Create;
begin
  FieldKinds := SortedList;
  Series := SortedList;
end;

destructor TMeasurement.Destroy;
begin
  FreeObjects(Series);
  Series.Free;
  FieldKinds.Free;
  inherited Destroy;
end;

function TMeasurement.FieldKind(const F: string; out K: TFieldKind): Boolean;
var
  I: Integer;
begin
  Result := FieldKinds.Find(F, I);
  if Result then
    K := TFieldKind(PtrInt(FieldKinds.Objects[I]))
  else
    K := fkFloat;
end;

procedure TMeasurement.TagKeys(Dest: TStrings);
var
  L: TStringList;
  I, J: Integer;
  S: TSeries;
begin
  L := SortedList;
  try
    for I := 0 to Series.Count - 1 do
    begin
      S := TSeries(Series.Objects[I]);
      for J := 0 to High(S.TagKeys) do
        L.Add(S.TagKeys[J]);
    end;
    Dest.Assign(L);
  finally
    L.Free;
  end;
end;

function TMeasurement.PointCount: Int64;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to Series.Count - 1 do
    Inc(Result, TSeries(Series.Objects[I]).PointCount);
end;

{ TDatabase }

constructor TDatabase.Create(const AName, ADir: string);
begin
  Name := AName;
  Dir := IncludeTrailingPathDelimiter(ADir);
  Measurements := SortedList;
end;

destructor TDatabase.Destroy;
begin
  FreeAndNil(FWal);
  FreeObjects(Measurements);
  Measurements.Free;
  inherited Destroy;
end;

procedure TDatabase.OpenWal;
var
  F: string;
begin
  if FWal <> nil then Exit;
  ForceDirectories(Dir);
  F := Dir + 'wal.lp';
  if FileExists(F) then
    FWal := TFileStream.Create(F, fmOpenReadWrite or fmShareDenyWrite)
  else
    FWal := TFileStream.Create(F, fmCreate or fmShareDenyWrite);
  FWal.Seek(0, soEnd);
  WalBytes := FWal.Size;
end;

function TDatabase.Measurement(const M: string): TMeasurement;
var
  I: Integer;
begin
  if Measurements.Find(M, I) then
    Result := TMeasurement(Measurements.Objects[I])
  else
    Result := nil;
end;

function TDatabase.Put(const P: TLinePoint; out Err: string): Boolean;
var
  M: TMeasurement;
  S: TSeries;
  C: TColumn;
  Key: string;
  I, Idx: Integer;
  K: TFieldKind;
begin
  Err := '';
  M := Measurement(P.Measurement);
  { field types first: the whole point is refused on a conflict }
  if M <> nil then
    for I := 0 to High(P.FieldKeys) do
      if M.FieldKind(P.FieldKeys[I], K) and (K <> P.FieldValues[I].Kind) then
      begin
        Err := Format('field type conflict: input field "%s" on measurement "%s" is type %s, ' +
          'already exists as type %s', [P.FieldKeys[I], P.Measurement,
          FieldKindName[P.FieldValues[I].Kind], FieldKindName[K]]);
        Exit(False);
      end;
  if M = nil then
  begin
    M := TMeasurement.Create;
    M.Name := P.Measurement;
    Measurements.AddObject(M.Name, M);
  end;
  Key := SeriesKey(P.TagKeys, P.TagValues);
  if M.Series.Find(Key, Idx) then
    S := TSeries(M.Series.Objects[Idx])
  else
  begin
    S := TSeries.Create;
    S.Key := Key;
    S.TagKeys := Copy(P.TagKeys);
    S.TagValues := Copy(P.TagValues);
    M.Series.AddObject(Key, S);
  end;
  for I := 0 to High(P.FieldKeys) do
  begin
    C := S.Column(P.FieldKeys[I]);
    if C = nil then
    begin
      C := TColumn.Create;
      C.Kind := P.FieldValues[I].Kind;
      S.Fields.AddObject(P.FieldKeys[I], C);
      M.FieldKinds.AddObject(P.FieldKeys[I], TObject(PtrInt(Ord(C.Kind))));
    end;
    C.Put(P.Time, P.FieldValues[I]);
  end;
  Result := True;
end;

procedure TDatabase.AppendWal(const Lines: string);
begin
  if Lines = '' then Exit;
  OpenWal;
  FWal.WriteBuffer(Lines[1], Length(Lines));    // one write per request, in the OS cache at once
  Inc(WalBytes, Length(Lines));
end;

procedure TDatabase.Load(out Points: Int64; out Err: string);
var
  L: TStringList;
  F, E: string;
  I, Bad: Integer;
  P: TLinePoint;
begin
  Points := 0;
  Err := '';
  Bad := 0;
  L := TStringList.Create;
  try
    for F in [Dir + 'snapshot.lp', Dir + 'wal.lp'] do
    begin
      if not FileExists(F) then Continue;
      L.LoadFromFile(F);
      for I := 0 to L.Count - 1 do
      begin
        if (L[I] = '') or (L[I][1] = '#') then Continue;
        if ParseLine(L[I], 1, 0, P, E) and Put(P, E) then
          Inc(Points)
        else
          Inc(Bad);
      end;
    end;
  finally
    L.Free;
  end;
  if Bad > 0 then
    Err := Format('%d line(s) could not be loaded', [Bad]);
  OpenWal;
end;

{ the whole database as line protocol: one line per series and time }
procedure TDatabase.Compact;
var
  Tmp, Snap: string;
  F: TFileStream;
  Buf, Line, Head: string;
  I, J, C: Integer;
  M: TMeasurement;
  S: TSeries;
  It: TRowIter;
  Cols: array of TColumn;
  First: Boolean;

  procedure Flush;
  begin
    if Buf <> '' then F.WriteBuffer(Buf[1], Length(Buf));
    Buf := '';
  end;

begin
  ForceDirectories(Dir);
  Tmp := Dir + 'snapshot.tmp';
  Snap := Dir + 'snapshot.lp';
  F := TFileStream.Create(Tmp, fmCreate);
  try
    Buf := '# snapshot of ' + Name + ', ' + FormatDateTime('yyyy-mm-dd hh:nn:ss', Now) + #10;
    for I := 0 to Measurements.Count - 1 do
    begin
      M := TMeasurement(Measurements.Objects[I]);
      for J := 0 to M.Series.Count - 1 do
      begin
        S := TSeries(M.Series.Objects[J]);
        Head := EscapeName(M.Name, False);
        if S.Key <> '' then Head := Head + ',' + S.Key;
        SetLength(Cols, S.Fields.Count);
        for C := 0 to S.Fields.Count - 1 do
          Cols[C] := TColumn(S.Fields.Objects[C]);
        It.Init(Cols, Low(Int64), High(Int64));
        while It.Next do
        begin
          Line := Head;
          First := True;
          for C := 0 to High(Cols) do
            if It.Has[C] then
            begin
              if First then Line := Line + ' ' else Line := Line + ',';
              First := False;
              Line := Line + EscapeName(S.Fields[C], True) + '=' +
                FieldValueText(Cols[C].Value(It.Idx(C)));
            end;
          Buf := Buf + Line + ' ' + IntToStr(It.T) + #10;
          if Length(Buf) > 1 shl 20 then Flush;
        end;
      end;
    end;
    Flush;
  finally
    F.Free;
  end;
  { snapshot first, then an empty WAL: a crash in between only replays twice }
  if FileExists(Snap) then DeleteFile(Snap);
  RenameFile(Tmp, Snap);
  OpenWal;
  FWal.Size := 0;
  WalBytes := 0;
  Dirty := False;
end;

function TDatabase.DeleteData(const M: string; Filter: TSeriesFilter; T0, T1: Int64): Int64;
var
  I, J, K: Integer;
  Meas: TMeasurement;
  S: TSeries;
  C: TColumn;
begin
  Result := 0;
  for I := Measurements.Count - 1 downto 0 do
  begin
    Meas := TMeasurement(Measurements.Objects[I]);
    if (M <> '') and (Meas.Name <> M) then Continue;
    for J := Meas.Series.Count - 1 downto 0 do
    begin
      S := TSeries(Meas.Series.Objects[J]);
      if Assigned(Filter) and not Filter(Meas, S) then Continue;
      for K := S.Fields.Count - 1 downto 0 do
      begin
        C := TColumn(S.Fields.Objects[K]);
        Inc(Result, C.DeleteRange(T0, T1));
        if C.Count = 0 then
        begin
          C.Free;
          S.Fields.Delete(K);
        end;
      end;
      if S.Fields.Count = 0 then
      begin
        S.Free;
        Meas.Series.Delete(J);
      end;
    end;
    if Meas.Series.Count = 0 then
    begin
      Meas.Free;
      Measurements.Delete(I);
    end;
  end;
  if Result > 0 then Dirty := True;
end;

procedure TDatabase.DropMeasurement(const M: string);
var
  I: Integer;
begin
  if Measurements.Find(M, I) then
  begin
    Measurements.Objects[I].Free;
    Measurements.Delete(I);
    Dirty := True;
  end;
end;

function TDatabase.PointCount: Int64;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to Measurements.Count - 1 do
    Inc(Result, TMeasurement(Measurements.Objects[I]).PointCount);
end;

function TDatabase.SeriesCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to Measurements.Count - 1 do
    Inc(Result, TMeasurement(Measurements.Objects[I]).Series.Count);
end;

{ TRowIter }

procedure TRowIter.Init(const ACols: array of TColumn; T0, T1: Int64);
var
  C: Integer;
begin
  SetLength(Cols, Length(ACols));
  SetLength(Pos, Length(ACols));
  SetLength(Stop, Length(ACols));
  SetLength(Has, Length(ACols));
  for C := 0 to High(ACols) do
  begin
    Cols[C] := ACols[C];
    if Cols[C] = nil then
    begin
      Pos[C] := 0;
      Stop[C] := 0;
    end
    else
    begin
      Pos[C] := Cols[C].LowerBound(T0);
      if T1 = High(Int64) then
        Stop[C] := Cols[C].Count
      else
        Stop[C] := Cols[C].LowerBound(T1 + 1);
    end;
  end;
end;

function TRowIter.Next: Boolean;
var
  C: Integer;
  Found: Boolean;
begin
  Found := False;
  for C := 0 to High(Cols) do
    if Pos[C] < Stop[C] then
      if not Found or (Cols[C].Times[Pos[C]] < T) then
      begin
        T := Cols[C].Times[Pos[C]];
        Found := True;
      end;
  if not Found then Exit(False);
  for C := 0 to High(Cols) do
  begin
    Has[C] := (Pos[C] < Stop[C]) and (Cols[C].Times[Pos[C]] = T);
    if Has[C] then Inc(Pos[C]);
  end;
  Result := True;
end;

function TRowIter.Idx(C: Integer): Integer;
begin
  Result := Pos[C] - 1;
end;

{ TStore }

constructor TStore.Create(const ADataDir: string);
begin
  Lock := TMultiReadExclusiveWriteSynchronizer.Create;
  DataDir := IncludeTrailingPathDelimiter(ADataDir);
  Databases := SortedList;
  AutoCreate := True;
end;

destructor TStore.Destroy;
begin
  FreeObjects(Databases);
  Databases.Free;
  Lock.Free;
  inherited Destroy;
end;

{ the name is also a folder: letters, digits, _ - . (not starting with .) }
function TStore.ValidName(const Name: string): Boolean;
var
  I: Integer;
begin
  Result := (Name <> '') and (Length(Name) <= 64) and (Name[1] <> '.');
  for I := 1 to Length(Name) do
    if not (Name[I] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '-', '.']) then
      Exit(False);
end;

function TStore.Find(const Name: string): TDatabase;
var
  I: Integer;
begin
  if Databases.Find(Name, I) then
    Result := TDatabase(Databases.Objects[I])
  else
    Result := nil;
end;

function TStore.CreateDb(const Name: string; out Err: string): TDatabase;
begin
  Err := '';
  Result := Find(Name);
  if Result <> nil then Exit;
  if not ValidName(Name) then
  begin
    Err := 'invalid database name "' + Name + '" (letters, digits, _ - . only)';
    Exit(nil);
  end;
  Result := TDatabase.Create(Name, DataDir + Name);
  Result.RetentionNs := DefaultRetentionNs;
  ForceDirectories(Result.Dir);
  Databases.AddObject(Name, Result);
end;

procedure TStore.DropDb(const Name: string);
var
  I: Integer;
  D: TDatabase;
  SR: TSearchRec;
begin
  if not Databases.Find(Name, I) then Exit;
  D := TDatabase(Databases.Objects[I]);
  Databases.Delete(I);
  try
    if FindFirst(D.Dir + '*', faAnyFile and not faDirectory, SR) = 0 then
    begin
      FreeAndNil(D.FWal);
      repeat
        DeleteFile(D.Dir + SR.Name);
      until FindNext(SR) <> 0;
      FindClose(SR);
    end;
    RemoveDir(D.Dir);
  finally
    D.Free;
  end;
end;

procedure TStore.LoadAll(Log: TStrings);
var
  SR: TSearchRec;
  D: TDatabase;
  N: Int64;
  Err: string;
  T0: QWord;
begin
  ForceDirectories(DataDir);
  if FindFirst(DataDir + '*', faDirectory, SR) = 0 then
  begin
    repeat
      if (SR.Attr and faDirectory = 0) or not ValidName(SR.Name) then Continue;
      T0 := GetTickCount64;
      D := TDatabase.Create(SR.Name, DataDir + SR.Name);
      D.RetentionNs := DefaultRetentionNs;
      D.Load(N, Err);
      Databases.AddObject(D.Name, D);
      Log.Add(Format('database %s: %d points, %d series loaded in %d ms', [D.Name, N,
        D.SeriesCount, GetTickCount64 - T0]));
      if Err <> '' then
        Log.Add('database ' + D.Name + ': ' + Err);
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
end;

function TStore.Write(const DbName, Body: string; Factor: Int64; out Points: Integer;
  out Err: string): Integer;
var
  Lines: TStringArray;
  Pts: array of TLinePoint;
  I, N, Dropped: Integer;
  E, Wal, Line: string;
  Ts: Int64;
  D: TDatabase;
begin
  Points := 0;
  Err := '';
  Dropped := 0;
  { parse outside the lock }
  Lines := Body.Split([#10]);
  SetLength(Pts, Length(Lines));
  N := 0;
  Ts := NowNs;
  for I := 0 to High(Lines) do
  begin
    Line := Trim(Lines[I]);
    if (Line = '') or (Line[1] = '#') then Continue;
    if ParseLine(Line, Factor, Ts, Pts[N], E) then
      Inc(N)
    else
    begin
      Inc(Dropped);
      if Err = '' then
        Err := Format('unable to parse ''%s'': %s', [Copy(Line, 1, 200), E]);
    end;
  end;
  Lock.BeginWrite;
  try
    D := Find(DbName);
    if D = nil then
    begin
      if not AutoCreate then
      begin
        Err := Format('database not found: "%s"', [DbName]);
        Exit(404);
      end;
      D := CreateDb(DbName, E);
      if D = nil then
      begin
        Err := E;
        Exit(400);
      end;
    end;
    Wal := '';
    for I := 0 to N - 1 do
      if D.Put(Pts[I], E) then
      begin
        Wal := Wal + FormatLine(Pts[I]) + #10;
        Inc(Points);
      end
      else
      begin
        Inc(Dropped);
        if Err = '' then Err := E;
      end;
    D.AppendWal(Wal);
    if D.WalBytes > 64 * 1024 * 1024 then          // keep the start-up replay short
      D.Compact;
  finally
    Lock.EndWrite;
  end;
  if Dropped > 0 then
  begin
    Err := Format('partial write: %s dropped=%d', [Err, Dropped]);
    Result := 400;
  end
  else
    Result := 204;
end;

procedure TStore.CompactAll;
var
  I: Integer;
begin
  Lock.BeginWrite;
  try
    for I := 0 to Databases.Count - 1 do
      TDatabase(Databases.Objects[I]).Compact;
  finally
    Lock.EndWrite;
  end;
end;

procedure TStore.Purge(Log: TStrings);
var
  I: Integer;
  D: TDatabase;
  N: Int64;
begin
  Lock.BeginWrite;
  try
    for I := 0 to Databases.Count - 1 do
    begin
      D := TDatabase(Databases.Objects[I]);
      if D.RetentionNs <= 0 then Continue;
      N := D.DeleteData('', nil, Low(Int64), NowNs - D.RetentionNs);
      if N > 0 then
      begin
        Log.Add(Format('retention: %d old points removed from %s', [N, D.Name]));
        D.Compact;
      end;
    end;
  finally
    Lock.EndWrite;
  end;
end;

end.

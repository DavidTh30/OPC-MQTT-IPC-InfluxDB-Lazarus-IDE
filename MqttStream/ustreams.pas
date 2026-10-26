{ ============================================================================
  ustreams - the stream engine of the MQTT Stream Server, one thread for:
    - Generator: test signals (sine, triangle, square, ...) sampled every
      RateMs, every sample published (not only changes)
          <prefix>/gen/<channel>       one value per message
          <prefix>/gen                 all channels in one JSON (Combined)
    - CSV replay: a PLC Data Logger file (Date,Time,Status,<tags>) played
      with the recorded timing (speed x0.1 .. x100) or one row per RateMs
          <prefix>/csv/<column>        Status + one topic per column
          <prefix>/csv                 the whole row in one JSON (Combined)
    - Control from any client:  <prefix>/control/gen/set  run | pause
          <prefix>/control/csv/set  play | pause | stop
          <prefix>/control/rate/set  ms      <prefix>/control/speed/set  factor
    - <prefix>/stats (retained, 1 s): rate, messages / s, CSV position
  Timing uses the performance counter and a 1 ms timer period, the next
  sample time is kept absolute (no drift).
  ============================================================================ }
unit ustreams;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, Math, DateUtils, StrUtils, mqttbroker, uwaves;

type
  TDoubleArray = array of Double;

  TPayloadFormat = (pfValue, pfJson);
  TCsvState = (csEmpty, csStopped, csPlaying, csPaused, csFinished);

  TCsvRow = record
    Time: TDateTime;                     // recorded time of the row
    Line: Integer;                       // index in the file lines
    Header: Integer;                     // index into the headers (columns of this row)
  end;

  TCsvInfo = record
    State: TCsvState;
    FileName: string;
    Row, Rows: Integer;
    RowTime: TDateTime;
    Columns: TStringArray;               // topics of the current header
    Values: TStringArray;                // last values published
  end;

  { TStreamEngine }

  TStreamEngine = class
  private
    FLock: TCriticalSection;
    FBroker: TMqttBroker;
    FPrefix: string;
    FThread: TThread;
    { settings (lock) }
    FRateMs: Integer;
    FFormat: TPayloadFormat;
    FQoS: Integer;
    FRetain, FCombined: Boolean;
    { generator (lock) }
    FChannels: TGenChannels;
    FWalk: array of Double;              // random walk state per channel
    FGenValues: array of Double;
    FGenRunning: Boolean;
    FGenT0: Double;                      // ms
    FNextGen: Double;
    FGenRestart: Boolean;
    { CSV (lock) }
    FCsvFile: string;
    FLines: TStringList;
    FHeaders: array of TStringArray;     // column topic names per header line
    FRows: array of TCsvRow;
    FCsvState: TCsvState;
    FCsvRow, FCsvStartRow: Integer;
    FCsvT0: Double;                      // ms when FCsvStartRow was due
    FCsvSpeed: Double;                   // 0 = one row per RateMs
    FCsvLoop: Boolean;
    FCsvValues: TStringArray;
    { statistics (lock) }
    FMsgs, FMsgsLast: Int64;
    FMsgRate: Double;
    FNextStats: Double;
    procedure Pub(const Topic, Payload: string);
    function GenValue(I: Integer; T: Double): Double;
    procedure GenSample(Now_: Double);
    procedure CsvPublishRow(R: Integer);
    procedure CsvStep(Now_: Double);
    procedure Stats(Now_: Double);
    function OnWrite(const Topic, Payload: string): Boolean;
  public
    constructor Create(ABroker: TMqttBroker; const APrefix: string);
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
    { generator }
    procedure SetChannels(const A: TGenChannels);
    procedure SetGenRunning(ARun: Boolean);
    function GenRunning: Boolean;
    function GenValues: TDoubleArray;
    { output settings }
    procedure SetOutput(ARateMs: Integer; AFormat: TPayloadFormat; AQoS: Integer;
      ARetain, ACombined: Boolean);
    function RateMs: Integer;
    { CSV replay }
    function LoadCsv(const FileName: string; out Err: string): Boolean;
    procedure CsvPlay;
    procedure CsvPause;
    procedure CsvStop;
    procedure SetCsvSpeed(ASpeed: Double; ALoop: Boolean);
    function CsvInfo: TCsvInfo;
    function MsgRate: Double;
    function Messages: Int64;
    property Prefix: string read FPrefix;
  end;

const
  CsvStateName: array[TCsvState] of string = ('no file', 'stopped', 'playing', 'paused',
    'finished');

{ "Voltage SP kV (DB10.DBD0)" -> "Voltage_SP_kV" }
function TopicName(const Header: string): string;
function MsNow: Double;

implementation

uses
  {$IFDEF WINDOWS} Windows, MMSystem; {$ELSE} BaseUnix; {$ENDIF}

const
  MIN_RATE = 5;                          // ms
  MAX_RATE = 60000;
  MAX_ROWS_PER_STEP = 2000;              // CSV rows published in one loop at most

var
  JsonFS: TFormatSettings;

type

  { TStreamThread }

  TStreamThread = class(TThread)
  private
    FEngine: TStreamEngine;
  protected
    procedure Execute; override;
  public
    constructor Create(AEngine: TStreamEngine);
  end;

{ ---------------------------------------------------------------------------- }

function MsNow: Double;
{$IFDEF WINDOWS}
var
  C, F: Int64;
begin
  QueryPerformanceCounter(C);
  QueryPerformanceFrequency(F);
  Result := Double(C) / Double(F) * 1000;
end;
{$ELSE}
begin
  Result := Double(GetTickCount64);
end;
{$ENDIF}

function TopicName(const Header: string): string;
var
  S: string;
  I: Integer;
begin
  S := Trim(Header);
  I := Pos(' (', S);
  if I > 1 then
    S := Trim(Copy(S, 1, I - 1));      // the address in brackets is not part of the name
  Result := '';
  for I := 1 to Length(S) do
    if S[I] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '-', '.'] then
      Result := Result + S[I]
    else if (Result <> '') and (Result[Length(Result)] <> '_') then
      Result := Result + '_';
  while (Result <> '') and (Result[Length(Result)] = '_') do
    SetLength(Result, Length(Result) - 1);
end;

function JsonStr(const S: string): string;
var
  I: Integer;
begin
  Result := '"';
  for I := 1 to Length(S) do
    case S[I] of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #0..#31: Result := Result + '\u' + IntToHex(Ord(S[I]), 4);
    else
      Result := Result + S[I];
    end;
  Result := Result + '"';
end;

{ a CSV cell as JSON: a number stays a number, everything else is a string }
function JsonCell(const S: string): string;
var
  X: Double;
begin
  if (S <> '') and TryStrToFloat(S, X, JsonFS) and not IsNan(X) and not IsInfinite(X) and
    (S[1] in ['-', '0'..'9']) then
    Result := S
  else if S = '' then
    Result := 'null'
  else
    Result := JsonStr(S);
end;

function FmtValue(X: Double; Decimals: Integer): string;
begin
  if IsNan(X) or IsInfinite(X) then
    Exit('null');
  Result := FloatToStrF(X, ffFixed, 15, EnsureRange(Decimals, 0, 9), JsonFS);
end;

function IsoUtc(T: TDateTime): string;
begin
  Result := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz"Z"', T);
end;

{ "2026-10-25" + "16:28:20.999" }
function ParseRowTime(const D, T: string; out Res: TDateTime): Boolean;
var
  Y, Mo, Dd, H, Mi, S, Ms: Integer;
  Sec: string;
begin
  Result := False;
  if (Length(D) <> 10) or (Length(T) < 8) then Exit;
  if not (TryStrToInt(Copy(D, 1, 4), Y) and TryStrToInt(Copy(D, 6, 2), Mo) and
    TryStrToInt(Copy(D, 9, 2), Dd) and TryStrToInt(Copy(T, 1, 2), H) and
    TryStrToInt(Copy(T, 4, 2), Mi) and TryStrToInt(Copy(T, 7, 2), S)) then Exit;
  Ms := 0;
  if (Length(T) > 9) and (T[9] = '.') then
  begin
    Sec := Copy(Copy(T, 10, 3) + '000', 1, 3);
    if not TryStrToInt(Sec, Ms) then Exit;
  end;
  Result := TryEncodeDateTime(Y, Mo, Dd, H, Mi, S, Ms, Res);
end;

{ TStreamThread }

constructor TStreamThread.Create(AEngine: TStreamEngine);
begin
  FEngine := AEngine;
  inherited Create(False);
end;

procedure TStreamThread.Execute;
var
  T: Double;
  Wait: Integer;
begin
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  {$IFDEF WINDOWS}
  timeBeginPeriod(1);                  // Sleep(1) = 1 ms instead of 15.6 ms
  {$ENDIF}
  try
    while not Terminated do
    begin
      T := MsNow;
      FEngine.GenSample(T);
      FEngine.CsvStep(T);
      FEngine.Stats(T);
      { sleep until the next sample, at most 10 ms (control changes, CSV rows) }
      FEngine.FLock.Enter;
      try
        if FEngine.FGenRunning then
          Wait := EnsureRange(Trunc(FEngine.FNextGen - MsNow), 0, 10)
        else
          Wait := 10;
      finally
        FEngine.FLock.Leave;
      end;
      if Wait > 0 then
        Sleep(Wait)
      else
        Sleep(0);
    end;
  finally
    {$IFDEF WINDOWS}
    timeEndPeriod(1);
    {$ENDIF}
  end;
end;

{ ---------------------------------------------------------------------------- }
{ TStreamEngine }

constructor TStreamEngine.Create(ABroker: TMqttBroker; const APrefix: string);
begin
  FLock := SyncObjs.TCriticalSection.Create;     // Windows has a record of the same name
  FBroker := ABroker;
  FPrefix := APrefix;
  FLines := TStringList.Create;
  FRateMs := 100;
  FCsvSpeed := 1;
  FBroker.OnWrite := @OnWrite;
end;

destructor TStreamEngine.Destroy;
begin
  Stop;
  if FBroker.OnWrite = @OnWrite then
    FBroker.OnWrite := nil;
  FLines.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TStreamEngine.Start;
begin
  FBroker.Publish(FPrefix + '/status', 'online', 0, True);
  FNextStats := MsNow + 1000;
  if FThread = nil then
    FThread := TStreamThread.Create(Self);
end;

procedure TStreamEngine.Stop;
begin
  if FThread = nil then Exit;
  FThread.Terminate;
  FThread.WaitFor;
  FreeAndNil(FThread);
end;

procedure TStreamEngine.Pub(const Topic, Payload: string);
begin
  FBroker.Publish(Topic, Payload, FQoS, FRetain);
  Inc(FMsgs);
end;

{ ---- generator ---- }

procedure TStreamEngine.SetChannels(const A: TGenChannels);
var
  I, Old: Integer;
begin
  FLock.Enter;
  try
    Old := Length(FWalk);
    FChannels := Copy(A);
    SetLength(FWalk, Length(A));
    SetLength(FGenValues, Length(A));
    for I := Old to High(FWalk) do
      FWalk[I] := A[I].Offset;
  finally
    FLock.Leave;
  end;
end;

procedure TStreamEngine.SetGenRunning(ARun: Boolean);
begin
  FLock.Enter;
  try
    if ARun and not FGenRunning then
      FGenRestart := True;                // the next loop sets the start time
    FGenRunning := ARun;
  finally
    FLock.Leave;
  end;
end;

function TStreamEngine.GenRunning: Boolean;
begin
  FLock.Enter;
  try
    Result := FGenRunning;
  finally
    FLock.Leave;
  end;
end;

function TStreamEngine.GenValues: TDoubleArray;
begin
  FLock.Enter;
  try
    Result := Copy(FGenValues);
  finally
    FLock.Leave;
  end;
end;

{ value of channel I at T s after the generator started (call with the lock held) }
function TStreamEngine.GenValue(I: Integer; T: Double): Double;
begin
  Result := WaveValue(FChannels[I], T, FWalk[I]);   // uwaves, shared with the InfluxDB generator
end;

procedure TStreamEngine.GenSample(Now_: Double);
var
  I, N: Integer;
  T: Double;
  Stamp, P, All: string;
begin
  FLock.Enter;
  try
    if not FGenRunning then Exit;
    if FGenRestart then
    begin
      FGenRestart := False;
      FGenT0 := Now_;
      FNextGen := Now_;
    end;
    if Now_ < FNextGen then Exit;
    T := (FNextGen - FGenT0) / 1000;              // sample time, exact multiple of the rate
    FNextGen := FNextGen + FRateMs;
    if FNextGen < Now_ - 1000 then                // more than 1 s behind: skip, don't burst
      FNextGen := Now_ + FRateMs;
    Stamp := IsoUtc(LocalTimeToUniversal(Now));
    All := '{"t": ' + JsonStr(Stamp);
    N := 0;
    for I := 0 to High(FChannels) do
    begin
      if not FChannels[I].Enabled or (FChannels[I].Name = '') then Continue;
      FGenValues[I] := GenValue(I, T);
      P := FmtValue(FGenValues[I], FChannels[I].Decimals);
      All := All + ', ' + JsonStr(FChannels[I].Name) + ': ' + P;
      Inc(N);
      if FFormat = pfJson then
        P := '{"t": ' + JsonStr(Stamp) + ', "v": ' + P + '}';
      Pub(FPrefix + '/gen/' + FChannels[I].Name, P);
    end;
    if FCombined and (N > 0) then
      Pub(FPrefix + '/gen', All + '}');
  finally
    FLock.Leave;
  end;
end;

{ ---- output settings ---- }

procedure TStreamEngine.SetOutput(ARateMs: Integer; AFormat: TPayloadFormat; AQoS: Integer;
  ARetain, ACombined: Boolean);
begin
  FLock.Enter;
  try
    FRateMs := EnsureRange(ARateMs, MIN_RATE, MAX_RATE);
    FFormat := AFormat;
    FQoS := EnsureRange(AQoS, 0, 2);
    FRetain := ARetain;
    FCombined := ACombined;
  finally
    FLock.Leave;
  end;
end;

function TStreamEngine.RateMs: Integer;
begin
  FLock.Enter;
  try
    Result := FRateMs;
  finally
    FLock.Leave;
  end;
end;

{ ---- CSV replay ---- }

function TStreamEngine.LoadCsv(const FileName: string; out Err: string): Boolean;
var
  L: TStringList;
  I, J, N, H: Integer;
  Cells, Names: TStringArray;
  Name: string;
  T, LastT: TDateTime;
  Rows: array of TCsvRow;
  Headers: array of TStringArray;
begin
  Err := '';
  L := TStringList.Create;
  try
    try
      L.LoadFromFile(FileName);
    except
      on E: Exception do
      begin
        Err := E.Message;
        Exit(False);
      end;
    end;
    Rows := nil;
    Headers := nil;
    H := -1;
    N := 0;
    LastT := 0;
    SetLength(Rows, L.Count);
    for I := 0 to L.Count - 1 do
    begin
      if Trim(L[I]) = '' then Continue;
      Cells := L[I].Split(',');
      if (Length(Cells) >= 2) and SameText(Cells[0], 'Date') and SameText(Cells[1], 'Time') then
      begin
        { header: Date,Time,Status,<tags>; the tags become topic names }
        SetLength(Names, Length(Cells) - 2);
        for J := 2 to High(Cells) do
        begin
          Name := TopicName(Cells[J]);
          if Name = '' then Name := 'Col' + IntToStr(J - 1);
          Names[J - 2] := Name;
        end;
        for J := 1 to High(Names) do                  // same name twice: _2, _3 ...
          if AnsiIndexStr(Names[J], Copy(Names, 0, J)) >= 0 then
            Names[J] := Names[J] + '_' + IntToStr(J + 1);
        SetLength(Headers, Length(Headers) + 1);
        Headers[High(Headers)] := Names;
        H := High(Headers);
        Continue;
      end;
      if (H < 0) or (Length(Cells) < 3) then Continue;   // data before any header
      if not ParseRowTime(Cells[0], Cells[1], T) then
      begin
        if N = 0 then Continue;
        T := LastT;                                       // keep the timing going
      end;
      Rows[N].Time := T;
      Rows[N].Line := I;
      Rows[N].Header := H;
      LastT := T;
      Inc(N);
    end;
    SetLength(Rows, N);
    if N = 0 then
    begin
      Err := 'no data rows (expected the PLC Data Logger format: Date,Time,Status,...)';
      Exit(False);
    end;
    FLock.Enter;
    try
      FLines.Assign(L);
      FRows := Rows;
      FHeaders := Headers;
      FCsvFile := FileName;
      FCsvState := csStopped;
      FCsvRow := 0;
      FCsvValues := nil;
    finally
      FLock.Leave;
    end;
    Result := True;
  finally
    L.Free;
  end;
end;

procedure TStreamEngine.CsvPlay;
begin
  FLock.Enter;
  try
    if FCsvState = csEmpty then Exit;
    if FCsvState in [csStopped, csFinished] then
      FCsvRow := 0;
    FCsvStartRow := FCsvRow;
    FCsvT0 := MsNow;
    FCsvState := csPlaying;
  finally
    FLock.Leave;
  end;
end;

procedure TStreamEngine.CsvPause;
begin
  FLock.Enter;
  try
    if FCsvState = csPlaying then
      FCsvState := csPaused;
  finally
    FLock.Leave;
  end;
end;

procedure TStreamEngine.CsvStop;
begin
  FLock.Enter;
  try
    if FCsvState <> csEmpty then
    begin
      FCsvState := csStopped;
      FCsvRow := 0;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TStreamEngine.SetCsvSpeed(ASpeed: Double; ALoop: Boolean);
begin
  FLock.Enter;
  try
    FCsvSpeed := Math.Max(ASpeed, Double(0));
    FCsvLoop := ALoop;
    if FCsvState = csPlaying then              // keep the position, new timing from here
    begin
      FCsvStartRow := FCsvRow;
      FCsvT0 := MsNow;
    end;
  finally
    FLock.Leave;
  end;
end;

{ one CSV row: Status + every column, and the whole row as JSON (lock held) }
procedure TStreamEngine.CsvPublishRow(R: Integer);
var
  Cells, Names: TStringArray;
  J: Integer;
  Stamp, V, All, P: string;
begin
  Cells := FLines[FRows[R].Line].Split(',');
  Names := FHeaders[FRows[R].Header];
  Stamp := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz', FRows[R].Time);   // recorded, local time
  SetLength(FCsvValues, Length(Names));
  All := '{"t": ' + JsonStr(Stamp);
  for J := 0 to High(Names) do
  begin
    if J + 2 <= High(Cells) then V := Cells[J + 2] else V := '';
    FCsvValues[J] := V;
    All := All + ', ' + JsonStr(Names[J]) + ': ' + JsonCell(V);
    if FFormat = pfJson then
      P := '{"t": ' + JsonStr(Stamp) + ', "v": ' + JsonCell(V) + '}'
    else
      P := V;
    Pub(FPrefix + '/csv/' + Names[J], P);
  end;
  if FCombined then
    Pub(FPrefix + '/csv', All + '}');
end;

procedure TStreamEngine.CsvStep(Now_: Double);
var
  N: Integer;
  Due: Double;
begin
  FLock.Enter;
  try
    if FCsvState <> csPlaying then Exit;
    N := 0;
    while (FCsvRow < Length(FRows)) and (N < MAX_ROWS_PER_STEP) do
    begin
      if FCsvSpeed > 0 then
        Due := FCsvT0 + Double(FRows[FCsvRow].Time - FRows[FCsvStartRow].Time) * 86400000 / FCsvSpeed
      else
        Due := FCsvT0 + Double(FCsvRow - FCsvStartRow) * FRateMs;
      if Due > Now_ then Break;
      CsvPublishRow(FCsvRow);
      Inc(FCsvRow);
      Inc(N);
    end;
    if FCsvRow >= Length(FRows) then
      if FCsvLoop then
      begin
        FCsvRow := 0;
        FCsvStartRow := 0;
        FCsvT0 := Now_ + FRateMs;              // a short gap between two loops
      end
      else
        FCsvState := csFinished;
  finally
    FLock.Leave;
  end;
end;

function TStreamEngine.CsvInfo: TCsvInfo;
begin
  FLock.Enter;
  try
    Result.State := FCsvState;
    Result.FileName := FCsvFile;
    Result.Row := FCsvRow;
    Result.Rows := Length(FRows);
    if (FCsvRow > 0) and (FCsvRow <= Length(FRows)) then
      Result.RowTime := FRows[FCsvRow - 1].Time
    else
      Result.RowTime := 0;
    if (FCsvRow > 0) and (FCsvRow <= Length(FRows)) then
      Result.Columns := Copy(FHeaders[FRows[FCsvRow - 1].Header])
    else if Length(FHeaders) > 0 then
      Result.Columns := Copy(FHeaders[0])
    else
      Result.Columns := nil;
    Result.Values := Copy(FCsvValues);
  finally
    FLock.Leave;
  end;
end;

{ ---- statistics and control ---- }

procedure TStreamEngine.Stats(Now_: Double);
var
  S: string;
begin
  FLock.Enter;
  try
    if Now_ < FNextStats then Exit;
    FMsgRate := (FMsgs - FMsgsLast) * 1000 / (Now_ - FNextStats + 1000);
    FMsgsLast := FMsgs;
    FNextStats := Now_ + 1000;
    S := Format('{"rate_ms": %d, "generator": %s, "csv": %s, "csv_row": %d, "csv_rows": %d, ' +
      '"messages_per_s": %s, "messages": %d}',
      [FRateMs, JsonStr(BoolToStr(FGenRunning, 'running', 'paused')),
       JsonStr(CsvStateName[FCsvState]), FCsvRow, Length(FRows),
       FloatToStrF(FMsgRate, ffFixed, 15, 1, JsonFS), FMsgs]);
  finally
    FLock.Leave;
  end;
  FBroker.Publish(FPrefix + '/stats', S, 0, True);
end;

function TStreamEngine.MsgRate: Double;
begin
  FLock.Enter;
  try
    Result := FMsgRate;
  finally
    FLock.Leave;
  end;
end;

function TStreamEngine.Messages: Int64;
begin
  FLock.Enter;
  try
    Result := FMsgs;
  finally
    FLock.Leave;
  end;
end;

function TStreamEngine.OnWrite(const Topic, Payload: string): Boolean;
var
  Cmd, S: string;
  X: Double;
begin
  Cmd := FPrefix + '/control/';
  if not Topic.StartsWith(Cmd) or not Topic.EndsWith('/set') then
    Exit(False);
  Result := True;
  Cmd := Copy(Topic, Length(Cmd) + 1, Length(Topic) - Length(Cmd) - 4);
  S := LowerCase(Trim(Payload));
  if Cmd = 'gen' then
  begin
    if (S = 'run') or (S = '1') or (S = 'on') or (S = 'true') then
      SetGenRunning(True)
    else if (S = 'pause') or (S = '0') or (S = 'off') or (S = 'false') then
      SetGenRunning(False)
    else
    begin
      FBroker.Log('control refused: ' + Topic + ' = ' + Payload + ' (run | pause)');
      Exit;
    end;
  end
  else if Cmd = 'csv' then
  begin
    if S = 'play' then CsvPlay
    else if S = 'pause' then CsvPause
    else if S = 'stop' then CsvStop
    else
    begin
      FBroker.Log('control refused: ' + Topic + ' = ' + Payload + ' (play | pause | stop)');
      Exit;
    end;
  end
  else if (Cmd = 'rate') and TryStrToFloat(S, X, JsonFS) and (X >= MIN_RATE) and (X <= MAX_RATE) then
  begin
    FLock.Enter;
    try
      FRateMs := Round(X);
    finally
      FLock.Leave;
    end;
  end
  else if (Cmd = 'speed') and TryStrToFloat(S, X, JsonFS) and (X >= 0) and (X <= 1000) then
    SetCsvSpeed(X, FCsvLoop)
  else
  begin
    FBroker.Log(Format('control refused: %s = %s (rate %d..%d ms, speed 0..1000)',
      [Topic, Payload, MIN_RATE, MAX_RATE]));
    Exit;
  end;
  FBroker.Log('control ' + Cmd + ' = ' + Trim(Payload));
end;

initialization
  JsonFS := DefaultFormatSettings;
  JsonFS.DecimalSeparator := '.';
  JsonFS.ThousandSeparator := #0;
end.

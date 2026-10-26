{ ============================================================================
  usiggen - the engine of the InfluxDB Signal Generator (one thread)
    - live: one sample every RateMs, time stamps on the wall clock, aligned to
      the rate (rate 1000 ms -> every full second)
    - backfill: the same signals for a past time range (for Grafana tests),
      made in chunks while the queue is short, so memory stays small
    - the wave time is the Unix time in s, so backfill and live join without a
      jump; RandomWalk keeps its own state
    - layout: all channels as fields of one point, or one point per channel
      with the tag channel=<name> and the field value
    - send: batches of at most 5000 lines (POST /write, precision ms) every
      SendMs (at once while backfilling); not reachable -> retry every 2 s;
      "database not found" -> CREATE DATABASE once
  ============================================================================ }
unit usiggen;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, Math, uwaves, uinfluxapi;

type
  TGenLayout = (glFields, glChannelTag);
  TDoubles = array of Double;

  TGenSettings = record
    Conn: TInfluxConn;
    Database, Measurement, Tags: string;   // Tags: site=lab, line=2
    Layout: TGenLayout;
    RateMs, SendMs: Integer;
  end;

  TGenStats = record
    Live: Boolean;
    Sent, Errors, Generated: Int64;        // lines (points)
    Queue: Integer;
    LastError: string;
    Backfill: Boolean;
    BackfillDone: Double;                  // 0..1
    LastOkMs: Double;                      // duration of the last write
  end;

  { TSignalGen }

  TSignalGen = class(TThread)
  private
    FLock: TCriticalSection;
    FWake: TEvent;
    FSet: TGenSettings;
    FCh: TGenChannels;
    FNoise, FWalk, FValues: array of Double;
    FLive: Boolean;
    FNext, FNextSend, FRetryAt: Double;
    FLastTs: Int64;
    FBfActive: Boolean;
    FBfFrom, FBfTo, FBfStep, FBfCur: Int64;
    FQueue: TStringList;
    FStats: TGenStats;
    FCreated: Boolean;
    FTagText: string;
    procedure Sample(Ts: Int64);
  protected
    procedure Execute; override;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Configure(const S: TGenSettings);
    procedure SetChannels(const A: TGenChannels; const Noise: array of Double);
    procedure SetLive(ALive: Boolean);
    { past range in ms since 1970 UTC }
    procedure StartBackfill(FromMs, ToMs, StepMs: Int64);
    procedure CancelBackfill;
    function Stats: TGenStats;
    function Values: TDoubles;
  end;

{ ms since 1970 UTC from the system clock }
function WallMs: Int64;
function MsNow: Double;
{ one line of line protocol: escapes for names / tag values }
function LpEscape(const S: string; Equals: Boolean): string;
function LpTags(const Tags: string): string;

implementation

uses
  {$IFDEF WINDOWS} Windows {$ELSE} BaseUnix {$ENDIF};

const
  MAX_BATCH = 5000;
  MAX_QUEUE = 200000;
  BACKFILL_QUEUE = 20000;      // backfill makes more lines only below this
  RETRY_MS = 2000;

var
  FS: TFormatSettings;

function WallMs: Int64;
{$IFDEF WINDOWS}
var
  FT: TFileTime;
begin
  GetSystemTimeAsFileTime(FT);
  Result := (((Int64(FT.dwHighDateTime) shl 32) or FT.dwLowDateTime) - 116444736000000000) div 10000;
end;
{$ELSE}
begin
  Result := Round((Now - UnixDateDelta) * Double(86400000));
end;
{$ENDIF}

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

function LpEscape(const S: string; Equals: Boolean): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    if (S[I] in [',', ' ', '\']) or (Equals and (S[I] = '=')) then Result := Result + '\';
    Result := Result + S[I];
  end;
end;

function LpTags(const Tags: string): string;
var
  P: string;
  I: Integer;
begin
  Result := '';
  for P in Tags.Split([',']) do
  begin
    I := Pos('=', P);
    if (I <= 1) or (Trim(Copy(P, I + 1, MaxInt)) = '') then Continue;
    Result := Result + ',' + LpEscape(Trim(Copy(P, 1, I - 1)), True) + '=' +
      LpEscape(Trim(Copy(P, I + 1, MaxInt)), True);
  end;
end;

{ TSignalGen }

constructor TSignalGen.Create;
begin
  FLock := SyncObjs.TCriticalSection.Create;     // Windows has a record of the same name
  FWake := TEvent.Create(nil, False, False, '');
  FQueue := TStringList.Create;
  FSet.RateMs := 1000;
  FSet.SendMs := 1000;
  inherited Create(False);
end;

destructor TSignalGen.Destroy;
begin
  Terminate;
  FWake.SetEvent;
  WaitFor;
  FQueue.Free;
  FWake.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TSignalGen.Configure(const S: TGenSettings);
begin
  FLock.Enter;
  try
    if (S.Database <> FSet.Database) or (S.Conn.Url <> FSet.Conn.Url) then FCreated := False;
    FSet := S;
    FSet.RateMs := EnsureRange(S.RateMs, 10, 3600000);
    FSet.SendMs := EnsureRange(S.SendMs, 100, 60000);
    if FSet.Measurement = '' then FSet.Measurement := 'signals';
    FTagText := LpTags(S.Tags);
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

procedure TSignalGen.SetChannels(const A: TGenChannels; const Noise: array of Double);
var
  I, Old: Integer;
begin
  FLock.Enter;
  try
    Old := Length(FWalk);
    FCh := Copy(A);
    SetLength(FNoise, Length(A));
    for I := 0 to High(A) do
      if I <= High(Noise) then FNoise[I] := Abs(Noise[I]) else FNoise[I] := 0;
    SetLength(FWalk, Length(A));
    SetLength(FValues, Length(A));
    for I := Old to High(FWalk) do FWalk[I] := A[I].Offset;
  finally
    FLock.Leave;
  end;
end;

procedure TSignalGen.SetLive(ALive: Boolean);
begin
  FLock.Enter;
  try
    if ALive and not FLive then FNext := MsNow;
    FLive := ALive;
    FStats.Live := ALive;
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

procedure TSignalGen.StartBackfill(FromMs, ToMs, StepMs: Int64);
begin
  FLock.Enter;
  try
    FBfStep := Max(StepMs, 1);
    FBfFrom := FromMs - FromMs mod FBfStep;           // aligned, as the live samples
    FBfTo := ToMs;
    FBfCur := FBfFrom;
    FBfActive := FBfTo > FBfFrom;
    FStats.Backfill := FBfActive;
    FStats.BackfillDone := 0;
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

procedure TSignalGen.CancelBackfill;
begin
  FLock.Enter;
  try
    FBfActive := False;
    FStats.Backfill := False;
  finally
    FLock.Leave;
  end;
end;

function TSignalGen.Stats: TGenStats;
begin
  FLock.Enter;
  try
    Result := FStats;
    Result.Queue := FQueue.Count;
  finally
    FLock.Leave;
  end;
end;

function TSignalGen.Values: TDoubles;
begin
  FLock.Enter;
  try
    Result := Copy(FValues);
  finally
    FLock.Leave;
  end;
end;

{ the lines of one sample at Ts (ms UTC), lock held }
procedure TSignalGen.Sample(Ts: Int64);
var
  I: Integer;
  V: Double;
  Fields, Num, Head: string;
  T: Double;
begin
  T := Ts / Double(1000);
  Head := LpEscape(FSet.Measurement, False);
  Fields := '';
  for I := 0 to High(FCh) do
  begin
    if not FCh[I].Enabled or (FCh[I].Name = '') then Continue;
    V := WaveValue(FCh[I], T, FWalk[I]);
    if FNoise[I] > 0 then V := V + FNoise[I] * (2 * Random - 1);
    FValues[I] := V;
    Num := FloatToStrF(V, ffFixed, 15, EnsureRange(FCh[I].Decimals, 0, 9), FS);
    if FSet.Layout = glChannelTag then
      FQueue.Add(Head + ',channel=' + LpEscape(FCh[I].Name, True) + FTagText + ' value=' + Num +
        ' ' + IntToStr(Ts))
    else
    begin
      if Fields <> '' then Fields := Fields + ',';
      Fields := Fields + LpEscape(FCh[I].Name, True) + '=' + Num;
    end;
    Inc(FStats.Generated);
  end;
  if (FSet.Layout = glFields) and (Fields <> '') then
    FQueue.Add(Head + FTagText + ' ' + Fields + ' ' + IntToStr(Ts));
  while FQueue.Count > MAX_QUEUE do FQueue.Delete(0);   // the database is away for long
end;

procedure TSignalGen.Execute;
var
  T: Double;
  Ts: Int64;
  N, I, Made: Integer;
  Body: string;
  S: TGenSettings;
  R: TInfluxResult;
  Send, Ok: Boolean;
  Wait: Integer;
begin
  while not Terminated do
  begin
    Body := '';
    N := 0;
    FLock.Enter;
    try
      T := MsNow;
      { live sample }
      if FLive and (T >= FNext) then
      begin
        Ts := WallMs;
        Ts := Ts - Ts mod FSet.RateMs;                 // aligned to the rate
        if Ts > FLastTs then
        begin
          Sample(Ts);
          FLastTs := Ts;
        end;
        FNext := FNext + FSet.RateMs;
        if FNext < T - 1000 then FNext := T + FSet.RateMs;
      end;
      { backfill chunk }
      if FBfActive and (FQueue.Count < BACKFILL_QUEUE) then
      begin
        Made := 0;
        while (FBfCur <= FBfTo) and (Made < MAX_BATCH) do
        begin
          Sample(FBfCur);
          Inc(FBfCur, FBfStep);
          Inc(Made);
        end;
        FStats.BackfillDone := (FBfCur - FBfFrom) / Math.Max(Double(FBfTo - FBfFrom), Double(1));
        if FBfCur > FBfTo then
        begin
          FBfActive := False;
          FStats.Backfill := False;
          FStats.BackfillDone := 1;
        end;
      end;
      { send? }
      Send := (FQueue.Count > 0) and (T >= FRetryAt) and
        ((T >= FNextSend) or (FQueue.Count >= MAX_BATCH) or FBfActive);
      if Send then
      begin
        N := Min(FQueue.Count, MAX_BATCH);
        for I := 0 to N - 1 do Body := Body + FQueue[I] + #10;
        S := FSet;
        FNextSend := T + FSet.SendMs;
      end;
    finally
      FLock.Leave;
    end;

    if N > 0 then
    begin
      R := InfluxWrite(S.Conn, S.Database, Body, 'ms');
      if (R.Code = 404) and (Pos('database not found', R.Body) > 0) and not FCreated then
      begin
        FCreated := True;                              // InfluxDB 1.x: create it, then again
        InfluxQuery(S.Conn, '', 'CREATE DATABASE ' + QuoteIdent(S.Database));
        R := InfluxWrite(S.Conn, S.Database, Body, 'ms');
      end;
      Ok := R.Ok or (R.Code = 400);                    // 400 = partial write: do not resend
      FLock.Enter;
      try
        if Ok then
        begin
          for I := 1 to Min(N, FQueue.Count) do FQueue.Delete(0);
          Inc(FStats.Sent, N);
          FStats.LastOkMs := R.Ms;
          FRetryAt := 0;
        end
        else
        begin
          Inc(FStats.Errors);
          FRetryAt := MsNow + RETRY_MS;
        end;
        FStats.LastError := R.Error;
      finally
        FLock.Leave;
      end;
      Continue;                                        // more to send / make: no wait
    end;

    { wait for the next sample (or a setting change) }
    FLock.Enter;
    try
      if FBfActive and (FQueue.Count < BACKFILL_QUEUE) then
        Wait := 0                                      // make the next chunk at once
      else if FLive then
        Wait := EnsureRange(Trunc(FNext - MsNow), 0, 50)
      else
        Wait := 50;                                    // also while a retry is pending
    finally
      FLock.Leave;
    end;
    if Wait > 0 then FWake.WaitFor(Wait);
  end;
end;

initialization
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  FS.ThousandSeparator := #0;
end.

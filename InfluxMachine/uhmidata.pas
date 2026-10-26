{ ============================================================================
  uhmidata - everything the HMI reads from and writes to InfluxDB, in its own
  thread (the 30 fps drawing never waits for the network)
    every 500 ms  SELECT last(*) ... ; SELECT last(speed) ...   live values + their time
    every 5 s     mean(temp / tank_level / speed / power) GROUP BY time(10s), last 10 min
    every 2 s     the last 8 events
    at once       the queued commands (POST /write, measurement command)
  ============================================================================ }
unit uhmidata;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, Math, fpjson, jsonparser, uinfluxapi, umachinedef;

const
  TREND_SERIES = 4;             // temp, level, speed, power
  TREND_MINUTES = 10;

type
  TTrend = record
    Times: array of Int64;      // ms UTC
    Vals: array[0..TREND_SERIES - 1] of array of Double;   // NaN = no value
  end;

  THmiSnapshot = record
    Connected: Boolean;
    Error: string;
    Live: TMachineData;
    LiveAgeMs: Int64;           // how old the last machine point is
    QueryMs: Double;
    Trend: TTrend;
    Events: TMachineEvents;
    CommandsSent: Integer;
  end;

  { THmiData }

  THmiData = class(TThread)
  private
    FLock: TCriticalSection;
    FWake: TEvent;
    FConn: TInfluxConn;
    FDb: string;
    FSnap: THmiSnapshot;
    FOut: TStringList;          // command lines to send
    procedure ReadLive;
    procedure ReadTrend;
    procedure ReadEvents;
    procedure SendCommands;
  protected
    procedure Execute; override;
  public
    constructor Create(const AConn: TInfluxConn; const ADb: string);
    destructor Destroy; override;
    function Snapshot: THmiSnapshot;
    { cmd = start / stop / reset / clear, or a setpoint field with a number }
    procedure Command(const Field, Value: string; IsText: Boolean);
  end;

implementation

function Results(const Json: string; out J: TJSONData): TJSONArray;
begin
  Result := nil;
  J := nil;
  try
    J := GetJSON(Json);
  except
    Exit;
  end;
  if J is TJSONObject then
    Result := TJSONObject(J).Find('results', jtArray) as TJSONArray;
end;

{ series k of statement i, or nil }
function SeriesOf(R: TJSONArray; I: Integer): TJSONObject;
var
  S: TJSONArray;
begin
  Result := nil;
  if (R = nil) or (I >= R.Count) or not (R.Items[I] is TJSONObject) then Exit;
  S := TJSONObject(R.Items[I]).Find('series', jtArray) as TJSONArray;
  if (S <> nil) and (S.Count > 0) then Result := S.Objects[0];
end;

{ THmiData }

constructor THmiData.Create(const AConn: TInfluxConn; const ADb: string);
begin
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FOut := TStringList.Create;
  FConn := AConn;
  FConn.TimeoutMs := 5000;
  FDb := ADb;
  inherited Create(False);
end;

destructor THmiData.Destroy;
begin
  Terminate;
  FWake.SetEvent;
  WaitFor;
  FOut.Free;
  FWake.Free;
  FLock.Free;
  inherited Destroy;
end;

function THmiData.Snapshot: THmiSnapshot;
var
  K: Integer;
begin
  FLock.Enter;
  try
    Result := FSnap;
    Result.Trend.Times := Copy(FSnap.Trend.Times);
    for K := 0 to TREND_SERIES - 1 do
      Result.Trend.Vals[K] := Copy(FSnap.Trend.Vals[K]);
    Result.Events := Copy(FSnap.Events);
  finally
    FLock.Leave;
  end;
end;

procedure THmiData.Command(const Field, Value: string; IsText: Boolean);
begin
  FLock.Enter;
  try
    FOut.Add(CommandLine(Field, Value, IsText, UtcMs + FOut.Count));   // + n: one point each
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

procedure THmiData.SendCommands;
var
  Body: string;
  N: Integer;
  R: TInfluxResult;
begin
  FLock.Enter;
  try
    N := FOut.Count;
    Body := FOut.Text;
  finally
    FLock.Leave;
  end;
  if N = 0 then Exit;
  R := InfluxWrite(FConn, FDb, Body, 'ms');
  FLock.Enter;
  try
    if R.Ok then
    begin
      while (N > 0) and (FOut.Count > 0) do
      begin
        FOut.Delete(0);
        Dec(N);
      end;
      Inc(FSnap.CommandsSent);
    end
    else
      FSnap.Error := 'command not sent: ' + R.Error;
  finally
    FLock.Leave;
  end;
end;

procedure THmiData.ReadLive;
var
  R: TInfluxResult;
  D: TMachineData;
  J: TJSONData;
  Res, Vals: TJSONArray;
  S: TJSONObject;
  T: Int64;
begin
  R := InfluxQuery(FConn, FDb, Format('SELECT last(*) FROM %s WHERE time > now() - 1m; ' +
    'SELECT last(speed) FROM %s WHERE time > now() - 1m', [MEAS_MACHINE, MEAS_MACHINE]), 'ms');
  T := 0;
  if R.Code > 0 then
  begin
    Res := Results(R.Body, J);
    try
      S := SeriesOf(Res, 1);
      if S <> nil then
      begin
        Vals := S.Find('values', jtArray) as TJSONArray;
        if (Vals <> nil) and (Vals.Count > 0) then T := Vals.Arrays[0].Items[0].AsInt64;
      end;
    finally
      J.Free;
    end;
  end;
  FLock.Enter;
  try
    FSnap.Connected := R.Code in [200, 204];
    FSnap.QueryMs := R.Ms;
    if R.Code = 0 then FSnap.Error := R.Error
    else if Copy(FSnap.Error, 1, 7) <> 'command' then FSnap.Error := '';
    if ParseLast(R.Body, D) then
    begin
      D.TimeMs := T;
      FSnap.Live := D;
      FSnap.LiveAgeMs := UtcMs - T;
    end
    else
    begin
      FSnap.Live.Valid := False;                 // no machine data in the last minute
      FSnap.LiveAgeMs := -1;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure THmiData.ReadTrend;
var
  R: TInfluxResult;
  J: TJSONData;
  Res, Vals, Row: TJSONArray;
  S: TJSONObject;
  Tr: TTrend;
  I, K: Integer;
begin
  R := InfluxQuery(FConn, FDb, Format('SELECT mean(temp), mean(tank_level), mean(speed), mean(power) ' +
    'FROM %s WHERE time > now() - %dm GROUP BY time(10s) fill(none)', [MEAS_MACHINE, TREND_MINUTES]), 'ms');
  if not R.Ok then Exit;
  Tr := Default(TTrend);
  Res := Results(R.Body, J);
  try
    S := SeriesOf(Res, 0);
    if S <> nil then
    begin
      Vals := S.Find('values', jtArray) as TJSONArray;
      if Vals <> nil then
      begin
        SetLength(Tr.Times, Vals.Count);
        for K := 0 to TREND_SERIES - 1 do SetLength(Tr.Vals[K], Vals.Count);
        for I := 0 to Vals.Count - 1 do
        begin
          Row := Vals.Arrays[I];
          Tr.Times[I] := Row.Items[0].AsInt64;
          for K := 0 to TREND_SERIES - 1 do
            if (K + 1 < Row.Count) and (Row.Items[K + 1].JSONType = jtNumber) then
              Tr.Vals[K][I] := Row.Items[K + 1].AsFloat
            else
              Tr.Vals[K][I] := NaN;
        end;
      end;
    end;
  finally
    J.Free;
  end;
  FLock.Enter;
  try
    FSnap.Trend := Tr;
  finally
    FLock.Leave;
  end;
end;

procedure THmiData.ReadEvents;
var
  R: TInfluxResult;
  J: TJSONData;
  Res, Cols, Vals, Row: TJSONArray;
  S: TJSONObject;
  E: TMachineEvents;
  I, C, CL, CT: Integer;
begin
  R := InfluxQuery(FConn, FDb, Format('SELECT * FROM %s ORDER BY time DESC LIMIT 8', [MEAS_EVENTS]), 'ms');
  if not R.Ok then Exit;
  E := nil;
  Res := Results(R.Body, J);
  try
    S := SeriesOf(Res, 0);
    if S <> nil then
    begin
      Cols := S.Find('columns', jtArray) as TJSONArray;
      Vals := S.Find('values', jtArray) as TJSONArray;
      CL := -1;
      CT := -1;
      if Cols <> nil then
        for C := 0 to Cols.Count - 1 do
          if Cols.Strings[C] = 'level' then CL := C
          else if Cols.Strings[C] = 'text' then CT := C;
      if (Vals <> nil) and (CT >= 0) then
      begin
        SetLength(E, Vals.Count);
        for I := 0 to Vals.Count - 1 do
        begin
          Row := Vals.Arrays[I];
          E[I].TimeMs := Row.Items[0].AsInt64;
          E[I].Text := JsonCellText(Row.Items[CT]);
          if CL >= 0 then E[I].Level := JsonCellText(Row.Items[CL]);
        end;
      end;
    end;
  finally
    J.Free;
  end;
  FLock.Enter;
  try
    FSnap.Events := E;
  finally
    FLock.Leave;
  end;
end;

procedure THmiData.Execute;
var
  NextLive, NextTrend, NextEvents, T: QWord;
begin
  NextLive := 0;
  NextTrend := 0;
  NextEvents := 0;
  while not Terminated do
  begin
    SendCommands;
    T := GetTickCount64;
    if T >= NextLive then
    begin
      ReadLive;
      NextLive := T + 500;
    end;
    if T >= NextEvents then
    begin
      ReadEvents;
      NextEvents := T + 2000;
    end;
    if T >= NextTrend then
    begin
      ReadTrend;
      NextTrend := T + 5000;
    end;
    FWake.WaitFor(100);                          // a command wakes it at once
  end;
end;

end.

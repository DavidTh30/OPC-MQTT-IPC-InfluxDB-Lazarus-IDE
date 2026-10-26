{ ============================================================================
  umachinesim - a bottle filling machine and its InfluxDB link
    TFillingMachine (the process, one Step per 100 ms):
      - state STOPPED -> start -> STARTING (speed ramps up) -> RUNNING
        -> stop -> STOPPING (ramps down) -> STOPPED; FAULT on tank empty
        (< 5 %) or overtemperature (> setpoint + 15 C), reset when it is gone
      - bottles at the conveyor speed; each gets fill_sp +- 0.8 % (more when
        the product is too cold); off by more than 2 % = reject
      - tank 500 L: the filling empties it, the inlet valve opens below 25 %
        and closes above 85 % (2 L/s)
      - heater with a thermostat (+-0.5 C), heat loss to 20 C
      - power: drive, heater, inlet pump
    TMachineRunner (thread): every 500 ms the machine point (and the events)
      to InfluxDB, and the commands newer than the last one it saw:
      cmd = start | stop | reset | clear,  speed_sp / fill_sp / temp_sp = value
  ============================================================================ }
unit umachinesim;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, Math, fpjson, jsonparser, uinfluxapi, umachinedef;

type
  TMachineState = (msStopped, msStarting, msRunning, msStopping, msFault);

  { TFillingMachine }

  TFillingMachine = class
  private
    FBottle: Double;                  // part of the next bottle (0..1)
    procedure Event(const Level, Text: string);
    procedure SetState(S: TMachineState);
  public
    State: TMachineState;
    D: TMachineData;                  // what goes to InfluxDB
    Events: TStringList;              // "level<TAB>text", taken by the runner
    constructor Create;
    destructor Destroy; override;
    procedure Step(Dt: Double);
    { one command from the HMI; Source for the event text }
    procedure Command(const Field, Value: string);
  end;

  { TMachineRunner }

  TMachineRunner = class(TThread)
  private
    FLock: TCriticalSection;
    FMachine: TFillingMachine;
    FConn: TInfluxConn;
    FDb: string;
    FLastCmdMs: Int64;
    FCreated: Boolean;
    FLog: TStringList;
    FWrites, FErrors, FCommands: Int64;
    FLastError: string;
    procedure PollCommands;
  protected
    procedure Execute; override;
  public
    constructor Create(const AConn: TInfluxConn; const ADb: string);
    destructor Destroy; override;
    procedure Snapshot(out D: TMachineData; out Writes, Errors, Commands: Int64; out Err: string);
    procedure TakeLog(Dest: TStrings);
    { a command typed in the simulator window (as if it came from the HMI) }
    procedure LocalCommand(const Field, Value: string);
  end;

const
  StateName: array[TMachineState] of string = ('STOPPED', 'STARTING', 'RUNNING', 'STOPPING', 'FAULT');

implementation

const
  TANK_L = 500.0;               // litres
  INFLOW_LPS = 2.0;
  RAMP_BPM_S = 40.0;            // speed change per s
  AMBIENT = 20.0;

function Gauss: Double;         // Box-Muller, mean 0, sd 1
begin
  Result := Sqrt(-2 * Ln(Max(Random, 1e-12))) * Cos(2 * Pi * Random);
end;

{ TFillingMachine }

constructor TFillingMachine.Create;
begin
  Events := TStringList.Create;
  D.SpeedSp := 80;
  D.FillSp := 500;
  D.TempSp := 45;
  D.Temp := 38;
  D.Level := 60;
  D.FillLast := 0;
  SetState(msStopped);
end;

destructor TFillingMachine.Destroy;
begin
  Events.Free;
  inherited Destroy;
end;

procedure TFillingMachine.Event(const Level, Text: string);
begin
  Events.Add(Level + #9 + Text);
end;

procedure TFillingMachine.SetState(S: TMachineState);
var
  First: Boolean;
begin
  First := D.State = '';                       // the constructor: no event
  if (S = State) and not First then Exit;
  State := S;
  D.State := StateName[S];
  D.Running := S in [msStarting, msRunning];
  if First then Exit;
  case S of
    msStarting: Event('info', 'start');
    msRunning: Event('info', Format('running at %s bottles/min', [FloatTxt(D.SpeedSp, 0)]));
    msStopping: Event('info', 'stop');
    msStopped: Event('info', 'stopped');
  end;
end;

procedure TFillingMachine.Step(Dt: Double);
var
  Target, Ml, Dev: Double;
begin
  { ---- faults ---- }
  if State <> msFault then
  begin
    if D.Level < 5 then
    begin
      D.Fault := 'tank empty';
      SetState(msFault);
      Event('alarm', 'FAULT: tank empty (level ' + FloatTxt(D.Level, 1) + ' %)');
    end
    else if D.Temp > D.TempSp + 15 then
    begin
      D.Fault := 'overtemperature';
      SetState(msFault);
      Event('alarm', 'FAULT: overtemperature (' + FloatTxt(D.Temp, 1) + ' C)');
    end;
  end;
  { ---- conveyor speed ---- }
  if State in [msStarting, msRunning] then Target := D.SpeedSp else Target := 0;
  if State = msFault then Target := 0;
  if D.Speed < Target then D.Speed := Min(Target, D.Speed + RAMP_BPM_S * Dt)
  else D.Speed := Max(Target, D.Speed - RAMP_BPM_S * Dt * IfThen(State = msFault, 3, 1));
  if (State = msStarting) and (D.Speed >= D.SpeedSp - 0.01) then SetState(msRunning);
  if (State = msStopping) and (D.Speed <= 0) then SetState(msStopped);
  { ---- bottles ---- }
  FBottle := FBottle + D.Speed / 60 * Dt;
  while FBottle >= 1 do
  begin
    FBottle := FBottle - 1;
    Ml := D.FillSp * (1 + 0.008 * Gauss);
    if D.Temp < D.TempSp - 5 then                    // too cold: thick, less exact
      Ml := Ml * (1 - 0.02 * Abs(Gauss));
    D.FillLast := Ml;
    Dev := Abs(Ml - D.FillSp) / D.FillSp;
    if Dev > 0.02 then Inc(D.Reject) else Inc(D.Good);
    D.Level := Max(0, D.Level - Ml / 1000 / TANK_L * 100);
  end;
  { ---- tank inlet (hysteresis 25 .. 85 %) ---- }
  if D.Level < 25 then D.Inlet := True
  else if D.Level > 85 then D.Inlet := False;
  if D.Inlet then D.Level := Min(100, D.Level + INFLOW_LPS * Dt / TANK_L * 100);
  { ---- heater (thermostat) ---- }
  if D.Temp < D.TempSp - 0.5 then D.Heater := True
  else if D.Temp > D.TempSp + 0.5 then D.Heater := False;
  D.Temp := D.Temp + (IfThen(D.Heater, 0.15, 0) - (D.Temp - AMBIENT) / 600) * Dt
    + 0.01 * Gauss * Sqrt(Dt);
  { ---- power (kW) ---- }
  D.Power := 0.4 + 0.035 * D.Speed + IfThen(D.Heater, 6.0, 0) + IfThen(D.Inlet, 1.1, 0);
end;

procedure TFillingMachine.Command(const Field, Value: string);
var
  X: Double;
begin
  if Field = 'cmd' then
    case LowerCase(Value) of
      'start':
        if State in [msStopped, msStopping] then SetState(msStarting)
        else if State = msFault then Event('warn', 'start refused: FAULT, reset first');
      'stop':
        if State in [msStarting, msRunning] then SetState(msStopping);
      'reset':
        if State = msFault then
        begin
          if (D.Level >= 15) and (D.Temp <= D.TempSp + 10) then
          begin
            Event('info', 'fault reset (' + D.Fault + ')');
            D.Fault := '';
            SetState(msStopped);
          end
          else
            Event('warn', 'reset refused: ' + D.Fault + ' still there');
        end;
      'clear':
        begin
          D.Good := 0;
          D.Reject := 0;
          Event('info', 'counters cleared');
        end;
    else
      Event('warn', 'unknown command ' + Value);
    end
  else if TryStrToFloat(Value, X, DotFS) then
    case Field of
      'speed_sp':
        begin
          X := EnsureRange(X, 0, SPEED_MAX);
          Event('info', Format('speed setpoint %s -> %s bottles/min', [FloatTxt(D.SpeedSp, 0), FloatTxt(X, 0)]));
          D.SpeedSp := X;
        end;
      'fill_sp':
        begin
          X := EnsureRange(X, FILL_MIN, FILL_MAX);
          Event('info', Format('fill setpoint %s -> %s ml', [FloatTxt(D.FillSp, 0), FloatTxt(X, 0)]));
          D.FillSp := X;
        end;
      'temp_sp':
        begin
          X := EnsureRange(X, TEMP_MIN, TEMP_MAX);
          Event('info', Format('temperature setpoint %s -> %s C', [FloatTxt(D.TempSp, 1), FloatTxt(X, 1)]));
          D.TempSp := X;
        end;
    end;
end;

{ TMachineRunner }

constructor TMachineRunner.Create(const AConn: TInfluxConn; const ADb: string);
begin
  FLock := TCriticalSection.Create;
  FLog := TStringList.Create;
  FMachine := TFillingMachine.Create;
  FConn := AConn;
  FConn.TimeoutMs := 5000;
  FDb := ADb;
  FLastCmdMs := UtcMs;                          // older commands are not for us
  inherited Create(False);
end;

destructor TMachineRunner.Destroy;
begin
  Terminate;
  WaitFor;
  FMachine.Free;
  FLog.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TMachineRunner.TakeLog(Dest: TStrings);
begin
  FLock.Enter;
  try
    Dest.AddStrings(FLog);
    FLog.Clear;
  finally
    FLock.Leave;
  end;
end;

procedure TMachineRunner.Snapshot(out D: TMachineData; out Writes, Errors, Commands: Int64;
  out Err: string);
begin
  FLock.Enter;
  try
    D := FMachine.D;
    Writes := FWrites;
    Errors := FErrors;
    Commands := FCommands;
    Err := FLastError;
  finally
    FLock.Leave;
  end;
end;

procedure TMachineRunner.LocalCommand(const Field, Value: string);
begin
  FLock.Enter;
  try
    FMachine.Command(Field, Value);
  finally
    FLock.Leave;
  end;
end;

{ the commands written since the last poll, in time order }
procedure TMachineRunner.PollCommands;
var
  R: TInfluxResult;
  J: TJSONData;
  Res, Series, Cols, Vals, Row: TJSONArray;
  I, C: Integer;
  T: Int64;
begin
  R := InfluxQuery(FConn, FDb, Format('SELECT * FROM %s WHERE time > %dms ORDER BY time ASC',
    [MEAS_COMMAND, FLastCmdMs]), 'ms');
  if not R.Ok then Exit;                       // no command measurement yet is no error
  try
    J := GetJSON(R.Body);
  except
    Exit;
  end;
  try
    Res := TJSONObject(J).Find('results', jtArray) as TJSONArray;
    if (Res = nil) or (Res.Count = 0) then Exit;
    Series := TJSONObject(Res.Items[0]).Find('series', jtArray) as TJSONArray;
    if (Series = nil) or (Series.Count = 0) then Exit;
    Cols := Series.Objects[0].Find('columns', jtArray) as TJSONArray;
    Vals := Series.Objects[0].Find('values', jtArray) as TJSONArray;
    if (Cols = nil) or (Vals = nil) then Exit;
    for I := 0 to Vals.Count - 1 do
    begin
      Row := Vals.Arrays[I];
      T := Row.Items[0].AsInt64;
      for C := 1 to Min(Cols.Count, Row.Count) - 1 do
      begin
        if Row.Items[C].JSONType = jtNull then Continue;
        if (Cols.Strings[C] <> 'cmd') and (Cols.Strings[C] <> 'speed_sp') and
          (Cols.Strings[C] <> 'fill_sp') and (Cols.Strings[C] <> 'temp_sp') then Continue;  // tags
        FLock.Enter;
        try
          FMachine.Command(Cols.Strings[C], JsonCellText(Row.Items[C]));
          Inc(FCommands);
          FLog.Add(FormatDateTime('hh:nn:ss', Now) + '  command ' + Cols.Strings[C] + ' = ' +
            JsonCellText(Row.Items[C]));
        finally
          FLock.Leave;
        end;
      end;
      FLastCmdMs := Max(FLastCmdMs, T);
    end;
  finally
    J.Free;
  end;
end;

procedure TMachineRunner.Execute;
var
  Lines, Lv, Txt: string;
  I, P, K: Integer;
  Ms: Int64;
  R: TInfluxResult;
begin
  K := 0;
  while not Terminated do
  begin
    Sleep(100);
    Ms := UtcMs;
    FLock.Enter;
    try
      FMachine.Step(0.1);
      Inc(K);
      if K mod 5 <> 0 then Continue;           // InfluxDB every 500 ms
      Lines := MachineLine(FMachine.D, Ms) + #10;
      for I := 0 to FMachine.Events.Count - 1 do
      begin
        P := Pos(#9, FMachine.Events[I]);
        Lv := Copy(FMachine.Events[I], 1, P - 1);
        Txt := Copy(FMachine.Events[I], P + 1, MaxInt);
        Lines := Lines + EventLine(Lv, Txt, Ms + I) + #10;   // +I: two events, two points
        FLog.Add(FormatDateTime('hh:nn:ss', Now) + '  ' + Lv + ': ' + Txt);
      end;
      FMachine.Events.Clear;
    finally
      FLock.Leave;
    end;
    R := InfluxWrite(FConn, FDb, Lines, 'ms');
    if (R.Code = 404) and not FCreated then
    begin
      FCreated := True;                         // InfluxDB 1.x: create the database first
      InfluxQuery(FConn, '', 'CREATE DATABASE ' + QuoteIdent(FDb));
      R := InfluxWrite(FConn, FDb, Lines, 'ms');
    end;
    FLock.Enter;
    try
      if R.Ok then Inc(FWrites) else Inc(FErrors);
      if R.Error <> FLastError then
        if R.Error <> '' then FLog.Add(FormatDateTime('hh:nn:ss', Now) + '  InfluxDB: ' + R.Error)
        else FLog.Add(FormatDateTime('hh:nn:ss', Now) + '  InfluxDB: writing again');
      FLastError := R.Error;
    finally
      FLock.Leave;
    end;
    PollCommands;
  end;
end;

end.

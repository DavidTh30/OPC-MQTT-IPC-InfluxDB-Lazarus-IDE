{ ============================================================================
  umachinedef - what the filling machine (MachineSim) and its HMI (MachineHMI)
  share: the InfluxDB layout, limits, and line / JSON helpers.
  InfluxDB is the only link between the two programs:
    machine  (every 500 ms)  machine,machine=filler1 state="RUNNING",running=true,
             speed_sp=100,speed=99.6,fill_sp=500,fill_last=501.2,tank_level=63.4,
             inlet=false,temp=45.1,temp_sp=45,heater=true,power=9.85,
             good=1234i,reject=12i,fault="" <ms>
    events   (on changes)    events,machine=filler1,level=info|warn|alarm text="..." <ms>
    command  (from the HMI)  command,machine=filler1,source=hmi cmd="start" <ms>
                             command,machine=filler1,source=hmi speed_sp=100 <ms>
  The machine reads the commands newer than the last one it saw.
  ============================================================================ }
unit umachinedef;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, fpjson, jsonparser;

const
  MACHINE_ID = 'filler1';
  MEAS_MACHINE = 'machine';
  MEAS_EVENTS = 'events';
  MEAS_COMMAND = 'command';
  DEFAULT_DB = 'machine';

  SPEED_MAX = 120;              // bottles / min
  FILL_MIN = 250;               // ml
  FILL_MAX = 1000;
  TEMP_MIN = 20;                // C
  TEMP_MAX = 80;

type
  TMachineData = record
    Valid: Boolean;
    TimeMs: Int64;              // ms since 1970 UTC of the point
    State, Fault: string;
    Running, Inlet, Heater: Boolean;
    SpeedSp, Speed, FillSp, FillLast, Level, Temp, TempSp, Power: Double;
    Good, Reject: Int64;
  end;

  TMachineEvent = record
    TimeMs: Int64;
    Level, Text: string;
  end;
  TMachineEvents = array of TMachineEvent;

function MachineLine(const D: TMachineData; Ms: Int64): string;
function EventLine(const Level, Text: string; Ms: Int64): string;
function CommandLine(const Field, Value: string; IsText: Boolean; Ms: Int64): string;
{ InfluxQL result -> data: the columns last_<field> of SELECT last(*) }
function ParseLast(const Json: string; out D: TMachineData): Boolean;
function FloatTxt(X: Double; Digits: Integer = 3): string;
function UtcMs: Int64;
function QualityPct(const D: TMachineData): Double;

var
  DotFS: TFormatSettings;

implementation

{$IFDEF WINDOWS}
uses
  Windows;
{$ENDIF}

function UtcMs: Int64;
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

function FloatTxt(X: Double; Digits: Integer): string;
begin
  if IsNan(X) or IsInfinite(X) then X := 0;
  Result := FloatToStrF(X, ffFixed, 15, Digits, DotFS);
end;

function Str(const S: string): string;
begin
  Result := '"' + StringReplace(StringReplace(S, '\', '\\', [rfReplaceAll]), '"', '\"', [rfReplaceAll]) + '"';
end;

function B(V: Boolean): string;
begin
  if V then Result := 'true' else Result := 'false';
end;

function MachineLine(const D: TMachineData; Ms: Int64): string;
begin
  Result := Format('%s,machine=%s state=%s,running=%s,speed_sp=%s,speed=%s,fill_sp=%s,' +
    'fill_last=%s,tank_level=%s,inlet=%s,temp=%s,temp_sp=%s,heater=%s,power=%s,good=%di,' +
    'reject=%di,fault=%s %d',
    [MEAS_MACHINE, MACHINE_ID, Str(D.State), B(D.Running), FloatTxt(D.SpeedSp, 1), FloatTxt(D.Speed, 2),
     FloatTxt(D.FillSp, 0), FloatTxt(D.FillLast, 1), FloatTxt(D.Level, 2), B(D.Inlet),
     FloatTxt(D.Temp, 2), FloatTxt(D.TempSp, 1), B(D.Heater), FloatTxt(D.Power, 2), D.Good,
     D.Reject, Str(D.Fault), Ms]);
end;

function EventLine(const Level, Text: string; Ms: Int64): string;
begin
  Result := Format('%s,machine=%s,level=%s text=%s %d', [MEAS_EVENTS, MACHINE_ID, Level, Str(Text), Ms]);
end;

function CommandLine(const Field, Value: string; IsText: Boolean; Ms: Int64): string;
var
  V: string;
begin
  if IsText then V := Str(Value) else V := Value;
  Result := Format('%s,machine=%s,source=hmi %s=%s %d', [MEAS_COMMAND, MACHINE_ID, Field, V, Ms]);
end;

function QualityPct(const D: TMachineData): Double;
begin
  if D.Good + D.Reject = 0 then Result := 100
  else Result := 100 * D.Good / (D.Good + D.Reject);
end;

function ParseLast(const Json: string; out D: TMachineData): Boolean;
var
  J: TJSONData;
  Res, Series, Cols, Vals, Row: TJSONArray;
  I: Integer;
  C: string;
  V: TJSONData;

  function Num: Double;
  begin
    if V.JSONType = jtNumber then Result := V.AsFloat else Result := 0;
  end;

  function Bool: Boolean;
  begin
    Result := (V.JSONType = jtBoolean) and V.AsBoolean;
  end;

  function Txt: string;
  begin
    if V.JSONType = jtString then Result := V.AsString else Result := '';
  end;

begin
  D := Default(TMachineData);
  Result := False;
  try
    J := GetJSON(Json);
  except
    Exit;
  end;
  try
    if not (J is TJSONObject) then Exit;
    Res := TJSONObject(J).Find('results', jtArray) as TJSONArray;
    if (Res = nil) or (Res.Count = 0) or not (Res.Items[0] is TJSONObject) then Exit;
    Series := TJSONObject(Res.Items[0]).Find('series', jtArray) as TJSONArray;
    if (Series = nil) or (Series.Count = 0) then Exit;
    Cols := Series.Objects[0].Find('columns', jtArray) as TJSONArray;
    Vals := Series.Objects[0].Find('values', jtArray) as TJSONArray;
    if (Cols = nil) or (Vals = nil) or (Vals.Count = 0) then Exit;
    Row := Vals.Arrays[0];
    for I := 0 to Min(Cols.Count, Row.Count) - 1 do
    begin
      C := Cols.Strings[I];
      if Copy(C, 1, 5) = 'last_' then Delete(C, 1, 5);
      V := Row.Items[I];
      case C of
        'state': D.State := Txt;
        'fault': D.Fault := Txt;
        'running': D.Running := Bool;
        'inlet': D.Inlet := Bool;
        'heater': D.Heater := Bool;
        'speed_sp': D.SpeedSp := Num;
        'speed': D.Speed := Num;
        'fill_sp': D.FillSp := Num;
        'fill_last': D.FillLast := Num;
        'tank_level': D.Level := Num;
        'temp': D.Temp := Num;
        'temp_sp': D.TempSp := Num;
        'power': D.Power := Num;
        'good': D.Good := Round(Num);
        'reject': D.Reject := Round(Num);
      end;
    end;
    D.Valid := D.State <> '';
    Result := D.Valid;
  finally
    J.Free;
  end;
end;

initialization
  DotFS := DefaultFormatSettings;
  DotFS.DecimalSeparator := '.';
  DotFS.ThousandSeparator := #0;
end.

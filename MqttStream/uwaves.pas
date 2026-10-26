{ ============================================================================
  uwaves - test signal shapes, shared by the MQTT Stream Server (ustreams)
  and the InfluxDB Signal Generator
    value at T s:  Sine Triangle Square Sawtooth Ramp Random RandomWalk Constant
    (p = phase 0..1 within the period; RandomWalk keeps its state in Walk)
  ============================================================================ }
unit uwaves;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Math;

type
  TWaveShape = (wsSine, wsTriangle, wsSquare, wsSawtooth, wsRamp, wsRandom, wsRandomWalk,
    wsConstant);

  TGenChannel = record
    Enabled: Boolean;
    Name: string;
    Shape: TWaveShape;
    Amplitude, Offset, Period: Double;   // Period in s
    Decimals: Integer;
  end;
  TGenChannels = array of TGenChannel;

const
  WaveShapeName: array[TWaveShape] of string = ('Sine', 'Triangle', 'Square', 'Sawtooth', 'Ramp',
    'Random', 'RandomWalk', 'Constant');

function ShapeFromName(const S: string; out Shape: TWaveShape): Boolean;
{ the value of the channel T s after the start; Walk = random walk state (start: Offset) }
function WaveValue(const C: TGenChannel; T: Double; var Walk: Double): Double;

implementation

function ShapeFromName(const S: string; out Shape: TWaveShape): Boolean;
var
  W: TWaveShape;
begin
  for W := Low(TWaveShape) to High(TWaveShape) do
    if SameText(S, WaveShapeName[W]) then
    begin
      Shape := W;
      Exit(True);
    end;
  Shape := wsSine;
  Result := False;
end;

function WaveValue(const C: TGenChannel; T: Double; var Walk: Double): Double;
var
  Ph, Step: Double;
begin
  if C.Period > 0 then
    Ph := Frac(T / C.Period)
  else
    Ph := 0;
  case C.Shape of
    wsSine: Result := C.Offset + C.Amplitude * Sin(2 * Pi * Ph);
    wsTriangle: Result := C.Offset + C.Amplitude * (1 - 4 * Abs(Ph - 0.5));
    wsSquare: if Ph < 0.5 then Result := C.Offset + C.Amplitude else Result := C.Offset - C.Amplitude;
    wsSawtooth: Result := C.Offset + C.Amplitude * (2 * Ph - 1);
    wsRamp: Result := C.Offset + C.Amplitude * Ph;
    wsRandom: Result := C.Offset + C.Amplitude * (2 * Random - 1);
    wsRandomWalk:
      begin
        { step of 5 % of the amplitude, reflected at Offset +- Amplitude }
        Step := Abs(C.Amplitude) * Double(0.05) * (2 * Random - 1);
        Walk := Walk + Step;
        if Walk > C.Offset + Abs(C.Amplitude) then
          Walk := 2 * (C.Offset + Abs(C.Amplitude)) - Walk;
        if Walk < C.Offset - Abs(C.Amplitude) then
          Walk := 2 * (C.Offset - Abs(C.Amplitude)) - Walk;
        Result := Walk;
      end;
  else
    Result := C.Offset;
  end;
end;

end.

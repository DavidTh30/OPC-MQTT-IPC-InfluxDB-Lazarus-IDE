{ ============================================================================
  uplcsim - simulated PLC, the same logic as Tools/s7sim.py
    - FB_NonlinearHV (10 points, Set 1) or FB_LinearHV (2 points, Set 2,
      with its input protection: bad calibrations rejected with Err code,
      setpoints clamped to X0..X1)
    - nonlinear HV supply AO -> plant -> AI with first-order lag
    - one PLC cycle every 50 ms in its own thread
  The tags have the names of DB10 (DB_HMI.xxx) plus test values Sim.xxx.
  ============================================================================ }
unit uplcsim;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, Math, uaencode, uaserver;

type
  TTagKind = (tkReal, tkInt, tkBool, tkRealArray, tkUInt16, tkDouble, tkDateTime);

  TSimTag = record
    Id: Integer;
    Name: string;
    Kind: TTagKind;
    Writable: Boolean;
  end;

  TCurve = record
    Eng, Volt: array of Single;
  end;

  { TPlcSim }

  TPlcSim = class
  private
    FLock: TCriticalSection;
    FThread: TThread;
    FNL: Integer;
    FReal: array[0..7] of Single;        // VoltSP_kV .. AI1_V
    FRaw: array[0..3] of SmallInt;       // AO0_Raw .. AI1_Raw
    FEnable: Boolean;
    FValid: array[0..3] of Boolean;      // Valid_VSP, VAct, CSP, CAct
    FFault: array[0..1] of Boolean;
    FHeartbeat: SmallInt;
    FErr: array[0..3] of SmallInt;       // Set 2
    FLimited: array[0..1] of Boolean;    // Set 2
    FLastSP: array[0..1] of Single;
    FCurve: array[0..3] of TCurve;       // request (DB10)
    FAct: array[0..3] of TCurve;         // accepted calibration (Set 2)
    FKV, FMA: Double;                    // plant
    FT0: QWord;
    procedure AddTag(AId: Integer; const AName: string; AKind: TTagKind; AWritable: Boolean);
    function Interp(X: Double; const XS, YS: array of Single; XFull, YFull, YMin, YMax: Double;
      out Valid: Boolean): Double;
    procedure LinInit;
    procedure LinAccept;
    function LinSetpoint(J: Integer): Double;
    procedure PlantStep(AO0, AO1, Dt: Double; out AI0, AI1: Double);
  public
    Tags: array of TSimTag;
    constructor Create(APoints: Integer);
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
    procedure Cycle(Dt: Double);
    { hold the PLC cycle off while several tags are written as one block (reentrant) }
    procedure Lock;
    procedure Unlock;
    function ReadTag(Tag: Integer; out V: TUAVariant): Boolean;
    function WriteTag(Tag: Integer; const V: TUAVariant): Cardinal;
    function TagText(Tag: Integer): string;
    property Points: Integer read FNL;
  end;

const
  TagKindName: array[TTagKind] of string = ('Float', 'Int16', 'Boolean', 'Float[]', 'UInt16',
    'Double', 'DateTime');
  TagKindType: array[TTagKind] of Byte = (vtFloat, vtInt16, vtBoolean, vtFloat, vtUInt16,
    vtDouble, vtDateTime);

procedure MaskFPUExceptions;

implementation

const
  T_VOLTSP = 0; T_CURSP = 1; T_VOLTACT = 2; T_CURACT = 3;
  T_AO0V = 4; T_AO1V = 5; T_AI0V = 6; T_AI1V = 7;
  T_RAW = 8;          // 8..11 AO0_Raw, AO1_Raw, AI0_Raw, AI1_Raw
  T_ENABLE = 12;
  T_VALID = 13;       // 13..16
  T_FAULT = 17;       // 17..18
  T_HEARTBEAT = 19;
  T_ERR = 20;         // 20..23 (Set 2)
  T_LIMITED = 24;     // 24..25 (Set 2)
  T_CURVE = 26;       // 26..33: curve k Eng = 26 + 2k, Volt = 27 + 2k
  T_COUNTER = 34; T_SINE = 35; T_TOGGLE = 36; T_CLOCK = 37;

  RealNames: array[0..7] of string = ('VoltSP_kV', 'CurSP_mA', 'VoltAct_kV', 'CurAct_mA',
    'AO0_V', 'AO1_V', 'AI0_V', 'AI1_V');
  RawNames: array[0..3] of string = ('AO0_Raw', 'AO1_Raw', 'AI0_Raw', 'AI1_Raw');
  CurveNames: array[0..3] of string = ('VSP', 'VAct', 'CSP', 'CAct');
  CurveFull: array[0..3] of Double = (15, 15, 20, 20);

type

  { TSimThread }

  TSimThread = class(TThread)
  private
    FSim: TPlcSim;
  protected
    procedure Execute; override;
  public
    constructor Create(ASim: TPlcSim);
  end;

procedure MaskFPUExceptions;
begin
  { a client may write NaN / Inf: compare and compute without exceptions }
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
end;

function Clamp(X, Lo, Hi: Double): Double;
begin
  if IsNan(X) or (X < Lo) then
    Result := Lo
  else if X > Hi then
    Result := Hi
  else
    Result := X;
end;

function ToInt16(X: Double): SmallInt;
begin
  if IsNan(X) then
    Result := 0
  else
    Result := Round(Clamp(X, -32768, 32767));
end;

function SameCurve(const A, B: TCurve): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(A.Eng) do
    if (A.Eng[I] <> B.Eng[I]) or (A.Volt[I] <> B.Volt[I]) then
      Exit(False);
  Result := True;
end;

function CopyCurve(const C: TCurve): TCurve;
begin
  Result.Eng := Copy(C.Eng);
  Result.Volt := Copy(C.Volt);
end;

{ TSimThread }

constructor TSimThread.Create(ASim: TPlcSim);
begin
  FSim := ASim;
  inherited Create(False);
end;

procedure TSimThread.Execute;
var
  T, T1: QWord;
begin
  MaskFPUExceptions;
  T := GetTickCount64;
  while not Terminated do
  begin
    Sleep(50);
    T1 := GetTickCount64;
    FSim.Cycle(Double(T1 - T) / 1000);
    T := T1;
  end;
end;

{ TPlcSim }

constructor TPlcSim.Create(APoints: Integer);
var
  I, K: Integer;
begin
  FLock := TCriticalSection.Create;
  FNL := APoints;
  FT0 := GetTickCount64;
  for K := 0 to 3 do
  begin
    SetLength(FCurve[K].Eng, FNL);
    SetLength(FCurve[K].Volt, FNL);
    for I := 0 to FNL - 1 do       // ideal line 0..full <-> 0..10 V
    begin
      FCurve[K].Eng[I] := CurveFull[K] * I / (FNL - 1);
      FCurve[K].Volt[I] := 10.0 * I / (FNL - 1);
    end;
  end;
  if FNL = 2 then
    LinInit;

  for I := 0 to 7 do
    AddTag(I, 'DB_HMI.' + RealNames[I], tkReal, I in [T_VOLTSP, T_CURSP]);
  for I := 0 to 3 do
    AddTag(T_RAW + I, 'DB_HMI.' + RawNames[I], tkInt, False);
  AddTag(T_ENABLE, 'DB_HMI.Enable', tkBool, True);
  for I := 0 to 3 do
    AddTag(T_VALID + I, 'DB_HMI.Valid_' + CurveNames[I], tkBool, False);
  AddTag(T_FAULT, 'DB_HMI.AI0_Fault', tkBool, False);
  AddTag(T_FAULT + 1, 'DB_HMI.AI1_Fault', tkBool, False);
  AddTag(T_HEARTBEAT, 'DB_HMI.Heartbeat', tkInt, False);
  if FNL = 2 then
  begin
    for I := 0 to 3 do
      AddTag(T_ERR + I, 'DB_HMI.Err_' + CurveNames[I], tkInt, True);   // write 0 = acknowledge
    AddTag(T_LIMITED, 'DB_HMI.VSP_Limited', tkBool, False);
    AddTag(T_LIMITED + 1, 'DB_HMI.CSP_Limited', tkBool, False);
  end;
  for K := 0 to 3 do
  begin
    AddTag(T_CURVE + 2 * K, 'DB_HMI.Curve_' + CurveNames[K] + '.Eng', tkRealArray, True);
    AddTag(T_CURVE + 2 * K + 1, 'DB_HMI.Curve_' + CurveNames[K] + '.Volt', tkRealArray, True);
  end;
  AddTag(T_COUNTER, 'Sim.Counter', tkUInt16, False);
  AddTag(T_SINE, 'Sim.Sine', tkDouble, False);
  AddTag(T_TOGGLE, 'Sim.Toggle', tkBool, False);
  AddTag(T_CLOCK, 'Sim.Clock', tkDateTime, False);
end;

destructor TPlcSim.Destroy;
begin
  Stop;
  FLock.Free;
  inherited Destroy;
end;

procedure TPlcSim.AddTag(AId: Integer; const AName: string; AKind: TTagKind; AWritable: Boolean);
var
  N: Integer;
begin
  N := Length(Tags);
  SetLength(Tags, N + 1);
  Tags[N].Id := AId;
  Tags[N].Name := AName;
  Tags[N].Kind := AKind;
  Tags[N].Writable := AWritable;
end;

procedure TPlcSim.Start;
begin
  if FThread = nil then
    FThread := TSimThread.Create(Self);
end;

procedure TPlcSim.Stop;
begin
  if FThread = nil then Exit;
  FThread.Terminate;
  FThread.WaitFor;
  FreeAndNil(FThread);
end;

procedure TPlcSim.Lock;
begin
  FLock.Enter;
end;

procedure TPlcSim.Unlock;
begin
  FLock.Leave;
end;

{ same as FC_NL_Interp (10 points) / FC_Lin_Scale (2 points) }
function TPlcSim.Interp(X: Double; const XS, YS: array of Single; XFull, YFull, YMin, YMax: Double;
  out Valid: Boolean): Double;
var
  I, K: Integer;
  XX, Y: Double;
begin
  if FNL = 2 then
    Valid := (XS[1] > XS[0]) and (YS[1] > YS[0])
  else
  begin
    Valid := True;
    for I := 1 to FNL - 1 do
      if not (XS[I] > XS[I - 1]) then Valid := False;
  end;
  if Valid and (FNL = 2) then
    Y := YS[0] + (X - XS[0]) * (YS[1] - YS[0]) / (XS[1] - XS[0])     // line, extended
  else if Valid then
  begin
    XX := Min(Max(X, Double(XS[0])), Double(XS[FNL - 1]));
    K := 0;
    for I := 1 to FNL - 2 do
      if XX >= XS[I] then K := I;
    Y := YS[K] + (YS[K + 1] - YS[K]) * (XX - XS[K]) / (XS[K + 1] - XS[K]);
  end
  else if XFull > 0 then
    Y := X * YFull / XFull
  else
    Y := 0;
  Result := Clamp(Y, YMin, YMax);
end;

{ ---- Set 2 protection (PLC_Linear FC_Lin_Check / FC_Lin_Accept) ---- }

function LinCheck(const C: TCurve; Full: Double): Integer;

  function Inside(X: Single; Hi: Double): Boolean;
  begin
    Result := not IsNan(X) and (X >= 0) and (X <= Hi);
  end;

begin
  if not (Inside(C.Eng[0], Full) and Inside(C.Eng[1], Full)) then Exit(1);
  if not (Inside(C.Volt[0], 10) and Inside(C.Volt[1], 10)) then Exit(2);
  if not (C.Eng[1] > C.Eng[0]) then Exit(3);
  if not (C.Volt[1] > C.Volt[0]) then Exit(4);
  if C.Eng[1] - C.Eng[0] < 0.1 * Full then Exit(5);
  if C.Volt[1] - C.Volt[0] < 1.0 then Exit(6);
  Result := 0;
end;

procedure TPlcSim.LinInit;
var
  K: Integer;
begin
  for K := 0 to 3 do
    if LinCheck(FCurve[K], CurveFull[K]) = 0 then
      FAct[K] := CopyCurve(FCurve[K])
    else
    begin
      SetLength(FAct[K].Eng, 2);
      SetLength(FAct[K].Volt, 2);
      FAct[K].Eng[0] := 0;
      FAct[K].Eng[1] := CurveFull[K];
      FAct[K].Volt[0] := 0;
      FAct[K].Volt[1] := 10;
    end;
end;

procedure TPlcSim.LinAccept;
var
  K, Code: Integer;
begin
  for K := 0 to 3 do
  begin
    Code := LinCheck(FCurve[K], CurveFull[K]);
    if Code <> 0 then
    begin
      FErr[K] := Code;                       // latched reason
      FCurve[K] := CopyCurve(FAct[K]);       // restore the last good calibration
    end
    else if not SameCurve(FCurve[K], FAct[K]) then
    begin
      FAct[K] := CopyCurve(FCurve[K]);
      FErr[K] := 0;
    end;
    FValid[K] := FErr[K] = 0;
  end;
end;

{ J = 0 voltage (curve VSP), 1 current (curve CSP): clamp to X0..X1 }
function TPlcSim.LinSetpoint(J: Integer): Double;
var
  SP, E0, E1: Single;
  C: Integer;
begin
  C := 2 * J;
  SP := FReal[J];
  E0 := FAct[C].Eng[0];
  E1 := FAct[C].Eng[1];
  if not IsNan(SP) and (SP >= E0) and (SP <= E1) then
  begin
    if SP <> FLastSP[J] then
      FLimited[J] := False;
  end
  else if not IsNan(SP) and (SP > E1) then
  begin
    SP := E1;
    FLimited[J] := True;
  end
  else
  begin                                      // below X0 or NaN
    SP := E0;
    FLimited[J] := True;
  end;
  FReal[J] := SP;
  FLastSP[J] := SP;
  Result := SP;
end;

{ nonlinear HV supply: real kV = 15*(ao/10)^1.25, monitor slightly nonlinear }
procedure TPlcSim.PlantStep(AO0, AO1, Dt: Double; out AI0, AI1: Double);
var
  Target, Load, Limit, T: Double;
begin
  Target := 15.0 * Power(AO0 / 10.0, 1.25);
  FKV := FKV + (Target - FKV) * Min(1.0, Dt / 0.8);
  Load := FKV * 1.1;                          // resistive load
  Limit := 20.0 * Power(AO1 / 10.0, 0.9);
  FMA := FMA + (Min(Load, Limit) - FMA) * Min(1.0, Dt / 0.3);
  T := Double(Now) * 86400;
  AI0 := Max(10.0 * Power(Max(FKV, 0) / 15.0, 0.92) + 0.01 * Sin(T * 3), 0);
  AI1 := Max(10.0 * Power(Max(FMA, 0) / 20.0, 1.05) + 0.01 * Sin(T * 5), 0);
end;

procedure TPlcSim.Cycle(Dt: Double);
var
  SPV, SPI, AO0, AO1, AI0, AI1, V0, V1: Double;
  R0, R1: Int64;
  Ok: Boolean;
begin
  FLock.Enter;
  try
    if FNL = 2 then
    begin
      LinAccept;
      SPV := LinSetpoint(0);
      SPI := LinSetpoint(1);
      AO0 := Interp(SPV, FAct[0].Eng, FAct[0].Volt, 15, 10, FAct[0].Volt[0], FAct[0].Volt[1], Ok);
      AO1 := Interp(SPI, FAct[2].Eng, FAct[2].Volt, 20, 10, FAct[2].Volt[0], FAct[2].Volt[1], Ok);
    end
    else
    begin
      SPV := Clamp(FReal[T_VOLTSP], 0, 15);
      SPI := Clamp(FReal[T_CURSP], 0, 20);
      AO0 := Interp(SPV, FCurve[0].Eng, FCurve[0].Volt, 15, 10, 0, 10, Ok);
      FValid[0] := Ok;
      AO1 := Interp(SPI, FCurve[2].Eng, FCurve[2].Volt, 20, 10, 0, 10, Ok);
      FValid[2] := Ok;
    end;
    if not FEnable then
    begin
      AO0 := 0;
      AO1 := 0;
    end;
    FReal[T_AO0V] := AO0;
    FReal[T_AO1V] := AO1;
    FRaw[0] := ToInt16(AO0 * 2764.8);
    FRaw[1] := ToInt16(AO1 * 2764.8);

    PlantStep(AO0, AO1, Dt, AI0, AI1);

    R0 := Round(AI0 * 2764.8);
    R1 := Round(AI1 * 2764.8);
    FRaw[2] := ToInt16(R0);
    FRaw[3] := ToInt16(R1);
    FFault[0] := R0 > 32511;
    FFault[1] := R1 > 32511;
    V0 := Min(R0 / 2764.8, 10.0);
    V1 := Min(R1 / 2764.8, 10.0);
    FReal[T_AI0V] := V0;
    FReal[T_AI1V] := V1;
    if FNL = 2 then
    begin
      FReal[T_VOLTACT] := Interp(V0, FAct[1].Volt, FAct[1].Eng, 10, 15, 0, 15, Ok);
      FReal[T_CURACT] := Interp(V1, FAct[3].Volt, FAct[3].Eng, 10, 20, 0, 20, Ok);
    end
    else
    begin
      FReal[T_VOLTACT] := Interp(V0, FCurve[1].Volt, FCurve[1].Eng, 10, 15, 0, 15, Ok);
      FValid[1] := Ok;
      FReal[T_CURACT] := Interp(V1, FCurve[3].Volt, FCurve[3].Eng, 10, 20, 0, 20, Ok);
      FValid[3] := Ok;
    end;
    if FHeartbeat >= 32767 then
      FHeartbeat := 0
    else
      Inc(FHeartbeat);
  finally
    FLock.Leave;
  end;
end;

function SingleArray(const A: array of Single): TUAVariant;
var
  D: array of Double;
  I: Integer;
begin
  SetLength(D, Length(A));
  for I := 0 to High(A) do
    D[I] := A[I];
  Result := VarArray(vtFloat, D);
end;

function TPlcSim.ReadTag(Tag: Integer; out V: TUAVariant): Boolean;
var
  T: Double;
  K: Integer;
begin
  Result := True;
  T := Double(GetTickCount64 - FT0) / 1000;
  FLock.Enter;
  try
    case Tag of
      T_VOLTSP..T_AI1V: V := VarScalar(vtFloat, FReal[Tag]);
      T_RAW..T_RAW + 3: V := VarScalar(vtInt16, FRaw[Tag - T_RAW]);
      T_ENABLE: V := VarScalar(vtBoolean, Ord(FEnable));
      T_VALID..T_VALID + 3: V := VarScalar(vtBoolean, Ord(FValid[Tag - T_VALID]));
      T_FAULT..T_FAULT + 1: V := VarScalar(vtBoolean, Ord(FFault[Tag - T_FAULT]));
      T_HEARTBEAT: V := VarScalar(vtInt16, FHeartbeat);
      T_ERR..T_ERR + 3: V := VarScalar(vtInt16, FErr[Tag - T_ERR]);
      T_LIMITED..T_LIMITED + 1: V := VarScalar(vtBoolean, Ord(FLimited[Tag - T_LIMITED]));
      T_CURVE..T_CURVE + 7:
        begin
          K := (Tag - T_CURVE) div 2;
          if Odd(Tag - T_CURVE) then
            V := SingleArray(FCurve[K].Volt)
          else
            V := SingleArray(FCurve[K].Eng);
        end;
      T_COUNTER: V := VarScalar(vtUInt16, Trunc(T * 10) and $FFFF);
      T_SINE: V := VarScalar(vtDouble, Sin(T / 2.0) * 50 + 50);
      T_TOGGLE: V := VarScalar(vtBoolean, Ord(Odd(Trunc(T / 2))));
      T_CLOCK: V := VarScalar(vtDateTime, UANow);
    else
      Result := False;
    end;
  finally
    FLock.Leave;
  end;
end;

function TPlcSim.WriteTag(Tag: Integer; const V: TUAVariant): Cardinal;
var
  K, I: Integer;
  X: Double;
  Scalar: Boolean;
begin
  Scalar := not V.IsArray and VarIsNumeric(V) and (Length(V.D) = 1);
  if Scalar then X := V.D[0] else X := 0;
  Result := UA_GOOD;
  FLock.Enter;
  try
    case Tag of
      T_VOLTSP, T_CURSP:
        if Scalar then FReal[Tag] := X else Result := UA_BadTypeMismatch;
      T_ENABLE:
        if Scalar then FEnable := X <> 0 else Result := UA_BadTypeMismatch;
      T_ERR..T_ERR + 3:
        if not Scalar or (FNL <> 2) then
          Result := UA_BadTypeMismatch
        else if (Frac(X) <> 0) or (X < -32768) or (X > 32767) then
          Result := UA_BadOutOfRange
        else
          FErr[Tag - T_ERR] := Round(X);
      T_CURVE..T_CURVE + 7:
        if V.IsArray and VarIsNumeric(V) and (Length(V.D) = FNL) then
        begin
          K := (Tag - T_CURVE) div 2;
          for I := 0 to FNL - 1 do
            if Odd(Tag - T_CURVE) then
              FCurve[K].Volt[I] := V.D[I]
            else
              FCurve[K].Eng[I] := V.D[I];
        end
        else
          Result := UA_BadTypeMismatch;
    else
      Result := UA_BadNotWritable;
    end;
  finally
    FLock.Leave;
  end;
end;

function TPlcSim.TagText(Tag: Integer): string;
var
  V: TUAVariant;
begin
  if ReadTag(Tag, V) then
    Result := VarText(V)
  else
    Result := '?';
end;

end.

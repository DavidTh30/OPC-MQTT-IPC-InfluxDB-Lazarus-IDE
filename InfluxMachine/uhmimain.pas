{ ============================================================================
  Machine HMI - operator screen of the filling machine, drawn with BGRABitmap.
  All data comes from InfluxDB and all commands go to InfluxDB (uhmidata);
  there is no other link to the machine.
    - process picture: tank (level, inlet valve, heater), pipe, filler with
      stream, conveyor with bottles moving at the real speed
    - gauges speed / temperature with setpoint marker, level and power bars,
      KPI tiles good / reject / quality / last fill
    - trend of the last 10 min (InfluxDB GROUP BY time(10s)), events list
    - buttons START / STOP / RESET / CLEAR and setpoints - / + (drawn, clickable)
    - the screen scales to the window (design 1280 x 760)
    - settings in MachineHMI.ini; command line --connect, --cmd=start|stop|reset|clear,
      --speed=<bpm>, --snapshot=<file.png> --after=<s> (one frame, then exit)
  ============================================================================ }
unit uhmimain;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, ExtCtrls, StdCtrls, IniFiles, Math,
  DateUtils, BGRABitmap, BGRABitmapTypes, uinfluxapi, umachinedef, uhmidata;

type
  THmiButton = record
    R: TRectF;
    Id: string;
    Enabled: Boolean;
  end;

  TPending = record
    Active: Boolean;
    Value: Double;
    Until_: QWord;
  end;

  { TMainForm }

  TMainForm = class(TForm)
    ButtonConnect: TButton;
    EditDb: TEdit;
    EditUrl: TEdit;
    LabelDb: TLabel;
    LabelUrl: TLabel;
    PaintHmi: TPaintBox;
    PanelTop: TPanel;
    Timer1: TTimer;
    procedure ButtonConnectClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure PaintHmiMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure PaintHmiMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure PaintHmiPaint(Sender: TObject);
    procedure Timer1Timer(Sender: TObject);
  private
    FData: THmiData;
    FBmp: TBGRABitmap;
    FSnap: THmiSnapshot;
    FS, FOX, FOY: Single;               // design -> pixel
    FButtons: array of THmiButton;
    FHover, FPressed: string;
    FPressedUntil: QWord;
    FPhase: Double;                     // conveyor position in bottles
    FLevelShow: Double;                 // eased tank level
    FLastFrame: Double;
    FBlink: Boolean;
    FPend: array[0..2] of TPending;     // speed, fill, temp setpoints sent, not confirmed yet
    FSnapFile: string;
    FSnapAt: QWord;
    FStartCmd, FStartSpeed: string;
    procedure Connect;
    procedure RenderFrame;
    function PX(V: Single): Single;
    function PY(V: Single): Single;
    function PS(V: Single): Single;
    procedure Txt(X, Y: Single; const S: string; Size: Single; C: TBGRAPixel;
      AAlign: TAlignment = taLeftJustify; Bold: Boolean = False);
    procedure Panel(X, Y, W, H: Single; const Title: string);
    procedure Button(X, Y, W, H: Single; const ACaption, Id: string; Base: TBGRAPixel; AEnabled: Boolean);
    procedure Gauge(CX, CY, R, V, VMin, VMax, Sp: Single; const ACaption, Units: string;
      Digits: Integer; C: TBGRAPixel);
    procedure Bar(X, Y, W, H, V, VMin, VMax: Single; const ACaption, Units: string; C: TBGRAPixel);
    procedure Tile(X, Y, W, H: Single; const ACaption, Value: string; C: TBGRAPixel);
    procedure DrawProcess(X, Y, W, H: Single);
    procedure DrawTrend(X, Y, W, H: Single);
    procedure DrawControls(X, Y, W, H: Single);
    procedure DrawEvents(X, Y, W, H: Single);
    procedure SetpointRow(Y, X, W: Single; Idx: Integer; const ACaption, Units: string;
      Live, Step, VMin, VMax: Double; Digits: Integer);
    function SpValue(Idx: Integer; Live: Double): Double;
    procedure Act(const Id: string);
    function IniName: string;
  end;

var
  MainForm: TMainForm;

implementation

{$R *.lfm}

const
  DW = 1280;                            // design size
  DH = 760;
  SP_FIELDS: array[0..2] of string = ('speed_sp', 'fill_sp', 'temp_sp');
  TREND_NAMES: array[0..TREND_SERIES - 1] of string = ('Temperature C', 'Tank level %', 'Speed b/min', 'Power kW');
  TREND_MIN: array[0..TREND_SERIES - 1] of Double = (20, 0, 0, 0);
  TREND_MAX: array[0..TREND_SERIES - 1] of Double = (80, 100, 120, 12);

var
  CBack, CPanel, CPanel2, CText, CDim, CGrid, CGreen, CRed, CAmber, CBlue, CCyan, CViolet: TBGRAPixel;

function TrendColor(K: Integer): TBGRAPixel;
begin
  case K of
    0: Result := CRed;
    1: Result := CCyan;
    2: Result := CGreen;
  else
    Result := CViolet;
  end;
end;

function MsNowD: Double;
begin
  Result := GetTickCount64;
end;

{ TMainForm }

procedure TMainForm.FormCreate(Sender: TObject);
var
  Ini: TIniFile;
begin
  FBmp := TBGRABitmap.Create(1, 1);
  Ini := TIniFile.Create(IniName);
  try
    EditUrl.Text := Ini.ReadString('Influx', 'Url', 'http://127.0.0.1:8086');
    EditDb.Text := Ini.ReadString('Influx', 'Database', DEFAULT_DB);
  finally
    Ini.Free;
  end;
  FLastFrame := MsNowD;
  FSnapFile := Application.GetOptionValue('snapshot');
  FSnapAt := GetTickCount64 + Round(1000 * StrToFloatDef(Application.GetOptionValue('after'), 5, DotFS));
  FStartCmd := Application.GetOptionValue('cmd');
  FStartSpeed := Application.GetOptionValue('speed');
  if Application.HasOption('connect') or (FSnapFile <> '') or (FStartCmd <> '') then Connect;
  if FStartCmd <> '' then FData.Command('cmd', FStartCmd, True);
  if FStartSpeed <> '' then FData.Command('speed_sp', FStartSpeed, False);
end;

procedure TMainForm.FormDestroy(Sender: TObject);
var
  Ini: TIniFile;
begin
  Timer1.Enabled := False;
  FreeAndNil(FData);
  FBmp.Free;
  Ini := TIniFile.Create(IniName);
  try
    Ini.WriteString('Influx', 'Url', EditUrl.Text);
    Ini.WriteString('Influx', 'Database', EditDb.Text);
  finally
    Ini.Free;
  end;
end;

function TMainForm.IniName: string;
begin
  Result := ChangeFileExt(Application.ExeName, '.ini');
end;

procedure TMainForm.Connect;
begin
  FreeAndNil(FData);
  FData := THmiData.Create(InfluxConn(EditUrl.Text), Trim(EditDb.Text));
  ButtonConnect.Caption := 'Reconnect';
end;

procedure TMainForm.ButtonConnectClick(Sender: TObject);
begin
  Connect;
end;

procedure TMainForm.Timer1Timer(Sender: TObject);
var
  T, Dt: Double;
  K: Integer;
  Live: array[0..2] of Double;
begin
  T := MsNowD;
  Dt := EnsureRange((T - FLastFrame) / 1000, 0, 0.2);
  FLastFrame := T;
  FBlink := (GetTickCount64 div 500) mod 2 = 0;
  if FData <> nil then FSnap := FData.Snapshot;
  { animation: the conveyor moves at the reported speed, the level eases }
  if FSnap.Live.Valid then
  begin
    FPhase := FPhase + FSnap.Live.Speed / 60 * Dt;
    FLevelShow := FLevelShow + (FSnap.Live.Level - FLevelShow) * Min(1, Dt * 4);
    Live[0] := FSnap.Live.SpeedSp;
    Live[1] := FSnap.Live.FillSp;
    Live[2] := FSnap.Live.TempSp;
    for K := 0 to 2 do                         // a setpoint is confirmed when the machine shows it
      if FPend[K].Active and ((Abs(Live[K] - FPend[K].Value) < 0.05) or (GetTickCount64 > FPend[K].Until_)) then
        FPend[K].Active := False;
  end;
  PaintHmi.Invalidate;
  if (FSnapFile <> '') and (GetTickCount64 >= FSnapAt) then
  begin
    RenderFrame;
    FBmp.SaveToFile(FSnapFile);
    FSnapFile := '';
    Close;
  end;
end;

{ ---- coordinates and primitives ---- }

function TMainForm.PX(V: Single): Single;
begin
  Result := FOX + V * FS;
end;

function TMainForm.PY(V: Single): Single;
begin
  Result := FOY + V * FS;
end;

function TMainForm.PS(V: Single): Single;
begin
  Result := V * FS;
end;

procedure TMainForm.Txt(X, Y: Single; const S: string; Size: Single; C: TBGRAPixel;
  AAlign: TAlignment; Bold: Boolean);
begin
  FBmp.FontHeight := Max(Round(PS(Size)), 6);
  if Bold then FBmp.FontStyle := [fsBold] else FBmp.FontStyle := [];
  FBmp.TextOut(PX(X), PY(Y), S, C, AAlign);
end;

procedure TMainForm.Panel(X, Y, W, H: Single; const Title: string);
begin
  FBmp.FillRoundRectAntialias(PX(X), PY(Y), PX(X + W), PY(Y + H), PS(10), PS(10), CPanel);
  FBmp.RoundRectAntialias(PX(X), PY(Y), PX(X + W), PY(Y + H), PS(10), PS(10), CGrid, PS(1));
  if Title <> '' then
    Txt(X + 14, Y + 8, Title, 15, CDim, taLeftJustify, True);
end;

procedure TMainForm.Button(X, Y, W, H: Single; const ACaption, Id: string; Base: TBGRAPixel;
  AEnabled: Boolean);
var
  C, TopC: TBGRAPixel;
  N: Integer;
begin
  C := Base;
  if not AEnabled then C := BGRA(70, 78, 92)
  else if (FPressed = Id) and (GetTickCount64 < FPressedUntil) then C := BGRA(255, 255, 255)
  else if FHover = Id then C := BGRA(Min(255, Base.red + 30), Min(255, Base.green + 30), Min(255, Base.blue + 30));
  TopC := BGRA(Min(255, C.red + 40), Min(255, C.green + 40), Min(255, C.blue + 40));
  FBmp.GradientFill(Round(PX(X)), Round(PY(Y)), Round(PX(X + W)), Round(PY(Y + H)), TopC, C, gtLinear,
    PointF(0, PY(Y)), PointF(0, PY(Y + H)), dmDrawWithTransparency);
  FBmp.RoundRectAntialias(PX(X), PY(Y), PX(X + W), PY(Y + H), PS(6), PS(6), BGRA(0, 0, 0, 120), PS(1.5));
  if AEnabled then
    Txt(X + W / 2, Y + H / 2 - 9, ACaption, 16, BGRA(15, 20, 28), taCenter, True)
  else
    Txt(X + W / 2, Y + H / 2 - 9, ACaption, 16, CDim, taCenter, True);
  N := Length(FButtons);
  SetLength(FButtons, N + 1);
  FButtons[N].R := RectF(PX(X), PY(Y), PX(X + W), PY(Y + H));
  FButtons[N].Id := Id;
  FButtons[N].Enabled := AEnabled;
end;

{ 270 degree gauge; Sp = NaN without a setpoint marker }
procedure TMainForm.Gauge(CX, CY, R, V, VMin, VMax, Sp: Single; const ACaption, Units: string;
  Digits: Integer; C: TBGRAPixel);
const
  A0 = 0.75 * Pi;                       // start angle (screen: y down)
  SWEEP = 1.5 * Pi;
var
  Pts: array of TPointF;
  I, N: Integer;
  F, A: Single;

  function At(Ang, Rad: Single): TPointF;
  begin
    Result := PointF(PX(CX) + Cos(Ang) * PS(Rad), PY(CY) + Sin(Ang) * PS(Rad));
  end;

  procedure ArcTo(F0, F1: Single; Col: TBGRAPixel; Wd: Single);
  var
    J: Integer;
  begin
    N := Max(2, Round(60 * (F1 - F0)) + 2);
    SetLength(Pts, N);
    for J := 0 to N - 1 do
      Pts[J] := At(A0 + SWEEP * (F0 + (F1 - F0) * J / (N - 1)), R);
    FBmp.DrawPolyLineAntialias(Pts, Col, PS(Wd));
  end;

begin
  FBmp.LineCap := pecRound;
  ArcTo(0, 1, CPanel2, 14);
  F := EnsureRange((V - VMin) / Max(VMax - VMin, 1e-9), 0, 1);
  if F > 0.001 then ArcTo(0, F, C, 14);
  for I := 0 to 10 do                   // ticks
  begin
    A := A0 + SWEEP * I / 10;
    FBmp.DrawLineAntialias(At(A, R + 11).X, At(A, R + 11).Y, At(A, R + 17).X, At(A, R + 17).Y, CDim, PS(1.5));
  end;
  if not IsNan(Sp) then                 // setpoint marker
  begin
    A := A0 + SWEEP * EnsureRange((Sp - VMin) / Max(VMax - VMin, 1e-9), 0, 1);
    FBmp.DrawLineAntialias(At(A, R - 12).X, At(A, R - 12).Y, At(A, R + 12).X, At(A, R + 12).Y,
      BGRA(255, 255, 255), PS(3));
  end;
  Txt(CX, CY - 22, FloatTxt(V, Digits), 30, CText, taCenter, True);
  Txt(CX, CY + 12, Units, 13, CDim, taCenter);
  Txt(CX, CY + R - 4, ACaption, 14, CText, taCenter, True);
  if not IsNan(Sp) then
    Txt(CX, CY + 30, 'SP ' + FloatTxt(Sp, Digits), 13, CDim, taCenter);
end;

procedure TMainForm.Bar(X, Y, W, H, V, VMin, VMax: Single; const ACaption, Units: string; C: TBGRAPixel);
var
  F: Single;
begin
  F := EnsureRange((V - VMin) / Max(VMax - VMin, 1e-9), 0, 1);
  Txt(X, Y, ACaption, 13, CDim);
  Txt(X + W, Y, FloatTxt(V, 1) + ' ' + Units, 13, CText, taRightJustify, True);
  FBmp.FillRoundRectAntialias(PX(X), PY(Y + 20), PX(X + W), PY(Y + 20 + H), PS(4), PS(4), CPanel2);
  if F > 0 then
    FBmp.FillRoundRectAntialias(PX(X), PY(Y + 20), PX(X + W * F), PY(Y + 20 + H), PS(4), PS(4), C);
end;

procedure TMainForm.Tile(X, Y, W, H: Single; const ACaption, Value: string; C: TBGRAPixel);
begin
  FBmp.FillRoundRectAntialias(PX(X), PY(Y), PX(X + W), PY(Y + H), PS(8), PS(8), CPanel2);
  FBmp.FillRectAntialias(PX(X), PY(Y + 8), PX(X + 4), PY(Y + H - 8), C);
  Txt(X + 14, Y + 8, ACaption, 12, CDim);
  Txt(X + 14, Y + 26, Value, 24, CText, taLeftJustify, True);
end;

{ ---- the process picture ---- }

procedure TMainForm.DrawProcess(X, Y, W, H: Single);
var
  D: TMachineData;
  TX, TY, TW, TH, LvY, BeltY, NozX, Bx, Fill: Single;
  I, K: Integer;
  Liquid, Glass: TBGRAPixel;
  Off: Double;
  Running: Boolean;
begin
  Panel(X, Y, W, H, 'Process');
  D := FSnap.Live;
  Running := D.Valid and (D.Speed > 0.5);
  Liquid := BGRA(255, 176, 59);                 // juice
  { tank }
  TX := X + 40; TY := Y + 96; TW := 150; TH := 196;
  FBmp.FillRoundRectAntialias(PX(TX), PY(TY), PX(TX + TW), PY(TY + TH), PS(18), PS(18), CPanel2);
  LvY := TY + TH - TH * EnsureRange(FLevelShow, 0, 100) / 100;
  if FLevelShow > 0.5 then
  begin
    FBmp.ClipRect := Rect(Round(PX(TX)), Round(PY(LvY)), Round(PX(TX + TW)), Round(PY(TY + TH)));
    FBmp.FillRoundRectAntialias(PX(TX), PY(TY), PX(TX + TW), PY(TY + TH), PS(18), PS(18), Liquid);
    FBmp.FillRectAntialias(PX(TX), PY(LvY), PX(TX + TW), PY(LvY + 6), BGRA(255, 220, 140, 180));
    FBmp.NoClip;
  end;
  FBmp.RoundRectAntialias(PX(TX), PY(TY), PX(TX + TW), PY(TY + TH), PS(18), PS(18), BGRA(190, 200, 215), PS(3));
  Txt(TX + TW / 2 + 1.5, TY + TH / 2 - 14.5, FloatTxt(D.Level, 1) + ' %', 26, BGRA(0, 0, 0, 150), taCenter, True);
  Txt(TX + TW / 2, TY + TH / 2 - 16, FloatTxt(D.Level, 1) + ' %', 26, CText, taCenter, True);
  Txt(TX + TW / 2 + 1, TY + TH / 2 + 15, FloatTxt(D.Temp, 1) + ' C', 16, BGRA(0, 0, 0, 150), taCenter, True);
  Txt(TX + TW / 2, TY + TH + 8, 'Tank 500 L', 13, CDim, taCenter);
  { heater coil at the bottom }
  for I := 0 to 4 do
    if D.Heater then
      FBmp.FillRoundRectAntialias(PX(TX + 20 + I * 24), PY(TY + TH - 26), PX(TX + 36 + I * 24),
        PY(TY + TH - 14), PS(4), PS(4), BGRA(255, 60, 40, IfThen(FBlink, 255, 190)))
    else
      FBmp.FillRoundRectAntialias(PX(TX + 20 + I * 24), PY(TY + TH - 26), PX(TX + 36 + I * 24),
        PY(TY + TH - 14), PS(4), PS(4), BGRA(90, 90, 100));
  Txt(TX + TW / 2, TY + TH / 2 + 14, FloatTxt(D.Temp, 1) + ' C', 16, CText, taCenter, True);
  if D.Heater then Txt(TX + TW / 2, TY + TH - 48, 'heater on', 12, BGRA(255, 225, 220), taCenter, True)
  else Txt(TX + TW / 2, TY + TH - 48, 'heater off', 12, CText, taCenter);
  { inlet pipe + valve (bow tie) }
  FBmp.DrawLineAntialias(PX(TX - 40), PY(TY - 30), PX(TX + 40), PY(TY - 30), BGRA(150, 160, 175), PS(10));
  FBmp.DrawLineAntialias(PX(TX + 40), PY(TY - 30), PX(TX + 40), PY(TY + 4), BGRA(150, 160, 175), PS(10));
  if D.Inlet then
  begin
    FBmp.FillPolyAntialias([PointF(PX(TX - 12), PY(TY - 44)), PointF(PX(TX + 4), PY(TY - 30)),
      PointF(PX(TX - 12), PY(TY - 16))], CGreen);
    FBmp.FillPolyAntialias([PointF(PX(TX + 20), PY(TY - 44)), PointF(PX(TX + 4), PY(TY - 30)),
      PointF(PX(TX + 20), PY(TY - 16))], CGreen);
    for I := 0 to 3 do                           // drops into the tank
      FBmp.FillEllipseAntialias(PX(TX + 40), PY(TY + 10 + Frac(FPhase / 2 + I / 4) * 40), PS(3), PS(4), Liquid);
    Txt(TX + 54, TY - 40, 'inlet OPEN', 12, CGreen, taLeftJustify, True);
  end
  else
  begin
    FBmp.FillPolyAntialias([PointF(PX(TX - 12), PY(TY - 44)), PointF(PX(TX + 4), PY(TY - 30)),
      PointF(PX(TX - 12), PY(TY - 16))], BGRA(110, 115, 125));
    FBmp.FillPolyAntialias([PointF(PX(TX + 20), PY(TY - 44)), PointF(PX(TX + 4), PY(TY - 30)),
      PointF(PX(TX + 20), PY(TY - 16))], BGRA(110, 115, 125));
    Txt(TX + 54, TY - 40, 'inlet closed', 12, CDim);
  end;
  { pipe tank -> filler, above the bottles }
  NozX := X + 470;
  BeltY := Y + H - 60;
  FBmp.DrawLineAntialias(PX(TX + TW), PY(TY + 50), PX(NozX), PY(TY + 50), BGRA(150, 160, 175), PS(10));
  FBmp.DrawLineAntialias(PX(NozX), PY(TY + 50), PX(NozX), PY(BeltY - 120), BGRA(150, 160, 175), PS(10));
  FBmp.FillRoundRectAntialias(PX(NozX - 26), PY(BeltY - 130), PX(NozX + 26), PY(BeltY - 96), PS(6), PS(6), BGRA(170, 180, 195));
  FBmp.FillPolyAntialias([PointF(PX(NozX - 10), PY(BeltY - 96)), PointF(PX(NozX + 10), PY(BeltY - 96)),
    PointF(PX(NozX + 4), PY(BeltY - 82)), PointF(PX(NozX - 4), PY(BeltY - 82))], BGRA(170, 180, 195));
  Txt(NozX + 34, BeltY - 128, 'Filler  ' + FloatTxt(D.FillSp, 0) + ' ml', 13, CText);
  { conveyor }
  FBmp.FillRoundRectAntialias(PX(X + 230), PY(BeltY), PX(X + W - 20), PY(BeltY + 14), PS(7), PS(7), BGRA(60, 66, 78));
  for I := 0 to 18 do                           // rollers turn with the belt
  begin
    Bx := X + 238 + I * 30;
    if Bx > X + W - 28 then Break;
    FBmp.FillEllipseAntialias(PX(Bx), PY(BeltY + 7), PS(5), PS(5), BGRA(120, 128, 142));
    FBmp.DrawLineAntialias(PX(Bx), PY(BeltY + 7), PX(Bx + Cos(FPhase * 6 + I) * 4), PY(BeltY + 7 + Sin(FPhase * 6 + I) * 4),
      BGRA(40, 44, 52), PS(1.5));
  end;
  { bottles, 70 apart, moving right; filled after the nozzle }
  Off := Frac(FPhase) * 70;
  Glass := BGRA(200, 230, 255, 200);
  for K := -1 to 8 do
  begin
    Bx := X + 240 + K * 70 + Off;
    if (Bx < X + 232) or (Bx > X + W - 50) then Continue;
    if Bx + 14 < NozX - 6 then Fill := 0
    else if Bx + 14 > NozX + 30 then Fill := 0.75
    else Fill := 0.75 * (Bx + 14 - NozX + 6) / 36;  // under the nozzle: filling
    FBmp.FillRoundRectAntialias(PX(Bx), PY(BeltY - 62), PX(Bx + 28), PY(BeltY), PS(6), PS(6), BGRA(200, 230, 255, 60));
    if Fill > 0 then
      FBmp.FillRoundRectAntialias(PX(Bx + 2), PY(BeltY - 62 * Fill), PX(Bx + 26), PY(BeltY - 2), PS(5), PS(5), Liquid);
    FBmp.RoundRectAntialias(PX(Bx), PY(BeltY - 62), PX(Bx + 28), PY(BeltY), PS(6), PS(6), Glass, PS(1.5));
    FBmp.FillRectAntialias(PX(Bx + 9), PY(BeltY - 76), PX(Bx + 19), PY(BeltY - 62), Glass);
  end;
  if Running then                               // the stream
    FBmp.FillRectAntialias(PX(NozX - 2), PY(BeltY - 82), PX(NozX + 2), PY(BeltY - 40), Liquid);
  Txt(X + 240, BeltY + 22, Format('conveyor %s bottles/min   last fill %s ml', [FloatTxt(D.Speed, 0),
    FloatTxt(D.FillLast, 1)]), 13, CDim);
end;

{ ---- trend: 4 signals, each on its own scale (0..100 % of its range) ---- }

procedure TMainForm.DrawTrend(X, Y, W, H: Single);
var
  Tr: TTrend;
  K, I, N: Integer;
  GX, GY, GW, GH, T0, T1, Fx: Double;
  Pts: array of TPointF;
  V: Double;
  Last: string;
begin
  Panel(X, Y, W, H, Format('Trend  last %d min  (from InfluxDB, 10 s means)', [TREND_MINUTES]));
  Tr := FSnap.Trend;
  GX := X + 20; GY := Y + 80; GW := W - 40; GH := H - 120;
  for I := 0 to 4 do
    FBmp.DrawLineAntialias(PX(GX), PY(GY + GH * I / 4), PX(GX + GW), PY(GY + GH * I / 4), CGrid, PS(1));
  for I := 0 to TREND_MINUTES do
  begin
    Fx := GX + GW * I / TREND_MINUTES;
    FBmp.DrawLineAntialias(PX(Fx), PY(GY), PX(Fx), PY(GY + GH), BGRA(CGrid.red, CGrid.green, CGrid.blue, 90), PS(1));
    if I mod 2 = 0 then
      Txt(Fx, GY + GH + 6, '-' + IntToStr(TREND_MINUTES - I) + ' min', 11, CDim, taCenter);
  end;
  T1 := UtcMs;
  T0 := T1 - TREND_MINUTES * 60000.0;
  FBmp.LineCap := pecRound;
  FBmp.JoinStyle := pjsRound;
  for K := 0 to TREND_SERIES - 1 do
  begin
    N := 0;
    SetLength(Pts, Length(Tr.Times));
    Last := '';
    for I := 0 to High(Tr.Times) do
    begin
      V := Tr.Vals[K][I];
      if IsNan(V) or (Tr.Times[I] < T0) then Continue;
      Pts[N] := PointF(PX(GX + GW * (Tr.Times[I] - T0) / (T1 - T0)),
        PY(GY + GH - GH * EnsureRange((V - TREND_MIN[K]) / (TREND_MAX[K] - TREND_MIN[K]), 0, 1)));
      Inc(N);
      Last := FloatTxt(V, 1);
    end;
    SetLength(Pts, N);
    if N > 1 then FBmp.DrawPolyLineAntialias(Pts, TrendColor(K), PS(2.2));
    { legend: name, range, last value }
    FBmp.FillRectAntialias(PX(X + 20 + (K mod 2) * 270), PY(Y + 38 + (K div 2) * 18),
      PX(X + 34 + (K mod 2) * 270), PY(Y + 50 + (K div 2) * 18), TrendColor(K));
    Txt(X + 40 + (K mod 2) * 270, Y + 34 + (K div 2) * 18, Format('%s %s', [TREND_NAMES[K], Last]), 12, CText);
  end;
  if Length(Tr.Times) = 0 then
    Txt(GX + GW / 2, GY + GH / 2 - 10, 'no data in the last 10 min', 16, CDim, taCenter);
end;

{ ---- controls ---- }

function TMainForm.SpValue(Idx: Integer; Live: Double): Double;
begin
  if FPend[Idx].Active then Result := FPend[Idx].Value else Result := Live;
end;

procedure TMainForm.SetpointRow(Y, X, W: Single; Idx: Integer; const ACaption, Units: string;
  Live, Step, VMin, VMax: Double; Digits: Integer);
var
  V: Double;
  S: string;
  Ok: Boolean;
begin
  Ok := FSnap.Live.Valid;
  V := SpValue(Idx, Live);
  Txt(X, Y + 8, ACaption, 14, CText);
  Button(X + W - 190, Y, 44, 36, '-', SP_FIELDS[Idx] + '-', BGRA(120, 170, 230), Ok and (V > VMin));
  S := FloatTxt(V, Digits) + ' ' + Units;
  if FPend[Idx].Active then S := S + ' ...';      // sent, the machine has not taken it yet
  Txt(X + W - 98, Y + 7, S, 16, CText, taCenter, True);
  Button(X + W - 44, Y, 44, 36, '+', SP_FIELDS[Idx] + '+', BGRA(120, 170, 230), Ok and (V < VMax));
end;

procedure TMainForm.DrawControls(X, Y, W, H: Single);
var
  D: TMachineData;
  Ok: Boolean;
begin
  Panel(X, Y, W, H, 'Operation');
  D := FSnap.Live;
  Ok := D.Valid;
  Button(X + 16, Y + 40, 96, 48, 'START', 'start', BGRA(60, 200, 110), Ok and (D.State = 'STOPPED'));
  Button(X + 118, Y + 40, 96, 48, 'STOP', 'stop', BGRA(230, 230, 235), Ok and D.Running);
  Button(X + 220, Y + 40, 96, 48, 'RESET', 'reset', BGRA(255, 180, 60), Ok and (D.State = 'FAULT'));
  SetpointRow(Y + 104, X + 16, W - 32, 0, 'Speed', 'b/min', D.SpeedSp, 10, 0, SPEED_MAX, 0);
  SetpointRow(Y + 148, X + 16, W - 32, 1, 'Fill volume', 'ml', D.FillSp, 50, FILL_MIN, FILL_MAX, 0);
  SetpointRow(Y + 192, X + 16, W - 32, 2, 'Temperature', 'C', D.TempSp, 1, TEMP_MIN, TEMP_MAX, 0);
  Button(X + 16, Y + 238, 160, 30, 'clear counters', 'clear', BGRA(150, 160, 180), Ok);
end;

procedure TMainForm.DrawEvents(X, Y, W, H: Single);
const
  CHARS = 38;                           // per line in the panel
var
  I, Line, P: Integer;
  C: TBGRAPixel;
  E: TMachineEvent;
  T: TDateTime;
  S: string;
begin
  Panel(X, Y, W, H, 'Events');
  Line := 0;
  for I := 0 to High(FSnap.Events) do
  begin
    if Y + 36 + Line * 22 > Y + H - 24 then Break;
    E := FSnap.Events[I];
    if E.Level = 'alarm' then C := CRed else if E.Level = 'warn' then C := CAmber else C := CText;
    T := UniversalTimeToLocal(UnixDateDelta + E.TimeMs / Double(86400000));
    Txt(X + 16, Y + 36 + Line * 22, FormatDateTime('hh:nn:ss', T), 12, CDim);
    S := E.Text;
    while S <> '' do                    // long texts wrap at a space
    begin
      P := Length(S);
      if P > CHARS then
      begin
        P := CHARS;
        while (P > 10) and (S[P] <> ' ') do Dec(P);
      end;
      Txt(X + 80, Y + 36 + Line * 22, Trim(Copy(S, 1, P)), 12, C);
      Delete(S, 1, P);
      Inc(Line);
    end;
  end;
  if Length(FSnap.Events) = 0 then Txt(X + 16, Y + 36, 'no events', 12, CDim);
end;

{ ---- the whole screen ---- }

procedure TMainForm.RenderFrame;
var
  D: TMachineData;
  StateC: TBGRAPixel;
  S, Conn: string;
begin
  if (FBmp.Width <> PaintHmi.Width) or (FBmp.Height <> PaintHmi.Height) then
    FBmp.SetSize(Max(PaintHmi.Width, 1), Max(PaintHmi.Height, 1));
  FS := Min(FBmp.Width / DW, FBmp.Height / DH);
  FOX := (FBmp.Width - DW * FS) / 2;
  FOY := (FBmp.Height - DH * FS) / 2;
  FBmp.FontQuality := fqFineAntialiasing;
  FBmp.Fill(CBack);
  SetLength(FButtons, 0);
  D := FSnap.Live;

  { header }
  FBmp.GradientFill(0, 0, FBmp.Width, Round(PY(56)), BGRA(30, 38, 54), CBack, gtLinear,
    PointF(0, 0), PointF(0, PY(56)), dmSet);
  Txt(20, 12, 'Filling line 1', 26, CText, taLeftJustify, True);
  Txt(220, 20, 'machine ' + MACHINE_ID + ' - data and commands through InfluxDB', 13, CDim);
  if FData = nil then
  begin
    S := 'NOT CONNECTED';
    StateC := BGRA(110, 115, 125);
  end
  else if not D.Valid or (FSnap.LiveAgeMs > 3000) then
  begin
    S := 'NO DATA';
    StateC := BGRA(150, 90, 200);
  end
  else
  begin
    S := D.State;
    if S = 'RUNNING' then StateC := CGreen
    else if S = 'FAULT' then
    begin
      if FBlink then StateC := CRed else StateC := BGRA(120, 30, 30);
      S := 'FAULT: ' + D.Fault;
    end
    else if (S = 'STARTING') or (S = 'STOPPING') then StateC := CAmber
    else StateC := BGRA(120, 140, 170);
  end;
  FBmp.FillRoundRectAntialias(PX(760), PY(12), PX(1010), PY(46), PS(17), PS(17), StateC);
  Txt(885, 18, S, 17, BGRA(15, 20, 28), taCenter, True);
  if FData = nil then Conn := 'press Connect'
  else if FSnap.Connected then
    Conn := Format('InfluxDB ok  %.0f ms   data %.1f s old', [FSnap.QueryMs, Max(FSnap.LiveAgeMs, 0) / 1000])
  else
    Conn := 'InfluxDB: ' + Copy(FSnap.Error, 1, 40);
  if FSnap.Connected then FBmp.FillEllipseAntialias(PX(1030), PY(29), PS(6), PS(6), CGreen)
  else FBmp.FillEllipseAntialias(PX(1030), PY(29), PS(6), PS(6), CRed);
  Txt(1042, 14, FormatDateTime('hh:nn:ss', Now), 15, CText, taLeftJustify, True);
  Txt(1042, 34, Conn, 11, CDim);

  { panels }
  DrawProcess(16, 70, 800, 360);
  Panel(830, 70, 434, 360, 'Machine');
  Gauge(940, 200, 78, D.Speed, 0, SPEED_MAX, D.SpeedSp, 'Speed', 'bottles/min', 0, CGreen);
  Gauge(1150, 200, 78, D.Temp, TEMP_MIN, TEMP_MAX, D.TempSp, 'Temperature', 'C', 1, CRed);
  Bar(856, 312, 180, 10, D.Level, 0, 100, 'Tank level', '%', CCyan);
  Bar(1062, 312, 180, 10, D.Power, 0, 12, 'Power', 'kW', CViolet);
  Tile(856, 356, 92, 64, 'Good', IntToStr(D.Good), CGreen);
  Tile(956, 356, 92, 64, 'Reject', IntToStr(D.Reject), CRed);
  Tile(1056, 356, 92, 64, 'Quality', FloatTxt(QualityPct(D), 1) + '%', CBlue);
  Tile(1156, 356, 92, 64, 'Fill', FloatTxt(D.FillLast, 0), CAmber);
  DrawTrend(16, 444, 560, 300);
  DrawControls(590, 444, 330, 300);
  DrawEvents(934, 444, 330, 300);
end;

procedure TMainForm.PaintHmiPaint(Sender: TObject);
begin
  RenderFrame;
  FBmp.Draw(PaintHmi.Canvas, 0, 0, True);
end;

{ ---- mouse ---- }

procedure TMainForm.PaintHmiMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
var
  B: THmiButton;
begin
  FHover := '';
  for B in FButtons do
    if B.Enabled and (X >= B.R.Left) and (X <= B.R.Right) and (Y >= B.R.Top) and (Y <= B.R.Bottom) then
      FHover := B.Id;
  if FHover <> '' then PaintHmi.Cursor := crHandPoint else PaintHmi.Cursor := crDefault;
end;

procedure TMainForm.PaintHmiMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  B: THmiButton;
begin
  for B in FButtons do
    if B.Enabled and (X >= B.R.Left) and (X <= B.R.Right) and (Y >= B.R.Top) and (Y <= B.R.Bottom) then
    begin
      FPressed := B.Id;
      FPressedUntil := GetTickCount64 + 150;
      Act(B.Id);
      Exit;
    end;
end;

procedure TMainForm.Act(const Id: string);
const
  STEPS: array[0..2] of Double = (10, 50, 1);
  MINS: array[0..2] of Double = (0, FILL_MIN, TEMP_MIN);
  MAXS: array[0..2] of Double = (SPEED_MAX, FILL_MAX, TEMP_MAX);
var
  K: Integer;
  Live, V: Double;
begin
  if FData = nil then Exit;
  if (Id = 'start') or (Id = 'stop') or (Id = 'reset') or (Id = 'clear') then
  begin
    FData.Command('cmd', Id, True);
    Exit;
  end;
  for K := 0 to 2 do
    if (Id = SP_FIELDS[K] + '-') or (Id = SP_FIELDS[K] + '+') then
    begin
      case K of
        0: Live := FSnap.Live.SpeedSp;
        1: Live := FSnap.Live.FillSp;
      else
        Live := FSnap.Live.TempSp;
      end;
      V := SpValue(K, Live);
      if Id[Length(Id)] = '+' then V := V + STEPS[K] else V := V - STEPS[K];
      V := EnsureRange(V, MINS[K], MAXS[K]);
      FPend[K].Active := True;                     // shown at once, confirmed by the machine
      FPend[K].Value := V;
      FPend[K].Until_ := GetTickCount64 + 3000;
      FData.Command(SP_FIELDS[K], FloatTxt(V, 1), False);
    end;
end;

initialization
  CBack := BGRA(14, 18, 26);
  CPanel := BGRA(24, 30, 42);
  CPanel2 := BGRA(36, 44, 60);
  CText := BGRA(230, 236, 245);
  CDim := BGRA(140, 152, 172);
  CGrid := BGRA(52, 62, 82);
  CGreen := BGRA(70, 210, 120);
  CRed := BGRA(255, 95, 85);
  CAmber := BGRA(255, 185, 60);
  CBlue := BGRA(90, 160, 255);
  CCyan := BGRA(60, 200, 230);
  CViolet := BGRA(180, 130, 255);
end.

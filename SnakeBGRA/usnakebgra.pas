{ ============================================================================
  Snake Arena (BGRABitmap) - game client for the MQTT Snake Arena server,
  drawn with BGRABitmap. With -dIPC (../IpcGame/IpcSnakeBGRA.lpi) it plays
  over IPC instead (../IpcGame/ipcsnakeclient). Same game side as SnakeLCL (../MqttGame/snakeclient),
  only the drawing is different:
    - smooth movement: every frame (60 / s) the snakes are placed between the
      last two server states, so a 10 Hz game still moves smoothly
    - antialiased round snakes with shading and eyes, glowing pulsing food,
      a burst of particles when a snake dies, translucent scoreboard
    - the static background (gradient, arena, grid dots) is drawn once per size
    - arrows or W A S D to steer, Enter = respawn now
    - settings in SnakeBGRA.ini next to the exe
    - command line: --connect, --snapshot=<file.png> --after=<s> (one frame, then exit)
  ============================================================================ }
unit usnakebgra;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, ExtCtrls, StdCtrls, ColorBox, LCLType,
  IniFiles, Math, BGRABitmap, BGRABitmapTypes, snakeproto, {$IFDEF IPC} ipcsnakeclient {$ELSE} snakeclient {$ENDIF};

type
  TParticle = record
    X, Y, VX, VY: Single;         // pixels, pixels per second
    Life: Single;                 // s left
    Color: TBGRAPixel;
  end;

  TNameTag = record
    Pt: TPointF;                  // head
    Name: string;
  end;

  { TMainForm }

  TMainForm = class(TForm)
    ButtonConnect: TButton;
    ButtonJoin: TButton;
    ColorSnake: TColorBox;
    EditHost: TEdit;
    EditName: TEdit;
    EditPort: TEdit;
    LabelHelp: TLabel;
    LabelHost: TLabel;
    LabelName: TLabel;
    LabelPort: TLabel;
    LabelState: TLabel;
    MemoEvents: TMemo;
    PaintArena: TPaintBox;
    PanelRight: TPanel;
    PanelTop: TPanel;
    Timer1: TTimer;
    procedure ButtonConnectClick(Sender: TObject);
    procedure ButtonJoinClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure PaintArenaMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer);
    procedure PaintArenaPaint(Sender: TObject);
    procedure Timer1Timer(Sender: TObject);
  private
    FConn: TSnakeConn;
    FBmp, FBack: TBGRABitmap;
    FBackKey: string;             // size the background was drawn for
    FParticles: array of TParticle;
    FLastFrame: Double;
    FFrames, FFps: Integer;
    FFpsTime: Double;
    FCS, FOX, FOY: Single;        // cell size and arena origin in pixels
    FSnapFile: string;            // --snapshot=<file.png>: one frame to a file, then exit
    FSnapAt: Double;
    procedure RenderFrame;
    procedure UpdateControls;
    procedure LoadIni;
    procedure SaveIni;
    function IniName: string;
    procedure DrawBackground(const S: TGameState);
    procedure Explode(const P: TSnakeInfo);
    procedure DrawSnake(const P: TSnakeInfo; const Pts: array of TPointF; Mine: Boolean);
    procedure DrawNames(const Tags: array of TNameTag);
    procedure DrawScoreboard(const S: TGameState);
    function CellPt(X, Y: Single): TPointF;
  end;

var
  MainForm: TMainForm;

implementation

{$R *.lfm}

function SnakePixel(C: LongWord; Alpha: Byte = 255): TBGRAPixel;
begin
  Result := BGRA((C shr 16) and $FF, (C shr 8) and $FF, C and $FF, Alpha);
end;

function Shade(C: TBGRAPixel; F: Single): TBGRAPixel;
begin
  Result := BGRA(EnsureRange(Round(C.red * F), 0, 255), EnsureRange(Round(C.green * F), 0, 255),
    EnsureRange(Round(C.blue * F), 0, 255), C.alpha);
end;

function ToRRGGBB(C: TColor): LongWord;
var
  R: LongInt;
begin
  R := ColorToRGB(C);
  Result := (LongWord(Red(R)) shl 16) or (LongWord(Green(R)) shl 8) or LongWord(Blue(R));
end;

{ TMainForm }

procedure TMainForm.FormCreate(Sender: TObject);
begin
  Randomize;
  FConn := TSnakeConn.Create;
  FBmp := TBGRABitmap.Create(1, 1);
  FBack := TBGRABitmap.Create(1, 1);
  KeyPreview := True;
  FLastFrame := MsNow;
  FFpsTime := FLastFrame;
  Caption := 'Snake Arena (BGRABitmap) - ' + TRANSPORT_NAME;   // -dIPC builds the IPC client
  LabelHost.Visible := TRANSPORT_HAS_HOST;
  EditHost.Visible := TRANSPORT_HAS_HOST;
  LabelPort.Visible := TRANSPORT_HAS_HOST;
  EditPort.Visible := TRANSPORT_HAS_HOST;
  LoadIni;
  UpdateControls;
  { command line: --connect (with the saved settings), --snapshot=<file.png> --after=<s> }
  FSnapFile := Application.GetOptionValue('snapshot');
  FSnapAt := MsNow + 1000 * StrToFloatDef(Application.GetOptionValue('after'), 5);
  if Application.HasOption('connect') or (FSnapFile <> '') then
    ButtonConnectClick(Self);
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  Timer1.Enabled := False;
  SaveIni;
  FConn.Free;
  FBmp.Free;
  FBack.Free;
end;

function TMainForm.IniName: string;
begin
  Result := ChangeFileExt(Application.ExeName, '.ini');
end;

procedure TMainForm.LoadIni;
var
  Ini: TIniFile;
  N: string;
begin
  Ini := TIniFile.Create(IniName);
  try
    EditHost.Text := Ini.ReadString('Game', 'Host', '127.0.0.1');
    EditPort.Text := IntToStr(Ini.ReadInteger('Game', 'Port', 1886));
    N := GetEnvironmentVariable('USERNAME');
    if N = '' then N := 'Player';
    EditName.Text := Ini.ReadString('Game', 'Name', N);
    ColorSnake.Selected := TColor(Ini.ReadInteger('Game', 'Color', clAqua));
  finally
    Ini.Free;
  end;
end;

procedure TMainForm.SaveIni;
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(IniName);
  try
    Ini.WriteString('Game', 'Host', EditHost.Text);
    Ini.WriteInteger('Game', 'Port', StrToIntDef(EditPort.Text, 1886));
    Ini.WriteString('Game', 'Name', EditName.Text);
    Ini.WriteInteger('Game', 'Color', ColorSnake.Selected);
  finally
    Ini.Free;
  end;
end;

procedure TMainForm.ButtonConnectClick(Sender: TObject);
var
  Port: Integer;
begin
  if FConn.Active then
  begin
    FConn.Disconnect;
    UpdateControls;
    Exit;
  end;
  if not TryStrToInt(Trim(EditPort.Text), Port) or (Port < 1) or (Port > 65535) then
  begin
    MemoEvents.Lines.Add('Invalid port: ' + EditPort.Text);
    Exit;
  end;
  if Trim(EditName.Text) = '' then
    EditName.Text := 'Player';
  FConn.Connect(Trim(EditHost.Text), Port, Trim(EditName.Text), ToRRGGBB(ColorSnake.Selected));
  SaveIni;
  UpdateControls;
  ActiveControl := nil;                          // the arrow keys steer, not the edits
end;

procedure TMainForm.ButtonJoinClick(Sender: TObject);
begin
  if Trim(EditName.Text) = '' then
    EditName.Text := 'Player';
  FConn.Join(Trim(EditName.Text), ToRRGGBB(ColorSnake.Selected));
  SaveIni;
  ActiveControl := nil;
end;

procedure TMainForm.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
var
  D: Char;
begin
  if ActiveControl is TEdit then
    Exit;                                        // typing a name or host
  case Key of
    VK_UP, VK_W: D := 'U';
    VK_DOWN, VK_S: D := 'D';
    VK_LEFT, VK_A: D := 'L';
    VK_RIGHT, VK_D: D := 'R';
    VK_RETURN:
      begin
        if FConn.Connected then ButtonJoinClick(Sender);
        Key := 0;
        Exit;
      end;
  else
    Exit;
  end;
  FConn.Turn(D);
  Key := 0;
end;

procedure TMainForm.PaintArenaMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  ActiveControl := nil;
end;

procedure TMainForm.UpdateControls;
begin
  EditHost.Enabled := not FConn.Active;
  EditPort.Enabled := not FConn.Active;
  ButtonJoin.Enabled := FConn.Connected;
  if FConn.Active then ButtonConnect.Caption := 'Disconnect' else ButtonConnect.Caption := 'Connect';
  if FConn.Connected and FConn.HasState then
    LabelState.Caption := Format('Connected   tick %d   %d snakes   %d fps', [FConn.State.Tick,
      Length(FConn.State.Snakes), FFps])
  else if FConn.Active then
    LabelState.Caption := CONNECTING_TEXT
  else
    LabelState.Caption := 'Not connected';
end;

{ a snake that was alive in the previous state and is gone now: particles }
procedure TMainForm.Explode(const P: TSnakeInfo);
var
  I, K, N: Integer;
  A, V: Single;
  Pt: TPointF;
begin
  for I := 0 to High(P.Body) do
  begin
    Pt := CellPt(P.Body[I].X + 0.5, P.Body[I].Y + 0.5);
    for K := 1 to 3 do
    begin
      if Length(FParticles) >= 1500 then Exit;
      N := Length(FParticles);
      SetLength(FParticles, N + 1);
      A := Random * 2 * Pi;
      V := 30 + Random * 120;
      FParticles[N].X := Pt.X;
      FParticles[N].Y := Pt.Y;
      FParticles[N].VX := Cos(A) * V;
      FParticles[N].VY := Sin(A) * V;
      FParticles[N].Life := 0.4 + Random * 0.5;
      FParticles[N].Color := SnakePixel(P.Color);
    end;
  end;
end;

procedure TMainForm.Timer1Timer(Sender: TObject);
var
  I, K: Integer;
  Old: TGameState;
begin
  if FConn.HasState then
    Old := FConn.State;
  if FConn.Poll and (Length(Old.Snakes) > 0) then
    for I := 0 to High(Old.Snakes) do             // snakes that just died
      if Old.Snakes[I].Alive then
      begin
        K := FindSnake(FConn.State, Old.Snakes[I].Key);
        if (K < 0) or not FConn.State.Snakes[K].Alive then
          Explode(Old.Snakes[I]);
      end;
  if FConn.Events.Count > 0 then
  begin
    for I := 0 to FConn.Events.Count - 1 do
      MemoEvents.Lines.Add(FConn.Events[I]);
    FConn.Events.Clear;
    while MemoEvents.Lines.Count > 300 do
      MemoEvents.Lines.Delete(0);
  end;
  if MsNow - FFpsTime >= 1000 then
  begin
    FFps := FFrames;
    FFrames := 0;
    FFpsTime := MsNow;
    UpdateControls;
  end;
  if (FSnapFile <> '') and (MsNow >= FSnapAt) then
  begin
    RenderFrame;
    FBmp.SaveToFile(FSnapFile);
    FSnapFile := '';
    Close;
    Exit;
  end;
  PaintArena.Invalidate;                         // every frame: the animation moves
end;

function TMainForm.CellPt(X, Y: Single): TPointF;
begin
  Result := PointF(FOX + X * FCS, FOY + Y * FCS);
end;

{ gradient, arena with rounded corners, grid dots, walls: once per size }
procedure TMainForm.DrawBackground(const S: TGameState);
var
  Key: string;
  X, Y: Integer;
  R: Single;
begin
  Key := Format('%d %d %d %d %d', [FBmp.Width, FBmp.Height, S.W, S.H, Ord(S.Wrap)]);
  if Key = FBackKey then Exit;
  FBackKey := Key;
  FBack.SetSize(FBmp.Width, FBmp.Height);
  FBack.GradientFill(0, 0, FBack.Width, FBack.Height, BGRA(22, 28, 48), BGRA(8, 10, 16), gtRadial,
    PointF(FBack.Width / 2, FBack.Height / 3), PointF(0, FBack.Height), dmSet);
  FBack.FillRoundRectAntialias(FOX - 6, FOY - 6, FOX + FCS * S.W + 6, FOY + FCS * S.H + 6, 14, 14,
    BGRA(0, 0, 0, 90));                          // shadow
  FBack.FillRoundRectAntialias(FOX - 3, FOY - 3, FOX + FCS * S.W + 3, FOY + FCS * S.H + 3, 10, 10,
    BGRA(26, 34, 52));
  R := Max(FCS * 0.06, 0.8);
  for Y := 1 to S.H - 1 do
    for X := 1 to S.W - 1 do
      FBack.FillEllipseAntialias(FOX + X * FCS, FOY + Y * FCS, R, R, BGRA(70, 86, 120, 110));
  if S.Wrap then
    FBack.RoundRectAntialias(FOX - 3, FOY - 3, FOX + FCS * S.W + 3, FOY + FCS * S.H + 3, 10, 10,
      BGRA(90, 120, 170, 60), 1)                 // no walls: a faint edge
  else
    FBack.RoundRectAntialias(FOX - 3, FOY - 3, FOX + FCS * S.W + 3, FOY + FCS * S.H + 3, 10, 10,
      BGRA(110, 150, 220), 2.5);
end;

procedure TMainForm.DrawSnake(const P: TSnakeInfo; const Pts: array of TPointF; Mine: Boolean);
var
  C: TBGRAPixel;
  Run: array of TPointF;
  I, N: Integer;
  H, Fwd, Side: TPointF;
  ER, PR: Single;

  procedure FlushRun;
  begin
    if N = 0 then Exit;
    if N = 1 then
      FBmp.FillEllipseAntialias(Run[0].X, Run[0].Y, FCS * 0.4, FCS * 0.4, C)
    else
    begin
      SetLength(Run, N);
      FBmp.DrawPolyLineAntialias(Run, Shade(C, 0.45), FCS * 0.86);   // outline
      FBmp.DrawPolyLineAntialias(Run, C, FCS * 0.72);
      FBmp.DrawPolyLineAntialias(Run, BGRA(255, 255, 255, 55), FCS * 0.22);  // shine
    end;
    N := 0;
    SetLength(Run, Length(Pts));
  end;

begin
  if Length(Pts) = 0 then Exit;
  C := SnakePixel(P.Color);
  SetLength(Run, Length(Pts));
  N := 0;
  for I := High(Pts) downto 0 do                 // tail first, the head ends on top
  begin
    { a jump of more than 1.5 cells = wrap around: a new line, no stroke across the arena }
    if (N > 0) and ((Abs(Pts[I].X - Run[N - 1].X) > FCS * 1.5) or
      (Abs(Pts[I].Y - Run[N - 1].Y) > FCS * 1.5)) then
      FlushRun;
    Run[N] := Pts[I];
    Inc(N);
  end;
  FlushRun;

  { head with eyes looking where it goes }
  H := Pts[0];
  if Mine then
    FBmp.EllipseAntialias(H.X, H.Y, FCS * 0.68, FCS * 0.68, BGRA(255, 255, 255, 200), 2);
  FBmp.FillEllipseAntialias(H.X, H.Y, FCS * 0.5, FCS * 0.5, Shade(C, 0.45));
  FBmp.FillEllipseAntialias(H.X, H.Y, FCS * 0.44, FCS * 0.44, Shade(C, 1.12));
  Fwd := PointF(DirDX(P.Dir), DirDY(P.Dir));
  Side := PointF(-Fwd.Y, Fwd.X);
  ER := FCS * 0.14;
  PR := FCS * 0.07;
  for I := -1 to 1 do
    if I <> 0 then
    begin
      FBmp.FillEllipseAntialias(H.X + (Fwd.X * 0.18 + Side.X * 0.2 * I) * FCS,
        H.Y + (Fwd.Y * 0.18 + Side.Y * 0.2 * I) * FCS, ER, ER, BGRAWhite);
      FBmp.FillEllipseAntialias(H.X + (Fwd.X * 0.24 + Side.X * 0.2 * I) * FCS,
        H.Y + (Fwd.Y * 0.24 + Side.Y * 0.2 * I) * FCS, PR, PR, BGRABlack);
    end;
end;

{ name tags after all snakes, so no body covers a name }
procedure TMainForm.DrawNames(const Tags: array of TNameTag);
var
  I: Integer;
  X, Y, HW: Single;
begin
  if FCS < 8 then Exit;
  FBmp.FontHeight := Round(EnsureRange(FCS * 0.75, 11, 18));
  FBmp.FontStyle := [];
  for I := 0 to High(Tags) do
  begin
    HW := FBmp.TextSize(Tags[I].Name).cx / 2 + 2;      // keep the whole name in the view
    X := EnsureRange(Tags[I].Pt.X, HW, Max(FBmp.Width - HW, HW));
    Y := Max(Tags[I].Pt.Y - FCS * 1.45, 0);
    FBmp.TextOut(X + 1, Y + 1, Tags[I].Name, BGRA(0, 0, 0, 160), taCenter);
    FBmp.TextOut(X, Y, Tags[I].Name, BGRA(255, 255, 255, 230), taCenter);
  end;
end;

procedure TMainForm.DrawScoreboard(const S: TGameState);
var
  Order: array of Integer;
  I, J, R, N: Integer;
  X, Y, LH: Single;
  T: string;
begin
  N := Min(Length(S.Snakes), 10);
  if N = 0 then Exit;
  SetLength(Order, Length(S.Snakes));
  for I := 0 to High(Order) do Order[I] := I;
  for I := 1 to High(Order) do                   // by score, then best
  begin
    R := Order[I];
    J := I - 1;
    while (J >= 0) and ((S.Snakes[Order[J]].Score < S.Snakes[R].Score) or
      ((S.Snakes[Order[J]].Score = S.Snakes[R].Score) and (S.Snakes[Order[J]].Best < S.Snakes[R].Best))) do
    begin
      Order[J + 1] := Order[J];
      Dec(J);
    end;
    Order[J + 1] := R;
  end;
  FBmp.FontHeight := 14;
  LH := 19;
  X := FBmp.Width - 214;
  Y := 12;
  FBmp.FillRoundRectAntialias(X, Y, X + 202, Y + 30 + N * LH, 10, 10, BGRA(10, 14, 24, 170));
  FBmp.FontStyle := [fsBold];
  FBmp.TextOut(X + 12, Y + 6, 'Score', BGRA(200, 210, 230));
  FBmp.TextOut(X + 190, Y + 6, 'best', BGRA(140, 150, 170), taRightJustify);
  FBmp.FontStyle := [];
  for I := 0 to N - 1 do
    with S.Snakes[Order[I]] do
    begin
      Y := 12 + 26 + I * LH;
      FBmp.FillEllipseAntialias(X + 18, Y + LH / 2 - 1, 5, 5, SnakePixel(Color, IfThen(Alive, 255, 90)));
      T := Name;
      if Key = FConn.Key then
      begin
        FBmp.FillRoundRectAntialias(X + 4, Y - 1, X + 198, Y + LH - 2, 5, 5, BGRA(255, 255, 255, 30));
        T := T + '  (you)';
      end;
      FBmp.TextOut(X + 30, Y, T, BGRA(230, 235, 245, IfThen(Alive, 255, 130)));
      FBmp.TextOut(X + 160, Y, IntToStr(Score), BGRA(255, 220, 120), taRightJustify);
      FBmp.TextOut(X + 190, Y, IntToStr(Best), BGRA(140, 150, 170), taRightJustify);
    end;
end;

procedure TMainForm.PaintArenaPaint(Sender: TObject);
begin
  RenderFrame;
  FBmp.Draw(PaintArena.Canvas, 0, 0, True);
end;

{ one animation frame into FBmp }
procedure TMainForm.RenderFrame;
var
  S, Prev: TGameState;
  Alpha, T, Dt, Pulse, R: Double;
  I, J, K, PK, Me: Integer;
  Pts: array of TPointF;
  Tags: array of TNameTag;
  P: TSnakeInfo;
  Fr, Tc: TCell;
  Msg: string;
begin
  T := MsNow;
  Dt := EnsureRange((T - FLastFrame) / 1000, 0, 0.1);
  FLastFrame := T;
  Inc(FFrames);
  if (FBmp.Width <> PaintArena.Width) or (FBmp.Height <> PaintArena.Height) then
    FBmp.SetSize(Max(PaintArena.Width, 1), Max(PaintArena.Height, 1));
  FBmp.FontQuality := fqFineAntialiasing;
  FBmp.LineCap := pecRound;
  FBmp.JoinStyle := pjsRound;

  if not FConn.HasState then
  begin
    FBmp.GradientFill(0, 0, FBmp.Width, FBmp.Height, BGRA(22, 28, 48), BGRA(8, 10, 16), gtLinear,
      PointF(0, 0), PointF(0, FBmp.Height), dmSet);
    FBmp.FontHeight := 26;
    FBmp.FontStyle := [fsBold];
    if FConn.Active then Msg := CONNECTING_TEXT else Msg := 'Press Connect to play';
    FBmp.TextOut(FBmp.Width / 2, FBmp.Height / 2 - 16, Msg, BGRA(220, 230, 255), taCenter);
    Exit;
  end;

  S := FConn.State;
  Prev := FConn.PrevState;
  FCS := Max(Min((FBmp.Width - 20) / S.W, (FBmp.Height - 20) / S.H), 3);
  FOX := (FBmp.Width - FCS * S.W) / 2;
  FOY := (FBmp.Height - FCS * S.H) / 2;
  DrawBackground(S);
  FBmp.PutImage(0, 0, FBack, dmSet);

  { food: glow + pulsing core + highlight }
  for I := 0 to High(S.Food) do
  begin
    Pulse := 0.5 + 0.5 * Sin(T / 160 + S.Food[I].X * 0.7 + S.Food[I].Y * 1.3);
    with CellPt(S.Food[I].X + 0.5, S.Food[I].Y + 0.5) do
    begin
      R := FCS * (0.55 + 0.2 * Pulse);
      FBmp.FillEllipseAntialias(X, Y, R, R, BGRA(255, 70, 90, 40));
      R := FCS * (0.28 + 0.05 * Pulse);
      FBmp.FillEllipseAntialias(X, Y, R, R, BGRA(255, 80, 100));
      FBmp.FillEllipseAntialias(X - R * 0.35, Y - R * 0.35, R * 0.35, R * 0.35, BGRA(255, 220, 220, 200));
    end;
  end;

  { snakes between the previous and the last state }
  if S.TickMs > 0 then
    Alpha := EnsureRange((T - FConn.StateTime) / S.TickMs, 0, 1)
  else
    Alpha := 1;
  Me := FConn.Me;
  Tags := nil;
  for J := 0 to Length(S.Snakes) do
  begin
    if J = Length(S.Snakes) then                  // ours last, on top
    begin
      if Me < 0 then Break;
      K := Me;
    end
    else if J = Me then
      Continue
    else
      K := J;
    P := S.Snakes[K];
    if not P.Alive or (Length(P.Body) = 0) then Continue;
    PK := FindSnake(Prev, P.Key);
    if (PK >= 0) and not (Prev.Snakes[PK].Alive and (Length(Prev.Snakes[PK].Body) > 0)) then
      PK := -1;                                   // just respawned: nothing to slide from
    SetLength(Pts, Length(P.Body));
    for I := 0 to High(P.Body) do
    begin
      Tc := P.Body[I];
      Fr := Tc;
      if PK >= 0 then
      begin
        { cell I moves from where cell I was in the previous state }
        Fr := Prev.Snakes[PK].Body[Min(I, High(Prev.Snakes[PK].Body))];
        if Abs(Fr.X - Tc.X) + Abs(Fr.Y - Tc.Y) > 1 then
          Fr := Tc;                               // wrap around or respawn: no sliding
      end;
      Pts[I] := CellPt(Fr.X + (Tc.X - Fr.X) * Alpha + 0.5, Fr.Y + (Tc.Y - Fr.Y) * Alpha + 0.5);
    end;
    DrawSnake(P, Pts, J = Length(S.Snakes));
    SetLength(Tags, Length(Tags) + 1);
    Tags[High(Tags)].Pt := Pts[0];
    Tags[High(Tags)].Name := P.Name;
  end;
  DrawNames(Tags);

  { particles of dead snakes }
  K := 0;
  for I := 0 to High(FParticles) do
  begin
    FParticles[I].Life := FParticles[I].Life - Dt;
    if FParticles[I].Life <= 0 then Continue;
    FParticles[I].X := FParticles[I].X + FParticles[I].VX * Dt;
    FParticles[I].Y := FParticles[I].Y + FParticles[I].VY * Dt;
    FParticles[I].VX := FParticles[I].VX * 0.94;
    FParticles[I].VY := FParticles[I].VY * 0.94;
    FParticles[I].Color.alpha := EnsureRange(Round(FParticles[I].Life * 400), 0, 255);
    FBmp.FillEllipseAntialias(FParticles[I].X, FParticles[I].Y, FCS * 0.16, FCS * 0.16,
      FParticles[I].Color);
    FParticles[K] := FParticles[I];
    Inc(K);
  end;
  SetLength(FParticles, K);

  DrawScoreboard(S);
  if Me >= 0 then
    with S.Snakes[Me] do
    begin
      FBmp.FontHeight := 18;
      FBmp.FontStyle := [fsBold];
      FBmp.TextOut(16, 12, Format('Score %d   Best %d   Kills %d', [Score, Best, Kills]),
        BGRA(255, 220, 120));
    end;
  if Me < 0 then
    Msg := 'Joining ...'
  else if not S.Snakes[Me].Alive then
    Msg := 'Respawning ...   (Enter = now)'
  else
    Msg := '';
  if Msg <> '' then
  begin
    FBmp.FontHeight := 28;
    FBmp.FontStyle := [fsBold];
    FBmp.FillRoundRectAntialias(FBmp.Width / 2 - 220, FBmp.Height / 2 - 30, FBmp.Width / 2 + 220,
      FBmp.Height / 2 + 26, 14, 14, BGRA(0, 0, 0, 140));
    FBmp.TextOut(FBmp.Width / 2, FBmp.Height / 2 - 20, Msg, BGRAWhite, taCenter);
  end;
end;

end.

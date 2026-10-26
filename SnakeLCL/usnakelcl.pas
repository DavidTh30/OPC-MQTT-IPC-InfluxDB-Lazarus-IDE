{ ============================================================================
  Snake Arena (LCL) - game client for the MQTT Snake Arena server, drawn with
  the standard LCL Canvas into a double buffer (TBitmap). The game logic and
  MQTT side are in ../MqttGame/snakeclient.pas (shared with SnakeBGRA).
  With -dIPC (../IpcGame/IpcSnakeLCL.lpi) the same window plays over IPC
  (../IpcGame/ipcsnakeclient.pas: SimpleIPC + shared memory, this PC only).
    - arrows or W A S D to steer, Enter = join again
    - scoreboard, events of the server
    - settings in SnakeLCL.ini next to the exe
    - command line: --connect, --snapshot=<file.png> --after=<s> (one frame, then exit)
  ============================================================================ }
unit usnakelcl;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, ExtCtrls, StdCtrls, ColorBox, LCLType,
  IniFiles, Math, snakeproto, {$IFDEF IPC} ipcsnakeclient {$ELSE} snakeclient {$ENDIF};

type

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
    LabelScore: TLabel;
    LabelState: TLabel;
    ListScores: TListBox;
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
    FBuffer: TBitmap;
    FLastBoard: QWord;
    FSnapFile: string;               // --snapshot=<file.png>: one frame to a file, then exit
    FSnapAt: Double;
    procedure RenderFrame;
    procedure UpdateBoard;
    procedure UpdateControls;
    procedure LoadIni;
    procedure SaveIni;
    function IniName: string;
  end;

var
  MainForm: TMainForm;

implementation

{$R *.lfm}

function SnakeColor(C: LongWord): TColor;
begin
  Result := RGBToColor((C shr 16) and $FF, (C shr 8) and $FF, C and $FF);
end;

function ToRRGGBB(C: TColor): LongWord;
var
  R: LongInt;
begin
  R := ColorToRGB(C);
  Result := (LongWord(Red(R)) shl 16) or (LongWord(Green(R)) shl 8) or LongWord(Blue(R));
end;

function Shade(C: TColor; F: Double): TColor;
var
  R: LongInt;
begin
  R := ColorToRGB(C);
  Result := RGBToColor(EnsureRange(Round(Red(R) * F), 0, 255), EnsureRange(Round(Green(R) * F), 0, 255),
    EnsureRange(Round(Blue(R) * F), 0, 255));
end;

{ TMainForm }

procedure TMainForm.FormCreate(Sender: TObject);
begin
  Randomize;
  FConn := TSnakeConn.Create;
  FBuffer := TBitmap.Create;
  KeyPreview := True;
  Caption := 'Snake Arena (LCL) - ' + TRANSPORT_NAME;   // -dIPC builds the IPC client
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
  FBuffer.Free;
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
    ColorSnake.Selected := TColor(Ini.ReadInteger('Game', 'Color', clLime));
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
    PaintArena.Invalidate;
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

procedure TMainForm.Timer1Timer(Sender: TObject);
var
  I, Me: Integer;
  Png: TPortableNetworkGraphic;
begin
  if FConn.Poll then
    PaintArena.Invalidate;
  if (FSnapFile <> '') and (MsNow >= FSnapAt) then
  begin
    RenderFrame;
    Png := TPortableNetworkGraphic.Create;
    try
      Png.Assign(FBuffer);
      Png.SaveToFile(FSnapFile);
    finally
      Png.Free;
    end;
    FSnapFile := '';
    Close;
    Exit;
  end;
  if FConn.Events.Count > 0 then
  begin
    for I := 0 to FConn.Events.Count - 1 do
      MemoEvents.Lines.Add(FConn.Events[I]);
    FConn.Events.Clear;
    while MemoEvents.Lines.Count > 300 do
      MemoEvents.Lines.Delete(0);
  end;
  if GetTickCount64 - FLastBoard >= 250 then
  begin
    FLastBoard := GetTickCount64;
    UpdateBoard;
    UpdateControls;
    Me := FConn.Me;
    if Me >= 0 then
      with FConn.State.Snakes[Me] do
        LabelScore.Caption := Format('Score %d   Best %d   Kills %d', [Score, Best, Kills])
    else
      LabelScore.Caption := '';
  end;
end;

procedure TMainForm.UpdateBoard;
var
  S: TGameState;
  Order: array of Integer;
  I, J, R: Integer;
  Line: string;
begin
  if not FConn.HasState then
  begin
    ListScores.Clear;
    Exit;
  end;
  S := FConn.State;
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
  ListScores.Items.BeginUpdate;
  try
    ListScores.Clear;
    for I := 0 to High(Order) do
      with S.Snakes[Order[I]] do
      begin
        Line := Format('%d. %s  %d  (best %d)', [I + 1, Name, Score, Best]);
        if Key = FConn.Key then Line := '> ' + Line;
        if not Alive then Line := Line + '  ...';
        ListScores.Items.Add(Line);
      end;
  finally
    ListScores.Items.EndUpdate;
  end;
end;

procedure TMainForm.UpdateControls;
begin
  EditHost.Enabled := not FConn.Active;
  EditPort.Enabled := not FConn.Active;
  ButtonJoin.Enabled := FConn.Connected;
  if FConn.Active then ButtonConnect.Caption := 'Disconnect' else ButtonConnect.Caption := 'Connect';
  if FConn.Connected and FConn.HasState then
    LabelState.Caption := Format('Connected   tick %d   %d snakes', [FConn.State.Tick,
      Length(FConn.State.Snakes)])
  else if FConn.Active then
    LabelState.Caption := CONNECTING_TEXT
  else
    LabelState.Caption := 'Not connected';
end;

procedure TMainForm.PaintArenaPaint(Sender: TObject);
begin
  RenderFrame;
  PaintArena.Canvas.Draw(0, 0, FBuffer);
end;

{ the whole arena into FBuffer (double buffer) }
procedure TMainForm.RenderFrame;
var
  C: TCanvas;
  S: TGameState;
  CS, OX, OY, I, J, X, Y, Me: Integer;
  Col: TColor;
  P: TSnakeInfo;
  Msg: string;

  procedure CellRect(CX, CY, Inset: Integer);
  begin
    C.Rectangle(OX + CX * CS + Inset, OY + CY * CS + Inset, OX + (CX + 1) * CS - Inset,
      OY + (CY + 1) * CS - Inset);
  end;

  procedure Eyes(const H: TCell; D: Char);
  var
    MX, MY, EX, EY, R: Integer;
  begin
    MX := OX + H.X * CS + CS div 2 + DirDX(D) * CS div 5;
    MY := OY + H.Y * CS + CS div 2 + DirDY(D) * CS div 5;
    EX := DirDY(D) * CS div 4;                   // across the direction
    EY := DirDX(D) * CS div 4;
    R := Max(CS div 8, 1);
    C.Brush.Color := clWhite;
    C.Pen.Color := clWhite;
    C.Ellipse(MX + EX - R, MY + EY - R, MX + EX + R + 1, MY + EY + R + 1);
    C.Ellipse(MX - EX - R, MY - EY - R, MX - EX + R + 1, MY - EY + R + 1);
  end;

  procedure CenterText(const T: string; Size: Integer);
  begin
    C.Font.Height := -Size;
    C.Font.Style := [fsBold];
    C.Font.Color := clWhite;
    C.Brush.Style := bsClear;
    C.TextOut((FBuffer.Width - C.TextWidth(T)) div 2, (FBuffer.Height - C.TextHeight(T)) div 2, T);
    C.Brush.Style := bsSolid;
  end;

begin
  FBuffer.SetSize(PaintArena.Width, PaintArena.Height);
  C := FBuffer.Canvas;
  C.Brush.Color := RGBToColor(18, 22, 30);
  C.FillRect(0, 0, FBuffer.Width, FBuffer.Height);
  if not FConn.HasState then
  begin
    if FConn.Active then CenterText(CONNECTING_TEXT, 22) else CenterText('Press Connect to play', 22);
    Exit;
  end;
  S := FConn.State;
  CS := Max(Min(FBuffer.Width div S.W, FBuffer.Height div S.H), 2);
  OX := (FBuffer.Width - CS * S.W) div 2;
  OY := (FBuffer.Height - CS * S.H) div 2;

  { arena, grid, walls }
  C.Pen.Style := psClear;
  C.Brush.Color := RGBToColor(28, 34, 46);
  C.Rectangle(OX, OY, OX + CS * S.W + 1, OY + CS * S.H + 1);
  C.Pen.Style := psSolid;
  if CS >= 8 then
  begin
    C.Pen.Color := RGBToColor(36, 44, 58);
    for X := 1 to S.W - 1 do
      C.Line(OX + X * CS, OY, OX + X * CS, OY + CS * S.H);
    for Y := 1 to S.H - 1 do
      C.Line(OX, OY + Y * CS, OX + CS * S.W, OY + Y * CS);
  end;
  if not S.Wrap then
  begin
    C.Pen.Color := RGBToColor(90, 110, 140);
    C.Pen.Width := 2;
    C.Brush.Style := bsClear;
    C.Rectangle(OX - 1, OY - 1, OX + CS * S.W + 2, OY + CS * S.H + 2);
    C.Brush.Style := bsSolid;
    C.Pen.Width := 1;
  end;

  { food }
  C.Brush.Color := RGBToColor(255, 80, 80);
  C.Pen.Color := RGBToColor(255, 160, 160);
  for I := 0 to High(S.Food) do
    C.Ellipse(OX + S.Food[I].X * CS + CS div 6, OY + S.Food[I].Y * CS + CS div 6,
      OX + (S.Food[I].X + 1) * CS - CS div 6, OY + (S.Food[I].Y + 1) * CS - CS div 6);

  { snakes, ours last (on top) }
  Me := FConn.Me;
  for J := 0 to Length(S.Snakes) do
  begin
    if J = Length(S.Snakes) then
    begin
      if Me < 0 then Break;
      P := S.Snakes[Me];
    end
    else if J = Me then
      Continue
    else
      P := S.Snakes[J];
    if not P.Alive or (Length(P.Body) = 0) then Continue;
    Col := SnakeColor(P.Color);
    C.Pen.Color := Shade(Col, 0.6);
    for I := High(P.Body) downto 1 do
    begin
      C.Brush.Color := Shade(Col, 1 - 0.35 * I / Max(Length(P.Body), 1));  // tail darker
      CellRect(P.Body[I].X, P.Body[I].Y, 1);
    end;
    C.Brush.Color := Shade(Col, 1.15);
    if J = Length(S.Snakes) then C.Pen.Color := clWhite;     // our head
    CellRect(P.Body[0].X, P.Body[0].Y, 0);
    if CS >= 10 then
      Eyes(P.Body[0], P.Dir);
  end;

  { name tags after all snakes, so no body covers a name }
  if CS >= 8 then
  begin
    C.Font.Height := -Max(CS * 2 div 3, 10);
    C.Font.Style := [];
    C.Font.Color := clWhite;
    C.Brush.Style := bsClear;
    for J := 0 to High(S.Snakes) do
      with S.Snakes[J] do
        if Alive and (Length(Body) > 0) then
          C.TextOut(EnsureRange(OX + Body[0].X * CS + CS div 2 - C.TextWidth(Name) div 2, 0,
            Max(FBuffer.Width - C.TextWidth(Name), 0)),               // whole name in the view
            Max(OY + Body[0].Y * CS - C.TextHeight(Name), 0), Name);
    C.Brush.Style := bsSolid;
  end;

  if Me < 0 then
    Msg := 'Joining ...'
  else if not S.Snakes[Me].Alive then
    Msg := 'Respawning ...   (Enter = now)'
  else
    Msg := '';
  if Msg <> '' then
    CenterText(Msg, 24);
end;

end.

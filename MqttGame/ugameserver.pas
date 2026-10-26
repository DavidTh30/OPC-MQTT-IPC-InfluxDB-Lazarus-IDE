{ ============================================================================
  Snake Arena Server - MQTT game server: the broker (MqttSim/mqttbroker)
  with the game running inside it. Clients: SnakeLCL, SnakeBGRA or any MQTT
  tool (protocol in snakeproto.pas).
    - arena size, tick, walls / wrap at start; bots and food while running
    - live player table, log of clients and game events
    - settings in GameServer.ini next to the exe
  With -dIPC (project ../IpcGame/IpcGameServer.lpi) the same window runs the
  game over IPC (SimpleIPC + shared memory, ../IpcGame/uipchost) instead.
  ============================================================================ }
unit ugameserver;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, Menus, ExtCtrls, StdCtrls, Grids,
  Spin, IniFiles, Math, {$IFDEF IPC} ipcshared, uipchost, {$ELSE} mqttbroker, ugamehost, {$ENDIF}
  snakeproto;

type

  { TMainForm }

  TMainForm = class(TForm)
    ButtonStart: TButton;
    CheckAutoStart: TCheckBox;
    CheckWrap: TCheckBox;
    EditPort: TEdit;
    GridPlayers: TStringGrid;
    LabelBots: TLabel;
    LabelFood: TLabel;
    LabelPort: TLabel;
    LabelSize: TLabel;
    LabelState: TLabel;
    LabelTick: TLabel;
    LabelX: TLabel;
    MainMenu1: TMainMenu;
    MemoLog: TMemo;
    MenuAbout: TMenuItem;
    MenuClearLog: TMenuItem;
    MenuExit: TMenuItem;
    MenuFile: TMenuItem;
    MenuHelp: TMenuItem;
    MenuServer: TMenuItem;
    MenuStart: TMenuItem;
    MenuStop: TMenuItem;
    PanelTop: TPanel;
    ShapeState: TShape;
    SpinBots: TSpinEdit;
    SpinFood: TSpinEdit;
    SpinH: TSpinEdit;
    SpinTick: TSpinEdit;
    SpinW: TSpinEdit;
    Splitter1: TSplitter;
    Timer1: TTimer;
    procedure ButtonStartClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure MenuAboutClick(Sender: TObject);
    procedure MenuClearLogClick(Sender: TObject);
    procedure MenuExitClick(Sender: TObject);
    procedure MenuStartClick(Sender: TObject);
    procedure MenuStopClick(Sender: TObject);
    procedure SpinBotsChange(Sender: TObject);
    procedure SpinFoodChange(Sender: TObject);
    procedure Timer1Timer(Sender: TObject);
  private
    {$IFNDEF IPC}
    FBroker: TMqttBroker;
    {$ENDIF}
    FHost: TGameHost;
    procedure Log(const S: string);
    procedure StartServer;
    procedure StopServer;
    procedure UpdateControls;
    procedure LoadIni;
    procedure SaveIni;
    function IniName: string;
  end;

var
  MainForm: TMainForm;

implementation

{$R *.lfm}

{ TMainForm }

procedure TMainForm.FormCreate(Sender: TObject);
begin
  Randomize;
  {$IFDEF IPC}
  Caption := 'Snake Arena Server (IPC)';
  LabelPort.Visible := False;                    // IPC = this PC, no port
  EditPort.Visible := False;
  {$ENDIF}
  LoadIni;
  UpdateControls;
  if CheckAutoStart.Checked then
    StartServer;
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  Timer1.Enabled := False;
  StopServer;
end;

function TMainForm.IniName: string;
begin
  Result := ChangeFileExt(Application.ExeName, '.ini');
end;

procedure TMainForm.LoadIni;
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(IniName);
  try
    EditPort.Text := IntToStr(Ini.ReadInteger('Server', 'Port', 1886));
    CheckAutoStart.Checked := Ini.ReadBool('Server', 'AutoStart', False);
    SpinW.Value := Ini.ReadInteger('Game', 'Width', 48);
    SpinH.Value := Ini.ReadInteger('Game', 'Height', 32);
    SpinTick.Value := Ini.ReadInteger('Game', 'TickMs', 100);
    CheckWrap.Checked := Ini.ReadBool('Game', 'Wrap', False);
    SpinBots.Value := Ini.ReadInteger('Game', 'Bots', 3);
    SpinFood.Value := Ini.ReadInteger('Game', 'Food', 10);
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
    Ini.WriteInteger('Server', 'Port', StrToIntDef(EditPort.Text, 1886));
    Ini.WriteBool('Server', 'AutoStart', CheckAutoStart.Checked);
    Ini.WriteInteger('Game', 'Width', SpinW.Value);
    Ini.WriteInteger('Game', 'Height', SpinH.Value);
    Ini.WriteInteger('Game', 'TickMs', SpinTick.Value);
    Ini.WriteBool('Game', 'Wrap', CheckWrap.Checked);
    Ini.WriteInteger('Game', 'Bots', SpinBots.Value);
    Ini.WriteInteger('Game', 'Food', SpinFood.Value);
  finally
    Ini.Free;
  end;
end;

procedure TMainForm.Log(const S: string);
begin
  MemoLog.Lines.Add(FormatDateTime('hh:nn:ss', Now) + '  ' + S);
end;

procedure TMainForm.StartServer;
var
  Port: Integer;
  Err: string;
begin
  if FHost <> nil then Exit;
  {$IFDEF IPC}
  Port := 0;
  FHost := TGameHost.Create(SpinW.Value, SpinH.Value, SpinTick.Value, CheckWrap.Checked);
  FHost.SetFood(SpinFood.Value);
  FHost.SetBots(SpinBots.Value);
  if not FHost.Start(Err) then
  begin
    Log('Start failed: ' + Err);
    FreeAndNil(FHost);
    UpdateControls;
    Exit;
  end;
  {$ELSE}
  if not TryStrToInt(Trim(EditPort.Text), Port) or (Port < 1) or (Port > 65535) then
  begin
    Log('Invalid port: ' + EditPort.Text);
    Exit;
  end;
  FBroker := TMqttBroker.Create;
  if not FBroker.Start(Port, Err) then
  begin
    Log('Start failed: ' + Err);
    FreeAndNil(FBroker);
    UpdateControls;
    Exit;
  end;
  FHost := TGameHost.Create(FBroker, SpinW.Value, SpinH.Value, SpinTick.Value, CheckWrap.Checked);
  FHost.SetFood(SpinFood.Value);
  FHost.SetBots(SpinBots.Value);
  FHost.Start;
  {$ENDIF}
  SaveIni;
  Log(Format('Snake Arena %d x %d, tick %d ms (%.0f moves/s), %s', [SpinW.Value, SpinH.Value,
    SpinTick.Value, 1000 / SpinTick.Value, BoolToStr(CheckWrap.Checked, 'wrap around', 'walls')]));
  UpdateControls;
end;

procedure TMainForm.StopServer;
begin
  if FHost = nil then Exit;
  FHost.Stop;
  {$IFDEF IPC}
  FHost.TakeLog(MemoLog.Lines);
  {$ELSE}
  FBroker.Stop;
  FBroker.TakeLog(MemoLog.Lines);
  {$ENDIF}
  FreeAndNil(FHost);
  {$IFNDEF IPC}
  FreeAndNil(FBroker);
  {$ENDIF}
  GridPlayers.RowCount := 1;
  UpdateControls;
end;

procedure TMainForm.UpdateControls;
var
  Running: Boolean;
begin
  Running := FHost <> nil;
  EditPort.Enabled := not Running;
  SpinW.Enabled := not Running;
  SpinH.Enabled := not Running;
  SpinTick.Enabled := not Running;
  CheckWrap.Enabled := not Running;
  MenuStart.Enabled := not Running;
  MenuStop.Enabled := Running;
  if Running then
    ButtonStart.Caption := 'Stop'
  else
  begin
    ButtonStart.Caption := 'Start';
    ShapeState.Brush.Color := clSilver;
    LabelState.Caption := 'Server stopped';
  end;
end;

procedure TMainForm.SpinBotsChange(Sender: TObject);
begin
  if FHost <> nil then FHost.SetBots(SpinBots.Value);
end;

procedure TMainForm.SpinFoodChange(Sender: TObject);
begin
  if FHost <> nil then FHost.SetFood(SpinFood.Value);
end;

procedure TMainForm.Timer1Timer(Sender: TObject);
var
  S: TGameState;
  I, R, J, Humans: Integer;
  Order: array of Integer;
  Host: string;
begin
  if FHost = nil then Exit;
  {$IFDEF IPC}
  FHost.TakeLog(MemoLog.Lines);
  {$ELSE}
  FBroker.TakeLog(MemoLog.Lines);
  {$ENDIF}
  while MemoLog.Lines.Count > 2000 do
    MemoLog.Lines.Delete(0);
  S := FHost.Snapshot;
  Humans := 0;
  for I := 0 to High(S.Snakes) do
    if not S.Snakes[I].IsBot then Inc(Humans);
  Host := GetEnvironmentVariable('COMPUTERNAME');
  if Host = '' then Host := 'localhost';
  if Humans > 0 then ShapeState.Brush.Color := clLime else ShapeState.Brush.Color := clYellow;
  {$IFDEF IPC}
  LabelState.Caption := Format('Running   IPC "%s"   %d player(s), %d bot(s)   tick %d   ' +
    'state %.1f kB/s (once, for all clients)   %.0f commands/s', [IPC_SERVER_ID, Humans,
    Length(S.Snakes) - Humans, S.Tick, FHost.KBytesPerSecond, FHost.CommandsPerSecond]);
  {$ELSE}
  LabelState.Caption := Format('Running   tcp://%s:%d   %d client(s), %d player(s), %d bot(s)   ' +
    'tick %d   state %.1f kB/s per client', [Host, FBroker.Port, FBroker.ClientCount, Humans,
    Length(S.Snakes) - Humans, S.Tick, FHost.KBytesPerSecond]);
  {$ENDIF}

  { players sorted by score, then best }
  SetLength(Order, Length(S.Snakes));
  for I := 0 to High(Order) do Order[I] := I;
  for I := 1 to High(Order) do
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
  GridPlayers.BeginUpdate;
  try
    GridPlayers.RowCount := Length(S.Snakes) + 1;
    for R := 0 to High(Order) do
      with S.Snakes[Order[R]] do
      begin
        GridPlayers.Cells[0, R + 1] := Name;
        GridPlayers.Cells[1, R + 1] := BoolToStr(IsBot, 'bot', 'player');
        GridPlayers.Cells[2, R + 1] := BoolToStr(Alive, 'alive', 'respawning');
        GridPlayers.Cells[3, R + 1] := IntToStr(Score);
        GridPlayers.Cells[4, R + 1] := IntToStr(Best);
        GridPlayers.Cells[5, R + 1] := IntToStr(Kills);
        GridPlayers.Cells[6, R + 1] := IntToStr(Length(Body));
        GridPlayers.Cells[7, R + 1] := '#' + ColorHex(Color);
        GridPlayers.Cells[8, R + 1] := Key;
      end;
  finally
    GridPlayers.EndUpdate;
  end;
end;

procedure TMainForm.ButtonStartClick(Sender: TObject);
begin
  if FHost = nil then StartServer else StopServer;
end;

procedure TMainForm.MenuStartClick(Sender: TObject);
begin
  StartServer;
end;

procedure TMainForm.MenuStopClick(Sender: TObject);
begin
  StopServer;
end;

procedure TMainForm.MenuClearLogClick(Sender: TObject);
begin
  MemoLog.Clear;
end;

procedure TMainForm.MenuExitClick(Sender: TObject);
begin
  Close;
end;

procedure TMainForm.MenuAboutClick(Sender: TObject);
begin
  {$IFDEF IPC}
  MessageDlg('About', 'Snake Arena Server (IPC) - multiplayer Snake on this PC' + LineEnding +
    'Commands: SimpleIPC "' + IPC_SERVER_ID + '", state: shared memory ' + IPC_MAP_NAME + LineEnding +
    'Clients: IpcSnakeLCL (LCL Canvas), IpcSnakeBGRA (BGRABitmap)' + LineEnding +
    'Config: ' + IniName, mtInformation, [mbOK], 0);
  {$ELSE}
  MessageDlg('About', 'Snake Arena Server - multiplayer Snake over MQTT 3.1 / 3.1.1' + LineEnding +
    'Clients: SnakeLCL (LCL Canvas), SnakeBGRA (BGRABitmap)' + LineEnding +
    'Topics: snake/cmd/<id>, snake/state, snake/event' + LineEnding +
    'Config: ' + IniName, mtInformation, [mbOK], 0);
  {$ENDIF}
end;

end.

{ ============================================================================
  MQTT Simulator - MQTT broker with the simulated HV PLC (same logic as
  Tools/s7sim.py and Tools/mqttsim.py), built with normal Lazarus forms.
    - MQTT 3.1 / 3.1.1 on tcp://<PC>:1884, anonymous, no TLS
    - topics <prefix>/DB_HMI/<tag>, writes on <topic>/set (see usimtopics)
    - any other client can publish / subscribe its own topics too
    - Set 1 (10 points) or Set 2 (2 points, input protection)
    - live topic table, log of clients, subscriptions and writes
    - settings in MqttSim.ini next to the exe
  ============================================================================ }
unit umqttmain;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, Menus, ExtCtrls, StdCtrls, Grids,
  IniFiles, mqttbroker, usimtopics, uplcsim;

type

  { TMainForm }

  TMainForm = class(TForm)
    ButtonStart: TButton;
    CheckAuto: TCheckBox;
    ComboPoints: TComboBox;
    EditPort: TEdit;
    EditPrefix: TEdit;
    GridTopics: TStringGrid;
    LabelPoints: TLabel;
    LabelPort: TLabel;
    LabelPrefix: TLabel;
    LabelState: TLabel;
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
    procedure Timer1Timer(Sender: TObject);
  private
    FBroker: TMqttBroker;
    FSim: TPlcSim;
    FTopics: TSimTopics;
    FInterval: Integer;
    procedure Log(const S: string);
    procedure StartServer;
    procedure StopServer;
    procedure FillGrid;
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
  LoadIni;
  UpdateControls;
  if CheckAuto.Checked then
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
    EditPort.Text := IntToStr(Ini.ReadInteger('Server', 'Port', 1884));
    EditPrefix.Text := Ini.ReadString('Server', 'Prefix', 'nonlinear');
    if Ini.ReadInteger('Server', 'Points', 10) = 2 then
      ComboPoints.ItemIndex := 1
    else
      ComboPoints.ItemIndex := 0;
    CheckAuto.Checked := Ini.ReadBool('Server', 'AutoStart', False);
    FInterval := Ini.ReadInteger('Server', 'IntervalMs', 100);
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
    Ini.WriteInteger('Server', 'Port', StrToIntDef(EditPort.Text, 1884));
    Ini.WriteString('Server', 'Prefix', EditPrefix.Text);
    if ComboPoints.ItemIndex = 1 then
      Ini.WriteInteger('Server', 'Points', 2)
    else
      Ini.WriteInteger('Server', 'Points', 10);
    Ini.WriteBool('Server', 'AutoStart', CheckAuto.Checked);
    Ini.WriteInteger('Server', 'IntervalMs', FInterval);
  finally
    Ini.Free;
  end;
end;

procedure TMainForm.Log(const S: string);
begin
  MemoLog.Lines.Add(FormatDateTime('hh:nn:ss', Now) + '  ' + S);
end;

procedure TMainForm.FillGrid;
var
  I: Integer;
begin
  GridTopics.BeginUpdate;
  try
    if FTopics = nil then
    begin
      GridTopics.RowCount := 1;
      Exit;
    end;
    GridTopics.RowCount := Length(FTopics.Items) + 1;
    for I := 0 to High(FTopics.Items) do
    begin
      GridTopics.Cells[0, I + 1] := FTopics.Items[I].Topic;
      GridTopics.Cells[1, I + 1] := FTopics.TypeText(I);
      if FTopics.Items[I].Writable then
        GridTopics.Cells[2, I + 1] := 'read / write (/set)'
      else
        GridTopics.Cells[2, I + 1] := 'read';
    end;
  finally
    GridTopics.EndUpdate;
  end;
end;

procedure TMainForm.StartServer;
var
  Port, Points: Integer;
  Prefix, Err: string;
begin
  if FBroker <> nil then Exit;
  if not TryStrToInt(Trim(EditPort.Text), Port) or (Port < 1) or (Port > 65535) then
  begin
    Log('Invalid port: ' + EditPort.Text);
    Exit;
  end;
  Prefix := Trim(EditPrefix.Text);
  if (Prefix = '') or (Pos('+', Prefix) > 0) or (Pos('#', Prefix) > 0) or
    Prefix.StartsWith('/') or Prefix.EndsWith('/') then
  begin
    Log('Invalid topic prefix: "' + EditPrefix.Text + '" (no + # and no / at the ends)');
    Exit;
  end;
  if ComboPoints.ItemIndex = 1 then Points := 2 else Points := 10;
  FBroker := TMqttBroker.Create;
  if not FBroker.Start(Port, Err) then
  begin
    Log('Start failed: ' + Err);
    FreeAndNil(FBroker);
    UpdateControls;
    Exit;
  end;
  FSim := TPlcSim.Create(Points);
  FTopics := TSimTopics.Create(FBroker, FSim, Prefix, FInterval);
  FSim.Start;
  FTopics.Start;
  SaveIni;
  FillGrid;
  Log(Format('PLC simulation running: %d points per curve (Set %d), topics %s/#',
    [Points, 1 + Ord(Points = 2), Prefix]));
  UpdateControls;
end;

procedure TMainForm.StopServer;
begin
  if FBroker = nil then Exit;
  FTopics.Stop;                      // no more publishing
  FBroker.Stop;                      // no more writes from clients
  FBroker.TakeLog(MemoLog.Lines);
  FreeAndNil(FTopics);
  FreeAndNil(FBroker);
  FreeAndNil(FSim);
  FillGrid;
  UpdateControls;
end;

procedure TMainForm.UpdateControls;
var
  Running: Boolean;
begin
  Running := FBroker <> nil;
  EditPort.Enabled := not Running;
  EditPrefix.Enabled := not Running;
  ComboPoints.Enabled := not Running;
  MenuStart.Enabled := not Running;
  MenuStop.Enabled := Running;
  if Running then
    ButtonStart.Caption := 'Stop'
  else
  begin
    ButtonStart.Caption := 'Start';
    ShapeState.Brush.Color := clSilver;
    LabelState.Caption := 'Broker stopped';
  end;
end;

procedure TMainForm.Timer1Timer(Sender: TObject);
var
  I, N: Integer;
  Host: string;
begin
  if FBroker = nil then Exit;
  FBroker.TakeLog(MemoLog.Lines);
  while MemoLog.Lines.Count > 2000 do
    MemoLog.Lines.Delete(0);

  N := FBroker.ClientCount;
  Host := GetEnvironmentVariable('COMPUTERNAME');
  if Host = '' then Host := 'localhost';
  if N > 0 then ShapeState.Brush.Color := clLime else ShapeState.Brush.Color := clYellow;
  LabelState.Caption := Format('Running   tcp://%s:%d   %d client(s), %d retained topic(s)',
    [Host, FBroker.Port, N, FBroker.RetainedCount]);

  GridTopics.BeginUpdate;
  try
    for I := 0 to High(FTopics.Items) do
      GridTopics.Cells[3, I + 1] := FTopics.Payload(I);
  finally
    GridTopics.EndUpdate;
  end;
end;

procedure TMainForm.ButtonStartClick(Sender: TObject);
begin
  if FBroker = nil then StartServer else StopServer;
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
  MessageDlg('About', 'MQTT Simulator - simulated HV PLC with an MQTT broker' + LineEnding +
    'MQTT 3.1 / 3.1.1, QoS 0/1/2, retained, last will, anonymous, no DLL' + LineEnding +
    'Write: publish to <topic>/set' + LineEnding +
    'Config: ' + IniName, mtInformation, [mbOK], 0);
end;

end.

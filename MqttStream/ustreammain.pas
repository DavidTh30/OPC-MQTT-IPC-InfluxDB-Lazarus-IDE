{ ============================================================================
  MQTT Stream Server - MQTT broker (MqttSim/mqttbroker) that streams data:
    - Generator: test signals, every sample published at a fixed rate
    - CSV replay: a PLC Data Logger CSV file with its recorded timing
  Built with normal Lazarus forms; settings in MqttStream.ini next to the exe.
  ============================================================================ }
unit ustreammain;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, Menus, ExtCtrls, StdCtrls, Grids,
  ComCtrls, IniFiles, Math, mqttbroker, uwaves, ustreams;

type

  { TMainForm }

  TMainForm = class(TForm)
    ButtonAdd: TButton;
    ButtonBrowse: TButton;
    ButtonDelete: TButton;
    ButtonGenRun: TButton;
    ButtonPause: TButton;
    ButtonPlay: TButton;
    ButtonStart: TButton;
    ButtonStop: TButton;
    CheckAutoStart: TCheckBox;
    CheckCombined: TCheckBox;
    CheckLoop: TCheckBox;
    CheckRetain: TCheckBox;
    ComboFormat: TComboBox;
    ComboQoS: TComboBox;
    ComboSpeed: TComboBox;
    EditFile: TEdit;
    EditPort: TEdit;
    EditPrefix: TEdit;
    EditRate: TEdit;
    GridCsv: TStringGrid;
    GridGen: TStringGrid;
    LabelCsvState: TLabel;
    LabelFile: TLabel;
    LabelFormat: TLabel;
    LabelGenHint: TLabel;
    LabelOutput: TLabel;
    LabelPort: TLabel;
    LabelPrefix: TLabel;
    LabelQoS: TLabel;
    LabelRate: TLabel;
    LabelSpeed: TLabel;
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
    OpenDialog1: TOpenDialog;
    PageControl1: TPageControl;
    PanelCsvTop: TPanel;
    PanelGenBottom: TPanel;
    PanelTop: TPanel;
    ProgressCsv: TProgressBar;
    ShapeState: TShape;
    SplitterLog: TSplitter;
    TabCsv: TTabSheet;
    TabGen: TTabSheet;
    Timer1: TTimer;
    procedure ButtonAddClick(Sender: TObject);
    procedure ButtonBrowseClick(Sender: TObject);
    procedure ButtonDeleteClick(Sender: TObject);
    procedure ButtonGenRunClick(Sender: TObject);
    procedure ButtonPauseClick(Sender: TObject);
    procedure ButtonPlayClick(Sender: TObject);
    procedure ButtonStartClick(Sender: TObject);
    procedure ButtonStopClick(Sender: TObject);
    procedure CsvOptionChange(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure GridGenCheckboxToggled(Sender: TObject; aCol, aRow: Integer;
      aState: TCheckboxState);
    procedure GridGenEditingDone(Sender: TObject);
    procedure MenuAboutClick(Sender: TObject);
    procedure MenuClearLogClick(Sender: TObject);
    procedure MenuExitClick(Sender: TObject);
    procedure MenuStartClick(Sender: TObject);
    procedure MenuStopClick(Sender: TObject);
    procedure OutputChange(Sender: TObject);
    procedure Timer1Timer(Sender: TObject);
  private
    FBroker: TMqttBroker;
    FEngine: TStreamEngine;
    FGenRun: Boolean;
    FLoading: Boolean;
    procedure Log(const S: string);
    procedure StartServer;
    procedure StopServer;
    function ReadChannels: TGenChannels;
    procedure WriteChannel(R: Integer; const C: TGenChannel);
    procedure ApplyChannels;
    procedure ApplyOutput;
    procedure ApplyCsvOptions;
    procedure LoadCsvFile(const FileName: string);
    procedure UpdateControls;
    procedure LoadIni;
    procedure SaveIni;
    function IniName: string;
    function Prefix: string;
  end;

var
  MainForm: TMainForm;

implementation

{$R *.lfm}

const
  COL_ON = 0; COL_NAME = 1; COL_SHAPE = 2; COL_AMP = 3; COL_OFS = 4; COL_PERIOD = 5;
  COL_DEC = 6; COL_VALUE = 7; COL_TOPIC = 8;
  SPEEDS: array[0..7] of Double = (0.1, 0.5, 1, 2, 5, 10, 100, 0);   // 0 = one row per rate

var
  FS: TFormatSettings;

function DefaultChannel(const AName: string; AShape: TWaveShape; A, O, P: Double;
  D: Integer): TGenChannel;
begin
  Result.Enabled := True;
  Result.Name := AName;
  Result.Shape := AShape;
  Result.Amplitude := A;
  Result.Offset := O;
  Result.Period := P;
  Result.Decimals := D;
end;

{ TMainForm }

procedure TMainForm.FormCreate(Sender: TObject);
var
  W: TWaveShape;
begin
  Randomize;
  GridGen.Columns[COL_SHAPE].PickList.Clear;
  for W := Low(TWaveShape) to High(TWaveShape) do
    GridGen.Columns[COL_SHAPE].PickList.Add(WaveShapeName[W]);
  LoadIni;
  UpdateControls;
  if CheckAutoStart.Checked then
    StartServer;
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  Timer1.Enabled := False;
  SaveIni;
  StopServer;
end;

function TMainForm.IniName: string;
begin
  Result := ChangeFileExt(Application.ExeName, '.ini');
end;

function TMainForm.Prefix: string;
begin
  Result := Trim(EditPrefix.Text);
end;

procedure TMainForm.LoadIni;
var
  Ini: TIniFile;
  I, N: Integer;
  L: TStringList;
  C: TGenChannel;
  W: TWaveShape;
begin
  FLoading := True;
  Ini := TIniFile.Create(IniName);
  L := TStringList.Create;
  try
    EditPort.Text := IntToStr(Ini.ReadInteger('Server', 'Port', 1885));
    EditPrefix.Text := Ini.ReadString('Server', 'Prefix', 'stream');
    CheckAutoStart.Checked := Ini.ReadBool('Server', 'AutoStart', False);
    EditRate.Text := IntToStr(Ini.ReadInteger('Output', 'RateMs', 100));
    ComboFormat.ItemIndex := Ini.ReadInteger('Output', 'Format', 0);
    ComboQoS.ItemIndex := Ini.ReadInteger('Output', 'QoS', 0);
    CheckRetain.Checked := Ini.ReadBool('Output', 'Retain', False);
    CheckCombined.Checked := Ini.ReadBool('Output', 'Combined', True);
    FGenRun := Ini.ReadBool('Generator', 'Running', True);
    N := Ini.ReadInteger('Generator', 'Count', -1);
    if N < 0 then
    begin
      GridGen.RowCount := 7;                         // first start
      WriteChannel(1, DefaultChannel('Sine', wsSine, 10, 0, 10, 3));
      WriteChannel(2, DefaultChannel('Triangle', wsTriangle, 5, 5, 20, 3));
      WriteChannel(3, DefaultChannel('Square', wsSquare, 1, 1, 4, 0));
      WriteChannel(4, DefaultChannel('Sawtooth', wsSawtooth, 50, 50, 30, 2));
      WriteChannel(5, DefaultChannel('Noise', wsRandom, 0.5, 20, 1, 3));
      WriteChannel(6, DefaultChannel('Walk', wsRandomWalk, 100, 0, 1, 2));
    end
    else
    begin
      GridGen.RowCount := N + 1;
      for I := 0 to N - 1 do
      begin
        L.CommaText := Ini.ReadString('Generator', 'Ch' + IntToStr(I), '');
        while L.Count < 7 do L.Add('');
        C.Enabled := L[0] <> '0';
        C.Name := TopicName(L[1]);
        ShapeFromName(L[2], W);
        C.Shape := W;
        C.Amplitude := StrToFloatDef(L[3], 1, FS);
        C.Offset := StrToFloatDef(L[4], 0, FS);
        C.Period := StrToFloatDef(L[5], 10, FS);
        C.Decimals := StrToIntDef(L[6], 3);
        WriteChannel(I + 1, C);
      end;
    end;
    EditFile.Text := Ini.ReadString('Csv', 'File', '');
    ComboSpeed.ItemIndex := Ini.ReadInteger('Csv', 'Speed', 2);
    CheckLoop.Checked := Ini.ReadBool('Csv', 'Loop', True);
  finally
    L.Free;
    Ini.Free;
    FLoading := False;
  end;
end;

procedure TMainForm.SaveIni;
var
  Ini: TIniFile;
  I: Integer;
  A: TGenChannels;
  L: TStringList;
begin
  Ini := TIniFile.Create(IniName);
  L := TStringList.Create;
  try
    Ini.WriteInteger('Server', 'Port', StrToIntDef(EditPort.Text, 1885));
    Ini.WriteString('Server', 'Prefix', EditPrefix.Text);
    Ini.WriteBool('Server', 'AutoStart', CheckAutoStart.Checked);
    Ini.WriteInteger('Output', 'RateMs', StrToIntDef(EditRate.Text, 100));
    Ini.WriteInteger('Output', 'Format', ComboFormat.ItemIndex);
    Ini.WriteInteger('Output', 'QoS', ComboQoS.ItemIndex);
    Ini.WriteBool('Output', 'Retain', CheckRetain.Checked);
    Ini.WriteBool('Output', 'Combined', CheckCombined.Checked);
    Ini.WriteBool('Generator', 'Running', FGenRun);
    A := ReadChannels;
    Ini.EraseSection('Generator');
    Ini.WriteBool('Generator', 'Running', FGenRun);
    Ini.WriteInteger('Generator', 'Count', Length(A));
    for I := 0 to High(A) do
    begin
      L.Clear;
      L.Add(IntToStr(Ord(A[I].Enabled)));
      L.Add(A[I].Name);
      L.Add(WaveShapeName[A[I].Shape]);
      L.Add(FloatToStr(A[I].Amplitude, FS));
      L.Add(FloatToStr(A[I].Offset, FS));
      L.Add(FloatToStr(A[I].Period, FS));
      L.Add(IntToStr(A[I].Decimals));
      Ini.WriteString('Generator', 'Ch' + IntToStr(I), L.CommaText);
    end;
    Ini.WriteString('Csv', 'File', EditFile.Text);
    Ini.WriteInteger('Csv', 'Speed', ComboSpeed.ItemIndex);
    Ini.WriteBool('Csv', 'Loop', CheckLoop.Checked);
  finally
    L.Free;
    Ini.Free;
  end;
end;

procedure TMainForm.Log(const S: string);
begin
  MemoLog.Lines.Add(FormatDateTime('hh:nn:ss', Now) + '  ' + S);
end;

{ ---- generator table ---- }

procedure TMainForm.WriteChannel(R: Integer; const C: TGenChannel);
begin
  if C.Enabled then GridGen.Cells[COL_ON, R] := '1' else GridGen.Cells[COL_ON, R] := '0';
  GridGen.Cells[COL_NAME, R] := C.Name;
  GridGen.Cells[COL_SHAPE, R] := WaveShapeName[C.Shape];
  GridGen.Cells[COL_AMP, R] := FloatToStr(C.Amplitude, FS);
  GridGen.Cells[COL_OFS, R] := FloatToStr(C.Offset, FS);
  GridGen.Cells[COL_PERIOD, R] := FloatToStr(C.Period, FS);
  GridGen.Cells[COL_DEC, R] := IntToStr(C.Decimals);
  GridGen.Cells[COL_TOPIC, R] := Prefix + '/gen/' + C.Name;
end;

{ the table as channels; bad cells are corrected in the table }
function TMainForm.ReadChannels: TGenChannels;
var
  R, I: Integer;
  C: TGenChannel;
  W: TWaveShape;
begin
  Result := nil;
  SetLength(Result, GridGen.RowCount - 1);
  for R := 1 to GridGen.RowCount - 1 do
  begin
    C.Enabled := GridGen.Cells[COL_ON, R] = '1';
    C.Name := TopicName(GridGen.Cells[COL_NAME, R]);
    if C.Name = '' then C.Name := 'Ch' + IntToStr(R);
    for I := 0 to R - 2 do                         // names must be unique
      if Result[I].Name = C.Name then
        C.Name := C.Name + '_' + IntToStr(R);
    ShapeFromName(GridGen.Cells[COL_SHAPE, R], W);
    C.Shape := W;
    C.Amplitude := StrToFloatDef(GridGen.Cells[COL_AMP, R], 1, FS);
    C.Offset := StrToFloatDef(GridGen.Cells[COL_OFS, R], 0, FS);
    C.Period := StrToFloatDef(GridGen.Cells[COL_PERIOD, R], 10, FS);
    if C.Period <= 0 then C.Period := 10;
    C.Decimals := EnsureRange(StrToIntDef(GridGen.Cells[COL_DEC, R], 3), 0, 9);
    Result[R - 1] := C;
  end;
end;

procedure TMainForm.ApplyChannels;
var
  A: TGenChannels;
  I: Integer;
begin
  if FLoading then Exit;
  A := ReadChannels;
  for I := 0 to High(A) do
    WriteChannel(I + 1, A[I]);                     // shows the corrected values
  if FEngine <> nil then
    FEngine.SetChannels(A);
end;

procedure TMainForm.GridGenEditingDone(Sender: TObject);
begin
  ApplyChannels;
end;

procedure TMainForm.GridGenCheckboxToggled(Sender: TObject; aCol, aRow: Integer;
  aState: TCheckboxState);
begin
  ApplyChannels;
end;

procedure TMainForm.ButtonAddClick(Sender: TObject);
begin
  GridGen.RowCount := GridGen.RowCount + 1;
  WriteChannel(GridGen.RowCount - 1, DefaultChannel('Ch' + IntToStr(GridGen.RowCount - 1),
    wsSine, 1, 0, 10, 3));
  ApplyChannels;
end;

procedure TMainForm.ButtonDeleteClick(Sender: TObject);
begin
  if (GridGen.Row < 1) or (GridGen.RowCount <= 1) then Exit;
  GridGen.DeleteRow(GridGen.Row);
  ApplyChannels;
end;

procedure TMainForm.ButtonGenRunClick(Sender: TObject);
begin
  FGenRun := not FGenRun;
  if FEngine <> nil then
    FEngine.SetGenRunning(FGenRun);
  UpdateControls;
end;

{ ---- output ---- }

procedure TMainForm.ApplyOutput;
var
  R: Integer;
begin
  if FLoading or (FEngine = nil) then Exit;
  R := StrToIntDef(Trim(EditRate.Text), 100);
  if (R < 5) or (R > 60000) then
  begin
    Log('Rate must be 5 .. 60000 ms');
    R := EnsureRange(R, 5, 60000);
    EditRate.Text := IntToStr(R);
  end;
  FEngine.SetOutput(R, TPayloadFormat(ComboFormat.ItemIndex), ComboQoS.ItemIndex,
    CheckRetain.Checked, CheckCombined.Checked);
end;

procedure TMainForm.OutputChange(Sender: TObject);
begin
  ApplyOutput;
end;

{ ---- CSV ---- }

procedure TMainForm.ApplyCsvOptions;
begin
  if FLoading or (FEngine = nil) then Exit;
  FEngine.SetCsvSpeed(SPEEDS[EnsureRange(ComboSpeed.ItemIndex, 0, High(SPEEDS))], CheckLoop.Checked);
end;

procedure TMainForm.CsvOptionChange(Sender: TObject);
begin
  ApplyCsvOptions;
end;

procedure TMainForm.LoadCsvFile(const FileName: string);
var
  Err: string;
  Info: TCsvInfo;
begin
  EditFile.Text := FileName;
  if (FEngine = nil) or (FileName = '') then Exit;
  if FEngine.LoadCsv(FileName, Err) then
  begin
    Info := FEngine.CsvInfo;
    Log(Format('CSV loaded: %s, %d rows, %d columns', [ExtractFileName(FileName), Info.Rows,
      Length(Info.Columns)]));
  end
  else
    Log('CSV not loaded: ' + Err);
end;

procedure TMainForm.ButtonBrowseClick(Sender: TObject);
begin
  if EditFile.Text <> '' then
    OpenDialog1.InitialDir := ExtractFilePath(EditFile.Text)
  else
    OpenDialog1.InitialDir := ExtractFilePath(Application.ExeName) + '..\DataLogger\Logs';
  if OpenDialog1.Execute then
  begin
    LoadCsvFile(OpenDialog1.FileName);
    SaveIni;
  end;
end;

procedure TMainForm.ButtonPlayClick(Sender: TObject);
begin
  if FEngine <> nil then FEngine.CsvPlay;
end;

procedure TMainForm.ButtonPauseClick(Sender: TObject);
begin
  if FEngine <> nil then FEngine.CsvPause;
end;

procedure TMainForm.ButtonStopClick(Sender: TObject);
begin
  if FEngine <> nil then FEngine.CsvStop;
end;

{ ---- server ---- }

procedure TMainForm.StartServer;
var
  Port: Integer;
  Err: string;
begin
  if FBroker <> nil then Exit;
  if not TryStrToInt(Trim(EditPort.Text), Port) or (Port < 1) or (Port > 65535) then
  begin
    Log('Invalid port: ' + EditPort.Text);
    Exit;
  end;
  if (Prefix = '') or (Pos('+', Prefix) > 0) or (Pos('#', Prefix) > 0) or
    Prefix.StartsWith('/') or Prefix.EndsWith('/') then
  begin
    Log('Invalid topic prefix: "' + EditPrefix.Text + '" (no + # and no / at the ends)');
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
  FEngine := TStreamEngine.Create(FBroker, Prefix);
  ApplyOutput;
  ApplyChannels;
  ApplyCsvOptions;
  FEngine.SetGenRunning(FGenRun);
  LoadCsvFile(EditFile.Text);
  FEngine.Start;
  SaveIni;
  Log(Format('Streaming under %s/# (generator %s)', [Prefix, BoolToStr(FGenRun, 'running', 'paused')]));
  UpdateControls;
end;

procedure TMainForm.StopServer;
begin
  if FBroker = nil then Exit;
  FEngine.Stop;                      // no more samples
  FBroker.Stop;
  FBroker.TakeLog(MemoLog.Lines);
  FreeAndNil(FEngine);
  FreeAndNil(FBroker);
  UpdateControls;
end;

procedure TMainForm.UpdateControls;
var
  Running: Boolean;
begin
  Running := FBroker <> nil;
  EditPort.Enabled := not Running;
  EditPrefix.Enabled := not Running;
  MenuStart.Enabled := not Running;
  MenuStop.Enabled := Running;
  ButtonPlay.Enabled := Running;
  ButtonPause.Enabled := Running;
  ButtonStop.Enabled := Running;
  if FGenRun then ButtonGenRun.Caption := 'Pause generator' else ButtonGenRun.Caption := 'Run generator';
  if Running then
    ButtonStart.Caption := 'Stop'
  else
  begin
    ButtonStart.Caption := 'Start';
    ShapeState.Brush.Color := clSilver;
    LabelState.Caption := 'Server stopped';
    LabelCsvState.Caption := 'Start the server to load and play the file';
  end;
end;

procedure TMainForm.Timer1Timer(Sender: TObject);
var
  I, N: Integer;
  Host: string;
  V: TDoubleArray;
  A: TGenChannels;
  Info: TCsvInfo;
begin
  if FBroker = nil then Exit;
  FBroker.TakeLog(MemoLog.Lines);
  while MemoLog.Lines.Count > 2000 do
    MemoLog.Lines.Delete(0);

  N := FBroker.ClientCount;
  Host := GetEnvironmentVariable('COMPUTERNAME');
  if Host = '' then Host := 'localhost';
  if N > 0 then ShapeState.Brush.Color := clLime else ShapeState.Brush.Color := clYellow;
  LabelState.Caption := Format('Running   tcp://%s:%d   %d client(s)   %.0f msg/s   %d messages',
    [Host, FBroker.Port, N, FEngine.MsgRate, FEngine.Messages]);
  if not EditRate.Focused and (StrToIntDef(EditRate.Text, -1) <> FEngine.RateMs) then
    EditRate.Text := IntToStr(FEngine.RateMs);   // changed over MQTT (control/rate/set)
  if FEngine.GenRunning <> FGenRun then
  begin
    FGenRun := FEngine.GenRunning;               // changed over MQTT (control/gen/set)
    UpdateControls;
  end;

  { live values of the generator }
  V := FEngine.GenValues;
  A := ReadChannels;
  if not GridGen.EditorMode then
    for I := 0 to Min(High(V), GridGen.RowCount - 2) do
      if A[I].Enabled then
        GridGen.Cells[COL_VALUE, I + 1] := FloatToStrF(V[I], ffFixed, 15, A[I].Decimals, FS)
      else
        GridGen.Cells[COL_VALUE, I + 1] := '';

  { CSV position and the last row }
  Info := FEngine.CsvInfo;
  if Info.State = csEmpty then
    LabelCsvState.Caption := 'No file loaded'
  else
  begin
    LabelCsvState.Caption := Format('%s   row %d of %d', [UpperCase(CsvStateName[Info.State]),
      Info.Row, Info.Rows]);
    if Info.RowTime > 0 then
      LabelCsvState.Caption := LabelCsvState.Caption + '   recorded ' +
        FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Info.RowTime);
  end;
  ProgressCsv.Max := Max(Info.Rows, 1);
  ProgressCsv.Position := Info.Row;
  GridCsv.RowCount := Length(Info.Columns) + 1;
  for I := 0 to High(Info.Columns) do
  begin
    GridCsv.Cells[0, I + 1] := FEngine.Prefix + '/csv/' + Info.Columns[I];
    if I <= High(Info.Values) then
      GridCsv.Cells[1, I + 1] := Info.Values[I]
    else
      GridCsv.Cells[1, I + 1] := '';
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
  MessageDlg('About', 'MQTT Stream Server - MQTT 3.1 / 3.1.1 broker that streams' + LineEnding +
    'test signals and PLC Data Logger CSV files, no DLL' + LineEnding +
    'Control: <prefix>/control/gen|csv|rate|speed/set' + LineEnding +
    'Config: ' + IniName, mtInformation, [mbOK], 0);
end;

initialization
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  FS.ThousandSeparator := #0;
end.

{ ============================================================================
  OPC UA Simulator - OPC UA server with the simulated HV PLC (same logic as
  Tools/s7sim.py and Tools/opcuasim.py), built with normal Lazarus forms.
    - endpoint opc.tcp://<PC>:4841/nonlinear/, security None, anonymous
    - namespace urn:nonlinear:hv (ns=2), NodeIds "DB_HMI.<tag>" / "Sim.<tag>"
    - Set 1 (10 points) or Set 2 (2 points, input protection)
    - live tag table, log of clients and writes
    - settings in OpcUaSim.ini next to the exe
  ============================================================================ }
unit umain;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, Menus, ExtCtrls, StdCtrls, Grids,
  IniFiles, uaencode, uaserver, uplcsim;

type

  { TMainForm }

  TMainForm = class(TForm)
    ButtonStart: TButton;
    CheckAuto: TCheckBox;
    ComboPoints: TComboBox;
    EditPort: TEdit;
    GridTags: TStringGrid;
    LabelPoints: TLabel;
    LabelPort: TLabel;
    LabelState: TLabel;
    MainMenu1: TMainMenu;
    MemoLog: TMemo;
    MenuAbout: TMenuItem;
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
    procedure MenuExitClick(Sender: TObject);
    procedure MenuStartClick(Sender: TObject);
    procedure MenuStopClick(Sender: TObject);
    procedure Timer1Timer(Sender: TObject);
  private
    FServer: TUAServer;
    FSim: TPlcSim;
    FNs: Word;
    procedure Log(const S: string);
    procedure StartServer;
    procedure StopServer;
    procedure BuildAddressSpace;
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

const
  NS_URI = 'urn:nonlinear:hv';

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
    EditPort.Text := IntToStr(Ini.ReadInteger('Server', 'Port', 4841));
    if Ini.ReadInteger('Server', 'Points', 10) = 2 then
      ComboPoints.ItemIndex := 1
    else
      ComboPoints.ItemIndex := 0;
    CheckAuto.Checked := Ini.ReadBool('Server', 'AutoStart', False);
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
    Ini.WriteInteger('Server', 'Port', StrToIntDef(EditPort.Text, 4841));
    if ComboPoints.ItemIndex = 1 then
      Ini.WriteInteger('Server', 'Points', 2)
    else
      Ini.WriteInteger('Server', 'Points', 10);
    Ini.WriteBool('Server', 'AutoStart', CheckAuto.Checked);
  finally
    Ini.Free;
  end;
end;

procedure TMainForm.Log(const S: string);
begin
  MemoLog.Lines.Add(FormatDateTime('hh:nn:ss', Now) + '  ' + S);
end;

{ every tag "A.B.C" becomes variable C in object A.B (objects are created on the way) }
procedure TMainForm.BuildAddressSpace;
var
  I, J: Integer;
  Parts: TStringArray;
  ParentNode, Obj: TUANode;
  Path: string;
  T: TSimTag;
  ALen: Integer;
begin
  FNs := FServer.AddNamespace(NS_URI);
  for I := 0 to High(FSim.Tags) do
  begin
    T := FSim.Tags[I];
    Parts := T.Name.Split('.');
    ParentNode := FServer.ObjectsFolder;
    Path := '';
    for J := 0 to High(Parts) - 1 do
    begin
      if Path <> '' then Path := Path + '.';
      Path := Path + Parts[J];
      Obj := FServer.FindNode(StrNodeId(FNs, Path));
      if Obj = nil then
        Obj := FServer.AddObject(ParentNode, FNs, Path, Parts[J]);
      ParentNode := Obj;
    end;
    if T.Kind = tkRealArray then ALen := FSim.Points else ALen := 0;
    FServer.AddVariable(ParentNode, FNs, T.Name, Parts[High(Parts)], TagKindType[T.Kind], ALen,
      T.Writable, T.Id);
  end;
end;

procedure TMainForm.FillGrid;
var
  I: Integer;
begin
  GridTags.BeginUpdate;
  try
    if FSim = nil then
    begin
      GridTags.RowCount := 1;
      Exit;
    end;
    GridTags.RowCount := Length(FSim.Tags) + 1;
    for I := 0 to High(FSim.Tags) do
    begin
      GridTags.Cells[0, I + 1] := Format('ns=%d;s=%s', [FNs, FSim.Tags[I].Name]);
      GridTags.Cells[1, I + 1] := TagKindName[FSim.Tags[I].Kind];
      if FSim.Tags[I].Writable then
        GridTags.Cells[2, I + 1] := 'read / write'
      else
        GridTags.Cells[2, I + 1] := 'read';
    end;
  finally
    GridTags.EndUpdate;
  end;
end;

procedure TMainForm.StartServer;
var
  Port, Points: Integer;
  Err: string;
begin
  if FServer <> nil then Exit;
  if not TryStrToInt(Trim(EditPort.Text), Port) or (Port < 1) or (Port > 65535) then
  begin
    Log('Invalid port: ' + EditPort.Text);
    Exit;
  end;
  if ComboPoints.ItemIndex = 1 then Points := 2 else Points := 10;
  FSim := TPlcSim.Create(Points);
  FServer := TUAServer.Create;
  FServer.OnReadTag := @FSim.ReadTag;
  FServer.OnWriteTag := @FSim.WriteTag;
  BuildAddressSpace;
  if not FServer.Start(Port, Err) then
  begin
    Log('Start failed: ' + Err);
    FreeAndNil(FServer);
    FreeAndNil(FSim);
    UpdateControls;
    Exit;
  end;
  FSim.Start;
  SaveIni;
  FillGrid;
  Log(Format('PLC simulation running: %d points per curve (Set %d)', [Points, 1 + Ord(Points = 2)]));
  UpdateControls;
end;

procedure TMainForm.StopServer;
begin
  if FServer = nil then Exit;
  FServer.Stop;                      // no more reads / writes from clients
  FServer.TakeLog(MemoLog.Lines);
  FreeAndNil(FServer);
  FreeAndNil(FSim);
  FillGrid;
  UpdateControls;
end;

procedure TMainForm.UpdateControls;
var
  Running: Boolean;
begin
  Running := FServer <> nil;
  EditPort.Enabled := not Running;
  ComboPoints.Enabled := not Running;
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

procedure TMainForm.Timer1Timer(Sender: TObject);
var
  I, N: Integer;
  Host: string;
begin
  if FServer = nil then Exit;
  FServer.TakeLog(MemoLog.Lines);
  while MemoLog.Lines.Count > 2000 do
    MemoLog.Lines.Delete(0);

  N := FServer.ClientCount;
  Host := GetEnvironmentVariable('COMPUTERNAME');
  if Host = '' then Host := 'localhost';
  if N > 0 then ShapeState.Brush.Color := clLime else ShapeState.Brush.Color := clYellow;
  LabelState.Caption := Format('Running   opc.tcp://%s:%d/nonlinear/   %d client(s)',
    [Host, FServer.Port, N]);

  GridTags.BeginUpdate;
  try
    for I := 0 to High(FSim.Tags) do
      GridTags.Cells[3, I + 1] := FSim.TagText(FSim.Tags[I].Id);
  finally
    GridTags.EndUpdate;
  end;
end;

procedure TMainForm.ButtonStartClick(Sender: TObject);
begin
  if FServer = nil then StartServer else StopServer;
end;

procedure TMainForm.MenuStartClick(Sender: TObject);
begin
  StartServer;
end;

procedure TMainForm.MenuStopClick(Sender: TObject);
begin
  StopServer;
end;

procedure TMainForm.MenuExitClick(Sender: TObject);
begin
  Close;
end;

procedure TMainForm.MenuAboutClick(Sender: TObject);
begin
  MessageDlg('About', 'OPC UA Simulator - simulated HV PLC as OPC UA server' + LineEnding +
    'UA TCP binary, security None, anonymous login, no DLL' + LineEnding +
    'Namespace ' + NS_URI + LineEnding +
    'Config: ' + IniName, mtInformation, [mbOK], 0);
end;

end.

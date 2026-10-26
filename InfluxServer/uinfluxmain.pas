{ ============================================================================
  InfluxDB Server - an InfluxDB 1.x compatible time series server built with
  normal Lazarus forms (HTTP API: uinfluxhttp, InfluxQL: uinfluxql /
  uqueryexec, store: utsdb, line protocol: ulineproto). Grafana (InfluxQL),
  Telegraf, the influx CLI and the client libraries can use it.
    - databases tab: measurements, series, points, WAL size; Compact now
    - query tab: InfluxQL inside the program, result as a table and JSON
    - log of starts, errors and (optional) every request
    - settings in InfluxServer.ini next to the exe
  ============================================================================ }
unit uinfluxmain;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, Menus, ExtCtrls, StdCtrls, Grids,
  ComCtrls, Spin, LCLType, IniFiles, Math, fpjson, jsonparser, utsdb, uinfluxhttp, uqueryexec;

type

  { TMainForm }

  TMainForm = class(TForm)
    ButtonCompact: TButton;
    ButtonData: TButton;
    ButtonRun: TButton;
    ButtonStart: TButton;
    CheckAutoCreate: TCheckBox;
    CheckAutoStart: TCheckBox;
    CheckLogRequests: TCheckBox;
    EditData: TEdit;
    EditPort: TEdit;
    EditQDb: TEdit;
    GridDb: TStringGrid;
    GridResult: TStringGrid;
    LabelData: TLabel;
    LabelPort: TLabel;
    LabelQDb: TLabel;
    LabelQInfo: TLabel;
    LabelRet: TLabel;
    LabelState: TLabel;
    MainMenu1: TMainMenu;
    MemoJson: TMemo;
    MemoLog: TMemo;
    MemoQ: TMemo;
    MenuAbout: TMenuItem;
    MenuClearLog: TMenuItem;
    MenuExit: TMenuItem;
    MenuFile: TMenuItem;
    MenuHelp: TMenuItem;
    MenuServer: TMenuItem;
    MenuStart: TMenuItem;
    MenuStop: TMenuItem;
    PageControl1: TPageControl;
    PanelDbButtons: TPanel;
    PanelQ: TPanel;
    PanelTop: TPanel;
    SelectDirectoryDialog1: TSelectDirectoryDialog;
    ShapeState: TShape;
    SpinRet: TSpinEdit;
    SplitterJson: TSplitter;
    SplitterLog: TSplitter;
    TabDb: TTabSheet;
    TabQuery: TTabSheet;
    Timer1: TTimer;
    procedure ButtonCompactClick(Sender: TObject);
    procedure ButtonDataClick(Sender: TObject);
    procedure ButtonRunClick(Sender: TObject);
    procedure ButtonStartClick(Sender: TObject);
    procedure CheckAutoCreateChange(Sender: TObject);
    procedure CheckLogRequestsChange(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure MemoQKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure MenuAboutClick(Sender: TObject);
    procedure MenuClearLogClick(Sender: TObject);
    procedure MenuExitClick(Sender: TObject);
    procedure MenuStartClick(Sender: TObject);
    procedure MenuStopClick(Sender: TObject);
    procedure SpinRetChange(Sender: TObject);
    procedure Timer1Timer(Sender: TObject);
  private
    FStore: TStore;
    FServer: TInfluxServer;
    FLastStat, FLastGrid, FLastPurge: QWord;
    FPrevW, FPrevP, FPrevQ: Int64;
    FRateW, FRateP, FRateQ: Double;
    procedure Log(const S: string);
    procedure StartServer;
    procedure StopServer;
    procedure FillDbGrid;
    procedure ShowResult(const Json: string);
    procedure UpdateControls;
    procedure LoadIni;
    procedure SaveIni;
    function IniName: string;
    function DataDir: string;
  end;

var
  MainForm: TMainForm;

implementation

{$R *.lfm}

function SizeText(B: Int64): string;
begin
  if B < 1024 then Result := IntToStr(B) + ' B'
  else if B < 1024 * 1024 then Result := Format('%.1f kB', [B / 1024])
  else Result := Format('%.1f MB', [B / 1048576]);
end;

{ TMainForm }

procedure TMainForm.FormCreate(Sender: TObject);
begin
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

function TMainForm.DataDir: string;
begin
  Result := Trim(EditData.Text);
  if Result = '' then Result := 'data';
  if ExtractFileDrive(Result) = '' then             // relative to the exe
    Result := ExtractFilePath(Application.ExeName) + Result;
end;

procedure TMainForm.LoadIni;
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(IniName);
  try
    EditPort.Text := IntToStr(Ini.ReadInteger('Server', 'Port', 8086));
    EditData.Text := Ini.ReadString('Server', 'DataDir', 'data');
    CheckAutoCreate.Checked := Ini.ReadBool('Server', 'AutoCreate', True);
    SpinRet.Value := Ini.ReadInteger('Server', 'RetentionDays', 0);
    CheckAutoStart.Checked := Ini.ReadBool('Server', 'AutoStart', False);
    CheckLogRequests.Checked := Ini.ReadBool('Server', 'LogRequests', False);
    EditQDb.Text := Ini.ReadString('Query', 'Db', '');
    MemoQ.Text := Ini.ReadString('Query', 'Text', 'SHOW DATABASES');
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
    Ini.WriteInteger('Server', 'Port', StrToIntDef(EditPort.Text, 8086));
    Ini.WriteString('Server', 'DataDir', EditData.Text);
    Ini.WriteBool('Server', 'AutoCreate', CheckAutoCreate.Checked);
    Ini.WriteInteger('Server', 'RetentionDays', SpinRet.Value);
    Ini.WriteBool('Server', 'AutoStart', CheckAutoStart.Checked);
    Ini.WriteBool('Server', 'LogRequests', CheckLogRequests.Checked);
    Ini.WriteString('Query', 'Db', EditQDb.Text);
    Ini.WriteString('Query', 'Text', StringReplace(Trim(MemoQ.Text), LineEnding, ' ', [rfReplaceAll]));
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
  L: TStringList;
  T0: QWord;
  ErrCount, BytesIn: Int64;
begin
  if FServer <> nil then Exit;
  if not TryStrToInt(Trim(EditPort.Text), Port) or (Port < 1) or (Port > 65535) then
  begin
    Log('Invalid port: ' + EditPort.Text);
    Exit;
  end;
  FStore := TStore.Create(DataDir);
  FStore.AutoCreate := CheckAutoCreate.Checked;
  FStore.DefaultRetentionNs := Int64(SpinRet.Value) * 86400 * 1000000000;
  L := TStringList.Create;
  try
    T0 := GetTickCount64;
    try
      FStore.LoadAll(L);
    except
      on E: Exception do L.Add('loading failed: ' + E.Message);
    end;
    for Err in L do Log(Err);
    Log(Format('data folder %s: %d database(s) in %d ms', [FStore.DataDir, FStore.Databases.Count,
      GetTickCount64 - T0]));
  finally
    L.Free;
  end;
  FServer := TInfluxServer.Create(FStore, Port);
  FServer.LogRequests := CheckLogRequests.Checked;
  if not FServer.Start(Err) then
  begin
    Log('Start failed: ' + Err);
    FreeAndNil(FServer);
    FreeAndNil(FStore);
    UpdateControls;
    Exit;
  end;
  FServer.TakeLog(MemoLog.Lines);
  FServer.Stats(FPrevW, FPrevP, FPrevQ, ErrCount, BytesIn);
  FLastStat := GetTickCount64;
  FLastPurge := FLastStat;
  SaveIni;
  FillDbGrid;
  UpdateControls;
end;

procedure TMainForm.StopServer;
var
  T0: QWord;
begin
  if FServer = nil then Exit;
  FServer.Stop;                                      // no more requests
  FServer.TakeLog(MemoLog.Lines);
  T0 := GetTickCount64;
  FStore.CompactAll;                                 // short start-up next time
  Log(Format('compacted in %d ms', [GetTickCount64 - T0]));
  FreeAndNil(FServer);
  FreeAndNil(FStore);
  FillDbGrid;
  UpdateControls;
end;

procedure TMainForm.UpdateControls;
var
  Running: Boolean;
begin
  Running := FServer <> nil;
  EditPort.Enabled := not Running;
  EditData.Enabled := not Running;
  ButtonData.Enabled := not Running;
  MenuStart.Enabled := not Running;
  MenuStop.Enabled := Running;
  ButtonCompact.Enabled := Running;
  ButtonRun.Enabled := Running;
  if Running then
    ButtonStart.Caption := 'Stop'
  else
  begin
    ButtonStart.Caption := 'Start';
    ShapeState.Brush.Color := clSilver;
    LabelState.Caption := 'Server stopped';
  end;
end;

procedure TMainForm.FillDbGrid;
var
  I, J: Integer;
  D: TDatabase;
  P: Int64;
begin
  GridDb.BeginUpdate;
  try
    if FStore = nil then
    begin
      GridDb.RowCount := 1;
      Exit;
    end;
    FStore.Lock.BeginRead;
    try
      GridDb.RowCount := FStore.Databases.Count + 1;
      for I := 0 to FStore.Databases.Count - 1 do
      begin
        D := TDatabase(FStore.Databases.Objects[I]);
        P := D.PointCount;
        GridDb.Cells[0, I + 1] := D.Name;
        GridDb.Cells[1, I + 1] := IntToStr(D.Measurements.Count);
        GridDb.Cells[2, I + 1] := IntToStr(D.SeriesCount);
        GridDb.Cells[3, I + 1] := IntToStr(P);
        GridDb.Cells[4, I + 1] := SizeText(D.WalBytes);
        if D.RetentionNs > 0 then
          GridDb.Cells[5, I + 1] := IntToStr(D.RetentionNs div (Int64(86400) * 1000000000)) + ' days'
        else
          GridDb.Cells[5, I + 1] := 'forever';
        GridDb.Cells[6, I + 1] := '';
        for J := 0 to Min(D.Measurements.Count, 8) - 1 do
          GridDb.Cells[6, I + 1] := GridDb.Cells[6, I + 1] + D.Measurements[J] + '  ';
      end;
    finally
      FStore.Lock.EndRead;
    end;
  finally
    GridDb.EndUpdate;
  end;
end;

procedure TMainForm.Timer1Timer(Sender: TObject);
var
  W, P, Q, E, B: Int64;
  Dt: Double;
  L: TStringList;
  Host: string;
begin
  if FServer = nil then Exit;
  FServer.TakeLog(MemoLog.Lines);
  while MemoLog.Lines.Count > 3000 do MemoLog.Lines.Delete(0);
  FServer.Stats(W, P, Q, E, B);
  Dt := (GetTickCount64 - FLastStat) / 1000;
  if Dt >= 1 then
  begin
    FRateW := (W - FPrevW) / Dt;
    FRateP := (P - FPrevP) / Dt;
    FRateQ := (Q - FPrevQ) / Dt;
    FPrevW := W;
    FPrevP := P;
    FPrevQ := Q;
    FLastStat := GetTickCount64;
  end;
  if FRateW + FRateQ > 0 then ShapeState.Brush.Color := clLime else ShapeState.Brush.Color := clYellow;
  Host := GetEnvironmentVariable('COMPUTERNAME');
  if Host = '' then Host := 'localhost';
  LabelState.Caption := Format('Running   http://%s:%d   writes %.1f/s (%.0f points/s)   ' +
    'queries %.1f/s   total %d writes, %d points, %d queries, %d errors, %s in',
    [Host, FServer.Port, FRateW, FRateP, FRateQ, W, P, Q, E, SizeText(B)]);
  if GetTickCount64 - FLastGrid >= 2000 then
  begin
    FLastGrid := GetTickCount64;
    FillDbGrid;
  end;
  if GetTickCount64 - FLastPurge >= 60000 then
  begin
    FLastPurge := GetTickCount64;
    L := TStringList.Create;
    try
      FStore.Purge(L);
      MemoLog.Lines.AddStrings(L);
    finally
      L.Free;
    end;
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

procedure TMainForm.ButtonDataClick(Sender: TObject);
begin
  SelectDirectoryDialog1.InitialDir := DataDir;
  if SelectDirectoryDialog1.Execute then
    EditData.Text := SelectDirectoryDialog1.FileName;
end;

procedure TMainForm.ButtonCompactClick(Sender: TObject);
var
  T0: QWord;
begin
  if FStore = nil then Exit;
  T0 := GetTickCount64;
  FStore.CompactAll;
  Log(Format('compacted in %d ms', [GetTickCount64 - T0]));
  FillDbGrid;
end;

procedure TMainForm.CheckAutoCreateChange(Sender: TObject);
begin
  if FStore <> nil then FStore.AutoCreate := CheckAutoCreate.Checked;
end;

procedure TMainForm.CheckLogRequestsChange(Sender: TObject);
begin
  if FServer <> nil then FServer.LogRequests := CheckLogRequests.Checked;
end;

procedure TMainForm.SpinRetChange(Sender: TObject);
var
  I: Integer;
begin
  if FStore = nil then Exit;
  FStore.Lock.BeginWrite;
  try
    FStore.DefaultRetentionNs := Int64(SpinRet.Value) * 86400 * 1000000000;
    for I := 0 to FStore.Databases.Count - 1 do
      TDatabase(FStore.Databases.Objects[I]).RetentionNs := FStore.DefaultRetentionNs;
  finally
    FStore.Lock.EndWrite;
  end;
end;

procedure TMainForm.ButtonRunClick(Sender: TObject);
var
  Code: Integer;
  T0: QWord;
  Json: string;
begin
  if FStore = nil then Exit;
  T0 := GetTickCount64;
  Json := ExecuteQuery(FStore, MemoQ.Text, Trim(EditQDb.Text), 0, Code);
  LabelQInfo.Caption := Format('HTTP %d, %d ms, %s', [Code, GetTickCount64 - T0,
    SizeText(Length(Json))]);
  MemoJson.Text := Copy(Json, 1, 200000);
  ShowResult(Json);
end;

procedure TMainForm.MemoQKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (Key = VK_F9) or ((Key = VK_RETURN) and (ssCtrl in Shift)) then
  begin
    Key := 0;
    ButtonRunClick(Sender);
  end;
end;

{ every series of every statement under each other; the first column names the series }
procedure TMainForm.ShowResult(const Json: string);
var
  J: TJSONData;
  Results, Series, Cols, Vals, Row: TJSONArray;
  S: TJSONObject;
  I, K, C, R, N: Integer;
  SName: string;
  Tags: TJSONObject;
begin
  GridResult.BeginUpdate;
  try
    GridResult.ColCount := 1;
    GridResult.RowCount := 1;
    GridResult.Cells[0, 0] := 'series';
    try
      J := GetJSON(Json);
    except
      Exit;
    end;
    try
      if not (J is TJSONObject) then Exit;
      if TJSONObject(J).Find('error') <> nil then
      begin
        LabelQInfo.Caption := LabelQInfo.Caption + '   ' + TJSONObject(J).Get('error', '');
        Exit;
      end;
      Results := TJSONObject(J).Find('results', jtArray) as TJSONArray;
      if Results = nil then Exit;
      N := 1;
      for I := 0 to Results.Count - 1 do
      begin
        S := Results.Objects[I];
        if S.Find('error') <> nil then
          LabelQInfo.Caption := LabelQInfo.Caption + '   error: ' + S.Get('error', '');
        Series := S.Find('series', jtArray) as TJSONArray;
        if Series = nil then Continue;
        for K := 0 to Series.Count - 1 do
        begin
          S := Series.Objects[K];
          SName := S.Get('name', '');
          Tags := S.Find('tags', jtObject) as TJSONObject;
          if Tags <> nil then
            for C := 0 to Tags.Count - 1 do
              SName := SName + ' ' + Tags.Names[C] + '=' + Tags.Items[C].AsString;
          Cols := S.Find('columns', jtArray) as TJSONArray;
          Vals := S.Find('values', jtArray) as TJSONArray;
          if Cols = nil then Continue;
          if Cols.Count + 1 > GridResult.ColCount then
            GridResult.ColCount := Cols.Count + 1;
          if (I = 0) and (K = 0) then
            for C := 0 to Cols.Count - 1 do
              GridResult.Cells[C + 1, 0] := Cols.Strings[C];
          if Vals = nil then Continue;
          for R := 0 to Vals.Count - 1 do
          begin
            if N > 20000 then Break;                 // enough to look at
            Row := Vals.Arrays[R];
            GridResult.RowCount := N + 1;
            GridResult.Cells[0, N] := SName;
            for C := 0 to Row.Count - 1 do
              if Row.Items[C].JSONType = jtString then
                GridResult.Cells[C + 1, N] := Row.Items[C].AsString
              else
                GridResult.Cells[C + 1, N] := Row.Items[C].AsJSON;
            Inc(N);
          end;
        end;
      end;
    finally
      J.Free;
    end;
  finally
    GridResult.EndUpdate;
  end;
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
  MessageDlg('About', 'InfluxDB Server - InfluxDB 1.x compatible, written in Lazarus' + LineEnding +
    'Version ' + INFLUX_VERSION + ', HTTP API /write /query /ping /health /api/v2/write' + LineEnding +
    'InfluxQL subset (SELECT, GROUP BY time, fill, SHOW, CREATE, DROP, DELETE)' + LineEnding +
    'Data: ' + DataDir + LineEnding + 'Config: ' + IniName, mtInformation, [mbOK], 0);
end;

end.

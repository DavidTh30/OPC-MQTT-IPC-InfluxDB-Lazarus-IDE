{ ============================================================================
  InfluxDB Client - browse and query an InfluxDB 1.x (also InfluxServer of
  this project, or InfluxDB 2.x through its v1 API), built with normal forms
    - tree: databases -> measurements -> fields (type) / tags -> tag values,
      loaded when a node is opened; double-click writes a query and runs it
    - InfluxQL editor (Ctrl+Enter / F9), history of the last 20 queries
    - result as table, as chart (TAChart, every numeric column of every series;
      drag = zoom, right drag = pan, wheel = zoom, double-click = all) and JSON
    - Write tab: line protocol with a precision
    - settings in InfluxClient.ini next to the exe (the password is not saved)
    - command line: --query=<InfluxQL> [--db=<db>] runs it at start;
      --snapshot=<file.png> also saves the chart (+ the table as .txt) and exits
  ============================================================================ }
unit uinfluxclientmain;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, ExtCtrls, StdCtrls, ComCtrls, Grids,
  LCLType, IniFiles, Math, DateUtils, fpjson, jsonparser, TAGraph, TASeries, TAIntervalSources,
  TATools, TAChartUtils, TALegend, uinfluxapi;

type
  TNodeKind = (nkDb, nkMeas, nkFieldGroup, nkTagGroup, nkField, nkTagKey, nkTagValue, nkDummy);

  TNodeInfo = class
    Kind: TNodeKind;
    Db, Meas, Name, Extra: string;    // Extra: field type / tag key of a value
  end;

  { TMainForm }

  TMainForm = class(TForm)
    ButtonConnect: TButton;
    ButtonRefresh: TButton;
    ButtonRun: TButton;
    ButtonWrite: TButton;
    CheckUtc: TCheckBox;
    ComboDb: TComboBox;
    ComboHist: TComboBox;
    ComboPrec: TComboBox;
    EditPass: TEdit;
    EditUrl: TEdit;
    EditUser: TEdit;
    GridResult: TStringGrid;
    LabelDb: TLabel;
    LabelHist: TLabel;
    LabelInfo: TLabel;
    LabelPass: TLabel;
    LabelPrec: TLabel;
    LabelState: TLabel;
    LabelTree: TLabel;
    LabelUrl: TLabel;
    LabelUser: TLabel;
    LabelWrite: TLabel;
    MemoJson: TMemo;
    MemoQuery: TMemo;
    MemoWrite: TMemo;
    PageControl1: TPageControl;
    PanelLeft: TPanel;
    PanelMain: TPanel;
    PanelQuery: TPanel;
    PanelTop: TPanel;
    PanelWriteTop: TPanel;
    ShapeState: TShape;
    SplitterLeft: TSplitter;
    TabChart: TTabSheet;
    TabJson: TTabSheet;
    TabTable: TTabSheet;
    TabWrite: TTabSheet;
    TreeDb: TTreeView;
    procedure ButtonConnectClick(Sender: TObject);
    procedure ButtonRefreshClick(Sender: TObject);
    procedure ButtonRunClick(Sender: TObject);
    procedure ButtonWriteClick(Sender: TObject);
    procedure CheckUtcChange(Sender: TObject);
    procedure ComboHistSelect(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure MemoQueryKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure TreeDbDblClick(Sender: TObject);
    procedure TreeDbExpanding(Sender: TObject; Node: TTreeNode; var AllowExpansion: Boolean);
  private
    FConn: TInfluxConn;
    FInfos: TFPList;                  // TNodeInfo of the tree nodes
    FChart: TChart;
    FDates: TDateTimeIntervalChartSource;
    FLastJson: string;
    FSnapFile: string;                // --snapshot=<png>: the chart after the query, then exit
    FStartTimer: TTimer;
    procedure StartQuery(Sender: TObject);
    function Conn: TInfluxConn;
    function AddNode(AParent: TTreeNode; const AText: string; AKind: TNodeKind;
      const ADb, AMeas, AName, AExtra: string; Lazy: Boolean): TTreeNode;
    procedure ClearTree;
    procedure LoadDatabases;
    procedure LoadChildren(Node: TTreeNode);
    function List(const Db, Q: string; Col: Integer; Dest: TStrings): Boolean;
    procedure RunQuery(const Q: string);
    procedure ShowResult(const Json: string);
    function MsToTime(Ms: Double): TDateTime;
    procedure AddHistory(const Q: string);
    procedure Info(const S: string; Err: Boolean = False);
    procedure LoadIni;
    procedure SaveIni;
    function IniName: string;
  end;

var
  MainForm: TMainForm;

implementation

{$R *.lfm}

const
  MAX_GRID_ROWS = 50000;
  MAX_LINES = 40;
  COLORS: array[0..9] of TColor = ($00B4771F, $000E7FFF, $002CA02C, $002827D6, $00BD6794,
    $004B568C, $00C277E3, $007F7F7F, $0022BDBC, $00CFBE17);

{ TMainForm }

procedure TMainForm.FormCreate(Sender: TObject);
var
  T: TChartToolset;
begin
  FInfos := TFPList.Create;
  { the chart is made here (no TAChart properties in the .lfm) }
  FChart := TChart.Create(Self);
  FChart.Parent := TabChart;
  FChart.Align := alClient;
  FChart.BackColor := clWhite;
  FChart.Legend.Visible := True;
  FChart.Legend.Alignment := laBottomCenter;
  FChart.Legend.ColumnCount := 3;
  FChart.Title.Visible := False;
  FDates := TDateTimeIntervalChartSource.Create(Self);
  FChart.BottomAxis.Marks.Source := FDates;
  FChart.BottomAxis.Marks.Style := smsLabel;
  FChart.BottomAxis.Grid.Color := $E0E0E0;
  FChart.LeftAxis.Grid.Color := $E0E0E0;
  T := TChartToolset.Create(Self);
  TZoomDragTool.Create(T).Shift := [ssLeft];
  TPanDragTool.Create(T).Shift := [ssRight];
  TZoomMouseWheelTool.Create(T);
  FChart.Toolset := T;
  LoadIni;
  { command line: --query=<InfluxQL> --db=<db> --snapshot=<chart.png> (for tests) }
  if Application.HasOption('query') then
  begin
    MemoQuery.Text := Application.GetOptionValue('query');
    if Application.HasOption('db') then ComboDb.Text := Application.GetOptionValue('db');
    FSnapFile := Application.GetOptionValue('snapshot');
    FStartTimer := TTimer.Create(Self);           // after the window is up
    FStartTimer.Interval := 300;
    FStartTimer.OnTimer := @StartQuery;
  end;
end;

procedure TMainForm.StartQuery(Sender: TObject);
var
  L: TStringList;
  R: Integer;
begin
  FStartTimer.Enabled := False;
  ButtonConnectClick(nil);
  RunQuery(Trim(MemoQuery.Text));
  if FSnapFile = '' then Exit;
  PageControl1.ActivePage := TabChart;
  FChart.SetBounds(0, 0, 900, 480);
  FChart.SaveToFile(TPortableNetworkGraphic, FSnapFile);
  L := TStringList.Create;                         // the table as text next to it
  try
    L.Add(LabelState.Caption);
    L.Add(LabelInfo.Caption);
    for R := 0 to GridResult.RowCount - 1 do
      L.Add(GridResult.Rows[R].DelimitedText);
    { and the whole tree, every node opened (what a user sees when clicking +) }
    R := 0;
    while (R < TreeDb.Items.Count) and (R < 2000) do
    begin
      TreeDb.Items[R].Expand(False);
      L.Add(StringOfChar(' ', 2 * TreeDb.Items[R].Level) + TreeDb.Items[R].Text);
      Inc(R);
    end;
    L.SaveToFile(ChangeFileExt(FSnapFile, '.txt'));
  finally
    L.Free;
  end;
  Close;
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  SaveIni;
  ClearTree;
  FInfos.Free;
end;

function TMainForm.IniName: string;
begin
  Result := ChangeFileExt(Application.ExeName, '.ini');
end;

procedure TMainForm.LoadIni;
var
  Ini: TIniFile;
  I: Integer;
  S: string;
begin
  Ini := TIniFile.Create(IniName);
  try
    EditUrl.Text := Ini.ReadString('Connection', 'Url', 'http://127.0.0.1:8086');
    EditUser.Text := Ini.ReadString('Connection', 'User', '');
    ComboDb.Text := Ini.ReadString('Query', 'Db', '');
    MemoQuery.Text := Ini.ReadString('Query', 'Text', 'SHOW DATABASES');
    CheckUtc.Checked := Ini.ReadBool('Query', 'Utc', False);
    ComboPrec.ItemIndex := Ini.ReadInteger('Write', 'Precision', 2);
    for I := 0 to 19 do
    begin
      S := Ini.ReadString('History', 'Q' + IntToStr(I), '');
      if S <> '' then ComboHist.Items.Add(S);
    end;
  finally
    Ini.Free;
  end;
end;

procedure TMainForm.SaveIni;
var
  Ini: TIniFile;
  I: Integer;
begin
  Ini := TIniFile.Create(IniName);
  try
    Ini.WriteString('Connection', 'Url', EditUrl.Text);
    Ini.WriteString('Connection', 'User', EditUser.Text);
    Ini.WriteString('Query', 'Db', ComboDb.Text);
    Ini.WriteString('Query', 'Text', StringReplace(Trim(MemoQuery.Text), LineEnding, ' ', [rfReplaceAll]));
    Ini.WriteBool('Query', 'Utc', CheckUtc.Checked);
    Ini.WriteInteger('Write', 'Precision', ComboPrec.ItemIndex);
    Ini.EraseSection('History');
    for I := 0 to Min(ComboHist.Items.Count, 20) - 1 do
      Ini.WriteString('History', 'Q' + IntToStr(I), ComboHist.Items[I]);
  finally
    Ini.Free;
  end;
end;

function TMainForm.Conn: TInfluxConn;
begin
  Result := InfluxConn(EditUrl.Text, Trim(EditUser.Text), EditPass.Text);
end;

procedure TMainForm.Info(const S: string; Err: Boolean);
begin
  LabelInfo.Caption := S;
  if Err then LabelInfo.Font.Color := clRed else LabelInfo.Font.Color := clWindowText;
end;

{ ---- connection and tree ---- }

procedure TMainForm.ButtonConnectClick(Sender: TObject);
var
  R: TInfluxResult;
begin
  FConn := Conn;
  Screen.Cursor := crHourGlass;
  try
    R := InfluxPing(FConn);
  finally
    Screen.Cursor := crDefault;
  end;
  if not R.Ok then
  begin
    ShapeState.Brush.Color := clRed;
    LabelState.Caption := R.Error;
    Exit;
  end;
  ShapeState.Brush.Color := clLime;
  LabelState.Caption := Format('InfluxDB %s at %s  (%.0f ms)', [R.Version, InfluxBaseUrl(FConn.Url), R.Ms]);
  LoadDatabases;
  SaveIni;
end;

procedure TMainForm.ButtonRefreshClick(Sender: TObject);
begin
  FConn := Conn;
  LoadDatabases;
end;

procedure TMainForm.ClearTree;
var
  I: Integer;
begin
  TreeDb.Items.Clear;
  for I := 0 to FInfos.Count - 1 do TNodeInfo(FInfos[I]).Free;
  FInfos.Clear;
end;

function TMainForm.AddNode(AParent: TTreeNode; const AText: string; AKind: TNodeKind;
  const ADb, AMeas, AName, AExtra: string; Lazy: Boolean): TTreeNode;
var
  N: TNodeInfo;
begin
  N := TNodeInfo.Create;
  N.Kind := AKind;
  N.Db := ADb;
  N.Meas := AMeas;
  N.Name := AName;
  N.Extra := AExtra;
  FInfos.Add(N);
  Result := TreeDb.Items.AddChildObject(AParent, AText, N);
  if Lazy then
    AddNode(Result, '...', nkDummy, '', '', '', '', False);   // the + until it is opened
end;

function TMainForm.List(const Db, Q: string; Col: Integer; Dest: TStrings): Boolean;
var
  R: TInfluxResult;
begin
  R := InfluxQuery(FConn, Db, Q);
  Result := R.Ok;
  if Result then
    InfluxColumn(R.Body, Col, Dest)
  else
    Info(R.Error, True);
end;

procedure TMainForm.LoadDatabases;
var
  L: TStringList;
  I: Integer;
  Keep: string;
begin
  L := TStringList.Create;
  TreeDb.Items.BeginUpdate;
  try
    ClearTree;
    if not List('', 'SHOW DATABASES', 0, L) then Exit;
    Keep := ComboDb.Text;
    ComboDb.Items.Assign(L);
    ComboDb.Text := Keep;
    if (ComboDb.Text = '') and (L.Count > 0) then ComboDb.Text := L[0];
    for I := 0 to L.Count - 1 do
      AddNode(nil, L[I], nkDb, L[I], '', L[I], '', True);
    Info(Format('%d database(s)', [L.Count]));
  finally
    TreeDb.Items.EndUpdate;
    L.Free;
  end;
end;

procedure TMainForm.LoadChildren(Node: TTreeNode);
var
  N: TNodeInfo;
  L, T: TStringList;
  I: Integer;
  Q: string;
begin
  N := TNodeInfo(Node.Data);
  L := TStringList.Create;
  T := TStringList.Create;
  Screen.Cursor := crHourGlass;
  TreeDb.Items.BeginUpdate;
  try
    Node.DeleteChildren;
    case N.Kind of
      nkDb:
        if List(N.Db, 'SHOW MEASUREMENTS', 0, L) then
          for I := 0 to L.Count - 1 do
            AddNode(Node, L[I], nkMeas, N.Db, L[I], L[I], '', True);
      nkMeas:
        begin
          AddNode(Node, 'fields', nkFieldGroup, N.Db, N.Meas, '', '', True);
          AddNode(Node, 'tags', nkTagGroup, N.Db, N.Meas, '', '', True);
        end;
      nkFieldGroup:
        if List(N.Db, 'SHOW FIELD KEYS FROM ' + QuoteIdent(N.Meas), 0, L) and
          List(N.Db, 'SHOW FIELD KEYS FROM ' + QuoteIdent(N.Meas), 1, T) then
          for I := 0 to L.Count - 1 do
            AddNode(Node, L[I] + '  : ' + T[Min(I, T.Count - 1)], nkField, N.Db, N.Meas, L[I],
              T[Min(I, T.Count - 1)], False);
      nkTagGroup:
        if List(N.Db, 'SHOW TAG KEYS FROM ' + QuoteIdent(N.Meas), 0, L) then
          for I := 0 to L.Count - 1 do
            AddNode(Node, L[I], nkTagKey, N.Db, N.Meas, L[I], '', True);
      nkTagKey:
        begin
          Q := Format('SHOW TAG VALUES FROM %s WITH KEY = %s LIMIT 500', [QuoteIdent(N.Meas),
            QuoteIdent(N.Name)]);
          if List(N.Db, Q, 1, L) then
            for I := 0 to L.Count - 1 do
              AddNode(Node, L[I], nkTagValue, N.Db, N.Meas, L[I], N.Name, False);
        end;
    end;
  finally
    TreeDb.Items.EndUpdate;
    Screen.Cursor := crDefault;
    T.Free;
    L.Free;
  end;
end;

procedure TMainForm.TreeDbExpanding(Sender: TObject; Node: TTreeNode; var AllowExpansion: Boolean);
begin
  if (Node.Count = 1) and (TNodeInfo(Node.Items[0].Data).Kind = nkDummy) then
    LoadChildren(Node);
end;

{ a query for the node, run at once }
procedure TMainForm.TreeDbDblClick(Sender: TObject);
var
  N: TNodeInfo;
  Q: string;
begin
  if TreeDb.Selected = nil then Exit;
  N := TNodeInfo(TreeDb.Selected.Data);
  case N.Kind of
    nkMeas:
      Q := Format('SELECT * FROM %s WHERE time > now() - 1h ORDER BY time DESC LIMIT 100',
        [QuoteIdent(N.Meas)]);
    nkField:
      if (N.Extra = 'float') or (N.Extra = 'integer') then
        Q := Format('SELECT mean(%s) FROM %s WHERE time > now() - 1h GROUP BY time(1m) fill(none)',
          [QuoteIdent(N.Name), QuoteIdent(N.Meas)])
      else
        Q := Format('SELECT %s FROM %s WHERE time > now() - 1h ORDER BY time DESC LIMIT 100',
          [QuoteIdent(N.Name), QuoteIdent(N.Meas)]);
    nkTagValue:
      Q := Format('SELECT * FROM %s WHERE %s = %s AND time > now() - 1h ORDER BY time DESC LIMIT 100',
        [QuoteIdent(N.Meas), QuoteIdent(N.Extra), QuoteString(N.Name)]);
  else
    Exit;
  end;
  ComboDb.Text := N.Db;
  MemoQuery.Text := Q;
  RunQuery(Q);
  if (N.Kind = nkField) and (FChart.SeriesCount > 0) then
    PageControl1.ActivePage := TabChart;
end;

{ ---- query ---- }

procedure TMainForm.ButtonRunClick(Sender: TObject);
begin
  RunQuery(Trim(MemoQuery.Text));
end;

procedure TMainForm.MemoQueryKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (Key = VK_F9) or ((Key = VK_RETURN) and (ssCtrl in Shift)) then
  begin
    Key := 0;
    ButtonRunClick(Sender);
  end;
end;

procedure TMainForm.ComboHistSelect(Sender: TObject);
begin
  if ComboHist.ItemIndex >= 0 then
    MemoQuery.Text := ComboHist.Items[ComboHist.ItemIndex];
end;

procedure TMainForm.AddHistory(const Q: string);
var
  I: Integer;
  S: string;
begin
  S := StringReplace(Trim(Q), LineEnding, ' ', [rfReplaceAll]);
  I := ComboHist.Items.IndexOf(S);
  if I >= 0 then ComboHist.Items.Delete(I);
  ComboHist.Items.Insert(0, S);
  while ComboHist.Items.Count > 20 do ComboHist.Items.Delete(20);
end;

procedure TMainForm.RunQuery(const Q: string);
var
  R: TInfluxResult;
begin
  if Q = '' then Exit;
  if FConn.Url = '' then FConn := Conn;
  Screen.Cursor := crHourGlass;
  try
    R := InfluxQuery(FConn, Trim(ComboDb.Text), Q, 'ms');   // ms times: easy for the chart
  finally
    Screen.Cursor := crDefault;
  end;
  FLastJson := R.Body;
  MemoJson.Text := Copy(R.Body, 1, 500000);
  ShowResult(R.Body);
  if R.Error <> '' then
    Info(Format('%s   (%.0f ms)', [R.Error, R.Ms]), True)
  else
    Info(LabelInfo.Caption + Format('   %.0f ms, %d bytes', [R.Ms, Length(R.Body)]));
  if R.Code > 0 then AddHistory(Q);
end;

function TMainForm.MsToTime(Ms: Double): TDateTime;
begin
  Result := UnixDateDelta + Ms / Double(86400000);   // Double: no Single constant
  if not CheckUtc.Checked then Result := UniversalTimeToLocal(Result);
end;

procedure TMainForm.CheckUtcChange(Sender: TObject);
begin
  if FLastJson <> '' then ShowResult(FLastJson);
end;

{ every series of every statement into the table; numeric columns into the chart }
procedure TMainForm.ShowResult(const Json: string);
var
  J: TJSONData;
  Results, Series, Cols, Vals, Row: TJSONArray;
  S: TJSONObject;
  Tags: TJSONObject;
  I, K, C, R, N, Lines, NSeries: Integer;
  SName: string;
  HasTime: Boolean;
  Line: TLineSeries;
  X: TDateTime;
  V: TJSONData;
begin
  FChart.ClearSeries;
  GridResult.BeginUpdate;
  try
    GridResult.Clear;
    GridResult.ColCount := 1;
    GridResult.RowCount := 1;
    GridResult.FixedRows := 1;
    GridResult.Cells[0, 0] := 'series';
    try
      J := GetJSON(Json);
    except
      Info('the answer is not JSON', True);
      Exit;
    end;
    try
      if not (J is TJSONObject) then Exit;
      Results := TJSONObject(J).Find('results', jtArray) as TJSONArray;
      if Results = nil then Exit;
      N := 1;
      Lines := 0;
      NSeries := 0;
      for I := 0 to Results.Count - 1 do
      begin
        if not (Results.Items[I] is TJSONObject) then Continue;
        Series := TJSONObject(Results.Items[I]).Find('series', jtArray) as TJSONArray;
        if Series = nil then Continue;
        for K := 0 to Series.Count - 1 do
        begin
          Inc(NSeries);
          S := Series.Objects[K];
          SName := S.Get('name', '');
          Tags := S.Find('tags', jtObject) as TJSONObject;
          if Tags <> nil then
            for C := 0 to Tags.Count - 1 do
              SName := SName + ' ' + Tags.Names[C] + '=' + Tags.Items[C].AsString;
          Cols := S.Find('columns', jtArray) as TJSONArray;
          Vals := S.Find('values', jtArray) as TJSONArray;
          if Cols = nil then Continue;
          if Cols.Count + 1 > GridResult.ColCount then GridResult.ColCount := Cols.Count + 1;
          if NSeries = 1 then
            for C := 0 to Cols.Count - 1 do GridResult.Cells[C + 1, 0] := Cols.Strings[C];
          if Vals = nil then Continue;
          HasTime := (Cols.Count > 0) and (Cols.Strings[0] = 'time');
          { table }
          for R := 0 to Vals.Count - 1 do
          begin
            if N > MAX_GRID_ROWS then Break;
            Row := Vals.Arrays[R];
            GridResult.RowCount := N + 1;
            GridResult.Cells[0, N] := SName;
            for C := 0 to Row.Count - 1 do
            begin
              V := Row.Items[C];
              if (C = 0) and HasTime and (V.JSONType = jtNumber) then
                GridResult.Cells[1, N] := FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', MsToTime(V.AsFloat))
              else
                GridResult.Cells[C + 1, N] := JsonCellText(V);
            end;
            Inc(N);
          end;
          { chart: a line for every column with numbers }
          if not HasTime then Continue;
          for C := 1 to Cols.Count - 1 do
          begin
            if Lines >= MAX_LINES then Break;
            Line := nil;
            for R := 0 to Vals.Count - 1 do
            begin
              Row := Vals.Arrays[R];
              if C >= Row.Count then Continue;
              V := Row.Items[C];
              if not (V.JSONType in [jtNumber, jtBoolean]) then Continue;
              if Line = nil then
              begin
                Line := TLineSeries.Create(FChart);
                Line.Title := Trim(SName + ' ' + Cols.Strings[C]);
                Line.SeriesColor := COLORS[Lines mod Length(COLORS)];
                Line.LinePen.Width := 2;
                FChart.AddSeries(Line);
                Inc(Lines);
              end;
              X := MsToTime(Row.Items[0].AsFloat);
              if V.JSONType = jtBoolean then
                Line.AddXY(X, Ord(V.AsBoolean))
              else
                Line.AddXY(X, V.AsFloat);
            end;
          end;
        end;
      end;
      GridResult.AutoSizeColumns;
      Info(Format('%d series, %d rows, %d chart line(s)', [NSeries, N - 1, Lines]));
    finally
      J.Free;
    end;
  finally
    GridResult.EndUpdate;
  end;
end;

{ ---- write ---- }

procedure TMainForm.ButtonWriteClick(Sender: TObject);
var
  R: TInfluxResult;
  Prec: string;
  N: Integer;
begin
  if Trim(ComboDb.Text) = '' then
  begin
    LabelWrite.Caption := 'Choose a database first';
    Exit;
  end;
  if FConn.Url = '' then FConn := Conn;
  Prec := ComboPrec.Text;
  N := MemoWrite.Lines.Count;
  R := InfluxWrite(FConn, Trim(ComboDb.Text), MemoWrite.Text, Prec);
  if R.Ok then
    LabelWrite.Caption := Format('written: %d line(s) to %s (HTTP %d, %.0f ms)', [N, ComboDb.Text, R.Code, R.Ms])
  else
    LabelWrite.Caption := R.Error;
  if R.Ok then LabelWrite.Font.Color := clGreen else LabelWrite.Font.Color := clRed;
end;

end.

{ ============================================================================
  InfluxDB Signal Generator - writes test signals into an InfluxDB 1.x
  (also InfluxServer of this project), built with normal Lazarus forms
    - channels: shape (../MqttStream/uwaves), amplitude, offset, period, noise,
      decimals; live value in the table
    - Live: one sample every Rate ms, sent every Send ms
    - Backfill: the same signals for the last hour ... 30 days, as fast as the
      database takes them (Grafana dashboards have history at once)
    - layout: all channels as fields of one point, or one point per channel
      (tag channel=<name>, field value)
    - settings in InfluxSignalGen.ini next to the exe (the password is not saved)
    - command line: --start (live), --backfill=<s> [--step=<s>],
      --exit-when-done (close when the backfill is sent)
  ============================================================================ }
unit usiggenmain;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, ExtCtrls, StdCtrls, ComCtrls, Grids,
  Spin, IniFiles, Math, uwaves, uinfluxapi, usiggen;

type

  { TMainForm }

  TMainForm = class(TForm)
    ButtonAdd: TButton;
    ButtonBackfill: TButton;
    ButtonDelete: TButton;
    ButtonLive: TButton;
    ButtonTest: TButton;
    ComboLayout: TComboBox;
    ComboSpan: TComboBox;
    EditDb: TEdit;
    EditMeas: TEdit;
    EditPass: TEdit;
    EditTags: TEdit;
    EditUrl: TEdit;
    EditUser: TEdit;
    GridCh: TStringGrid;
    GroupBackfill: TGroupBox;
    LabelBackfill: TLabel;
    LabelDb: TLabel;
    LabelLayout: TLabel;
    LabelMeas: TLabel;
    LabelPass: TLabel;
    LabelRate: TLabel;
    LabelSend: TLabel;
    LabelSpan: TLabel;
    LabelState: TLabel;
    LabelStep: TLabel;
    LabelTags: TLabel;
    LabelUrl: TLabel;
    LabelUser: TLabel;
    MemoLog: TMemo;
    PanelBottom: TPanel;
    PanelTop: TPanel;
    ProgressBf: TProgressBar;
    ShapeState: TShape;
    SpinRate: TSpinEdit;
    SpinSend: TSpinEdit;
    SpinStep: TSpinEdit;
    Splitter1: TSplitter;
    Timer1: TTimer;
    procedure ButtonAddClick(Sender: TObject);
    procedure ButtonBackfillClick(Sender: TObject);
    procedure ButtonDeleteClick(Sender: TObject);
    procedure ButtonLiveClick(Sender: TObject);
    procedure ButtonTestClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure GridChCheckboxToggled(Sender: TObject; aCol, aRow: Integer; aState: TCheckboxState);
    procedure GridChEditingDone(Sender: TObject);
    procedure SettingChange(Sender: TObject);
    procedure Timer1Timer(Sender: TObject);
  private
    FGen: TSignalGen;
    FLoading, FExitWhenDone, FWasBackfill: Boolean;
    FLastErr: string;
    FPrevSent: Int64;
    FPrevT: QWord;
    FRate: Double;
    procedure Log(const S: string);
    function Settings: TGenSettings;
    procedure ApplySettings;
    procedure ApplyChannels;
    procedure WriteChannel(R: Integer; const C: TGenChannel; Noise: Double);
    procedure ReadChannels(out A: TGenChannels; out Noise: TDoubles);
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
  COL_ON = 0; COL_NAME = 1; COL_SHAPE = 2; COL_AMP = 3; COL_OFS = 4; COL_PERIOD = 5;
  COL_NOISE = 6; COL_DEC = 7; COL_VALUE = 8;
  SPANS: array[0..5] of Int64 = (3600, 6 * 3600, 24 * 3600, 2 * 86400, 7 * 86400, 30 * 86400);

var
  FS: TFormatSettings;

function Ch(const AName: string; AShape: TWaveShape; A, O, P: Double; D: Integer): TGenChannel;
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
  Secs: Double;
begin
  Randomize;
  GridCh.Columns[COL_SHAPE].PickList.Clear;
  for W := Low(TWaveShape) to High(TWaveShape) do
    GridCh.Columns[COL_SHAPE].PickList.Add(WaveShapeName[W]);
  FGen := TSignalGen.Create;
  LoadIni;
  ApplySettings;
  ApplyChannels;
  UpdateControls;
  { command line (also for tests without the window) }
  FExitWhenDone := Application.HasOption('exit-when-done');
  if Application.HasOption('step') then
    SpinStep.Value := StrToIntDef(Application.GetOptionValue('step'), SpinStep.Value);
  if Application.HasOption('backfill') then
  begin
    Secs := StrToFloatDef(Application.GetOptionValue('backfill'), 3600, FS);
    FGen.StartBackfill(WallMs - Round(Secs * 1000), WallMs, Int64(SpinStep.Value) * 1000);
    FWasBackfill := True;
    Log(Format('backfill of the last %.0f s, every %d s', [Secs, SpinStep.Value]));
  end;
  if Application.HasOption('start') then ButtonLiveClick(nil);
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  Timer1.Enabled := False;
  SaveIni;
  FGen.Free;
end;

function TMainForm.IniName: string;
begin
  Result := ChangeFileExt(Application.ExeName, '.ini');
end;

procedure TMainForm.Log(const S: string);
begin
  MemoLog.Lines.Add(FormatDateTime('hh:nn:ss', Now) + '  ' + S);
  while MemoLog.Lines.Count > 1000 do MemoLog.Lines.Delete(0);
end;

procedure TMainForm.LoadIni;
var
  Ini: TIniFile;
  L: TStringList;
  I, N: Integer;
  C: TGenChannel;
  W: TWaveShape;
begin
  FLoading := True;
  Ini := TIniFile.Create(IniName);
  L := TStringList.Create;
  try
    EditUrl.Text := Ini.ReadString('Influx', 'Url', 'http://127.0.0.1:8086');
    EditUser.Text := Ini.ReadString('Influx', 'User', '');
    EditDb.Text := Ini.ReadString('Influx', 'Database', 'signals');
    EditMeas.Text := Ini.ReadString('Influx', 'Measurement', 'signals');
    EditTags.Text := Ini.ReadString('Influx', 'Tags', 'source=generator');
    ComboLayout.ItemIndex := Ini.ReadInteger('Influx', 'Layout', 0);
    SpinRate.Value := Ini.ReadInteger('Generator', 'RateMs', 1000);
    SpinSend.Value := Ini.ReadInteger('Generator', 'SendMs', 1000);
    ComboSpan.ItemIndex := Ini.ReadInteger('Backfill', 'Span', 2);
    SpinStep.Value := Ini.ReadInteger('Backfill', 'StepS', 10);
    N := Ini.ReadInteger('Channels', 'Count', -1);
    if N < 0 then
    begin
      GridCh.RowCount := 7;                          // first start: a small plant
      WriteChannel(1, Ch('temperature', wsSine, 3, 21, 3600, 2), 0.1);
      WriteChannel(2, Ch('pressure', wsRandomWalk, 0.05, 1.013, 60, 4), 0);
      WriteChannel(3, Ch('flow', wsTriangle, 20, 50, 600, 1), 1);
      WriteChannel(4, Ch('valve', wsSquare, 0.5, 0.5, 300, 0), 0);
      WriteChannel(5, Ch('power', wsSawtooth, 2, 10, 900, 2), 0.2);
      WriteChannel(6, Ch('counter', wsRamp, 1000, 0, 3600, 0), 0);
    end
    else
    begin
      GridCh.RowCount := N + 1;
      for I := 0 to N - 1 do
      begin
        L.CommaText := Ini.ReadString('Channels', 'Ch' + IntToStr(I), '');
        while L.Count < 8 do L.Add('');
        C.Enabled := L[0] <> '0';
        C.Name := L[1];
        ShapeFromName(L[2], W);
        C.Shape := W;
        C.Amplitude := StrToFloatDef(L[3], 1, FS);
        C.Offset := StrToFloatDef(L[4], 0, FS);
        C.Period := StrToFloatDef(L[5], 60, FS);
        C.Decimals := StrToIntDef(L[7], 3);
        WriteChannel(I + 1, C, StrToFloatDef(L[6], 0, FS));
      end;
    end;
  finally
    L.Free;
    Ini.Free;
    FLoading := False;
  end;
end;

procedure TMainForm.SaveIni;
var
  Ini: TIniFile;
  A: TGenChannels;
  Noise: TDoubles;
  L: TStringList;
  I: Integer;
begin
  Ini := TIniFile.Create(IniName);
  L := TStringList.Create;
  try
    Ini.WriteString('Influx', 'Url', EditUrl.Text);
    Ini.WriteString('Influx', 'User', EditUser.Text);
    Ini.WriteString('Influx', 'Database', EditDb.Text);
    Ini.WriteString('Influx', 'Measurement', EditMeas.Text);
    Ini.WriteString('Influx', 'Tags', EditTags.Text);
    Ini.WriteInteger('Influx', 'Layout', ComboLayout.ItemIndex);
    Ini.WriteInteger('Generator', 'RateMs', SpinRate.Value);
    Ini.WriteInteger('Generator', 'SendMs', SpinSend.Value);
    Ini.WriteInteger('Backfill', 'Span', ComboSpan.ItemIndex);
    Ini.WriteInteger('Backfill', 'StepS', SpinStep.Value);
    ReadChannels(A, Noise);
    Ini.EraseSection('Channels');
    Ini.WriteInteger('Channels', 'Count', Length(A));
    for I := 0 to High(A) do
    begin
      L.Clear;
      L.Add(IntToStr(Ord(A[I].Enabled)));
      L.Add(A[I].Name);
      L.Add(WaveShapeName[A[I].Shape]);
      L.Add(FloatToStr(A[I].Amplitude, FS));
      L.Add(FloatToStr(A[I].Offset, FS));
      L.Add(FloatToStr(A[I].Period, FS));
      L.Add(FloatToStr(Noise[I], FS));
      L.Add(IntToStr(A[I].Decimals));
      Ini.WriteString('Channels', 'Ch' + IntToStr(I), L.CommaText);
    end;
  finally
    L.Free;
    Ini.Free;
  end;
end;

function TMainForm.Settings: TGenSettings;
begin
  Result := Default(TGenSettings);
  Result.Conn := InfluxConn(EditUrl.Text, Trim(EditUser.Text), EditPass.Text);
  Result.Conn.TimeoutMs := 15000;
  Result.Database := Trim(EditDb.Text);
  Result.Measurement := Trim(EditMeas.Text);
  Result.Tags := EditTags.Text;
  Result.Layout := TGenLayout(Max(ComboLayout.ItemIndex, 0));
  Result.RateMs := SpinRate.Value;
  Result.SendMs := SpinSend.Value;
end;

procedure TMainForm.ApplySettings;
begin
  if not FLoading then FGen.Configure(Settings);
end;

procedure TMainForm.SettingChange(Sender: TObject);
begin
  ApplySettings;
end;

{ ---- channel table ---- }

procedure TMainForm.WriteChannel(R: Integer; const C: TGenChannel; Noise: Double);
begin
  if C.Enabled then GridCh.Cells[COL_ON, R] := '1' else GridCh.Cells[COL_ON, R] := '0';
  GridCh.Cells[COL_NAME, R] := C.Name;
  GridCh.Cells[COL_SHAPE, R] := WaveShapeName[C.Shape];
  GridCh.Cells[COL_AMP, R] := FloatToStr(C.Amplitude, FS);
  GridCh.Cells[COL_OFS, R] := FloatToStr(C.Offset, FS);
  GridCh.Cells[COL_PERIOD, R] := FloatToStr(C.Period, FS);
  GridCh.Cells[COL_NOISE, R] := FloatToStr(Noise, FS);
  GridCh.Cells[COL_DEC, R] := IntToStr(C.Decimals);
end;

procedure TMainForm.ReadChannels(out A: TGenChannels; out Noise: TDoubles);
var
  R, I: Integer;
  C: TGenChannel;
  W: TWaveShape;
begin
  A := nil;
  Noise := nil;
  SetLength(A, GridCh.RowCount - 1);
  SetLength(Noise, GridCh.RowCount - 1);
  for R := 1 to GridCh.RowCount - 1 do
  begin
    C.Enabled := GridCh.Cells[COL_ON, R] = '1';
    C.Name := Trim(GridCh.Cells[COL_NAME, R]);
    if C.Name = '' then C.Name := 'ch' + IntToStr(R);
    for I := 0 to R - 2 do                         // field names must be unique
      if A[I].Name = C.Name then C.Name := C.Name + '_' + IntToStr(R);
    ShapeFromName(GridCh.Cells[COL_SHAPE, R], W);
    C.Shape := W;
    C.Amplitude := StrToFloatDef(GridCh.Cells[COL_AMP, R], 1, FS);
    C.Offset := StrToFloatDef(GridCh.Cells[COL_OFS, R], 0, FS);
    C.Period := StrToFloatDef(GridCh.Cells[COL_PERIOD, R], 60, FS);
    if C.Period <= 0 then C.Period := 60;
    C.Decimals := EnsureRange(StrToIntDef(GridCh.Cells[COL_DEC, R], 3), 0, 9);
    A[R - 1] := C;
    Noise[R - 1] := Abs(StrToFloatDef(GridCh.Cells[COL_NOISE, R], 0, FS));
  end;
end;

procedure TMainForm.ApplyChannels;
var
  A: TGenChannels;
  Noise: TDoubles;
  I: Integer;
begin
  if FLoading then Exit;
  ReadChannels(A, Noise);
  for I := 0 to High(A) do WriteChannel(I + 1, A[I], Noise[I]);   // show corrected values
  FGen.SetChannels(A, Noise);
end;

procedure TMainForm.GridChEditingDone(Sender: TObject);
begin
  ApplyChannels;
end;

procedure TMainForm.GridChCheckboxToggled(Sender: TObject; aCol, aRow: Integer;
  aState: TCheckboxState);
begin
  ApplyChannels;
end;

procedure TMainForm.ButtonAddClick(Sender: TObject);
begin
  GridCh.RowCount := GridCh.RowCount + 1;
  WriteChannel(GridCh.RowCount - 1, Ch('ch' + IntToStr(GridCh.RowCount - 1), wsSine, 1, 0, 60, 3), 0);
  ApplyChannels;
end;

procedure TMainForm.ButtonDeleteClick(Sender: TObject);
begin
  if (GridCh.Row < 1) or (GridCh.RowCount <= 1) then Exit;
  GridCh.DeleteRow(GridCh.Row);
  ApplyChannels;
end;

{ ---- run ---- }

procedure TMainForm.ButtonTestClick(Sender: TObject);
var
  S: TGenSettings;
  R: TInfluxResult;
begin
  S := Settings;
  R := InfluxPing(S.Conn);
  if not R.Ok then
  begin
    Log('Test: ' + R.Error);
    Exit;
  end;
  Log(Format('Test: InfluxDB %s at %s (%.0f ms)', [R.Version, InfluxBaseUrl(S.Conn.Url), R.Ms]));
  R := InfluxQuery(S.Conn, '', 'CREATE DATABASE ' + QuoteIdent(S.Database));
  if R.Ok then Log('Test: database "' + S.Database + '" ready') else Log('Test: ' + R.Error);
end;

procedure TMainForm.ButtonLiveClick(Sender: TObject);
begin
  ApplySettings;
  ApplyChannels;
  FGen.SetLive(not FGen.Stats.Live);
  if FGen.Stats.Live then
    Log(Format('live: every %d ms to %s / %s', [SpinRate.Value, EditDb.Text, EditMeas.Text]))
  else
    Log('live stopped');
  SaveIni;
  UpdateControls;
end;

procedure TMainForm.ButtonBackfillClick(Sender: TObject);
var
  Span: Int64;
begin
  if FGen.Stats.Backfill then
  begin
    FGen.CancelBackfill;
    Log('backfill cancelled');
    UpdateControls;
    Exit;
  end;
  ApplySettings;
  ApplyChannels;
  Span := SPANS[EnsureRange(ComboSpan.ItemIndex, 0, High(SPANS))];
  FGen.StartBackfill(WallMs - Span * 1000, WallMs, Int64(SpinStep.Value) * 1000);
  FWasBackfill := True;
  Log(Format('backfill: %s, one sample every %d s (%d samples)', [ComboSpan.Text, SpinStep.Value,
    Span div Max(SpinStep.Value, 1)]));
  SaveIni;
  UpdateControls;
end;

procedure TMainForm.UpdateControls;
var
  S: TGenStats;
begin
  S := FGen.Stats;
  if S.Live then ButtonLive.Caption := 'Stop live' else ButtonLive.Caption := 'Start live';
  if S.Backfill then ButtonBackfill.Caption := 'Cancel' else ButtonBackfill.Caption := 'Backfill';
end;

procedure TMainForm.Timer1Timer(Sender: TObject);
var
  S: TGenStats;
  V: TDoubles;
  A: TGenChannels;
  Noise: TDoubles;
  I: Integer;
  Dt: Double;
begin
  S := FGen.Stats;
  Dt := (GetTickCount64 - FPrevT) / 1000;
  if Dt >= 1 then
  begin
    FRate := (S.Sent - FPrevSent) / Dt;
    FPrevSent := S.Sent;
    FPrevT := GetTickCount64;
  end;
  if S.LastError <> '' then ShapeState.Brush.Color := clRed
  else if S.Live or S.Backfill then ShapeState.Brush.Color := clLime
  else ShapeState.Brush.Color := clSilver;
  LabelState.Caption := Format('%s   sent %d points (%.0f/s)   queue %d   errors %d',
    [BoolToStr(S.Live, 'LIVE', 'stopped'), S.Sent, FRate, S.Queue, S.Errors]);
  if S.LastError <> '' then
    LabelState.Caption := LabelState.Caption + '   ' + S.LastError;
  if (S.LastError <> FLastErr) then
  begin
    if S.LastError <> '' then Log('error: ' + S.LastError)
    else if FLastErr <> '' then Log('writing again');
    FLastErr := S.LastError;
  end;
  ProgressBf.Position := Round(S.BackfillDone * 1000);
  if S.Backfill then
    LabelBackfill.Caption := Format('%.1f %%   queue %d', [S.BackfillDone * 100, S.Queue])
  else if FWasBackfill and (S.Queue = 0) then
  begin
    LabelBackfill.Caption := 'backfill sent';
    Log(Format('backfill sent (%d points in total)', [S.Sent]));
    FWasBackfill := False;
    if FExitWhenDone then Close;
  end;
  UpdateControls;
  { live values }
  if not GridCh.EditorMode then
  begin
    V := FGen.Values;
    ReadChannels(A, Noise);
    for I := 0 to Min(High(V), GridCh.RowCount - 2) do
      if A[I].Enabled and (S.Live or S.Backfill) then
        GridCh.Cells[COL_VALUE, I + 1] := FloatToStrF(V[I], ffFixed, 15, A[I].Decimals, FS)
      else
        GridCh.Cells[COL_VALUE, I + 1] := '';
  end;
end;

initialization
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  FS.ThousandSeparator := #0;
end.

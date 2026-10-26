{ ============================================================================
  Machine Simulator - the bottle filling machine of the InfluxDB HMI example.
  It writes its data to InfluxDB and takes its commands from there
  (umachinesim); this window only shows what it does.
    - URL / database, Start (F5) / Stop, buttons for local commands
    - live values, log of events, commands and InfluxDB errors
    - settings in MachineSim.ini; command line --start
  ============================================================================ }
unit usimmain;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, ExtCtrls, StdCtrls, IniFiles,
  uinfluxapi, umachinedef, umachinesim;

type

  { TMainForm }

  TMainForm = class(TForm)
    ButtonClear: TButton;
    ButtonReset: TButton;
    ButtonRun: TButton;
    ButtonStart: TButton;
    ButtonStop: TButton;
    EditDb: TEdit;
    EditUrl: TEdit;
    LabelDb: TLabel;
    LabelUrl: TLabel;
    LabelValues: TLabel;
    LabelState: TLabel;
    MemoLog: TMemo;
    PanelTop: TPanel;
    ShapeState: TShape;
    Timer1: TTimer;
    procedure ButtonClearClick(Sender: TObject);
    procedure ButtonResetClick(Sender: TObject);
    procedure ButtonRunClick(Sender: TObject);
    procedure ButtonStartClick(Sender: TObject);
    procedure ButtonStopClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure Timer1Timer(Sender: TObject);
  private
    FRunner: TMachineRunner;
    procedure UpdateControls;
    function IniName: string;
  end;

var
  MainForm: TMainForm;

implementation

{$R *.lfm}

{ TMainForm }

procedure TMainForm.FormCreate(Sender: TObject);
var
  Ini: TIniFile;
begin
  Randomize;
  Ini := TIniFile.Create(IniName);
  try
    EditUrl.Text := Ini.ReadString('Influx', 'Url', 'http://127.0.0.1:8086');
    EditDb.Text := Ini.ReadString('Influx', 'Database', DEFAULT_DB);
  finally
    Ini.Free;
  end;
  UpdateControls;
  if Application.HasOption('start') then ButtonRunClick(nil);
end;

procedure TMainForm.FormDestroy(Sender: TObject);
var
  Ini: TIniFile;
begin
  Timer1.Enabled := False;
  FreeAndNil(FRunner);
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

procedure TMainForm.UpdateControls;
begin
  EditUrl.Enabled := FRunner = nil;
  EditDb.Enabled := FRunner = nil;
  ButtonStart.Enabled := FRunner <> nil;
  ButtonStop.Enabled := FRunner <> nil;
  ButtonReset.Enabled := FRunner <> nil;
  ButtonClear.Enabled := FRunner <> nil;
  if FRunner = nil then
  begin
    ButtonRun.Caption := 'Run machine';
    ShapeState.Brush.Color := clSilver;
    LabelState.Caption := 'machine off';
    LabelValues.Caption := '';
  end
  else
    ButtonRun.Caption := 'Switch off';
end;

procedure TMainForm.ButtonRunClick(Sender: TObject);
begin
  if FRunner = nil then
  begin
    FRunner := TMachineRunner.Create(InfluxConn(EditUrl.Text), Trim(EditDb.Text));
    MemoLog.Lines.Add(FormatDateTime('hh:nn:ss', Now) + '  machine on, data to ' +
      InfluxBaseUrl(EditUrl.Text) + ' / ' + EditDb.Text);
  end
  else
  begin
    FreeAndNil(FRunner);
    MemoLog.Lines.Add(FormatDateTime('hh:nn:ss', Now) + '  machine off');
  end;
  UpdateControls;
end;

procedure TMainForm.ButtonStartClick(Sender: TObject);
begin
  if FRunner <> nil then FRunner.LocalCommand('cmd', 'start');
end;

procedure TMainForm.ButtonStopClick(Sender: TObject);
begin
  if FRunner <> nil then FRunner.LocalCommand('cmd', 'stop');
end;

procedure TMainForm.ButtonResetClick(Sender: TObject);
begin
  if FRunner <> nil then FRunner.LocalCommand('cmd', 'reset');
end;

procedure TMainForm.ButtonClearClick(Sender: TObject);
begin
  if FRunner <> nil then FRunner.LocalCommand('cmd', 'clear');
end;

procedure TMainForm.Timer1Timer(Sender: TObject);
var
  D: TMachineData;
  W, E, C: Int64;
  Err: string;
begin
  if FRunner = nil then Exit;
  FRunner.TakeLog(MemoLog.Lines);
  while MemoLog.Lines.Count > 1000 do MemoLog.Lines.Delete(0);
  FRunner.Snapshot(D, W, E, C, Err);
  if Err <> '' then ShapeState.Brush.Color := clRed
  else if D.State = 'FAULT' then ShapeState.Brush.Color := $0000A5FF
  else if D.Running then ShapeState.Brush.Color := clLime
  else ShapeState.Brush.Color := clYellow;
  LabelState.Caption := Format('%s   %d points written, %d commands, %d errors   %s',
    [D.State, W, C, E, Err]);
  LabelValues.Caption := Format(
    'speed %s / %s bottles/min     fill %s ml (last %s)     tank %s %%%s     temp %s / %s C%s     ' +
    'power %s kW     good %d   reject %d   quality %s %%   %s',
    [FloatTxt(D.Speed, 1), FloatTxt(D.SpeedSp, 0), FloatTxt(D.FillSp, 0), FloatTxt(D.FillLast, 1),
     FloatTxt(D.Level, 1), BoolToStr(D.Inlet, ' (inlet open)', ''), FloatTxt(D.Temp, 1),
     FloatTxt(D.TempSp, 1), BoolToStr(D.Heater, ' (heater on)', ''), FloatTxt(D.Power, 2),
     D.Good, D.Reject, FloatTxt(QualityPct(D), 1), D.Fault]);
end;

end.

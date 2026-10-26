{ ============================================================================
  MQTT Client - general MQTT 3.1 / 3.1.1 client built with normal Lazarus
  forms (works with MqttSim, Tools/mqttsim.py, Mosquitto or any broker).
    - connection: host, port, client id, keep alive, user / password,
      clean session, last will, auto reconnect
    - subscriptions with QoS, kept over reconnects
    - topic table: last value of every topic, QoS, retained, count, time
    - publish with QoS and retain; double-click a topic to edit its value
    - log of the connection, subscriptions and (optional) every message
    - settings in MqttClient.ini next to the exe (the password is not saved)
  ============================================================================ }
unit uclientmain;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, Menus, ExtCtrls, StdCtrls, Grids,
  IniFiles, mqttcodec, umqttclient;

type

  { TTopicRow }

  TTopicRow = class
    Payload: string;
    QoS: Integer;
    Retain: Boolean;
    Count: Integer;
    Time: TDateTime;
  end;

  { TMainForm }

  TMainForm = class(TForm)
    ButtonClearTopics: TButton;
    ButtonConnect: TButton;
    ButtonPublish: TButton;
    ButtonSubscribe: TButton;
    ButtonUnsubscribe: TButton;
    CheckAutoConnect: TCheckBox;
    CheckAutoReconnect: TCheckBox;
    CheckClean: TCheckBox;
    CheckLogMessages: TCheckBox;
    CheckRetain: TCheckBox;
    CheckWillRetain: TCheckBox;
    ComboLevel: TComboBox;
    ComboPubQoS: TComboBox;
    ComboSubQoS: TComboBox;
    ComboWillQoS: TComboBox;
    EditClientId: TEdit;
    EditFilter: TEdit;
    EditHost: TEdit;
    EditKeepAlive: TEdit;
    EditPassword: TEdit;
    EditPort: TEdit;
    EditPubTopic: TEdit;
    EditUser: TEdit;
    EditWillPayload: TEdit;
    EditWillTopic: TEdit;
    GridTopics: TStringGrid;
    GroupPublish: TGroupBox;
    GroupSubscribe: TGroupBox;
    LabelClientId: TLabel;
    LabelFilter: TLabel;
    LabelHost: TLabel;
    LabelKeepAlive: TLabel;
    LabelPassword: TLabel;
    LabelPayload: TLabel;
    LabelPort: TLabel;
    LabelPubQoS: TLabel;
    LabelPubTopic: TLabel;
    LabelState: TLabel;
    LabelUser: TLabel;
    LabelWill: TLabel;
    LabelWillPayload: TLabel;
    ListSubs: TListBox;
    MainMenu1: TMainMenu;
    MemoLog: TMemo;
    MemoPayload: TMemo;
    MenuAbout: TMenuItem;
    MenuClearLog: TMenuItem;
    MenuConnect: TMenuItem;
    MenuConnection: TMenuItem;
    MenuCopyPublish: TMenuItem;
    MenuCopySet: TMenuItem;
    MenuDisconnect: TMenuItem;
    MenuExit: TMenuItem;
    MenuFile: TMenuItem;
    MenuHelp: TMenuItem;
    MenuSep1: TMenuItem;
    MenuClearTopics: TMenuItem;
    PanelConn: TPanel;
    PanelLeft: TPanel;
    PanelPubBottom: TPanel;
    PanelPubTop: TPanel;
    PopupTopics: TPopupMenu;
    ShapeState: TShape;
    SplitterLeft: TSplitter;
    SplitterLog: TSplitter;
    Timer1: TTimer;
    procedure ButtonClearTopicsClick(Sender: TObject);
    procedure ButtonConnectClick(Sender: TObject);
    procedure ButtonPublishClick(Sender: TObject);
    procedure ButtonSubscribeClick(Sender: TObject);
    procedure ButtonUnsubscribeClick(Sender: TObject);
    procedure EditFilterKeyPress(Sender: TObject; var Key: Char);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure GridTopicsDblClick(Sender: TObject);
    procedure MenuAboutClick(Sender: TObject);
    procedure MenuClearLogClick(Sender: TObject);
    procedure MenuConnectClick(Sender: TObject);
    procedure MenuCopyPublishClick(Sender: TObject);
    procedure MenuCopySetClick(Sender: TObject);
    procedure MenuDisconnectClick(Sender: TObject);
    procedure MenuExitClick(Sender: TObject);
    procedure MemoPayloadKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure Timer1Timer(Sender: TObject);
  private
    FClient: TMqttClient;
    FTopics: TStringList;            // sorted topic -> TTopicRow, row = index + 1
    FSubFilters: TStringList;        // filter of each ListSubs line
    FConnectTimeout: Integer;
    procedure Log(const S: string);
    procedure DoConnect;
    procedure DoDisconnect;
    procedure AddSubscription(const Filter: string; QoS: Integer);
    procedure ShowRow(I: Integer);
    procedure TakeMessages;
    procedure CopyToPublish(AsSet: Boolean);
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
  MAX_SHOWN = 300;                   // payload characters shown in the table / log

{ control characters as '.', long payloads cut }
function ShowPayload(const P: string): string;
var
  I: Integer;
begin
  if P = '' then
    Exit('(empty)');
  Result := Copy(P, 1, MAX_SHOWN);
  for I := 1 to Length(Result) do
    if Result[I] < ' ' then
      Result[I] := '.';
  if Length(P) > MAX_SHOWN then
    Result := Result + Format(' ... (%d bytes)', [Length(P)]);
end;

{ TMainForm }

procedure TMainForm.FormCreate(Sender: TObject);
begin
  Randomize;
  FClient := TMqttClient.Create;
  FTopics := TStringList.Create;
  FTopics.CaseSensitive := True;
  FTopics.Sorted := True;
  FTopics.OwnsObjects := True;
  FSubFilters := TStringList.Create;
  LoadIni;
  UpdateControls;
  if CheckAutoConnect.Checked then
    DoConnect;
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  Timer1.Enabled := False;
  SaveIni;
  FClient.Free;
  FTopics.Free;
  FSubFilters.Free;
end;

function TMainForm.IniName: string;
begin
  Result := ChangeFileExt(Application.ExeName, '.ini');
end;

procedure TMainForm.LoadIni;
var
  Ini: TIniFile;
  I, N: Integer;
begin
  Ini := TIniFile.Create(IniName);
  try
    EditHost.Text := Ini.ReadString('Connection', 'Host', '127.0.0.1');
    EditPort.Text := IntToStr(Ini.ReadInteger('Connection', 'Port', 1884));
    EditClientId.Text := Ini.ReadString('Connection', 'ClientId',
      'lazmqtt-' + LowerCase(IntToHex(Random($FFFFFF), 6)));
    EditKeepAlive.Text := IntToStr(Ini.ReadInteger('Connection', 'KeepAlive', 60));
    if Ini.ReadInteger('Connection', 'Level', 4) = 3 then
      ComboLevel.ItemIndex := 1
    else
      ComboLevel.ItemIndex := 0;
    EditUser.Text := Ini.ReadString('Connection', 'User', '');
    CheckClean.Checked := Ini.ReadBool('Connection', 'CleanSession', True);
    CheckAutoReconnect.Checked := Ini.ReadBool('Connection', 'AutoReconnect', True);
    CheckAutoConnect.Checked := Ini.ReadBool('Connection', 'AutoConnect', False);
    FConnectTimeout := Ini.ReadInteger('Connection', 'ConnectTimeoutMs', 3000);
    EditWillTopic.Text := Ini.ReadString('Will', 'Topic', '');
    EditWillPayload.Text := Ini.ReadString('Will', 'Payload', 'offline');
    ComboWillQoS.ItemIndex := Ini.ReadInteger('Will', 'QoS', 0);
    CheckWillRetain.Checked := Ini.ReadBool('Will', 'Retain', False);
    EditPubTopic.Text := Ini.ReadString('Publish', 'Topic', 'nonlinear/DB_HMI/VoltSP_kV/set');
    ComboPubQoS.ItemIndex := Ini.ReadInteger('Publish', 'QoS', 0);
    CheckRetain.Checked := Ini.ReadBool('Publish', 'Retain', False);
    CheckLogMessages.Checked := Ini.ReadBool('View', 'LogMessages', False);
    N := Ini.ReadInteger('Subscriptions', 'Count', -1);
    if N < 0 then
      AddSubscription('nonlinear/#', 0)              // first start
    else
      for I := 0 to N - 1 do
        AddSubscription(Ini.ReadString('Subscriptions', 'Filter' + IntToStr(I), ''),
          Ini.ReadInteger('Subscriptions', 'QoS' + IntToStr(I), 0));
  finally
    Ini.Free;
  end;
end;

procedure TMainForm.SaveIni;
var
  Ini: TIniFile;
  I: Integer;
  L: TStringList;
begin
  Ini := TIniFile.Create(IniName);
  L := TStringList.Create;
  try
    Ini.WriteString('Connection', 'Host', EditHost.Text);
    Ini.WriteInteger('Connection', 'Port', StrToIntDef(EditPort.Text, 1884));
    Ini.WriteString('Connection', 'ClientId', EditClientId.Text);
    Ini.WriteInteger('Connection', 'KeepAlive', StrToIntDef(EditKeepAlive.Text, 60));
    if ComboLevel.ItemIndex = 1 then
      Ini.WriteInteger('Connection', 'Level', 3)
    else
      Ini.WriteInteger('Connection', 'Level', 4);
    Ini.WriteString('Connection', 'User', EditUser.Text);
    Ini.WriteBool('Connection', 'CleanSession', CheckClean.Checked);
    Ini.WriteBool('Connection', 'AutoReconnect', CheckAutoReconnect.Checked);
    Ini.WriteBool('Connection', 'AutoConnect', CheckAutoConnect.Checked);
    Ini.WriteInteger('Connection', 'ConnectTimeoutMs', FConnectTimeout);
    Ini.WriteString('Will', 'Topic', EditWillTopic.Text);
    Ini.WriteString('Will', 'Payload', EditWillPayload.Text);
    Ini.WriteInteger('Will', 'QoS', ComboWillQoS.ItemIndex);
    Ini.WriteBool('Will', 'Retain', CheckWillRetain.Checked);
    Ini.WriteString('Publish', 'Topic', EditPubTopic.Text);
    Ini.WriteInteger('Publish', 'QoS', ComboPubQoS.ItemIndex);
    Ini.WriteBool('Publish', 'Retain', CheckRetain.Checked);
    Ini.WriteBool('View', 'LogMessages', CheckLogMessages.Checked);
    FClient.GetSubscriptions(L);
    Ini.EraseSection('Subscriptions');
    Ini.WriteInteger('Subscriptions', 'Count', L.Count);
    for I := 0 to L.Count - 1 do
    begin
      Ini.WriteString('Subscriptions', 'Filter' + IntToStr(I), L[I]);
      Ini.WriteInteger('Subscriptions', 'QoS' + IntToStr(I), PtrInt(L.Objects[I]));
    end;
  finally
    L.Free;
    Ini.Free;
  end;
end;

procedure TMainForm.Log(const S: string);
begin
  MemoLog.Lines.Add(FormatDateTime('hh:nn:ss', Now) + '  ' + S);
end;

procedure TMainForm.DoConnect;
var
  C: TMqttConfig;
  Port, KA: Integer;
begin
  if not TryStrToInt(Trim(EditPort.Text), Port) or (Port < 1) or (Port > 65535) then
  begin
    Log('Invalid port: ' + EditPort.Text);
    Exit;
  end;
  if not TryStrToInt(Trim(EditKeepAlive.Text), KA) or (KA < 0) or (KA > 65535) then
  begin
    Log('Invalid keep alive (0..65535 s): ' + EditKeepAlive.Text);
    Exit;
  end;
  if Trim(EditHost.Text) = '' then
  begin
    Log('Enter the broker host');
    Exit;
  end;
  if (ComboLevel.ItemIndex = 1) and (Trim(EditClientId.Text) = '') then
  begin
    Log('MQTT 3.1 needs a client id');
    Exit;
  end;
  if (EditWillTopic.Text <> '') and not ValidTopic(EditWillTopic.Text) then
  begin
    Log('Invalid will topic (no + or #): ' + EditWillTopic.Text);
    Exit;
  end;
  C := Default(TMqttConfig);
  C.Host := Trim(EditHost.Text);
  C.Port := Port;
  C.ClientId := Trim(EditClientId.Text);
  C.UserName := EditUser.Text;
  C.Password := EditPassword.Text;
  C.KeepAlive := KA;
  C.CleanSession := CheckClean.Checked;
  if ComboLevel.ItemIndex = 1 then C.Level := 3 else C.Level := 4;
  C.WillTopic := EditWillTopic.Text;
  C.WillPayload := EditWillPayload.Text;
  C.WillQoS := ComboWillQoS.ItemIndex;
  C.WillRetain := CheckWillRetain.Checked;
  C.ConnectTimeout := FConnectTimeout;
  C.AutoReconnect := CheckAutoReconnect.Checked;
  FClient.Connect(C);
  SaveIni;
  UpdateControls;
end;

procedure TMainForm.DoDisconnect;
begin
  FClient.Disconnect;
  FClient.TakeLog(MemoLog.Lines);
  UpdateControls;
end;

procedure TMainForm.AddSubscription(const Filter: string; QoS: Integer);
var
  I: Integer;
  Line: string;
begin
  if not ValidFilter(Filter) then
  begin
    Log('Invalid filter: "' + Filter + '" (+ and # only as a whole level, # only at the end)');
    Exit;
  end;
  if (QoS < 0) or (QoS > 2) then QoS := 0;
  FClient.Subscribe(Filter, QoS);
  Line := Format('%s   (QoS %d)', [Filter, QoS]);
  I := FSubFilters.IndexOf(Filter);
  if I < 0 then
  begin
    FSubFilters.Add(Filter);
    ListSubs.Items.Add(Line);
  end
  else
    ListSubs.Items[I] := Line;
  if FClient.State <> mqsConnected then
    Log('subscription ' + Filter + ' will be sent when connected');
end;

procedure TMainForm.ShowRow(I: Integer);
var
  R: TTopicRow;
begin
  R := TTopicRow(FTopics.Objects[I]);
  GridTopics.Cells[0, I + 1] := FTopics[I];
  GridTopics.Cells[1, I + 1] := ShowPayload(R.Payload);
  GridTopics.Cells[2, I + 1] := IntToStr(R.QoS);
  if R.Retain then
    GridTopics.Cells[3, I + 1] := 'yes'
  else
    GridTopics.Cells[3, I + 1] := '';
  GridTopics.Cells[4, I + 1] := IntToStr(R.Count);
  GridTopics.Cells[5, I + 1] := FormatDateTime('hh:nn:ss.zzz', R.Time);
end;

procedure TMainForm.TakeMessages;
var
  M: TMqttMessages;
  I, K: Integer;
  R: TTopicRow;
  Dirty: array of Boolean;
  Flags: string;
begin
  M := FClient.TakeMessages;
  if Length(M) = 0 then Exit;
  GridTopics.BeginUpdate;
  try
    for I := 0 to High(M) do
    begin
      if not FTopics.Find(M[I].Topic, K) then
      begin
        R := TTopicRow.Create;
        K := FTopics.AddObject(M[I].Topic, R);
        GridTopics.InsertColRow(False, K + 1);       // keeps the table sorted by topic
      end
      else
        R := TTopicRow(FTopics.Objects[K]);
      R.Payload := M[I].Payload;
      R.QoS := M[I].QoS;
      R.Retain := M[I].Retain;
      Inc(R.Count);
      R.Time := M[I].Time;
      if CheckLogMessages.Checked then
      begin
        Flags := Format('qos %d', [M[I].QoS]);
        if M[I].Retain then Flags := Flags + ', retained';
        if M[I].Dup then Flags := Flags + ', dup';
        Log('<- ' + M[I].Topic + '  ' + ShowPayload(M[I].Payload) + '  (' + Flags + ')');
      end;
    end;
    { rows move when topics are inserted: rewrite the rows of every topic received }
    SetLength(Dirty, FTopics.Count);
    for I := 0 to High(M) do
      if FTopics.Find(M[I].Topic, K) then
        Dirty[K] := True;
    for K := 0 to FTopics.Count - 1 do
      if Dirty[K] or (GridTopics.Cells[0, K + 1] <> FTopics[K]) then
        ShowRow(K);
  finally
    GridTopics.EndUpdate;
  end;
end;

procedure TMainForm.UpdateControls;
var
  Busy: Boolean;
  St: TMqttState;
begin
  Busy := FClient.Active;
  St := FClient.State;
  EditHost.Enabled := not Busy;
  EditPort.Enabled := not Busy;
  EditClientId.Enabled := not Busy;
  EditKeepAlive.Enabled := not Busy;
  ComboLevel.Enabled := not Busy;
  EditUser.Enabled := not Busy;
  EditPassword.Enabled := not Busy;
  CheckClean.Enabled := not Busy;
  CheckAutoReconnect.Enabled := not Busy;
  EditWillTopic.Enabled := not Busy;
  EditWillPayload.Enabled := not Busy;
  ComboWillQoS.Enabled := not Busy;
  CheckWillRetain.Enabled := not Busy;
  MenuConnect.Enabled := not Busy;
  MenuDisconnect.Enabled := Busy;
  ButtonPublish.Enabled := St = mqsConnected;
  if Busy then ButtonConnect.Caption := 'Disconnect' else ButtonConnect.Caption := 'Connect';
  case St of
    mqsConnected: ShapeState.Brush.Color := clLime;
    mqsConnecting: ShapeState.Brush.Color := clYellow;
  else
    ShapeState.Brush.Color := clSilver;
  end;
  if St = mqsConnected then
    LabelState.Caption := Format('Connected to %s:%d   received %d   sent %d   in flight %d   topics %d',
      [FClient.Config.Host, FClient.Config.Port, FClient.Received, FClient.Sent,
       FClient.InFlight, FTopics.Count])
  else if Busy then
    LabelState.Caption := Format('Connecting to %s:%d ...', [FClient.Config.Host, FClient.Config.Port])
  else
    LabelState.Caption := 'Disconnected';
end;

procedure TMainForm.Timer1Timer(Sender: TObject);
begin
  FClient.TakeLog(MemoLog.Lines);
  TakeMessages;
  while MemoLog.Lines.Count > 3000 do
    MemoLog.Lines.Delete(0);
  UpdateControls;
end;

procedure TMainForm.ButtonConnectClick(Sender: TObject);
begin
  if FClient.Active then DoDisconnect else DoConnect;
end;

procedure TMainForm.MenuConnectClick(Sender: TObject);
begin
  if not FClient.Active then DoConnect;
end;

procedure TMainForm.MenuDisconnectClick(Sender: TObject);
begin
  DoDisconnect;
end;

procedure TMainForm.ButtonSubscribeClick(Sender: TObject);
begin
  AddSubscription(Trim(EditFilter.Text), ComboSubQoS.ItemIndex);
end;

procedure TMainForm.EditFilterKeyPress(Sender: TObject; var Key: Char);
begin
  if Key = #13 then
  begin
    Key := #0;
    ButtonSubscribeClick(Sender);
  end;
end;

procedure TMainForm.ButtonUnsubscribeClick(Sender: TObject);
var
  I: Integer;
begin
  I := ListSubs.ItemIndex;
  if I < 0 then
  begin
    Log('Select a subscription first');
    Exit;
  end;
  FClient.Unsubscribe(FSubFilters[I]);
  FSubFilters.Delete(I);
  ListSubs.Items.Delete(I);
end;

procedure TMainForm.ButtonPublishClick(Sender: TObject);
var
  Payload, Err, Flags: string;
begin
  Payload := MemoPayload.Text;
  while (Payload <> '') and (Payload[Length(Payload)] in [#10, #13]) do
    SetLength(Payload, Length(Payload) - 1);       // the line end the memo adds
  if FClient.Publish(Trim(EditPubTopic.Text), Payload, ComboPubQoS.ItemIndex,
    CheckRetain.Checked, Err) then
  begin
    Flags := Format('qos %d', [ComboPubQoS.ItemIndex]);
    if CheckRetain.Checked then Flags := Flags + ', retained';
    Log('-> ' + Trim(EditPubTopic.Text) + '  ' + ShowPayload(Payload) + '  (' + Flags + ')');
  end
  else
    Log('publish refused: ' + Err);
end;

procedure TMainForm.MemoPayloadKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (Key = 13) and (ssCtrl in Shift) then          // Ctrl+Enter = Publish
  begin
    Key := 0;
    if ButtonPublish.Enabled then ButtonPublishClick(Sender);
  end;
end;

procedure TMainForm.CopyToPublish(AsSet: Boolean);
var
  R: Integer;
begin
  R := GridTopics.Row;
  if (R < 1) or (R > FTopics.Count) then Exit;
  if AsSet then
    EditPubTopic.Text := FTopics[R - 1] + '/set'
  else
    EditPubTopic.Text := FTopics[R - 1];
  MemoPayload.Text := TTopicRow(FTopics.Objects[R - 1]).Payload;
  MemoPayload.SetFocus;
  MemoPayload.SelectAll;
end;

procedure TMainForm.GridTopicsDblClick(Sender: TObject);
begin
  CopyToPublish(True);
end;

procedure TMainForm.MenuCopyPublishClick(Sender: TObject);
begin
  CopyToPublish(False);
end;

procedure TMainForm.MenuCopySetClick(Sender: TObject);
begin
  CopyToPublish(True);
end;

procedure TMainForm.ButtonClearTopicsClick(Sender: TObject);
begin
  FTopics.Clear;
  GridTopics.RowCount := 1;
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
  MessageDlg('About', 'MQTT Client - MQTT 3.1 / 3.1.1 client, no DLL' + LineEnding +
    'QoS 0/1/2, retained, last will, keep alive, auto reconnect' + LineEnding +
    'Double-click a topic: edit it as <topic>/set (simulator write)' + LineEnding +
    'Ctrl+Enter in the payload: Publish' + LineEnding +
    'Config: ' + IniName, mtInformation, [mbOK], 0);
end;

end.

{ ============================================================================
  umqttclient - MQTT 3.1 / 3.1.1 client (TCP, no TLS), one worker thread
    - connect with client id, keep alive, clean session, user / password, will
    - publish and subscribe with QoS 0 / 1 / 2 (both directions)
    - keep alive with PINGREQ, auto reconnect (every 3 s) with the same
      subscriptions
    - thread safe: the GUI calls Publish / Subscribe at any time and collects
      received messages and log lines with TakeMessages / TakeLog (timer)
  ============================================================================ }
unit umqttclient;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, ssockets, Sockets, mqttcodec;

type
  TMqttState = (mqsDisconnected, mqsConnecting, mqsConnected);

  TMqttConfig = record
    Host: string;
    Port: Integer;
    ClientId: string;
    UserName, Password: string;      // password is only sent with a user name
    KeepAlive: Integer;              // s, 0 = off
    CleanSession: Boolean;
    Level: Integer;                  // 4 = MQTT 3.1.1, 3 = MQTT 3.1
    WillTopic, WillPayload: string;  // no will if WillTopic = ''
    WillQoS: Integer;
    WillRetain: Boolean;
    ConnectTimeout: Integer;         // ms, TCP connect and CONNACK
    AutoReconnect: Boolean;
  end;

  TMqttMessage = record
    Topic, Payload: string;
    QoS: Integer;
    Retain, Dup: Boolean;
    Time: TDateTime;
  end;
  TMqttMessages = array of TMqttMessage;

  { TMqttClient }

  TMqttClient = class
  private
    FLock: TCriticalSection;
    FLogLock: TCriticalSection;
    FThread: TThread;
    FCfg: TMqttConfig;
    FState: TMqttState;
    FOut: string;                    // bytes waiting to be sent (only while connected)
    FMsgs: TMqttMessages;
    FMsgCount, FDropped: Integer;
    FLog: TStringList;
    FSubs: TStringList;              // filter -> QoS in Objects, kept for reconnects
    FPending: TStringList;           // SUBSCRIBE / UNSUBSCRIBE packet id -> TStringList of filters
    FInFlight: Integer;              // our QoS 1 / 2 messages without PUBACK / PUBCOMP
    FNextId: Word;
    FRx, FTx: Int64;
    function NextId: Word;
    procedure Send(const Data: string);
    function TakeOut: string;
    procedure AddMessage(const M: TMqttMessage);
    procedure SetState(S: TMqttState);
    procedure SessionStart;
    procedure SessionEnd;
    procedure ClearPending;
    function TakePending(Id: Integer): TStringList;
    procedure Acked;
  public
    constructor Create;
    destructor Destroy; override;
    { starts the worker thread (an open connection is closed first) }
    procedure Connect(const Cfg: TMqttConfig);
    { sends DISCONNECT and waits for the worker thread (no last will) }
    procedure Disconnect;
    function Publish(const Topic, Payload: string; QoS: Integer; Retain: Boolean;
      out Err: string): Boolean;
    { stored for reconnects, sent at once when connected }
    procedure Subscribe(const Filter: string; QoS: Integer);
    procedure Unsubscribe(const Filter: string);
    procedure GetSubscriptions(Dest: TStrings);
    function TakeMessages: TMqttMessages;
    procedure TakeLog(Dest: TStrings);
    procedure Log(const S: string);
    function State: TMqttState;
    { the worker thread runs: connected, connecting or waiting to reconnect }
    function Active: Boolean;
    function InFlight: Integer;
    function Received: Int64;
    function Sent: Int64;
    property Config: TMqttConfig read FCfg;
  end;

const
  MqttStateName: array[TMqttState] of string = ('disconnected', 'connecting', 'connected');

implementation

{$IFDEF WINDOWS}
uses
  WinSock2;
{$ELSE}
uses
  BaseUnix;
{$ENDIF}

const
  MAX_MESSAGES = 20000;        // received, not yet taken by the GUI
  RECONNECT_DELAY = 3000;      // ms
  IPPROTO_TCP_ = 6;
  TCP_NODELAY_ = 1;

type
  EMqttClosed = class(Exception);

  { TClientThread }

  TClientThread = class(TThread)
  private
    FClient: TMqttClient;
    FSock: TInetSocket;
    FLastSend, FPingSent: QWord;
    FRefused: Boolean;               // CONNACK refused: reconnecting would not help
    FQoS2In: array of Word;          // received QoS 2 ids waiting for PUBREL
    function WaitData(Ms: Integer): Boolean;
    procedure RecvExact(var Buf; Count: Integer);
    procedure SendRaw(const S: string);
    procedure ReadPacket(out PType, Flags: Byte; out Body: string);
    function ConnectPacket: string;
    procedure HandlePacket(PType, Flags: Byte; const Body: string);
    procedure HandlePublish(Flags: Byte; const B: string);
    procedure Session;
  protected
    procedure Execute; override;
  public
    constructor Create(AClient: TMqttClient);
  end;

{ ---------------------------------------------------------------------------- }
{ TClientThread }

constructor TClientThread.Create(AClient: TMqttClient);
begin
  FClient := AClient;
  inherited Create(False);
end;

function TClientThread.WaitData(Ms: Integer): Boolean;
var
  R: LongInt;
{$IFDEF WINDOWS}
  FDS: WinSock2.TFDSet;
  TV: WinSock2.TTimeVal;
begin
  WinSock2.FD_ZERO(FDS);
  WinSock2.FD_SET(FSock.Handle, FDS);
  TV.tv_sec := 0;
  TV.tv_usec := Ms * 1000;
  R := WinSock2.select(0, @FDS, nil, nil, @TV);
{$ELSE}
  FDS: TFDSet;
  TV: TTimeVal;
begin
  fpFD_ZERO(FDS);
  fpFD_SET(FSock.Handle, FDS);
  TV.tv_sec := 0;
  TV.tv_usec := Ms * 1000;
  R := fpSelect(FSock.Handle + 1, @FDS, nil, nil, @TV);
{$ENDIF}
  if R < 0 then
    raise EMqttClosed.Create('closed');
  Result := R > 0;
end;

procedure TClientThread.RecvExact(var Buf; Count: Integer);
var
  P: PByte;
  R: LongInt;
begin
  P := @Buf;
  while Count > 0 do
  begin
    R := fpRecv(FSock.Handle, P, Count, 0);
    if R <= 0 then
      raise EMqttClosed.Create('closed');
    Inc(P, R);
    Dec(Count, R);
  end;
end;

procedure TClientThread.SendRaw(const S: string);
var
  Ofs, R: Integer;
begin
  Ofs := 1;
  while Ofs <= Length(S) do
  begin
    R := fpSend(FSock.Handle, @S[Ofs], Length(S) - Ofs + 1, 0);
    if R <= 0 then
      raise EMqttClosed.Create('closed');
    Inc(Ofs, R);
  end;
  if S <> '' then
    FLastSend := GetTickCount64;
end;

procedure TClientThread.ReadPacket(out PType, Flags: Byte; out Body: string);
var
  H, B: Byte;
  N, Mult, I: Integer;
begin
  RecvExact(H, 1);
  N := 0;
  Mult := 1;
  I := 0;
  repeat
    RecvExact(B, 1);
    Inc(N, (B and $7F) * Mult);
    Mult := Mult shl 7;
    Inc(I);
    if (B and $80 <> 0) and (I = 4) then
      raise EMqttError.Create('bad remaining length');
  until B and $80 = 0;
  if N > MAX_PACKET then
    raise EMqttError.CreateFmt('packet too large (%d bytes)', [N]);
  Body := '';
  SetLength(Body, N);
  if N > 0 then
    RecvExact(Body[1], N);
  PType := H shr 4;
  Flags := H and $0F;
end;

function TClientThread.ConnectPacket: string;
var
  C: TMqttConfig;
  Flags: Integer;
  Body: string;
begin
  C := FClient.FCfg;
  Flags := 0;
  if C.CleanSession then Flags := Flags or $02;
  if C.WillTopic <> '' then
  begin
    Flags := Flags or $04 or (C.WillQoS shl 3);
    if C.WillRetain then Flags := Flags or $20;
  end;
  if C.UserName <> '' then
  begin
    Flags := Flags or $80;
    if C.Password <> '' then Flags := Flags or $40;
  end;
  if C.Level = 3 then
    Body := EncStr('MQIsdp') + #3
  else
    Body := EncStr('MQTT') + #4;
  Body := Body + Chr(Flags) + EncU16(C.KeepAlive) + EncStr(C.ClientId);
  if C.WillTopic <> '' then
    Body := Body + EncStr(C.WillTopic) + EncStr(C.WillPayload);
  if C.UserName <> '' then
  begin
    Body := Body + EncStr(C.UserName);
    if C.Password <> '' then Body := Body + EncStr(C.Password);
  end;
  Result := Packet(MQ_CONNECT, 0, Body);
end;

procedure TClientThread.HandlePublish(Flags: Byte; const B: string);
var
  M: TMqttMessage;
  P, Id, I: Integer;
begin
  M.QoS := (Flags shr 1) and 3;
  M.Retain := Flags and 1 <> 0;
  M.Dup := Flags and 8 <> 0;
  if M.QoS = 3 then
    raise EMqttError.Create('PUBLISH with QoS 3');
  P := 1;
  M.Topic := GetStr(B, P);
  Id := 0;
  if M.QoS > 0 then
  begin
    Id := GetU16(B, P);
    Inc(P, 2);
  end;
  M.Payload := Copy(B, P, MaxInt);
  M.Time := Now;
  if M.QoS = 1 then
    FClient.Send(Packet(MQ_PUBACK, 0, EncU16(Id)))
  else if M.QoS = 2 then
  begin
    FClient.Send(Packet(MQ_PUBREC, 0, EncU16(Id)));
    for I := 0 to High(FQoS2In) do
      if FQoS2In[I] = Id then
        Exit;                                       // sent again before PUBREL: only once
    SetLength(FQoS2In, Length(FQoS2In) + 1);
    FQoS2In[High(FQoS2In)] := Id;
  end;
  FClient.AddMessage(M);
end;

procedure TClientThread.HandlePacket(PType, Flags: Byte; const Body: string);
var
  Id, I: Integer;
  L: TStringList;
  S: string;
begin
  case PType of
    MQ_PUBLISH: HandlePublish(Flags, Body);
    MQ_PUBACK, MQ_PUBCOMP:
      FClient.Acked;
    MQ_PUBREC:                                      // our QoS 2 message, step 2
      FClient.Send(Packet(MQ_PUBREL, 2, EncU16(GetU16(Body, 1))));
    MQ_PUBREL:
      begin
        Id := GetU16(Body, 1);
        for I := 0 to High(FQoS2In) do
          if FQoS2In[I] = Id then
          begin
            Delete(FQoS2In, I, 1);
            Break;
          end;
        FClient.Send(Packet(MQ_PUBCOMP, 0, EncU16(Id)));
      end;
    MQ_SUBACK:
      begin
        L := FClient.TakePending(GetU16(Body, 1));
        if L <> nil then
          try
            for I := 0 to L.Count - 1 do
            begin
              if I + 3 > Length(Body) then Break;
              if Ord(Body[I + 3]) = $80 then
                FClient.Log('subscribe REFUSED by the broker: ' + L[I])
              else
                FClient.Log(Format('subscribed %s (granted QoS %d)', [L[I], Ord(Body[I + 3])]));
            end;
          finally
            L.Free;
          end;
      end;
    MQ_UNSUBACK:
      begin
        L := FClient.TakePending(GetU16(Body, 1));
        if L <> nil then
          try
            S := L.CommaText;
            FClient.Log('unsubscribed ' + S);
          finally
            L.Free;
          end;
      end;
    MQ_PINGRESP:
      FPingSent := 0;
  else
    raise EMqttError.Create('unexpected ' + PacketName(PType) + ' from the broker');
  end;
end;

procedure TClientThread.Session;
var
  C: TMqttConfig;
  PType, Flags: Byte;
  Body: string;
  T0, Now_, KA: QWord;
  One: LongInt;
begin
  C := FClient.FCfg;
  FClient.SetState(mqsConnecting);
  FClient.Log(Format('connecting to %s:%d ...', [C.Host, C.Port]));
  try
    FSock := TInetSocket.Create(C.Host, C.Port, C.ConnectTimeout);
  except
    on E: Exception do
    begin
      FClient.Log('connect failed: ' + E.Message);
      FClient.SetState(mqsDisconnected);
      Exit;
    end;
  end;
  FQoS2In := nil;
  FPingSent := 0;
  try
    try
      One := 1;
      fpSetSockOpt(FSock.Handle, IPPROTO_TCP_, TCP_NODELAY_, @One, SizeOf(One));
      SendRaw(ConnectPacket);
      T0 := GetTickCount64;
      while not WaitData(50) do
      begin
        if Terminated then Exit;
        if GetTickCount64 - T0 > QWord(C.ConnectTimeout) then
          raise EMqttError.Create('no CONNACK from the broker');
      end;
      ReadPacket(PType, Flags, Body);
      if (PType <> MQ_CONNACK) or (Length(Body) < 2) then
        raise EMqttError.Create('broker answered ' + PacketName(PType) + ' instead of CONNACK');
      if Ord(Body[2]) <> 0 then
      begin
        FClient.Log('connection refused by the broker: ' + ConnackText(Ord(Body[2])));
        FRefused := Ord(Body[2]) <> 3;               // 3 = server unavailable, try again
        Exit;
      end;
      if Ord(Body[1]) and 1 <> 0 then
        FClient.Log('connected (session present)')
      else
        FClient.Log('connected');
      FClient.SessionStart;
      KA := QWord(C.KeepAlive) * 1000;
      while not Terminated do
      begin
        if WaitData(20) then
        begin
          ReadPacket(PType, Flags, Body);
          HandlePacket(PType, Flags, Body);
        end;
        SendRaw(FClient.TakeOut);
        if KA > 0 then
        begin
          Now_ := GetTickCount64;
          if FPingSent > 0 then
          begin
            if Now_ - FPingSent > KA then
              raise EMqttError.Create('no PINGRESP within the keep alive time');
          end
          else if Now_ - FLastSend >= KA * 3 div 4 then
          begin
            SendRaw(Packet(MQ_PINGREQ, 0));
            FPingSent := Now_;
          end;
        end;
      end;
      SendRaw(FClient.TakeOut);
      SendRaw(Packet(MQ_DISCONNECT, 0));             // clean close: the broker drops the will
      FClient.Log('disconnected');
    except
      on E: EMqttClosed do
        if FClient.State = mqsConnected then
          FClient.Log('connection closed by the broker')
        else      // old brokers close instead of sending CONNACK code 1
          FClient.Log('closed by the broker before CONNACK (protocol version not supported? ' +
            'try MQTT 3.1)');
      on E: Exception do
        FClient.Log('connection lost: ' + E.Message);
    end;
  finally
    FClient.SessionEnd;
    FreeAndNil(FSock);
  end;
end;

procedure TClientThread.Execute;
var
  T0: QWord;
begin
  while not Terminated do
  begin
    Session;
    if Terminated or not FClient.FCfg.AutoReconnect or FRefused then
      Break;
    FClient.SetState(mqsConnecting);
    T0 := GetTickCount64;
    while not Terminated and (GetTickCount64 - T0 < RECONNECT_DELAY) do
      Sleep(50);
  end;
  FClient.SetState(mqsDisconnected);
end;

{ ---------------------------------------------------------------------------- }
{ TMqttClient }

constructor TMqttClient.Create;
begin
  FLock := TCriticalSection.Create;
  FLogLock := TCriticalSection.Create;
  FLog := TStringList.Create;
  FSubs := TStringList.Create;
  FSubs.CaseSensitive := True;
  FPending := TStringList.Create;
end;

destructor TMqttClient.Destroy;
begin
  Disconnect;
  ClearPending;
  FPending.Free;
  FSubs.Free;
  FLog.Free;
  FLogLock.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TMqttClient.Connect(const Cfg: TMqttConfig);
begin
  Disconnect;
  FCfg := Cfg;
  if FCfg.ConnectTimeout <= 0 then FCfg.ConnectTimeout := 3000;
  FThread := TClientThread.Create(Self);
end;

procedure TMqttClient.Disconnect;
begin
  if FThread = nil then Exit;
  FThread.Terminate;
  FThread.WaitFor;
  FreeAndNil(FThread);
end;

function TMqttClient.NextId: Word;
begin
  FNextId := FNextId mod $FFFF + 1;
  Result := FNextId;
end;

procedure TMqttClient.Send(const Data: string);
begin
  FLock.Enter;
  try
    FOut := FOut + Data;
  finally
    FLock.Leave;
  end;
end;

function TMqttClient.TakeOut: string;
begin
  FLock.Enter;
  try
    Result := FOut;
    FOut := '';
  finally
    FLock.Leave;
  end;
end;

procedure TMqttClient.SetState(S: TMqttState);
begin
  FLock.Enter;
  try
    FState := S;
  finally
    FLock.Leave;
  end;
end;

procedure TMqttClient.ClearPending;
var
  I: Integer;
begin
  for I := 0 to FPending.Count - 1 do
    FPending.Objects[I].Free;
  FPending.Clear;
end;

function TMqttClient.TakePending(Id: Integer): TStringList;
var
  I: Integer;
begin
  Result := nil;
  FLock.Enter;
  try
    I := FPending.IndexOf(IntToStr(Id));
    if I >= 0 then
    begin
      Result := TStringList(FPending.Objects[I]);
      FPending.Delete(I);
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TMqttClient.Acked;
begin
  FLock.Enter;
  try
    if FInFlight > 0 then Dec(FInFlight);
  finally
    FLock.Leave;
  end;
end;

{ CONNACK accepted: subscribe again to everything (also after a reconnect) }
procedure TMqttClient.SessionStart;
var
  I: Integer;
  Id: Word;
  Body: string;
  L: TStringList;
begin
  FLock.Enter;
  try
    FOut := '';
    FInFlight := 0;
    ClearPending;
    FState := mqsConnected;
    if FSubs.Count = 0 then Exit;
    Id := NextId;
    Body := EncU16(Id);
    L := TStringList.Create;
    for I := 0 to FSubs.Count - 1 do
    begin
      Body := Body + EncStr(FSubs[I]) + Chr(PtrInt(FSubs.Objects[I]));
      L.Add(FSubs[I]);
    end;
    FPending.AddObject(IntToStr(Id), L);
    FOut := Packet(MQ_SUBSCRIBE, 2, Body);
  finally
    FLock.Leave;
  end;
end;

procedure TMqttClient.SessionEnd;
begin
  FLock.Enter;
  try
    FOut := '';
    if FInFlight > 0 then
      Log(Format('%d QoS 1 / 2 message(s) were not acknowledged', [FInFlight]));
    FInFlight := 0;
    ClearPending;
    FState := mqsDisconnected;
  finally
    FLock.Leave;
  end;
end;

procedure TMqttClient.AddMessage(const M: TMqttMessage);
begin
  FLock.Enter;
  try
    Inc(FRx);
    if FMsgCount >= MAX_MESSAGES then
    begin
      Inc(FDropped);
      Exit;
    end;
    if FMsgCount >= Length(FMsgs) then
      SetLength(FMsgs, Length(FMsgs) * 2 + 64);
    FMsgs[FMsgCount] := M;
    Inc(FMsgCount);
  finally
    FLock.Leave;
  end;
end;

function TMqttClient.Publish(const Topic, Payload: string; QoS: Integer; Retain: Boolean;
  out Err: string): Boolean;
var
  Body: string;
begin
  Err := '';
  if not ValidTopic(Topic) then
    Err := 'invalid topic (empty, or with + / #)'
  else if (QoS < 0) or (QoS > 2) then
    Err := 'QoS must be 0, 1 or 2'
  else if Length(Payload) + Length(Topic) > MAX_PACKET - 8 then
    Err := 'payload too large';
  if Err <> '' then Exit(False);
  FLock.Enter;
  try
    if FState <> mqsConnected then
    begin
      Err := 'not connected';
      Exit(False);
    end;
    Body := EncStr(Topic);
    if QoS > 0 then
    begin
      Body := Body + EncU16(NextId);
      Inc(FInFlight);
    end;
    FOut := FOut + Packet(MQ_PUBLISH, (QoS shl 1) or Ord(Retain), Body + Payload);
    Inc(FTx);
    Result := True;
  finally
    FLock.Leave;
  end;
end;

procedure TMqttClient.Subscribe(const Filter: string; QoS: Integer);
var
  I: Integer;
  Id: Word;
  L: TStringList;
begin
  FLock.Enter;
  try
    I := FSubs.IndexOf(Filter);
    if I < 0 then
      FSubs.AddObject(Filter, TObject(PtrInt(QoS)))
    else
      FSubs.Objects[I] := TObject(PtrInt(QoS));
    if FState <> mqsConnected then Exit;
    Id := NextId;
    L := TStringList.Create;
    L.Add(Filter);
    FPending.AddObject(IntToStr(Id), L);
    FOut := FOut + Packet(MQ_SUBSCRIBE, 2, EncU16(Id) + EncStr(Filter) + Chr(QoS));
  finally
    FLock.Leave;
  end;
end;

procedure TMqttClient.Unsubscribe(const Filter: string);
var
  I: Integer;
  Id: Word;
  L: TStringList;
begin
  FLock.Enter;
  try
    I := FSubs.IndexOf(Filter);
    if I >= 0 then
      FSubs.Delete(I);
    if FState <> mqsConnected then Exit;
    Id := NextId;
    L := TStringList.Create;
    L.Add(Filter);
    FPending.AddObject(IntToStr(Id), L);
    FOut := FOut + Packet(MQ_UNSUBSCRIBE, 2, EncU16(Id) + EncStr(Filter));
  finally
    FLock.Leave;
  end;
end;

procedure TMqttClient.GetSubscriptions(Dest: TStrings);
var
  I: Integer;
begin
  FLock.Enter;
  try
    Dest.Clear;
    for I := 0 to FSubs.Count - 1 do
      Dest.AddObject(FSubs[I], FSubs.Objects[I]);
  finally
    FLock.Leave;
  end;
end;

function TMqttClient.TakeMessages: TMqttMessages;
var
  D: Integer;
begin
  FLock.Enter;
  try
    Result := Copy(FMsgs, 0, FMsgCount);
    FMsgCount := 0;
    if Length(FMsgs) > 4096 then
      FMsgs := nil;                                  // give back memory after a burst
    D := FDropped;
    FDropped := 0;
  finally
    FLock.Leave;
  end;
  if D > 0 then
    Log(Format('%d message(s) dropped (the window could not keep up)', [D]));
end;

procedure TMqttClient.Log(const S: string);
begin
  FLogLock.Enter;
  try
    FLog.Add(FormatDateTime('hh:nn:ss', Now) + '  ' + S);
    while FLog.Count > 1000 do
      FLog.Delete(0);
  finally
    FLogLock.Leave;
  end;
end;

procedure TMqttClient.TakeLog(Dest: TStrings);
begin
  FLogLock.Enter;
  try
    if FLog.Count = 0 then Exit;
    Dest.AddStrings(FLog);
    FLog.Clear;
  finally
    FLogLock.Leave;
  end;
end;

function TMqttClient.State: TMqttState;
begin
  FLock.Enter;
  try
    Result := FState;
  finally
    FLock.Leave;
  end;
end;

function TMqttClient.Active: Boolean;
begin
  Result := (FThread <> nil) and not FThread.Finished;
end;

function TMqttClient.InFlight: Integer;
begin
  FLock.Enter;
  try
    Result := FInFlight;
  finally
    FLock.Leave;
  end;
end;

function TMqttClient.Received: Int64;
begin
  FLock.Enter;
  try
    Result := FRx;
  finally
    FLock.Leave;
  end;
end;

function TMqttClient.Sent: Int64;
begin
  FLock.Enter;
  try
    Result := FTx;
  finally
    FLock.Leave;
  end;
end;

end.

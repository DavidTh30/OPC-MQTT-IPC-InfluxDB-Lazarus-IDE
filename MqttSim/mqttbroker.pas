{ ============================================================================
  mqttbroker - small MQTT 3.1 / 3.1.1 broker (TCP, no TLS, anonymous)
    - one thread per client, up to 32 clients
    - wildcards + and #, retained messages, QoS 0 / 1 / 2, last will, keep alive
    - no persistent sessions (every connect starts clean), MQTT 5 is refused
    - OnWrite sees every PUBLISH from a client before it is routed, so the
      simulator can take its "<tag>/set" topics
  ============================================================================ }
unit mqttbroker;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, Math, Sockets, mqttcodec;

type
  { True = the message was taken (it is not routed to the subscribers) }
  TMqttWriteEvent = function(const Topic, Payload: string): Boolean of object;

  { TMqttBroker }

  TMqttBroker = class
  private
    FLock: TCriticalSection;       // clients, subscriptions, retained messages
    FLogLock: TCriticalSection;
    FLog: TStringList;
    FListen: LongInt;
    FListener: TThread;
    FClients: TFPList;             // TMqttConn
    FRetained: TStringList;        // sorted, topic -> TRetainMsg
    FPort: Integer;
    FRunning: Boolean;
    FAutoId: Cardinal;
    FOnWrite: TMqttWriteEvent;
    procedure AddConn(Sock: LongInt; const Peer: string);
  public
    constructor Create;
    destructor Destroy; override;
    function Start(APort: Integer; out Err: string): Boolean;
    procedure Stop;
    { route a message to every matching subscription; Retain stores it (empty payload = delete) }
    procedure Publish(const Topic, Payload: string; QoS: Integer = 0; Retain: Boolean = False);
    procedure Log(const S: string);
    procedure TakeLog(Dest: TStrings);
    function ClientCount: Integer;
    function RetainedCount: Integer;
    property Running: Boolean read FRunning;
    property Port: Integer read FPort;
    property OnWrite: TMqttWriteEvent read FOnWrite write FOnWrite;
  end;

implementation

{$IFDEF WINDOWS}
uses
  WinSock2;
{$ELSE}
uses
  BaseUnix;
{$ENDIF}

const
  MAX_CLIENTS = 32;
  MAX_QUEUE = 4 * 1024 * 1024;  // unsent bytes per client; more = client too slow, closed
  CONNECT_TIMEOUT = 10000;      // ms from TCP connect to CONNECT
  IPPROTO_TCP_ = 6;
  TCP_NODELAY_ = 1;

type
  EMqttClosed = class(Exception);   // socket closed, nothing to log

  TRetainMsg = class
    Payload: string;
    QoS: Integer;
  end;

  { TMqttListener }

  TMqttListener = class(TThread)
  private
    FBroker: TMqttBroker;
  protected
    procedure Execute; override;
  public
    constructor Create(ABroker: TMqttBroker);
  end;

  { TMqttConn }

  TMqttConn = class(TThread)
  private
    FBroker: TMqttBroker;
    FSock: LongInt;
    FPeer: string;
    FOutLock: TCriticalSection;
    FOut: string;                   // bytes waiting to be sent
    FOverflow: Boolean;
    FNextId: Word;
    FConnected: Boolean;            // CONNECT accepted
    FKeepAlive: Integer;            // s, 0 = off
    FLastRecv: QWord;
    FHasWill, FWillRetain: Boolean;
    FWillTopic, FWillPayload: string;
    FWillQoS: Integer;
    FQoS2In: array of Word;         // QoS 2 packet ids waiting for PUBREL
    function WaitData(Ms: Integer): Boolean;
    procedure RecvExact(var Buf; Count: Integer);
    procedure ReadPacket(out PType, Flags: Byte; out Body: string);
    procedure Flush;
    function Name: string;
    function HandleConnect(const B: string): Boolean;
    procedure HandlePublish(Flags: Byte; const B: string);
    procedure HandlePubRel(const B: string);
    procedure HandleSubscribe(const B: string);
    procedure HandleUnsubscribe(const B: string);
  protected
    procedure Execute; override;
  public
    ClientId: string;
    Online: Boolean;                // receives messages (guarded by the broker lock)
    Kicked: Boolean;                // replaced by a new connection with the same client id
    Subs: TStringList;              // filter -> granted QoS in Objects (broker lock)
    constructor Create(ABroker: TMqttBroker; ASock: LongInt; const APeer: string);
    destructor Destroy; override;
    procedure Shutdown;
    procedure Enqueue(const Data: string);
    procedure Deliver(const Topic, Payload: string; QoS: Integer; Retain: Boolean);
  end;

procedure MaskFPU;
begin
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
end;

{ ---------------------------------------------------------------------------- }
{ TMqttBroker }

constructor TMqttBroker.Create;
begin
  FLock := TCriticalSection.Create;
  FLogLock := TCriticalSection.Create;
  FLog := TStringList.Create;
  FClients := TFPList.Create;
  FRetained := TStringList.Create;
  FRetained.CaseSensitive := True;
  FRetained.Sorted := True;
  FListen := -1;
end;

destructor TMqttBroker.Destroy;
var
  I: Integer;
begin
  Stop;
  for I := 0 to FRetained.Count - 1 do
    FRetained.Objects[I].Free;
  FRetained.Free;
  FClients.Free;
  FLog.Free;
  FLogLock.Free;
  FLock.Free;
  inherited Destroy;
end;

function TMqttBroker.Start(APort: Integer; out Err: string): Boolean;
var
  Addr: TInetSockAddr;
  One: LongInt;
begin
  Err := '';
  if FRunning then Exit(True);
  FListen := fpSocket(AF_INET, SOCK_STREAM, 0);
  if FListen < 0 then
  begin
    Err := 'socket() failed, error ' + IntToStr(SocketError);
    Exit(False);
  end;
  {$IFNDEF WINDOWS}
  One := 1;     // on Windows SO_REUSEADDR would let two servers share the port
  fpSetSockOpt(FListen, SOL_SOCKET, SO_REUSEADDR, @One, SizeOf(One));
  {$ENDIF}
  One := 0;
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := htons(APort);
  Addr.sin_addr.s_addr := 0;
  if (fpBind(FListen, @Addr, SizeOf(Addr)) <> 0) or (fpListen(FListen, 8) <> 0) then
  begin
    Err := Format('port %d is not free (error %d)', [APort, SocketError]);
    CloseSocket(FListen);
    FListen := -1;
    Exit(False);
  end;
  FPort := APort;
  FRunning := True;
  FListener := TMqttListener.Create(Self);
  Log(Format('Broker started: tcp://<this PC>:%d', [APort]));
  Result := True;
end;

procedure TMqttBroker.Stop;
var
  I: Integer;
  L: TFPList;
begin
  if not FRunning then Exit;
  FRunning := False;
  FListener.Terminate;
  CloseSocket(FListen);
  FListener.WaitFor;
  FreeAndNil(FListener);
  FListen := -1;
  { the connections take FLock when they end (last will), so wait for them outside it }
  L := TFPList.Create;
  try
    FLock.Enter;
    try
      L.Assign(FClients);
    finally
      FLock.Leave;
    end;
    for I := 0 to L.Count - 1 do
      TMqttConn(L[I]).Shutdown;
    for I := 0 to L.Count - 1 do
      TMqttConn(L[I]).WaitFor;
    FLock.Enter;
    try
      FClients.Clear;
    finally
      FLock.Leave;
    end;
    for I := 0 to L.Count - 1 do
      TMqttConn(L[I]).Free;
  finally
    L.Free;
  end;
  Log('Broker stopped');
end;

procedure TMqttBroker.AddConn(Sock: LongInt; const Peer: string);
var
  I: Integer;
  C: TMqttConn;
begin
  FLock.Enter;
  try
    for I := FClients.Count - 1 downto 0 do      // remove closed connections
    begin
      C := TMqttConn(FClients[I]);
      if C.Finished then
      begin
        FClients.Delete(I);
        C.WaitFor;
        C.Free;
      end;
    end;
    if FClients.Count >= MAX_CLIENTS then
    begin
      CloseSocket(Sock);
      Log(Peer + ' refused: too many connections');
      Exit;
    end;
    FClients.Add(TMqttConn.Create(Self, Sock, Peer));
  finally
    FLock.Leave;
  end;
end;

procedure TMqttBroker.Publish(const Topic, Payload: string; QoS: Integer; Retain: Boolean);
var
  I, J, Q, Idx: Integer;
  C: TMqttConn;
  R: TRetainMsg;
begin
  FLock.Enter;
  try
    if Retain then
    begin
      Idx := FRetained.IndexOf(Topic);
      if Payload = '' then
      begin
        if Idx >= 0 then
        begin
          FRetained.Objects[Idx].Free;
          FRetained.Delete(Idx);
        end;
      end
      else
      begin
        if Idx < 0 then
        begin
          R := TRetainMsg.Create;
          FRetained.AddObject(Topic, R);
        end
        else
          R := TRetainMsg(FRetained.Objects[Idx]);
        R.Payload := Payload;
        R.QoS := QoS;
      end;
    end;
    for I := 0 to FClients.Count - 1 do
    begin
      C := TMqttConn(FClients[I]);
      if not C.Online then Continue;
      Q := -1;
      for J := 0 to C.Subs.Count - 1 do
        if TopicMatch(C.Subs[J], Topic) then
          Q := Max(Q, Integer(PtrInt(C.Subs.Objects[J])));
      if Q >= 0 then
        C.Deliver(Topic, Payload, Min(QoS, Q), False);
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TMqttBroker.Log(const S: string);
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

procedure TMqttBroker.TakeLog(Dest: TStrings);
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

function TMqttBroker.ClientCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  FLock.Enter;
  try
    for I := 0 to FClients.Count - 1 do
      if TMqttConn(FClients[I]).Online then
        Inc(Result);
  finally
    FLock.Leave;
  end;
end;

function TMqttBroker.RetainedCount: Integer;
begin
  FLock.Enter;
  try
    Result := FRetained.Count;
  finally
    FLock.Leave;
  end;
end;

{ ---------------------------------------------------------------------------- }
{ TMqttListener }

constructor TMqttListener.Create(ABroker: TMqttBroker);
begin
  FBroker := ABroker;
  inherited Create(False);
end;

procedure TMqttListener.Execute;
var
  Addr: TInetSockAddr;
  L: TSockLen;
  S: LongInt;
begin
  while not Terminated do
  begin
    L := SizeOf(Addr);
    S := fpAccept(FBroker.FListen, @Addr, @L);
    if Terminated then
    begin
      if S >= 0 then CloseSocket(S);
      Break;
    end;
    if S < 0 then
    begin
      Sleep(100);
      Continue;
    end;
    FBroker.AddConn(S, NetAddrToStr(Addr.sin_addr) + ':' + IntToStr(ntohs(Addr.sin_port)));
  end;
end;

{ ---------------------------------------------------------------------------- }
{ TMqttConn - socket I/O }

constructor TMqttConn.Create(ABroker: TMqttBroker; ASock: LongInt; const APeer: string);
var
  One: LongInt;
begin
  FBroker := ABroker;
  FSock := ASock;
  FPeer := APeer;
  FOutLock := TCriticalSection.Create;
  Subs := TStringList.Create;
  Subs.CaseSensitive := True;
  One := 1;
  fpSetSockOpt(FSock, IPPROTO_TCP_, TCP_NODELAY_, @One, SizeOf(One));
  inherited Create(False);
end;

destructor TMqttConn.Destroy;
begin
  Subs.Free;
  FOutLock.Free;
  inherited Destroy;
end;

procedure TMqttConn.Shutdown;
begin
  Terminate;
  fpShutdown(FSock, 2);     // select / recv return at once, Execute closes the socket
end;

function TMqttConn.Name: string;
begin
  if ClientId <> '' then
    Result := ClientId + ' (' + FPeer + ')'
  else
    Result := FPeer;
end;

function TMqttConn.WaitData(Ms: Integer): Boolean;
var
  R: LongInt;
{$IFDEF WINDOWS}
  FDS: WinSock2.TFDSet;
  TV: WinSock2.TTimeVal;
begin
  WinSock2.FD_ZERO(FDS);
  WinSock2.FD_SET(FSock, FDS);
  TV.tv_sec := 0;
  TV.tv_usec := Ms * 1000;
  R := WinSock2.select(0, @FDS, nil, nil, @TV);
{$ELSE}
  FDS: TFDSet;
  TV: TTimeVal;
begin
  fpFD_ZERO(FDS);
  fpFD_SET(FSock, FDS);
  TV.tv_sec := 0;
  TV.tv_usec := Ms * 1000;
  R := fpSelect(FSock + 1, @FDS, nil, nil, @TV);
{$ENDIF}
  if R < 0 then
    raise EMqttClosed.Create('closed');
  Result := R > 0;
end;

procedure TMqttConn.RecvExact(var Buf; Count: Integer);
var
  P: PByte;
  R: LongInt;
begin
  P := @Buf;
  while Count > 0 do
  begin
    R := fpRecv(FSock, P, Count, 0);
    if R <= 0 then
      raise EMqttClosed.Create('closed');
    Inc(P, R);
    Dec(Count, R);
  end;
end;

procedure TMqttConn.ReadPacket(out PType, Flags: Byte; out Body: string);
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

procedure TMqttConn.Enqueue(const Data: string);
begin
  FOutLock.Enter;
  try
    if Length(FOut) + Length(Data) > MAX_QUEUE then
      FOverflow := True
    else
      FOut := FOut + Data;
  finally
    FOutLock.Leave;
  end;
end;

procedure TMqttConn.Deliver(const Topic, Payload: string; QoS: Integer; Retain: Boolean);
var
  Body: string;
begin
  FOutLock.Enter;
  try
    Body := EncStr(Topic);
    if QoS > 0 then
    begin
      FNextId := FNextId mod $FFFF + 1;
      Body := Body + EncU16(FNextId);
    end;
  finally
    FOutLock.Leave;
  end;
  Enqueue(Packet(MQ_PUBLISH, (QoS shl 1) or Ord(Retain), Body + Payload));
end;

procedure TMqttConn.Flush;
var
  S: string;
  Ofs, R: Integer;
begin
  FOutLock.Enter;
  try
    S := FOut;
    FOut := '';
  finally
    FOutLock.Leave;
  end;
  Ofs := 1;
  while Ofs <= Length(S) do
  begin
    R := fpSend(FSock, @S[Ofs], Length(S) - Ofs + 1, 0);
    if R <= 0 then
      raise EMqttClosed.Create('closed');
    Inc(Ofs, R);
  end;
end;

procedure TMqttConn.Execute;
var
  PType, Flags: Byte;
  Body: string;
  Clean: Boolean;
begin
  MaskFPU;
  Clean := False;
  FLastRecv := GetTickCount64;
  try
    try
      while not Terminated do
      begin
        if WaitData(10) then
        begin
          ReadPacket(PType, Flags, Body);
          FLastRecv := GetTickCount64;
          if not FConnected then
          begin
            if (PType <> MQ_CONNECT) or not HandleConnect(Body) then
            begin
              if PType <> MQ_CONNECT then
                FBroker.Log(FPeer + ': first packet is not CONNECT');
              Break;
            end;
          end
          else
            case PType of
              MQ_PUBLISH: HandlePublish(Flags, Body);
              MQ_PUBREL: HandlePubRel(Body);
              MQ_PUBREC: Enqueue(Packet(MQ_PUBREL, 2, EncU16(GetU16(Body, 1))));  // our QoS 2 delivery
              MQ_PUBACK, MQ_PUBCOMP: ;
              MQ_SUBSCRIBE: HandleSubscribe(Body);
              MQ_UNSUBSCRIBE: HandleUnsubscribe(Body);
              MQ_PINGREQ: Enqueue(Packet(MQ_PINGRESP, 0));
              MQ_DISCONNECT:
                begin
                  Clean := True;
                  Break;
                end;
            else
              raise EMqttError.CreateFmt('unexpected packet type %d', [PType]);
            end;
        end;
        if FOverflow then
          raise EMqttError.Create('client too slow, send queue full');
        Flush;
        if not FConnected and (GetTickCount64 - FLastRecv > CONNECT_TIMEOUT) then
          raise EMqttError.Create('no CONNECT within 10 s');
        if FConnected and (FKeepAlive > 0) and
          (GetTickCount64 - FLastRecv > QWord(FKeepAlive) * 1500) then
          raise EMqttError.Create('keep alive timeout');
      end;
      Flush;            // for example a CONNACK that refuses the connection
    except
      on E: EMqttClosed do ;
      on E: Exception do
        FBroker.Log(Name + ': ' + E.Message);
    end;
  finally
    FBroker.FLock.Enter;
    try
      Online := False;
    finally
      FBroker.FLock.Leave;
    end;
    if FHasWill and not Clean and not Kicked then
    begin
      FBroker.Log(Name + ': last will -> ' + FWillTopic);
      { the will is a publish for the client: the same way as its own messages }
      if not (Assigned(FBroker.OnWrite) and FBroker.OnWrite(FWillTopic, FWillPayload)) then
        FBroker.Publish(FWillTopic, FWillPayload, FWillQoS, FWillRetain);
    end;
    CloseSocket(FSock);
    if FConnected then
      FBroker.Log(Name + ' disconnected');
  end;
end;

{ ---------------------------------------------------------------------------- }
{ TMqttConn - packets }

function TMqttConn.HandleConnect(const B: string): Boolean;
var
  P, Level, CFlags, I: Integer;
  Proto, Id: string;
  C: TMqttConn;
begin
  P := 1;
  Proto := GetStr(B, P);
  if P + 3 > Length(B) then
    raise EMqttError.Create('CONNECT too short');
  Level := Ord(B[P]);
  CFlags := Ord(B[P + 1]);
  FKeepAlive := GetU16(B, P + 2);
  Inc(P, 4);
  if not (((Proto = 'MQTT') and (Level = 4)) or ((Proto = 'MQIsdp') and (Level = 3))) then
  begin
    Enqueue(Packet(MQ_CONNACK, 0, #0#1));            // unacceptable protocol version
    FBroker.Log(Format('%s refused: protocol %s level %d (MQTT 3.1 / 3.1.1 only)',
      [FPeer, Proto, Level]));
    Exit(False);
  end;
  Id := GetStr(B, P);
  if CFlags and $04 <> 0 then
  begin
    FHasWill := True;
    FWillTopic := GetStr(B, P);
    FWillPayload := GetStr(B, P);
    FWillQoS := Min((CFlags shr 3) and 3, 2);
    FWillRetain := CFlags and $20 <> 0;
  end;
  { user name / password are not checked: anonymous broker }
  FBroker.FLock.Enter;
  try
    if Id = '' then
    begin
      Inc(FBroker.FAutoId);
      Id := 'auto-' + IntToStr(FBroker.FAutoId);
    end;
    ClientId := Id;
    for I := 0 to FBroker.FClients.Count - 1 do        // same id: the old connection is closed
    begin
      C := TMqttConn(FBroker.FClients[I]);
      if (C <> Self) and C.Online and (C.ClientId = Id) then
      begin
        C.Online := False;
        C.Kicked := True;
        C.Shutdown;
        FBroker.Log(C.Name + ' replaced by a new connection with the same client id');
      end;
    end;
    Enqueue(Packet(MQ_CONNACK, 0, #0#0));              // session present = 0
    Online := True;
  finally
    FBroker.FLock.Leave;
  end;
  FConnected := True;
  if Level = 4 then Proto := '3.1.1' else Proto := '3.1';
  FBroker.Log(Format('%s connected, MQTT %s, keep alive %d s', [Name, Proto, FKeepAlive]));
  Result := True;
end;

procedure TMqttConn.HandlePublish(Flags: Byte; const B: string);
var
  P, QoS, Id, I: Integer;
  Topic, Payload: string;
  Retain: Boolean;
begin
  QoS := (Flags shr 1) and 3;
  Retain := Flags and 1 <> 0;
  if QoS = 3 then
    raise EMqttError.Create('PUBLISH with QoS 3');
  P := 1;
  Topic := GetStr(B, P);
  Id := 0;
  if QoS > 0 then
  begin
    Id := GetU16(B, P);
    Inc(P, 2);
  end;
  Payload := Copy(B, P, MaxInt);
  if QoS = 1 then
    Enqueue(Packet(MQ_PUBACK, 0, EncU16(Id)))
  else if QoS = 2 then
  begin
    Enqueue(Packet(MQ_PUBREC, 0, EncU16(Id)));
    for I := 0 to High(FQoS2In) do
      if FQoS2In[I] = Id then
        Exit;                                         // sent again before PUBREL: only once
    SetLength(FQoS2In, Length(FQoS2In) + 1);
    FQoS2In[High(FQoS2In)] := Id;
  end;
  if not ValidTopic(Topic) then
  begin
    FBroker.Log(Name + ': PUBLISH to an invalid topic ignored');
    Exit;
  end;
  if Assigned(FBroker.OnWrite) and FBroker.OnWrite(Topic, Payload) then
    Exit;                                             // a simulator write, not routed
  FBroker.Publish(Topic, Payload, QoS, Retain);
end;

procedure TMqttConn.HandlePubRel(const B: string);
var
  Id, I: Integer;
begin
  Id := GetU16(B, 1);
  for I := 0 to High(FQoS2In) do
    if FQoS2In[I] = Id then
    begin
      Delete(FQoS2In, I, 1);
      Break;
    end;
  Enqueue(Packet(MQ_PUBCOMP, 0, EncU16(Id)));
end;

procedure TMqttConn.HandleSubscribe(const B: string);
var
  P, Q, I, J: Integer;
  Flt, Codes: string;
  Added: TStringList;
  R: TRetainMsg;
begin
  GetU16(B, 1);                                       // packet id present
  P := 3;
  Codes := '';
  Added := TStringList.Create;
  try
    { SUBACK and the retained messages go out under the broker lock, so a live
      message for the same topic can't come in between }
    FBroker.FLock.Enter;
    try
      while P <= Length(B) do
      begin
        Flt := GetStr(B, P);
        if P > Length(B) then
          raise EMqttError.Create('SUBSCRIBE without QoS');
        Q := Ord(B[P]);
        Inc(P);
        if not ValidFilter(Flt) or (Q > 2) then
        begin
          Codes := Codes + #$80;
          Added.AddObject(Flt, TObject(PtrInt(-1)));
          Continue;
        end;
        I := Subs.IndexOf(Flt);
        if I < 0 then
          Subs.AddObject(Flt, TObject(PtrInt(Q)))
        else
          Subs.Objects[I] := TObject(PtrInt(Q));
        Codes := Codes + Chr(Q);
        Added.AddObject(Flt, TObject(PtrInt(Q)));
      end;
      Enqueue(Packet(MQ_SUBACK, 0, Copy(B, 1, 2) + Codes));
      for I := 0 to Added.Count - 1 do
      begin
        Q := PtrInt(Added.Objects[I]);
        if Q < 0 then Continue;                       // refused filter
        for J := 0 to FBroker.FRetained.Count - 1 do
          if TopicMatch(Added[I], FBroker.FRetained[J]) then
          begin
            R := TRetainMsg(FBroker.FRetained.Objects[J]);
            Deliver(FBroker.FRetained[J], R.Payload, Min(R.QoS, Q), True);
          end;
      end;
    finally
      FBroker.FLock.Leave;
    end;
    for I := 0 to Added.Count - 1 do
    begin
      Q := PtrInt(Added.Objects[I]);
      if Q < 0 then
        FBroker.Log(Format('%s subscribe %s refused (invalid filter or QoS)', [Name, Added[I]]))
      else
        FBroker.Log(Format('%s subscribe %s qos %d', [Name, Added[I], Q]));
    end;
  finally
    Added.Free;
  end;
end;

procedure TMqttConn.HandleUnsubscribe(const B: string);
var
  P, I: Integer;
  Flt: string;
begin
  GetU16(B, 1);
  P := 3;
  FBroker.FLock.Enter;
  try
    while P <= Length(B) do
    begin
      Flt := GetStr(B, P);
      I := Subs.IndexOf(Flt);
      if I >= 0 then
        Subs.Delete(I);
    end;
  finally
    FBroker.FLock.Leave;
  end;
  Enqueue(Packet(MQ_UNSUBACK, 0, Copy(B, 1, 2)));
end;

end.

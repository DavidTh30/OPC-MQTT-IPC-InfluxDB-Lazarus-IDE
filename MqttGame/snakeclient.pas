{ ============================================================================
  snakeclient - the game side of a Snake Arena client, shared by the LCL
  client (SnakeLCL) and the BGRABitmap client (SnakeBGRA). Only the drawing
  differs between them.
    - MQTT connection (umqttclient) with the last will "leave" on our command
      topic, so the server removes our snake when the connection drops
    - join (again after every reconnect), turns, ping every 5 s
    - the last two states with their arrival time, for smooth animation
  ============================================================================ }
unit snakeclient;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, umqttclient, snakeproto;

const
  TRANSPORT_NAME = 'MQTT';
  TRANSPORT_HAS_HOST = True;       // the window shows Host / Port
  CONNECTING_TEXT = 'Connecting ...';

type

  { TSnakeConn }

  TSnakeConn = class
  private
    FClient: TMqttClient;
    FKey, FName: string;
    FColor: LongWord;
    FJoinSent: Boolean;
    FLastPing: QWord;
    FState, FPrev: TGameState;
    FStateTime, FPrevTime: Double;
    FHasState: Boolean;
    FStates: Integer;
    procedure Send(const Cmd: string);
  public
    Events: TStringList;          // server events and connection log, taken by the form
    constructor Create;
    destructor Destroy; override;
    procedure Connect(const Host: string; Port: Integer; const AName: string; AColor: LongWord);
    procedure Disconnect;
    { enter the arena again (after death it respawns at once), or change name / colour }
    procedure Join(const AName: string; AColor: LongWord);
    procedure Turn(D: Char);
    { call often (timer): collects messages, sends join / ping; True = a new state arrived }
    function Poll: Boolean;
    function Active: Boolean;
    function Connected: Boolean;
    { index of our snake in State, -1 = not in the arena }
    function Me: Integer;
    property State: TGameState read FState;
    property PrevState: TGameState read FPrev;
    property StateTime: Double read FStateTime;
    property PrevTime: Double read FPrevTime;
    property HasState: Boolean read FHasState;
    property Key: string read FKey;
    property StatesReceived: Integer read FStates;
  end;

implementation

{ TSnakeConn }

constructor TSnakeConn.Create;
begin
  FClient := TMqttClient.Create;
  Events := TStringList.Create;
  FKey := 'snake-' + LowerCase(IntToHex(Random($FFFFFF), 6));
end;

destructor TSnakeConn.Destroy;
begin
  Disconnect;
  FClient.Free;
  Events.Free;
  inherited Destroy;
end;

procedure TSnakeConn.Send(const Cmd: string);
var
  Err: string;
begin
  FClient.Publish(SNAKE_ROOT + '/cmd/' + FKey, Cmd, 0, False, Err);
end;

procedure TSnakeConn.Connect(const Host: string; Port: Integer; const AName: string;
  AColor: LongWord);
var
  C: TMqttConfig;
begin
  FName := AName;
  FColor := AColor;
  C := Default(TMqttConfig);
  C.Host := Host;
  C.Port := Port;
  C.ClientId := FKey;
  C.KeepAlive := 10;
  C.CleanSession := True;
  C.Level := 4;
  C.WillTopic := SNAKE_ROOT + '/cmd/' + FKey;    // dropped connection = leave
  C.WillPayload := 'leave';
  C.ConnectTimeout := 3000;
  C.AutoReconnect := True;
  FClient.Subscribe(SNAKE_ROOT + '/state', 0);
  FClient.Subscribe(SNAKE_ROOT + '/event', 0);
  FJoinSent := False;
  FHasState := False;
  FClient.Connect(C);
end;

procedure TSnakeConn.Disconnect;
begin
  if FClient.State = mqsConnected then
  begin
    Send('leave');
    Sleep(50);                                   // let the worker thread send it
  end;
  FClient.Disconnect;
  FJoinSent := False;
end;

procedure TSnakeConn.Join(const AName: string; AColor: LongWord);
begin
  FName := AName;
  FColor := AColor;
  FJoinSent := False;                            // Poll sends it (now or when connected)
end;

procedure TSnakeConn.Turn(D: Char);
begin
  if Pos(D, DIRS) > 0 then
    Send('dir ' + D);
end;

function TSnakeConn.Poll: Boolean;
var
  M: TMqttMessages;
  I, Last, Prev: Integer;
  S: TGameState;
  T: Double;
begin
  Result := False;
  FClient.TakeLog(Events);
  if FClient.State <> mqsConnected then
    FJoinSent := False                            // join again after a reconnect
  else
  begin
    if not FJoinSent then
    begin
      Send('join ' + ColorHex(FColor) + ' ' + FName);
      FJoinSent := True;
      FLastPing := GetTickCount64;
    end;
    if GetTickCount64 - FLastPing > 5000 then
    begin
      Send('ping');
      FLastPing := GetTickCount64;
    end;
  end;
  M := FClient.TakeMessages;
  Last := -1;
  Prev := -1;
  for I := 0 to High(M) do
    if M[I].Topic = SNAKE_ROOT + '/state' then
    begin
      Prev := Last;
      Last := I;
    end
    else if M[I].Topic = SNAKE_ROOT + '/event' then
      Events.Add(FormatDateTime('hh:nn:ss', M[I].Time) + '  ' + M[I].Payload);
  if Last < 0 then Exit;
  T := MsNow;
  { two states in one poll: the older one is the start of the animation }
  if (Prev >= 0) and DecodeState(M[Prev].Payload, S) then
  begin
    FState := S;
    FStateTime := T;
  end;
  if DecodeState(M[Last].Payload, S) then
  begin
    FPrev := FState;
    FPrevTime := FStateTime;
    if not FHasState then
    begin
      FPrev := S;
      FPrevTime := T;
    end;
    FState := S;
    FStateTime := T;
    FHasState := True;
    Inc(FStates);
    Result := True;
  end;
end;

function TSnakeConn.Active: Boolean;
begin
  Result := FClient.Active;
end;

function TSnakeConn.Connected: Boolean;
begin
  Result := FClient.State = mqsConnected;
end;

function TSnakeConn.Me: Integer;
begin
  if FHasState then
    Result := FindSnake(FState, FKey)
  else
    Result := -1;
end;

end.

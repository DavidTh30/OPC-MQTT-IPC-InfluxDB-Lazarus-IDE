{ ============================================================================
  ugamehost - runs Snake Arena on the MQTT broker (MqttSim/mqttbroker)
    - game thread: one TSnakeGame.Step per tick (performance counter, 1 ms
      timer period, absolute schedule), then snake/state + snake/event
    - snake/cmd/<key> from the broker (taken, not routed): join / dir / ping / leave
    - players without a message for 30 s are removed (the client pings every 5 s,
      a dropped client sends "leave" as its last will)
  ============================================================================ }
unit ugamehost;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, Math, mqttbroker, snakeproto, snakegame;

type

  { TGameHost }

  TGameHost = class
  private
    FLock: TCriticalSection;
    FBroker: TMqttBroker;
    FGame: TSnakeGame;
    FThread: TThread;
    FTickMs: Integer;
    FBytes, FBytesLast: Int64;
    FKBps: Double;
    function OnWrite(const Topic, Payload: string): Boolean;
    procedure DoTick;
  public
    constructor Create(ABroker: TMqttBroker; AW, AH, ATickMs: Integer; AWrap: Boolean);
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
    procedure SetBots(N: Integer);
    procedure SetFood(N: Integer);
    function Snapshot: TGameState;
    function KBytesPerSecond: Double;
    property TickMs: Integer read FTickMs;
  end;

implementation

{$IFDEF WINDOWS}
uses
  MMSystem;
{$ENDIF}

const
  PLAYER_TIMEOUT = 30000;      // ms without any command

type

  { TGameThread }

  TGameThread = class(TThread)
  private
    FHost: TGameHost;
  protected
    procedure Execute; override;
  public
    constructor Create(AHost: TGameHost);
  end;

{ TGameThread }

constructor TGameThread.Create(AHost: TGameHost);
begin
  FHost := AHost;
  inherited Create(False);
end;

procedure TGameThread.Execute;
var
  Next, T, LastStat: Double;
begin
  {$IFDEF WINDOWS}
  timeBeginPeriod(1);
  {$ENDIF}
  try
    Next := MsNow;
    LastStat := Next;
    while not Terminated do
    begin
      T := MsNow;
      if T >= Next then
      begin
        FHost.DoTick;
        Next := Next + FHost.FTickMs;
        if Next < T - 1000 then Next := T + FHost.FTickMs;   // far behind: no burst
      end;
      if T - LastStat >= 1000 then
      begin
        FHost.FLock.Enter;
        try
          FHost.FKBps := (FHost.FBytes - FHost.FBytesLast) / (T - LastStat);
          FHost.FBytesLast := FHost.FBytes;
        finally
          FHost.FLock.Leave;
        end;
        LastStat := T;
      end;
      Sleep(EnsureRange(Trunc(Next - MsNow), 0, 10));
    end;
  finally
    {$IFDEF WINDOWS}
    timeEndPeriod(1);
    {$ENDIF}
  end;
end;

{ TGameHost }

constructor TGameHost.Create(ABroker: TMqttBroker; AW, AH, ATickMs: Integer; AWrap: Boolean);
begin
  FLock := TCriticalSection.Create;
  FBroker := ABroker;
  FTickMs := EnsureRange(ATickMs, 30, 1000);
  FGame := TSnakeGame.Create(AW, AH, AWrap);
  FBroker.OnWrite := @OnWrite;
end;

destructor TGameHost.Destroy;
begin
  Stop;
  if FBroker.OnWrite = @OnWrite then
    FBroker.OnWrite := nil;
  FGame.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TGameHost.Start;
begin
  FBroker.Publish(SNAKE_ROOT + '/status', 'online', 0, True);
  FBroker.Publish(SNAKE_ROOT + '/info', Format('%d %d %d %d', [FGame.W, FGame.H, FTickMs,
    Ord(FGame.Wrap)]), 0, True);
  if FThread = nil then
    FThread := TGameThread.Create(Self);
end;

procedure TGameHost.Stop;
begin
  if FThread = nil then Exit;
  FThread.Terminate;
  FThread.WaitFor;
  FreeAndNil(FThread);
end;

procedure TGameHost.DoTick;
var
  I: Integer;
  P: TPlayer;
  Text: string;
  Ev: TStringList;
  Now_: QWord;
begin
  Ev := TStringList.Create;
  try
    FLock.Enter;
    try
      Now_ := GetTickCount64;
      for I := FGame.Players.Count - 1 downto 0 do
      begin
        P := TPlayer(FGame.Players[I]);
        if not P.IsBot and (Now_ - P.LastSeen > PLAYER_TIMEOUT) then
        begin
          FBroker.Log(P.Name + ' removed: no message for 30 s');
          FGame.Leave(P.Key);
        end;
      end;
      FGame.Step;
      Text := EncodeState(FGame.State(FTickMs));
      Ev.Assign(FGame.Events);
      FGame.Events.Clear;
      Inc(FBytes, Length(Text));
    finally
      FLock.Leave;
    end;
    { publish outside the game lock (the broker has its own) }
    FBroker.Publish(SNAKE_ROOT + '/state', Text, 0, False);
    for I := 0 to Ev.Count - 1 do
    begin
      FBroker.Publish(SNAKE_ROOT + '/event', Ev[I], 0, False);
      FBroker.Log('game: ' + Ev[I]);
    end;
  finally
    Ev.Free;
  end;
end;

{ snake/cmd/<key>: join <RRGGBB> <name> | dir U/R/D/L | ping | leave }
function TGameHost.OnWrite(const Topic, Payload: string): Boolean;
var
  Pre, Key, Cmd, Arg, Name: string;
  I: Integer;
begin
  Pre := SNAKE_ROOT + '/cmd/';
  if not Topic.StartsWith(Pre) then
    Exit(False);
  Result := True;
  Key := Copy(Topic, Length(Pre) + 1, MaxInt);
  if (Key = '') or (Pos('/', Key) > 0) or (Key <> SafeKey(Key)) then
  begin
    FBroker.Log('command refused, bad key: ' + Topic);
    Exit;
  end;
  if Key.StartsWith('bot') then
    Key := 'p' + Key;                          // never take over a server bot
  I := Pos(' ', Payload + ' ');
  Cmd := LowerCase(Copy(Payload, 1, I - 1));
  Arg := Trim(Copy(Payload, I + 1, MaxInt));
  FLock.Enter;
  try
    if Cmd = 'join' then
    begin
      I := Pos(' ', Arg + ' ');
      Name := Trim(Copy(Copy(Arg, I + 1, MaxInt), 1, 20));
      if Name = '' then Name := Key;
      Name := StringReplace(StringReplace(Name, #10, ' ', [rfReplaceAll]), #13, ' ', [rfReplaceAll]);
      FGame.Join(Key, Name, HexColor(Copy(Arg, 1, I - 1), $40C0FF));
    end
    else if Cmd = 'dir' then
    begin
      if Arg <> '' then FGame.Turn(Key, UpCase(Arg[1]));
    end
    else if (Cmd = 'u') or (Cmd = 'r') or (Cmd = 'd') or (Cmd = 'l') then
      FGame.Turn(Key, UpCase(Cmd[1]))
    else if Cmd = 'ping' then
      FGame.Turn(Key, ' ')                     // only marks the player as seen
    else if Cmd = 'leave' then
      FGame.Leave(Key)
    else
      FBroker.Log('unknown command from ' + Key + ': ' + Copy(Payload, 1, 60));
  finally
    FLock.Leave;
  end;
end;

procedure TGameHost.SetBots(N: Integer);
begin
  FLock.Enter;
  try
    FGame.SetBots(N);
  finally
    FLock.Leave;
  end;
end;

procedure TGameHost.SetFood(N: Integer);
begin
  FLock.Enter;
  try
    FGame.FoodCount := EnsureRange(N, 1, 200);
  finally
    FLock.Leave;
  end;
end;

function TGameHost.Snapshot: TGameState;
begin
  FLock.Enter;
  try
    Result := FGame.State(FTickMs);
  finally
    FLock.Leave;
  end;
end;

function TGameHost.KBytesPerSecond: Double;
begin
  FLock.Enter;
  try
    Result := FKBps;
  finally
    FLock.Leave;
  end;
end;

end.

{ ============================================================================
  uipchost - runs Snake Arena over IPC (same rules: ../MqttGame/snakegame)
    - game thread: owns the SimpleIPC server (its hidden window belongs to this
      thread), and waits for commands with PeekMessage until the next tick, so
      a command is handled within a few ms and the tick stays on time
    - every tick: TSnakeGame.Step, then the state text (snakeproto) plus the
      last 20 events ("E <id> <text>") into the shared memory block
    - players are removed when their process ends (pid from every command),
      on "leave", or after 10 s without any command (the clients ping every 2 s)
  The API is the same as ugamehost (MQTT), so the server window is shared.
  ============================================================================ }
unit uipchost;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, Math, Windows, simpleipc, snakeproto, snakegame, ipcshared;

type

  { TGameHost }

  TGameHost = class
  private
    FLock: SyncObjs.TCriticalSection;
    FLogLock: SyncObjs.TCriticalSection;
    FLog: TStringList;
    FGame: TSnakeGame;
    FThread: TThread;
    FTickMs: Integer;
    FWriter: TStateWriter;
    FPids: TStringList;              // key -> process handle (Objects)
    FRecent: TStringList;            // "E <id> <text>", last 20
    FEventId: Integer;
    FBytes, FBytesLast, FCmds, FCmdsLast: Int64;
    FKBps, FCmdRate: Double;
    FReady: TEvent;
    FStartErr: string;
    procedure HandleCommand(const Msg: string);
    procedure Forget(const Key: string);
    procedure DoTick;
  public
    constructor Create(AW, AH, ATickMs: Integer; AWrap: Boolean);
    destructor Destroy; override;
    function Start(out Err: string): Boolean;
    procedure Stop;
    procedure SetBots(N: Integer);
    procedure SetFood(N: Integer);
    function Snapshot: TGameState;
    function KBytesPerSecond: Double;
    function CommandsPerSecond: Double;
    procedure Log(const S: string);
    procedure TakeLog(Dest: TStrings);
    property TickMs: Integer read FTickMs;
  end;

implementation

uses
  MMSystem;

const
  PLAYER_TIMEOUT = 10000;      // ms without any command
  RECENT_EVENTS = 20;

type

  { TIpcGameThread }

  TIpcGameThread = class(TThread)
  private
    FHost: TGameHost;
  protected
    procedure Execute; override;
  public
    constructor Create(AHost: TGameHost);
  end;

{ TIpcGameThread }

constructor TIpcGameThread.Create(AHost: TGameHost);
begin
  FHost := AHost;
  inherited Create(False);
end;

procedure TIpcGameThread.Execute;
var
  Srv: TSimpleIPCServer;
  Next, T, LastStat: Double;
  Wait: Integer;
begin
  Srv := TSimpleIPCServer.Create(nil);
  try
    Srv.ServerID := IPC_SERVER_ID;
    Srv.Global := True;                 // window name = server id, clients find it
    try
      Srv.StartServer(False);           // not threaded: this thread pumps the messages
    except
      on E: Exception do
      begin
        FHost.FStartErr := 'SimpleIPC server: ' + E.Message;
        FHost.FReady.SetEvent;
        Exit;
      end;
    end;
    FHost.FReady.SetEvent;
    timeBeginPeriod(1);
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
            FHost.FCmdRate := (FHost.FCmds - FHost.FCmdsLast) * 1000 / (T - LastStat);
            FHost.FBytesLast := FHost.FBytes;
            FHost.FCmdsLast := FHost.FCmds;
          finally
            FHost.FLock.Leave;
          end;
          LastStat := T;
        end;
        { wait for commands until the next tick (this is also the sleep) }
        Wait := EnsureRange(Trunc(Next - MsNow), 0, 10);
        if Srv.PeekMessage(Wait, True) then
          repeat
            FHost.HandleCommand(Srv.StringMessage);
          until not Srv.PeekMessage(0, True);
      end;
    finally
      timeEndPeriod(1);
      Srv.StopServer;
    end;
  finally
    Srv.Free;
  end;
end;

{ TGameHost }

constructor TGameHost.Create(AW, AH, ATickMs: Integer; AWrap: Boolean);
begin
  FLock := SyncObjs.TCriticalSection.Create;
  FLogLock := SyncObjs.TCriticalSection.Create;
  FLog := TStringList.Create;
  FPids := TStringList.Create;
  FRecent := TStringList.Create;
  FReady := TEvent.Create(nil, True, False, '');
  FTickMs := EnsureRange(ATickMs, 30, 1000);
  FGame := TSnakeGame.Create(AW, AH, AWrap);
  FWriter := TStateWriter.Create;
end;

destructor TGameHost.Destroy;
var
  I: Integer;
begin
  Stop;
  for I := 0 to FPids.Count - 1 do
    CloseHandle(THandle(PtrUInt(FPids.Objects[I])));
  FPids.Free;
  FWriter.Free;
  FGame.Free;
  FRecent.Free;
  FReady.Free;
  FLog.Free;
  FLogLock.Free;
  FLock.Free;
  inherited Destroy;
end;

function TGameHost.Start(out Err: string): Boolean;
var
  C: TSimpleIPCClient;
  Running: Boolean;
begin
  Err := '';
  if FThread <> nil then Exit(True);
  C := TSimpleIPCClient.Create(nil);
  try
    C.ServerID := IPC_SERVER_ID;
    Running := C.ServerRunning;
  finally
    C.Free;
  end;
  if Running then
  begin
    Err := 'another Snake Arena IPC server is already running on this PC';
    Exit(False);
  end;
  if not FWriter.Open(Err) then Exit(False);
  FReady.ResetEvent;
  FStartErr := '';
  FThread := TIpcGameThread.Create(Self);
  if (FReady.WaitFor(3000) <> wrSignaled) or (FStartErr <> '') then
  begin
    Err := FStartErr;
    if Err = '' then Err := 'the game thread did not start';
    Stop;
    Exit(False);
  end;
  Log(Format('IPC server "%s" started, state in %s', [IPC_SERVER_ID, IPC_MAP_NAME]));
  Result := True;
end;

procedure TGameHost.Stop;
begin
  if FThread = nil then Exit;
  FThread.Terminate;
  FThread.WaitFor;
  FreeAndNil(FThread);
end;

procedure TGameHost.Forget(const Key: string);
var
  I: Integer;
begin
  I := FPids.IndexOf(Key);
  if I < 0 then Exit;
  CloseHandle(THandle(PtrUInt(FPids.Objects[I])));
  FPids.Delete(I);
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
      { a client process that ended (closed, crashed, killed) leaves at once }
      for I := FPids.Count - 1 downto 0 do
        if WaitForSingleObject(THandle(PtrUInt(FPids.Objects[I])), 0) = WAIT_OBJECT_0 then
        begin
          P := FGame.Find(FPids[I]);
          if P <> nil then
          begin
            Log(P.Name + ': client process ended');
            FGame.Leave(P.Key);
          end;
          Forget(FPids[I]);
        end;
      for I := FGame.Players.Count - 1 downto 0 do
      begin
        P := TPlayer(FGame.Players[I]);
        if not P.IsBot and (Now_ - P.LastSeen > PLAYER_TIMEOUT) then
        begin
          Log(P.Name + ' removed: no command for 10 s');
          Forget(P.Key);
          FGame.Leave(P.Key);
        end;
      end;
      FGame.Step;
      for I := 0 to FGame.Events.Count - 1 do
      begin
        Inc(FEventId);
        FRecent.Add('E ' + IntToStr(FEventId) + ' ' + FGame.Events[I]);
        Ev.Add(FGame.Events[I]);
      end;
      FGame.Events.Clear;
      while FRecent.Count > RECENT_EVENTS do
        FRecent.Delete(0);
      Text := EncodeState(FGame.State(FTickMs));
      for I := 0 to FRecent.Count - 1 do
        Text := Text + FRecent[I] + #10;
      Inc(FBytes, Length(Text));
    finally
      FLock.Leave;
    end;
    FWriter.Write(Text);              // only this thread writes the block
    for I := 0 to Ev.Count - 1 do
      Log('game: ' + Ev[I]);
  finally
    Ev.Free;
  end;
end;

{ "<key> <pid> <command>"; command = join <RRGGBB> <name> | dir U/R/D/L | ping | leave }
procedure TGameHost.HandleCommand(const Msg: string);
var
  Rest, Key, Cmd, Arg, Name: string;
  Pid: LongInt;
  I: Integer;
  H: THandle;

  function Token: string;                      // the next word of Rest
  var
    P: Integer;
  begin
    Rest := TrimLeft(Rest);
    P := Pos(' ', Rest + ' ');
    Result := Copy(Rest, 1, P - 1);
    Rest := Copy(Rest, P + 1, MaxInt);
  end;

begin
  Rest := Msg;
  Key := Token;
  if not TryStrToInt(Token, Pid) then
  begin
    Log('command refused (expected "<key> <pid> <command>"): ' + Copy(Msg, 1, 60));
    Exit;
  end;
  Cmd := LowerCase(Token);
  Arg := Trim(Rest);
  if (Key = '') or (Key <> SafeKey(Key)) or (Cmd = '') then
  begin
    Log('command refused: ' + Copy(Msg, 1, 60));
    Exit;
  end;
  if Key.StartsWith('bot') then
    Key := 'p' + Key;                          // never take over a server bot
  FLock.Enter;
  try
    Inc(FCmds);
    if (Cmd <> 'leave') and (FPids.IndexOf(Key) < 0) then
    begin
      H := OpenProcess(SYNCHRONIZE, False, Pid);
      if H <> 0 then
        FPids.AddObject(Key, TObject(PtrUInt(H)));
    end;
    if Cmd = 'join' then
    begin
      I := Pos(' ', Arg + ' ');
      Name := Trim(Copy(Copy(Arg, I + 1, MaxInt), 1, 20));
      if Name = '' then Name := Key;
      FGame.Join(Key, Name, HexColor(Copy(Arg, 1, I - 1), $40C0FF));
    end
    else if Cmd = 'dir' then
    begin
      if Arg <> '' then FGame.Turn(Key, UpCase(Arg[1]));
    end
    else if Cmd = 'ping' then
      FGame.Turn(Key, ' ')                     // only marks the player as seen
    else if Cmd = 'leave' then
    begin
      FGame.Leave(Key);
      Forget(Key);
    end
    else
      Log('unknown command from ' + Key + ': ' + Copy(Msg, 1, 60));
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

function TGameHost.CommandsPerSecond: Double;
begin
  FLock.Enter;
  try
    Result := FCmdRate;
  finally
    FLock.Leave;
  end;
end;

procedure TGameHost.Log(const S: string);
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

procedure TGameHost.TakeLog(Dest: TStrings);
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

end.

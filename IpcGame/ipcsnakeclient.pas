{ ============================================================================
  ipcsnakeclient - the game side of a Snake Arena IPC client. Same class name
  and API as ../MqttGame/snakeclient (MQTT), so SnakeLCL and SnakeBGRA are
  built for IPC from the same source with the switch -dIPC.
    - commands to the server with SimpleIPC:  <key> <pid> <command>
    - the state from the shared memory block, read in Poll (every frame)
    - no server yet / server ended: tries again every second, joins again
    - Host and Port of Connect are not used (IPC = this PC)
  ============================================================================ }
unit ipcsnakeclient;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, simpleipc, snakeproto, ipcshared;

const
  TRANSPORT_NAME = 'IPC';
  TRANSPORT_HAS_HOST = False;      // IPC = this PC: no Host / Port in the window
  CONNECTING_TEXT = 'Waiting for the IPC game server ...';

type

  { TSnakeConn }

  TSnakeConn = class
  private
    FIpc: TSimpleIPCClient;
    FReader: TStateReader;
    FKey, FName, FPid: string;
    FColor: LongWord;
    FActive, FConnected, FJoinSent: Boolean;
    FLastPing, FLastTry, FLastState, FLastAlive: QWord;
    FServerPid: LongWord;         // the server we joined; another pid = it was restarted
    FLastEvent: Integer;
    FState, FPrev: TGameState;
    FStateTime, FPrevTime: Double;
    FHasState: Boolean;
    FStates: Integer;
    procedure Send(const Cmd: string);
    procedure Lost(const Why: string);
    procedure TryConnect;
    procedure TakeEvents(const Text: string);
  public
    Events: TStringList;          // server events and connection log, taken by the form
    constructor Create;
    destructor Destroy; override;
    procedure Connect(const Host: string; Port: Integer; const AName: string; AColor: LongWord);
    procedure Disconnect;
    procedure Join(const AName: string; AColor: LongWord);
    procedure Turn(D: Char);
    { call often (timer): reads the state, sends join / ping; True = a new state }
    function Poll: Boolean;
    function Active: Boolean;
    function Connected: Boolean;
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

const
  RETRY_MS = 1000;
  PING_MS = 2000;
  STALL_MS = 3000;             // no new state for 3 s = the server hangs

{ TSnakeConn }

constructor TSnakeConn.Create;
begin
  Events := TStringList.Create;
  FReader := TStateReader.Create;
  FKey := 'ipc-' + LowerCase(IntToHex(Random($FFFFFF), 6));
  FPid := IntToStr(GetProcessID);
end;

destructor TSnakeConn.Destroy;
begin
  Disconnect;
  FReader.Free;
  Events.Free;
  inherited Destroy;
end;

procedure TSnakeConn.Connect(const Host: string; Port: Integer; const AName: string;
  AColor: LongWord);
begin
  FName := AName;
  FColor := AColor;
  FActive := True;
  FConnected := False;
  FJoinSent := False;
  FHasState := False;
  FLastTry := 0;
  Events.Add(FormatDateTime('hh:nn:ss', Now) + '  looking for the IPC server "' + IPC_SERVER_ID + '" ...');
end;

procedure TSnakeConn.Disconnect;
begin
  if FConnected then
    Send('leave');
  FreeAndNil(FIpc);
  FReader.Close;
  FActive := False;
  FConnected := False;
  FJoinSent := False;
end;

procedure TSnakeConn.Join(const AName: string; AColor: LongWord);
begin
  FName := AName;
  FColor := AColor;
  FJoinSent := False;                            // Poll sends it
end;

procedure TSnakeConn.Send(const Cmd: string);
begin
  if FIpc = nil then Exit;
  try
    FIpc.SendStringMessage(FKey + ' ' + FPid + ' ' + Cmd);
  except
    on E: Exception do
      Lost('send failed: ' + E.Message);
  end;
end;

procedure TSnakeConn.Turn(D: Char);
begin
  if FConnected and (Pos(D, DIRS) > 0) then
    Send('dir ' + D);
end;

procedure TSnakeConn.Lost(const Why: string);
begin
  if FConnected then
    Events.Add(FormatDateTime('hh:nn:ss', Now) + '  connection lost: ' + Why);
  FreeAndNil(FIpc);
  FReader.Close;
  FConnected := False;
  FJoinSent := False;
  FHasState := False;
  FLastTry := GetTickCount64;
end;

procedure TSnakeConn.TryConnect;
begin
  FLastTry := GetTickCount64;
  if not FReader.Open then Exit;                 // no shared memory = no server
  if not ProcessAlive(FReader.ServerPid) then
  begin
    FReader.Close;
    Exit;
  end;
  FIpc := TSimpleIPCClient.Create(nil);
  FIpc.ServerID := IPC_SERVER_ID;
  try
    if not FIpc.ServerRunning then
      raise Exception.Create('not running');
    FIpc.Connect;
  except
    FreeAndNil(FIpc);
    FReader.Close;
    Exit;
  end;
  FConnected := True;
  FJoinSent := False;
  FLastEvent := -1;                              // set from the first state
  FLastState := GetTickCount64;
  FLastAlive := FLastState;
  FServerPid := FReader.ServerPid;
  Events.Add(FormatDateTime('hh:nn:ss', Now) + '  connected to the IPC server (pid ' +
    IntToStr(FReader.ServerPid) + ')');
end;

{ the "E <id> <text>" lines of the state: show the ones not seen yet }
procedure TSnakeConn.TakeEvents(const Text: string);
var
  Lines: TStringArray;
  I, P, Id, MaxId: Integer;
begin
  Lines := Text.Split([#10]);
  MaxId := FLastEvent;
  for I := 0 to High(Lines) do
    if Lines[I].StartsWith('E ') then
    begin
      P := Pos(' ', Copy(Lines[I], 3, MaxInt));
      if (P = 0) or not TryStrToInt(Copy(Lines[I], 3, P - 1), Id) then Continue;
      if (FLastEvent >= 0) and (Id > FLastEvent) then
        Events.Add(FormatDateTime('hh:nn:ss', Now) + '  ' + Copy(Lines[I], P + 3, MaxInt));
      MaxId := Max(MaxId, Id);
    end;
  if MaxId < 0 then MaxId := 0;                  // first state without events
  FLastEvent := MaxId;
end;

function TSnakeConn.Poll: Boolean;
var
  Text: string;
  S: TGameState;
  T: Double;
begin
  Result := False;
  if not FActive then Exit;
  if not FConnected then
  begin
    if GetTickCount64 - FLastTry >= RETRY_MS then
      TryConnect;
    if not FConnected then Exit;
  end;
  if FReader.ServerPid = 0 then
  begin
    Lost('the server stopped');
    Exit;
  end;
  { a new server reuses the block while we hold it open: the stream goes on, but our
    SimpleIPC handle still points to the old server - connect (and join) again }
  if FReader.ServerPid <> FServerPid then
  begin
    Lost('the server was restarted');
    Exit;
  end;
  if GetTickCount64 - FLastAlive >= 500 then
  begin
    FLastAlive := GetTickCount64;
    if not ProcessAlive(FServerPid) then        // killed: it could not clear ServerPid
    begin
      Lost('the server process ended');
      Exit;
    end;
  end;
  if not FJoinSent then
  begin
    Send('join ' + ColorHex(FColor) + ' ' + FName);
    FJoinSent := True;
    FLastPing := GetTickCount64;
  end
  else if GetTickCount64 - FLastPing >= PING_MS then
  begin
    Send('ping');
    FLastPing := GetTickCount64;
  end;
  if not FConnected then Exit;
  if FReader.Read(Text) then
  begin
    FLastState := GetTickCount64;
    TakeEvents(Text);
    if DecodeState(Text, S) then
    begin
      T := MsNow;
      if FHasState then
      begin
        FPrev := FState;
        FPrevTime := FStateTime;
      end
      else
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
  end
  else if GetTickCount64 - FLastState > STALL_MS then
  begin
    if ProcessAlive(FReader.ServerPid) then
      Lost('no new state for 3 s')
    else
      Lost('the server process ended');
  end;
end;

function TSnakeConn.Active: Boolean;
begin
  Result := FActive;
end;

function TSnakeConn.Connected: Boolean;
begin
  Result := FConnected;
end;

function TSnakeConn.Me: Integer;
begin
  if FHasState then
    Result := FindSnake(FState, FKey)
  else
    Result := -1;
end;

end.

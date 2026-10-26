{ ============================================================================
  ipcshared - the IPC transport of Snake Arena IPC (one PC, no network)
    - commands client -> server: SimpleIPC (fcl-process), server id
      SnakeArenaIPC, one string per command:  <key> <pid> <command>
      (the same commands as the MQTT version: join / dir / ping / leave)
    - game state server -> all clients: one named shared memory block
      (Local\SnakeArenaIPC_State) that every client reads; the server writes
      it once per tick, so it costs the same for 1 or 20 clients
    - seqlock: the writer makes Seq odd while it writes and even after;
      a reader copies the text and keeps it only if Seq was even and did
      not change meanwhile (no lock, a slow reader never blocks the server)
    - the pid lets the server see a client process that ended (crash, kill)
      at once, like the last will of MQTT
  ============================================================================ }
unit ipcshared;

{$mode objfpc}{$H+}

interface

uses
  Windows, SysUtils;

const
  IPC_SERVER_ID = 'SnakeArenaIPC';
  IPC_MAP_NAME = 'Local\SnakeArenaIPC_State';
  IPC_MAP_SIZE = 1024 * 1024;
  IPC_MAGIC = $314B4E53;                 // 'SNK1'
  IPC_VERSION = 1;

type
  PIpcHeader = ^TIpcHeader;
  TIpcHeader = packed record
    Magic, Version: LongWord;
    Seq: LongWord;                       // odd = being written
    Len: LongWord;                       // bytes of text after the header
    ServerPid: LongWord;
    Reserved: array[0..10] of LongWord;
  end;

  { TStateWriter - the server side }

  TStateWriter = class
  private
    FMap: THandle;
    FHeader: PIpcHeader;
  public
    constructor Create;
    destructor Destroy; override;
    function Open(out Err: string): Boolean;
    procedure Write(const S: string);
  end;

  { TStateReader - the client side }

  TStateReader = class
  private
    FMap: THandle;
    FHeader: PIpcHeader;
    FLastSeq: LongWord;
  public
    destructor Destroy; override;
    function Open: Boolean;
    procedure Close;
    function IsOpen: Boolean;
    { True = a new state since the last call, S = its text }
    function Read(out S: string): Boolean;
    function ServerPid: LongWord;
  end;

{ the process still runs (False also for pid 0) }
function ProcessAlive(Pid: LongWord): Boolean;

implementation

const
  MAX_TEXT = IPC_MAP_SIZE - SizeOf(TIpcHeader);

function ProcessAlive(Pid: LongWord): Boolean;
var
  H: THandle;
begin
  if Pid = 0 then Exit(False);
  H := OpenProcess(SYNCHRONIZE, False, Pid);
  if H = 0 then Exit(False);
  try
    Result := WaitForSingleObject(H, 0) = WAIT_TIMEOUT;
  finally
    CloseHandle(H);
  end;
end;

function TextPtr(H: PIpcHeader): PByte;
begin
  Result := PByte(H) + SizeOf(TIpcHeader);
end;

{ TStateWriter }

constructor TStateWriter.Create;
begin
  FMap := 0;
  FHeader := nil;
end;

destructor TStateWriter.Destroy;
begin
  if FHeader <> nil then
  begin
    FHeader^.ServerPid := 0;            // clients see at once that the server is gone
    UnmapViewOfFile(FHeader);
  end;
  if FMap <> 0 then
    CloseHandle(FMap);
  inherited Destroy;
end;

function TStateWriter.Open(out Err: string): Boolean;
var
  Existed: Boolean;
begin
  Err := '';
  FMap := CreateFileMappingW(INVALID_HANDLE_VALUE, nil, PAGE_READWRITE, 0, IPC_MAP_SIZE,
    PWideChar(WideString(IPC_MAP_NAME)));
  if FMap = 0 then
  begin
    Err := 'CreateFileMapping failed, error ' + IntToStr(GetLastError);
    Exit(False);
  end;
  Existed := GetLastError = ERROR_ALREADY_EXISTS;
  FHeader := MapViewOfFile(FMap, FILE_MAP_ALL_ACCESS, 0, 0, IPC_MAP_SIZE);
  if FHeader = nil then
  begin
    if Existed then
      { another program made the block first, read-only or smaller (our clients never
        make it, they only open it); it is freed when that program ends }
      Err := Format('the shared memory %s was created by another program (error %d); ' +
        'close that program and start again', [IPC_MAP_NAME, GetLastError])
    else
      Err := 'MapViewOfFile failed, error ' + IntToStr(GetLastError);
    CloseHandle(FMap);
    FMap := 0;
    Exit(False);
  end;
  { a block left by clients of an earlier server is reused; Seq goes on from there }
  if Odd(FHeader^.Seq) then Inc(FHeader^.Seq);
  FHeader^.Magic := IPC_MAGIC;
  FHeader^.Version := IPC_VERSION;
  FHeader^.ServerPid := GetCurrentProcessId;
  Result := True;
end;

procedure TStateWriter.Write(const S: string);
var
  L: Integer;
begin
  if FHeader = nil then Exit;
  L := Length(S);
  if L > MAX_TEXT then L := MAX_TEXT;
  Inc(FHeader^.Seq);                    // odd: readers wait
  ReadWriteBarrier;
  FHeader^.Len := L;
  if L > 0 then
    Move(S[1], TextPtr(FHeader)^, L);
  ReadWriteBarrier;
  Inc(FHeader^.Seq);                    // even: complete
end;

{ TStateReader }

destructor TStateReader.Destroy;
begin
  Close;
  inherited Destroy;
end;

function TStateReader.Open: Boolean;
begin
  Close;
  FMap := OpenFileMappingW(FILE_MAP_READ, False, PWideChar(WideString(IPC_MAP_NAME)));
  if FMap = 0 then Exit(False);
  FHeader := MapViewOfFile(FMap, FILE_MAP_READ, 0, 0, IPC_MAP_SIZE);
  if (FHeader = nil) or (FHeader^.Magic <> IPC_MAGIC) or (FHeader^.Version <> IPC_VERSION) then
  begin
    Close;
    Exit(False);
  end;
  FLastSeq := FHeader^.Seq - 2;         // the current state counts as new
  Result := True;
end;

procedure TStateReader.Close;
begin
  if FHeader <> nil then
    UnmapViewOfFile(FHeader);
  if FMap <> 0 then
    CloseHandle(FMap);
  FHeader := nil;
  FMap := 0;
end;

function TStateReader.IsOpen: Boolean;
begin
  Result := FHeader <> nil;
end;

function TStateReader.Read(out S: string): Boolean;
var
  Attempt: Integer;
  S1, L: LongWord;
begin
  S := '';
  Result := False;
  if FHeader = nil then Exit;
  for Attempt := 1 to 50 do
  begin
    S1 := FHeader^.Seq;
    ReadBarrier;
    if Odd(S1) then
    begin
      Sleep(0);                         // the server is writing right now
      Continue;
    end;
    if S1 = FLastSeq then Exit;         // nothing new
    L := FHeader^.Len;
    if L > MAX_TEXT then Continue;
    SetLength(S, L);
    if L > 0 then
      Move(TextPtr(FHeader)^, S[1], L);
    ReadBarrier;
    if FHeader^.Seq = S1 then           // not overwritten while we copied
    begin
      FLastSeq := S1;
      Exit(True);
    end;
  end;
  S := '';
end;

function TStateReader.ServerPid: LongWord;
begin
  if FHeader = nil then
    Result := 0
  else
    Result := FHeader^.ServerPid;
end;

end.

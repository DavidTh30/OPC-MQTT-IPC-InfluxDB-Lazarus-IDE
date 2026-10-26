{ ============================================================================
  uinfluxhttp - the HTTP API of InfluxDB 1.x (plus the v2 write endpoint)
    GET  /ping                          204 (X-Influxdb-Version header)
    GET  /health                        200, JSON with "status":"pass"
    POST /write?db=&precision=          line protocol (also gzip), 204 / 400 / 404
    POST /api/v2/write?bucket=&precision=   the same, bucket = db[/rp]
    GET / POST /query?q=&db=&epoch=     InfluxQL -> JSON (POST also as form field q)
    POST /api/v2/query                  501: Flux is not supported
  fphttpserver (fcl-web) in its own thread, one thread per connection; the
  accept loop wakes every 200 ms, so Stop needs no connection to itself.
  Anonymous: u / p and the Authorization header are accepted and ignored.
  ============================================================================ }
unit uinfluxhttp;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, Math, fphttpserver, httpdefs, zstream, utsdb, ulineproto,
  uqueryexec;

const
  INFLUX_VERSION = '1.8.10-lazarus';

type

  { TInfluxServer }

  TInfluxServer = class
  private
    FStore: TStore;
    FPort: Integer;
    FThread: TThread;
    FHttp: TFPHttpServer;
    FStop: Boolean;
    FStartErr: string;
    FRunning: Integer;            // requests being handled
    FLogLock, FStatLock: TCriticalSection;
    FLog: TStringList;
    FWrites, FPoints, FQueries, FErrors, FBytesIn: Int64;
    procedure HandleRequest(Sender: TObject; var ARequest: TFPHTTPConnectionRequest;
      var AResponse: TFPHTTPConnectionResponse);
    procedure Idle(Sender: TObject);
    procedure Count(Writes, Points, Queries, Errors, Bytes: Int64);
  public
    LogRequests: Boolean;
    constructor Create(AStore: TStore; APort: Integer);
    destructor Destroy; override;
    function Start(out Err: string): Boolean;
    procedure Stop;
    procedure Log(const S: string);
    procedure TakeLog(Dest: TStrings);
    procedure Stats(out Writes, Points, Queries, Errors, BytesIn: Int64);
    property Port: Integer read FPort;
  end;

{ the port is free (bound without SO_REUSEADDR, which would let two servers share it) }
function PortFree(Port: Integer): Boolean;

implementation

uses
  Sockets {$IFDEF WINDOWS}, WinSock2 {$ENDIF};

type

  { THttpThread }

  THttpThread = class(TThread)
  private
    FOwner: TInfluxServer;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TInfluxServer);
  end;

function PortFree(Port: Integer): Boolean;
var
  S: LongInt;
  Addr: TInetSockAddr;
begin
  S := fpSocket(AF_INET, SOCK_STREAM, 0);
  if S < 0 then Exit(False);
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := htons(Port);
  Result := fpBind(S, @Addr, SizeOf(Addr)) = 0;
  CloseSocket(S);
end;

function StrToHex(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    Result := Result + IntToHex(Ord(S[I]), 2);
end;

{ gzip body (Telegraf, client libraries) -> plain text }
function Gunzip(const Data: string; out Plain: string; out Err: string): Boolean;
var
  P, Flags, N: Integer;
  Src: TStringStream;
  Z: TDecompressionStream;
  Buf: array[0..65535] of Byte;
  Out_: TStringStream;
begin
  Result := False;
  Err := '';
  Plain := '';
  if (Length(Data) < 18) or (Data[1] <> #$1F) or (Data[2] <> #$8B) or (Data[3] <> #8) then
  begin
    Err := Format('not a gzip body (%d bytes, starts with %s)', [Length(Data),
      StrToHex(Copy(Data, 1, 4))]);
    Exit;
  end;
  Flags := Ord(Data[4]);
  P := 11;                                          // after the 10 byte header
  if Flags and 4 <> 0 then                          // FEXTRA
    P := P + 2 + Ord(Data[P]) + Ord(Data[P + 1]) shl 8;
  if Flags and 8 <> 0 then                          // FNAME
  begin
    while (P <= Length(Data)) and (Data[P] <> #0) do Inc(P);
    Inc(P);
  end;
  if Flags and 16 <> 0 then                         // FCOMMENT
  begin
    while (P <= Length(Data)) and (Data[P] <> #0) do Inc(P);
    Inc(P);
  end;
  if Flags and 2 <> 0 then Inc(P, 2);               // FHCRC
  Src := TStringStream.Create(Copy(Data, P, Length(Data) - P - 7));   // without CRC32 + size
  Out_ := TStringStream.Create('');
  try
    try
      Z := TDecompressionStream.Create(Src, True);  // raw deflate
      try
        repeat
          N := Z.Read(Buf, SizeOf(Buf));
          if N > 0 then Out_.WriteBuffer(Buf, N);
        until N <= 0;
      finally
        Z.Free;
      end;
      Plain := Out_.DataString;
      Result := True;
    except
      on E: Exception do Err := 'gzip: ' + E.Message;
    end;
  finally
    Src.Free;
    Out_.Free;
  end;
end;

{ THttpThread }

constructor THttpThread.Create(AOwner: TInfluxServer);
begin
  FOwner := AOwner;
  inherited Create(False);
end;

procedure THttpThread.Execute;
var
  H: TFPHttpServer;
begin
  H := TFPHttpServer.Create(nil);
  try
    H.Port := FOwner.FPort;
    H.Threaded := True;
    H.QueueSize := 64;
    H.OnRequest := @FOwner.HandleRequest;
    H.AcceptIdleTimeout := 200;
    H.OnAcceptIdle := @FOwner.Idle;
    FOwner.FHttp := H;
    try
      H.Active := True;                             // runs the accept loop until Idle stops it
    except
      on E: Exception do
        FOwner.FStartErr := E.Message;
    end;
  finally
    FOwner.FHttp := nil;
    H.Free;
  end;
end;

{ TInfluxServer }

constructor TInfluxServer.Create(AStore: TStore; APort: Integer);
begin
  FStore := AStore;
  FPort := APort;
  FLogLock := TCriticalSection.Create;
  FStatLock := TCriticalSection.Create;
  FLog := TStringList.Create;
end;

destructor TInfluxServer.Destroy;
begin
  Stop;
  FLog.Free;
  FStatLock.Free;
  FLogLock.Free;
  inherited Destroy;
end;

function TInfluxServer.Start(out Err: string): Boolean;
var
  T0: QWord;
begin
  Err := '';
  if FThread <> nil then Exit(True);
  if not PortFree(FPort) then
  begin
    Err := Format('port %d is in use (another InfluxDB?)', [FPort]);
    Exit(False);
  end;
  FStop := False;
  FStartErr := '';
  FThread := THttpThread.Create(Self);
  T0 := GetTickCount64;
  while (GetTickCount64 - T0 < 400) and not TThread(FThread).Finished do Sleep(10);
  if TThread(FThread).Finished then
  begin
    Err := FStartErr;
    if Err = '' then Err := 'the HTTP server did not start';
    FThread.WaitFor;
    FreeAndNil(FThread);
    Exit(False);
  end;
  Log(Format('HTTP API on http://<this PC>:%d  (InfluxDB %s, v1 API + /api/v2/write)',
    [FPort, INFLUX_VERSION]));
  Result := True;
end;

procedure TInfluxServer.Idle(Sender: TObject);
begin
  if FStop and (FHttp <> nil) then
    FHttp.Active := False;                          // ends the accept loop in this thread
end;

procedure TInfluxServer.Stop;
var
  T0: QWord;
begin
  if FThread = nil then Exit;
  FStop := True;
  FThread.WaitFor;
  FreeAndNil(FThread);
  T0 := GetTickCount64;                             // requests that are still running
  while (FRunning > 0) and (GetTickCount64 - T0 < 5000) do Sleep(10);
  Log('HTTP API stopped');
end;

procedure TInfluxServer.Log(const S: string);
begin
  FLogLock.Enter;
  try
    FLog.Add(FormatDateTime('hh:nn:ss', Now) + '  ' + S);
    while FLog.Count > 2000 do FLog.Delete(0);
  finally
    FLogLock.Leave;
  end;
end;

procedure TInfluxServer.TakeLog(Dest: TStrings);
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

procedure TInfluxServer.Count(Writes, Points, Queries, Errors, Bytes: Int64);
begin
  FStatLock.Enter;
  try
    Inc(FWrites, Writes);
    Inc(FPoints, Points);
    Inc(FQueries, Queries);
    Inc(FErrors, Errors);
    Inc(FBytesIn, Bytes);
  finally
    FStatLock.Leave;
  end;
end;

procedure TInfluxServer.Stats(out Writes, Points, Queries, Errors, BytesIn: Int64);
begin
  FStatLock.Enter;
  try
    Writes := FWrites;
    Points := FPoints;
    Queries := FQueries;
    Errors := FErrors;
    BytesIn := FBytesIn;
  finally
    FStatLock.Leave;
  end;
end;

function Param(R: TFPHTTPConnectionRequest; const Name: string): string;
begin
  Result := R.QueryFields.Values[Name];
  if (Result = '') and SameText(R.Method, 'POST') then
    Result := R.ContentFields.Values[Name];         // form fields of a POST /query
end;

procedure TInfluxServer.HandleRequest(Sender: TObject; var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
var
  Path, Body, Err, Db, Q, Prec, Info, Ep: string;
  Factor, EpochF: Int64;
  Code, Points, P: Integer;
  T0: QWord;
  V2: Boolean;

  procedure Reply(ACode: Integer; const AText, AJson: string);
  begin
    AResponse.Code := ACode;
    AResponse.CodeText := AText;
    if AJson <> '' then
    begin
      AResponse.ContentType := 'application/json';
      AResponse.Content := AJson;
    end;
  end;

  procedure ErrorReply(ACode: Integer; const AText, Msg: string);
  begin
    if V2 then
      Reply(ACode, AText, '{"code":"invalid","message":' + JsonString(Msg) + '}')
    else
      Reply(ACode, AText, '{"error":' + JsonString(Msg) + '}');
    Count(0, 0, 0, 1, 0);
  end;

begin
  InterLockedIncrement(FRunning);
  T0 := GetTickCount64;
  Info := '';
  V2 := False;
  try
    try
      Path := ARequest.URL;
      P := Pos('?', Path);
      if P > 0 then Path := Copy(Path, 1, P - 1);
      while (Length(Path) > 1) and (Path[Length(Path)] = '/') do SetLength(Path, Length(Path) - 1);
      AResponse.SetCustomHeader('X-Influxdb-Version', INFLUX_VERSION);
      AResponse.SetCustomHeader('X-Influxdb-Build', 'OSS');
      AResponse.SetCustomHeader('Access-Control-Allow-Origin', '*');
      if SameText(ARequest.Method, 'OPTIONS') then
      begin
        AResponse.SetCustomHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
        AResponse.SetCustomHeader('Access-Control-Allow-Headers',
          'Authorization, Content-Type, Content-Encoding, Accept');
        Reply(204, 'No Content', '');
        Exit;
      end;

      if (Path = '/ping') or (Path = '/api/v2/ping') then
      begin
        if SameText(Param(ARequest, 'verbose'), 'true') then
          Reply(200, 'OK', '{"version":"' + INFLUX_VERSION + '"}')
        else
          Reply(204, 'No Content', '');
      end
      else if Path = '/health' then
        Reply(200, 'OK', '{"name":"influxdb","message":"ready for queries and writes",' +
          '"status":"pass","checks":[],"version":"' + INFLUX_VERSION + '"}')
      else if (Path = '/write') or (Path = '/api/v2/write') then
      begin
        V2 := Path = '/api/v2/write';
        if not SameText(ARequest.Method, 'POST') then
        begin
          ErrorReply(405, 'Method Not Allowed', 'use POST to write');
          Exit;
        end;
        if V2 then
        begin
          Db := Param(ARequest, 'bucket');
          P := Pos('/', Db);                        // bucket "db/rp"
          if P > 0 then Db := Copy(Db, 1, P - 1);
        end
        else
          Db := Param(ARequest, 'db');
        if Db = '' then
        begin
          ErrorReply(400, 'Bad Request', 'database is required');
          Exit;
        end;
        Prec := Param(ARequest, 'precision');
        Factor := PrecisionFactor(Prec);
        if Factor = 0 then
        begin
          ErrorReply(400, 'Bad Request', 'invalid precision ' + Prec);
          Exit;
        end;
        if Pos('gzip', LowerCase(ARequest.GetFieldByName('Content-Encoding'))) > 0 then
        begin
          { not Gunzip(Body, Body): the out parameter would empty the input first }
          if not Gunzip(ARequest.Content, Body, Err) then
          begin
            ErrorReply(400, 'Bad Request', Err);
            Exit;
          end;
        end
        else
          Body := ARequest.Content;
        Code := FStore.Write(Db, Body, Factor, Points, Err);
        Count(1, Points, 0, Ord(Code <> 204), Length(ARequest.Content));
        Info := Format('db=%s %d points', [Db, Points]);
        if Code = 204 then
          Reply(204, 'No Content', '')
        else
        begin
          if Code = 404 then Reply(404, 'Not Found', '') else Reply(400, 'Bad Request', '');
          if V2 then
            AResponse.Content := '{"code":"invalid","message":' + JsonString(Err) + '}'
          else
            AResponse.Content := '{"error":' + JsonString(Err) + '}';
          AResponse.ContentType := 'application/json';
          Info := Info + ': ' + Copy(Err, 1, 200);
        end;
      end
      else if Path = '/query' then
      begin
        Q := Param(ARequest, 'q');
        if Q = '' then
        begin
          ErrorReply(400, 'Bad Request', 'missing required parameter "q"');
          Exit;
        end;
        Db := Param(ARequest, 'db');
        Ep := Param(ARequest, 'epoch');
        EpochF := 0;
        if Ep <> '' then
        begin
          EpochF := PrecisionFactor(Ep);
          if EpochF = 0 then
          begin
            ErrorReply(400, 'Bad Request', 'invalid epoch ' + Ep);
            Exit;
          end;
        end;
        Body := ExecuteQuery(FStore, Q, Db, EpochF, Code);
        Count(0, 0, 1, Ord(Code <> 200), 0);
        if Code = 200 then Reply(200, 'OK', Body + #10) else Reply(Code, 'Bad Request', Body + #10);
        Info := Copy(StringReplace(Q, #10, ' ', [rfReplaceAll]), 1, 300);
      end
      else if Path = '/api/v2/query' then
        Reply(501, 'Not Implemented', '{"code":"not implemented","message":"Flux is not ' +
          'supported by this server, use InfluxQL on /query"}')
      else if Path = '/' then
      begin
        AResponse.Code := 200;
        AResponse.ContentType := 'text/plain';
        AResponse.Content := 'InfluxDB ' + INFLUX_VERSION + ' (Lazarus) - /ping /health /write /query /api/v2/write'#10;
      end
      else
        Reply(404, 'Not Found', '{"error":"not found"}');
    except
      on E: Exception do
      begin
        Reply(500, 'Internal Server Error', '{"error":' + JsonString(E.Message) + '}');
        Count(0, 0, 0, 1, 0);
        Info := Info + ' ' + E.ClassName + ': ' + E.Message;
      end;
    end;
  finally
    if LogRequests or (AResponse.Code >= 400) then
      Log(Format('%s %s %d %s  %d ms', [ARequest.Method, Path, AResponse.Code, Info,
        GetTickCount64 - T0]));
    InterLockedDecrement(FRunning);
  end;
end;

end.

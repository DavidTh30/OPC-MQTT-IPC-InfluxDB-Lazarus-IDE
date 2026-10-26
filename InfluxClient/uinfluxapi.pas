{ ============================================================================
  uinfluxapi - InfluxDB 1.x HTTP API calls (shared by the InfluxDB Client and
  the InfluxDB Signal Generator)
    InfluxPing   GET  /ping                      version from X-Influxdb-Version
    InfluxQuery  GET  /query (SELECT, SHOW)       POST /query (CREATE, DROP, DELETE, ...)
    InfluxWrite  POST /write?db=&precision=      line protocol
  One TFPHTTPClient per call, so every thread can call them.
  u / p for InfluxDB 1.x, or a token (Authorization: Token ...) for InfluxDB 2.x
  through its v1 API.
  ============================================================================ }
unit uinfluxapi;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fphttpclient, fpjson, jsonparser;

type
  TInfluxConn = record
    Url: string;                  // http://127.0.0.1:8086
    User, Password: string;       // optional
    Token: string;                // optional, InfluxDB 2.x
    TimeoutMs: Integer;
  end;

  TInfluxResult = record
    Ok: Boolean;                  // reached the server and no error in the answer
    Code: Integer;                // HTTP status, 0 = not reachable
    Body: string;
    Error: string;
    Version: string;              // InfluxPing
    Ms: Double;
  end;

function InfluxConn(const AUrl: string; const AUser: string = ''; const APassword: string = ''): TInfluxConn;
function InfluxBaseUrl(const Url: string): string;
function InfluxPing(const C: TInfluxConn): TInfluxResult;
{ Epoch: '' = RFC3339 times, else ns u ms s m h }
function InfluxQuery(const C: TInfluxConn; const Db, Q: string; const Epoch: string = ''): TInfluxResult;
function InfluxWrite(const C: TInfluxConn; const Db, Lines, Precision: string): TInfluxResult;
{ "name" with \" escaped (InfluxQL identifier) / 'value' with \' escaped (string literal) }
function QuoteIdent(const S: string): string;
function QuoteString(const S: string): string;
{ all values of one column of the first series of each statement (SHOW DATABASES, ...) }
procedure InfluxColumn(const Json: string; Col: Integer; Dest: TStrings);
{ a JSON value as text: strings without quotes, numbers as 21.5 (not 2.15E+001) }
function JsonCellText(V: TJSONData): string;

implementation

uses
  {$IFDEF WINDOWS} Windows {$ELSE} BaseUnix {$ENDIF};

function NowMs: Double;
{$IFDEF WINDOWS}
var
  C, F: Int64;
begin
  QueryPerformanceCounter(C);
  QueryPerformanceFrequency(F);
  Result := Double(C) / Double(F) * 1000;
end;
{$ELSE}
begin
  Result := Double(GetTickCount64);
end;
{$ENDIF}

function InfluxConn(const AUrl, AUser, APassword: string): TInfluxConn;
begin
  Result := Default(TInfluxConn);
  Result.Url := AUrl;
  Result.User := AUser;
  Result.Password := APassword;
  Result.TimeoutMs := 30000;
end;

function InfluxBaseUrl(const Url: string): string;
begin
  Result := Trim(Url);
  while (Result <> '') and (Result[Length(Result)] = '/') do SetLength(Result, Length(Result) - 1);
  if (Result <> '') and (Pos('://', Result) = 0) then Result := 'http://' + Result;
end;

function Auth(const C: TInfluxConn): string;
begin
  Result := '';
  if C.User <> '' then
    Result := '&u=' + EncodeURLElement(C.User) + '&p=' + EncodeURLElement(C.Password);
end;

{ the "error" of an InfluxDB answer: top level, or the first statement with one }
function JsonError(const Body: string): string;
var
  J: TJSONData;
  R: TJSONArray;
  I: Integer;
begin
  Result := '';
  try
    J := GetJSON(Body);
  except
    Exit;
  end;
  try
    if not (J is TJSONObject) then Exit;
    Result := TJSONObject(J).Get('error', '');
    if Result = '' then Result := TJSONObject(J).Get('message', '');   // InfluxDB 2.x
    if Result <> '' then Exit;
    R := TJSONObject(J).Find('results', jtArray) as TJSONArray;
    if R <> nil then
      for I := 0 to R.Count - 1 do
        if (R.Items[I] is TJSONObject) and (TJSONObject(R.Items[I]).Find('error') <> nil) then
          Exit(Format('statement %d: %s', [I + 1, TJSONObject(R.Items[I]).Get('error', '')]));
  finally
    J.Free;
  end;
end;

function Call(const C: TInfluxConn; const Method, PathQuery, Body, ContentType: string): TInfluxResult;
var
  H: TFPHTTPClient;
  Req, Res: TStringStream;
  T0: Double;
begin
  Result := Default(TInfluxResult);
  T0 := NowMs;
  H := TFPHTTPClient.Create(nil);
  Req := nil;
  Res := TStringStream.Create('');
  try
    H.ConnectTimeout := 3000;
    if C.TimeoutMs > 0 then H.IOTimeout := C.TimeoutMs else H.IOTimeout := 30000;
    if C.Token <> '' then H.AddHeader('Authorization', 'Token ' + C.Token);
    if Body <> '' then
    begin
      Req := TStringStream.Create(Body);
      H.RequestBody := Req;
      H.AddHeader('Content-Type', ContentType);
    end;
    try
      H.HTTPMethod(Method, InfluxBaseUrl(C.Url) + PathQuery, Res, []);
      Result.Code := H.ResponseStatusCode;
      Result.Body := Res.DataString;
      Result.Version := H.ResponseHeaders.Values['X-Influxdb-Version'];
      if Result.Code >= 400 then
      begin
        Result.Error := JsonError(Result.Body);
        if Result.Error = '' then Result.Error := Format('HTTP %d %s', [Result.Code, Trim(Copy(Result.Body, 1, 200))]);
      end
      else
        Result.Error := JsonError(Result.Body);
      Result.Ok := Result.Error = '';
    except
      on E: Exception do
        Result.Error := InfluxBaseUrl(C.Url) + ' not reachable: ' + E.Message;
    end;
  finally
    H.RequestBody := nil;
    Req.Free;
    Res.Free;
    H.Free;
  end;
  Result.Ms := NowMs - T0;
end;

function InfluxPing(const C: TInfluxConn): TInfluxResult;
begin
  Result := Call(C, 'GET', '/ping', '', '');
  if Result.Ok and not (Result.Code in [200, 204]) then
  begin
    Result.Ok := False;
    Result.Error := Format('/ping answered HTTP %d - is this an InfluxDB?', [Result.Code]);
  end;
end;

function InfluxQuery(const C: TInfluxConn; const Db, Q, Epoch: string): TInfluxResult;
var
  P, First: string;
begin
  P := '';
  if Db <> '' then P := '&db=' + EncodeURLElement(Db);
  if Epoch <> '' then P := P + '&epoch=' + Epoch;
  P := P + Auth(C);
  First := UpperCase(Copy(TrimLeft(Q), 1, 6));
  if (First = 'SELECT') or (Copy(First, 1, 4) = 'SHOW') then
    Result := Call(C, 'GET', '/query?q=' + EncodeURLElement(Q) + P, '', '')
  else
    { InfluxDB 1.x wants POST for statements that change something }
    Result := Call(C, 'POST', '/query?' + Copy(P, 2, MaxInt), 'q=' + EncodeURLElement(Q),
      'application/x-www-form-urlencoded');
end;

function InfluxWrite(const C: TInfluxConn; const Db, Lines, Precision: string): TInfluxResult;
var
  P: string;
begin
  P := '/write?db=' + EncodeURLElement(Db);
  if Precision <> '' then P := P + '&precision=' + Precision;
  Result := Call(C, 'POST', P + Auth(C), Lines, 'text/plain; charset=utf-8');
  if Result.Ok and (Result.Code <> 204) and (Result.Code <> 200) then
    Result.Ok := False;
end;

function QuoteIdent(const S: string): string;
begin
  Result := '"' + StringReplace(StringReplace(S, '\', '\\', [rfReplaceAll]), '"', '\"', [rfReplaceAll]) + '"';
end;

function QuoteString(const S: string): string;
begin
  Result := '''' + StringReplace(StringReplace(S, '\', '\\', [rfReplaceAll]), '''', '\''', [rfReplaceAll]) + '''';
end;

var
  FS: TFormatSettings;

function JsonCellText(V: TJSONData): string;
begin
  case V.JSONType of
    jtString: Result := V.AsString;
    jtNumber:
      if TJSONNumber(V).NumberType = ntFloat then
        Result := FloatToStrF(V.AsFloat, ffGeneral, 15, 0, FS)
      else
        Result := IntToStr(V.AsInt64);
    jtNull: Result := '';
  else
    Result := V.AsJSON;                            // true / false, arrays
  end;
end;

procedure InfluxColumn(const Json: string; Col: Integer; Dest: TStrings);
var
  J: TJSONData;
  R, Series, Vals: TJSONArray;
  I, K, V: Integer;
  S: TJSONObject;
  Row: TJSONArray;
begin
  Dest.Clear;
  try
    J := GetJSON(Json);
  except
    Exit;
  end;
  try
    if not (J is TJSONObject) then Exit;
    R := TJSONObject(J).Find('results', jtArray) as TJSONArray;
    if R = nil then Exit;
    for I := 0 to R.Count - 1 do
    begin
      if not (R.Items[I] is TJSONObject) then Continue;
      Series := TJSONObject(R.Items[I]).Find('series', jtArray) as TJSONArray;
      if Series = nil then Continue;
      for K := 0 to Series.Count - 1 do
      begin
        S := Series.Objects[K];
        Vals := S.Find('values', jtArray) as TJSONArray;
        if Vals = nil then Continue;
        for V := 0 to Vals.Count - 1 do
        begin
          Row := Vals.Arrays[V];
          if Col < Row.Count then
            Dest.Add(JsonCellText(Row.Items[Col]));
        end;
      end;
    end;
  finally
    J.Free;
  end;
end;

initialization
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  FS.ThousandSeparator := #0;
end.

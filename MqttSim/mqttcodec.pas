{ ============================================================================
  mqttcodec - MQTT 3.1 / 3.1.1 packet helpers shared by the broker (MqttSim)
  and the client (MqttClient): packet types, encoding of lengths / strings,
  decoding with bounds checks, topic filter matching.
  Packets are kept in strings (1-based bytes).
  ============================================================================ }
unit mqttcodec;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

const
  MQ_CONNECT = 1; MQ_CONNACK = 2; MQ_PUBLISH = 3; MQ_PUBACK = 4; MQ_PUBREC = 5;
  MQ_PUBREL = 6; MQ_PUBCOMP = 7; MQ_SUBSCRIBE = 8; MQ_SUBACK = 9; MQ_UNSUBSCRIBE = 10;
  MQ_UNSUBACK = 11; MQ_PINGREQ = 12; MQ_PINGRESP = 13; MQ_DISCONNECT = 14;
  MAX_PACKET = 1024 * 1024;

type
  EMqttError = class(Exception);    // protocol error: the connection is closed

function EncLen(N: Integer): string;
function EncU16(N: Integer): string;
function EncStr(const S: string): string;
function Packet(PType, Flags: Byte; const Body: string = ''): string;
{ big endian word at P (1-based) }
function GetU16(const B: string; P: Integer): Integer;
{ length-prefixed string at P, P moves behind it }
function GetStr(const B: string; var P: Integer): string;
{ MQTT filter with + and # against a topic name ($ topics only match explicit filters) }
function TopicMatch(const Filter, Topic: string): Boolean;
function ValidFilter(const Filter: string): Boolean;
function ValidTopic(const Topic: string): Boolean;
function PacketName(PType: Integer): string;
function ConnackText(Code: Integer): string;

implementation

function EncLen(N: Integer): string;
var
  B: Byte;
begin
  Result := '';
  repeat
    B := N and $7F;
    N := N shr 7;
    if N > 0 then
      B := B or $80;
    Result := Result + Chr(B);
  until N = 0;
end;

function EncU16(N: Integer): string;
begin
  Result := Chr((N shr 8) and $FF) + Chr(N and $FF);
end;

function EncStr(const S: string): string;
begin
  Result := EncU16(Length(S)) + S;
end;

function Packet(PType, Flags: Byte; const Body: string): string;
begin
  Result := Chr((PType shl 4) or Flags) + EncLen(Length(Body)) + Body;
end;

function GetU16(const B: string; P: Integer): Integer;
begin
  if P + 1 > Length(B) then
    raise EMqttError.Create('packet too short');
  Result := (Ord(B[P]) shl 8) or Ord(B[P + 1]);
end;

function GetStr(const B: string; var P: Integer): string;
var
  N: Integer;
begin
  N := GetU16(B, P);
  if P + 1 + N > Length(B) then
    raise EMqttError.Create('packet too short');
  Result := Copy(B, P + 2, N);
  Inc(P, 2 + N);
end;

{ "a/b/" -> ['a', 'b', ''] (empty levels are kept, unlike some Split versions) }
function SplitLevels(const S: string): TStringArray;
var
  I, Start, N: Integer;
begin
  Result := nil;
  N := 0;
  SetLength(Result, 1);
  Start := 1;
  for I := 1 to Length(S) do
    if S[I] = '/' then
    begin
      Result[N] := Copy(S, Start, I - Start);
      Inc(N);
      SetLength(Result, N + 1);
      Start := I + 1;
    end;
  Result[N] := Copy(S, Start, Length(S) - Start + 1);
end;

function TopicMatch(const Filter, Topic: string): Boolean;
var
  F, T: TStringArray;
  I: Integer;
begin
  if (Topic <> '') and (Topic[1] = '$') and (Filter <> '') and (Filter[1] in ['+', '#']) then
    Exit(False);
  F := SplitLevels(Filter);
  T := SplitLevels(Topic);
  for I := 0 to High(F) do
  begin
    if F[I] = '#' then
      Exit(True);
    if (I > High(T)) or ((F[I] <> '+') and (F[I] <> T[I])) then
      Exit(False);
  end;
  Result := Length(F) = Length(T);
end;

function ValidFilter(const Filter: string): Boolean;
var
  P: TStringArray;
  I: Integer;
begin
  if (Filter = '') or (Length(Filter) > 65535) then
    Exit(False);
  P := SplitLevels(Filter);
  for I := 0 to High(P) do
  begin
    if (Pos('#', P[I]) > 0) and ((P[I] <> '#') or (I <> High(P))) then
      Exit(False);
    if (Pos('+', P[I]) > 0) and (P[I] <> '+') then
      Exit(False);
  end;
  Result := True;
end;

function ValidTopic(const Topic: string): Boolean;
begin
  Result := (Topic <> '') and (Length(Topic) <= 65535) and (Pos('+', Topic) = 0) and
    (Pos('#', Topic) = 0);
end;

function PacketName(PType: Integer): string;
const
  Names: array[1..14] of string = ('CONNECT', 'CONNACK', 'PUBLISH', 'PUBACK', 'PUBREC',
    'PUBREL', 'PUBCOMP', 'SUBSCRIBE', 'SUBACK', 'UNSUBSCRIBE', 'UNSUBACK', 'PINGREQ',
    'PINGRESP', 'DISCONNECT');
begin
  if (PType >= 1) and (PType <= 14) then
    Result := Names[PType]
  else
    Result := 'type ' + IntToStr(PType);
end;

function ConnackText(Code: Integer): string;
begin
  case Code of
    0: Result := 'accepted';
    1: Result := 'unacceptable protocol version';
    2: Result := 'client id rejected';
    3: Result := 'server unavailable';
    4: Result := 'bad user name or password';
    5: Result := 'not authorized';
  else
    Result := 'refused, code ' + IntToStr(Code);
  end;
end;

end.

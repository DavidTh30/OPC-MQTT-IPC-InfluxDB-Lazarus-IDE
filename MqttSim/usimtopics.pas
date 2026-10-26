{ ============================================================================
  usimtopics - the simulated PLC (uplcsim) as MQTT topics, the same layout
  as Tools/mqttsim.py:
    <prefix>/DB_HMI/<tag>        value as JSON text (5.0, 12, true)
    <prefix>/DB_HMI/Curve_xxx    JSON object with the arrays "Eng" and "Volt"
    <prefix>/Sim/<tag>           test values, Clock as ISO 8601 UTC text
    <prefix>/status              online
  Every topic is retained and published only when its value changed.
  A client writes by publishing to "<topic>/set".
  ============================================================================ }
unit usimtopics;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, fpjson, jsonparser, uaencode, uaserver, uplcsim, mqttbroker;

type
  TSimTopic = record
    Topic: string;
    Kind: TTagKind;
    Tag: Integer;
    VoltTag: Integer;          // curves: the .Volt tag (Tag is .Eng), else -1
    Writable: Boolean;
  end;

  { TSimTopics }

  TSimTopics = class
  private
    FBroker: TMqttBroker;
    FSim: TPlcSim;
    FPrefix: string;
    FInterval: Integer;
    FThread: TThread;
    FLast: array of string;    // last published payload (publish thread only)
    function TagJson(Tag: Integer): string;
    function WriteValue(const T: TSimTopic; const Payload: string; out Msg: string): Boolean;
    function OnWrite(const Topic, Payload: string): Boolean;
  public
    Items: array of TSimTopic;
    constructor Create(ABroker: TMqttBroker; ASim: TPlcSim; const APrefix: string;
      AIntervalMs: Integer);
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
    procedure PublishChanged;
    function Payload(I: Integer): string;
    function TypeText(I: Integer): string;
    property Prefix: string read FPrefix;
  end;

implementation

type

  { TPublishThread }

  TPublishThread = class(TThread)
  private
    FOwner: TSimTopics;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TSimTopics);
  end;

var
  JsonFS: TFormatSettings;

{ 7 significant digits like the float32 in DB10, always with a decimal point (5.0) }
function JsonReal(X: Double): string;
begin
  if IsNan(X) or IsInfinite(X) then
    Exit('null');
  Result := FloatToStrF(X, ffGeneral, 7, 0, JsonFS);
  if (Pos('.', Result) = 0) and (Pos('E', Result) = 0) then
    Result := Result + '.0';
end;

function StatusText(Code: Cardinal): string;
begin
  case Code of
    UA_BadTypeMismatch: Result := 'wrong type or array length';
    UA_BadOutOfRange: Result := 'out of range';
    UA_BadNotWritable: Result := 'read only';
  else
    Result := Format('error 0x%.8x', [Code]);
  end;
end;

{ TPublishThread }

constructor TPublishThread.Create(AOwner: TSimTopics);
begin
  FOwner := AOwner;
  inherited Create(False);
end;

procedure TPublishThread.Execute;
begin
  MaskFPUExceptions;
  while not Terminated do
  begin
    FOwner.PublishChanged;
    Sleep(FOwner.FInterval);
  end;
end;

{ TSimTopics }

constructor TSimTopics.Create(ABroker: TMqttBroker; ASim: TPlcSim; const APrefix: string;
  AIntervalMs: Integer);
var
  I, J, N: Integer;
  Name: string;
begin
  FBroker := ABroker;
  FSim := ASim;
  FPrefix := APrefix;
  FInterval := Max(AIntervalMs, 20);
  for I := 0 to High(FSim.Tags) do
  begin
    Name := FSim.Tags[I].Name;
    if FSim.Tags[I].Kind = tkRealArray then
    begin
      { Curve_xxx.Eng + Curve_xxx.Volt -> one topic Curve_xxx }
      if not Name.EndsWith('.Eng') then Continue;
      Name := Copy(Name, 1, Length(Name) - 4);
    end;
    N := Length(Items);
    SetLength(Items, N + 1);
    Items[N].Topic := FPrefix + '/' + StringReplace(Name, '.', '/', [rfReplaceAll]);
    Items[N].Kind := FSim.Tags[I].Kind;
    Items[N].Tag := FSim.Tags[I].Id;
    Items[N].VoltTag := -1;
    Items[N].Writable := FSim.Tags[I].Writable;
    if Items[N].Kind = tkRealArray then
      for J := 0 to High(FSim.Tags) do
        if FSim.Tags[J].Name = Name + '.Volt' then
          Items[N].VoltTag := FSim.Tags[J].Id;
  end;
  SetLength(FLast, Length(Items));
  FBroker.OnWrite := @OnWrite;
end;

destructor TSimTopics.Destroy;
begin
  Stop;
  if FBroker.OnWrite = @OnWrite then
    FBroker.OnWrite := nil;
  inherited Destroy;
end;

procedure TSimTopics.Start;
begin
  FBroker.Publish(FPrefix + '/status', 'online', 0, True);
  if FThread = nil then
    FThread := TPublishThread.Create(Self);
end;

procedure TSimTopics.Stop;
begin
  if FThread = nil then Exit;
  FThread.Terminate;
  FThread.WaitFor;
  FreeAndNil(FThread);
end;

function TSimTopics.TagJson(Tag: Integer): string;
var
  V: TUAVariant;
  I: Integer;
  UTC: TDateTime;
begin
  if not FSim.ReadTag(Tag, V) or ((Length(V.D) = 0) and not V.IsArray) then
    Exit('null');
  if V.IsArray then
  begin
    Result := '[';
    for I := 0 to High(V.D) do
    begin
      if I > 0 then Result := Result + ', ';
      Result := Result + JsonReal(V.D[I]);
    end;
    Exit(Result + ']');
  end;
  case V.VType of
    vtBoolean: Result := BoolToStr(V.D[0] <> 0, 'true', 'false');
    vtFloat, vtDouble: Result := JsonReal(V.D[0]);
    vtDateTime:
      begin
        { UA time = 100 ns since 1601-01-01 UTC; 109205 days from 1601 to 1899-12-30 }
        UTC := Double(V.D[0]) / Double(864000000000) - 109205;
        Result := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz"+00:00"', UTC);
      end;
  else
    Result := IntToStr(Round(V.D[0]));
  end;
end;

function TSimTopics.Payload(I: Integer): string;
begin
  if Items[I].Kind = tkRealArray then
    Result := '{"Eng": ' + TagJson(Items[I].Tag) + ', "Volt": ' + TagJson(Items[I].VoltTag) + '}'
  else
    Result := TagJson(Items[I].Tag);   // Clock is plain text, no JSON quotes (as mqttsim.py)
end;

function TSimTopics.TypeText(I: Integer): string;
begin
  case Items[I].Kind of
    tkReal: Result := 'Real';
    tkInt: Result := 'Int';
    tkBool: Result := 'Bool';
    tkRealArray: Result := 'JSON curve';
    tkUInt16: Result := 'UInt16';
    tkDouble: Result := 'Double';
    tkDateTime: Result := 'ISO 8601';
  end;
end;

procedure TSimTopics.PublishChanged;
var
  I: Integer;
  P: string;
begin
  for I := 0 to High(Items) do
  begin
    P := Payload(I);
    if P <> FLast[I] then
    begin
      FLast[I] := P;
      FBroker.Publish(Items[I].Topic, P, 0, True);
    end;
  end;
end;

function TSimTopics.WriteValue(const T: TSimTopic; const Payload: string; out Msg: string): Boolean;
var
  S: string;
  X: Double;
  Code: Cardinal;
  J: TJSONData;
  Obj: TJSONObject;

  function ArrayOf(const Key: string; out V: TUAVariant): Boolean;
  var
    A: TJSONArray;
    D: array of Double;
    K: Integer;
  begin
    Result := False;
    if Obj.IndexOfName(Key) < 0 then Exit;
    if not (Obj.Elements[Key] is TJSONArray) then
      raise EConvertError.Create(Key + ' is not an array');
    A := TJSONArray(Obj.Elements[Key]);
    SetLength(D, A.Count);
    for K := 0 to A.Count - 1 do
      if A[K] is TJSONNumber then
        D[K] := A[K].AsFloat
      else
        raise EConvertError.Create(Key + ' must hold numbers');
    V := VarArray(vtFloat, D);
    Result := True;
  end;

var
  VE, VV: TUAVariant;
  HasE, HasV: Boolean;
begin
  Msg := '';
  S := LowerCase(Trim(Payload));
  Code := UA_GOOD;
  case T.Kind of
    tkBool:
      begin
        if (S = '1') or (S = 'true') or (S = 'on') then
          X := 1
        else if (S = '0') or (S = 'false') or (S = 'off') then
          X := 0
        else
        begin
          Msg := 'expected 1/0/true/false/on/off';
          Exit(False);
        end;
        Code := FSim.WriteTag(T.Tag, VarScalar(vtBoolean, X));
      end;
    tkReal, tkInt:
      begin
        if not TryStrToFloat(S, X, JsonFS) then
        begin
          Msg := 'not a number';
          Exit(False);
        end;
        if T.Kind = tkReal then
          Code := FSim.WriteTag(T.Tag, VarScalar(vtFloat, X))
        else
          Code := FSim.WriteTag(T.Tag, VarScalar(vtInt16, X));
      end;
    tkRealArray:
      begin
        try
          J := GetJSON(Payload);
        except
          on E: Exception do
          begin
            Msg := 'invalid JSON: ' + E.Message;
            Exit(False);
          end;
        end;
        try
          if not (J is TJSONObject) then
          begin
            Msg := 'expected {"Eng": [..], "Volt": [..]}';
            Exit(False);
          end;
          Obj := TJSONObject(J);
          try
            HasE := ArrayOf('Eng', VE);
            HasV := ArrayOf('Volt', VV);
          except
            on E: EConvertError do
            begin
              Msg := E.Message;
              Exit(False);
            end;
          end;
          if not HasE and not HasV then
          begin
            Msg := 'expected "Eng" and / or "Volt"';
            Exit(False);
          end;
          { both parts in one PLC cycle, else Set 2 could check a half written curve }
          FSim.Lock;
          try
            if HasE then Code := FSim.WriteTag(T.Tag, VE);
            if (Code = UA_GOOD) and HasV then Code := FSim.WriteTag(T.VoltTag, VV);
          finally
            FSim.Unlock;
          end;
        finally
          J.Free;
        end;
      end;
  else
    Code := UA_BadNotWritable;
  end;
  if Code <> UA_GOOD then
    Msg := StatusText(Code);
  Result := Code = UA_GOOD;
end;

{ client publish to <topic>/set -> simulated DB10 (the next PLC cycle checks it) }
function TSimTopics.OnWrite(const Topic, Payload: string): Boolean;
var
  Base, Msg, Shown: string;
  I: Integer;
begin
  if not Topic.EndsWith('/set') or not Topic.StartsWith(FPrefix + '/') then
    Exit(False);
  Result := True;
  Base := Copy(Topic, 1, Length(Topic) - 4);
  Shown := Payload;
  if Length(Shown) > 200 then
    Shown := Copy(Shown, 1, 200) + '...';
  for I := 0 to High(Items) do
    if Items[I].Topic = Base then
    begin
      if not Items[I].Writable then
        Break;
      if WriteValue(Items[I], Payload, Msg) then
        FBroker.Log('write ' + Base + ' = ' + Shown)
      else
        FBroker.Log('write refused ' + Base + ' = ' + Shown + ' (' + Msg + ')');
      Exit;
    end;
  FBroker.Log('write refused (unknown or read only): ' + Topic);
end;

initialization
  JsonFS := DefaultFormatSettings;
  JsonFS.DecimalSeparator := '.';
  JsonFS.ThousandSeparator := #0;
end.

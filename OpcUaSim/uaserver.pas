{ ============================================================================
  uaserver - minimal OPC UA server (UA TCP binary, no DLL needed)
    - Hello / Acknowledge, secure channel with security policy None
    - one session per connection, anonymous login only
    - GetEndpoints, FindServers, CreateSession, ActivateSession, CloseSession
    - Browse, BrowseNext, TranslateBrowsePathsToNodeIds, RegisterNodes
    - Read, Write (Value attribute, also with IndexRange on arrays)
    - Subscriptions: Create / Modify / Delete / SetPublishingMode,
      MonitoredItems: Create / Modify / Delete / SetMonitoringMode, Publish
  Address space: the standard Root / Objects / Types / Server nodes, plus
  the objects and variables the program adds. Variable values come from the
  OnReadTag / OnWriteTag events (called from the connection threads).
  ============================================================================ }
unit uaserver;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, Math, Sockets, uaencode;

const
  { status codes }
  UA_GOOD = $00000000;
  UA_BadInternalError = $80020000;
  UA_BadDecodingError = $80070000;
  UA_BadTimeout = $800A0000;
  UA_BadServiceUnsupported = $800B0000;
  UA_BadNothingToDo = $800F0000;
  UA_BadIdentityTokenInvalid = $80200000;
  UA_BadSessionIdInvalid = $80250000;
  UA_BadSessionClosed = $80260000;
  UA_BadSessionNotActivated = $80270000;
  UA_BadSubscriptionIdInvalid = $80280000;
  UA_BadNodeIdUnknown = $80340000;
  UA_BadAttributeIdInvalid = $80350000;
  UA_BadIndexRangeInvalid = $80360000;
  UA_BadIndexRangeNoData = $80370000;
  UA_BadNotReadable = $803A0000;
  UA_BadNotWritable = $803B0000;
  UA_BadOutOfRange = $803C0000;
  UA_BadMonitoringModeInvalid = $80410000;
  UA_BadMonitoredItemIdInvalid = $80420000;
  UA_BadContinuationPointInvalid = $804A0000;
  UA_BadBrowseDirectionInvalid = $804D0000;
  UA_BadSecurityModeRejected = $80540000;
  UA_BadSecurityPolicyRejected = $80550000;
  UA_BadNoMatch = $806F0000;
  UA_BadTypeMismatch = $80740000;
  UA_BadTooManySubscriptions = $80770000;
  UA_BadTooManyPublishRequests = $80780000;
  UA_BadNoSubscription = $80790000;
  UA_BadMessageNotAvailable = $807B0000;
  UA_BadTcpMessageTypeInvalid = $807E0000;
  UA_BadTcpMessageTooLarge = $80800000;

  { node classes }
  ncObject = 1;
  ncVariable = 2;
  ncObjectType = 8;
  ncVariableType = 16;
  ncReferenceType = 32;
  ncDataType = 64;

  { reference types }
  rtReferences = 31;
  rtNonHierarchical = 32;
  rtHierarchical = 33;
  rtHasChild = 34;
  rtOrganizes = 35;
  rtHasTypeDefinition = 40;
  rtAggregates = 44;
  rtHasSubtype = 45;
  rtHasProperty = 46;
  rtHasComponent = 47;

  { special value sources (TUANode.Tag < 0) }
  TAG_CONST = -1;
  TAG_NSARRAY = -2;
  TAG_STATUS = -3;
  TAG_STARTTIME = -4;
  TAG_CURTIME = -5;

  APP_URI = 'urn:nonlinear:opcuasim';
  APP_NAME = 'Nonlinear HV OPC UA Simulator';

type
  TUANode = class;

  TUARef = record
    RefType: Cardinal;
    Target: TUANode;
  end;

  { TUANode }

  TUANode = class
  public
    Id: TUANodeId;
    NodeClass: Integer;
    BrowseName: TUAQName;
    DisplayName: string;
    Description: string;
    TypeDef: Cardinal;          // ns=0 type definition, 0 = none
    TypeLinked: Boolean;
    Refs: array of TUARef;      // forward references
    InvRefs: array of TUARef;   // built at Start
    DataType: Cardinal;         // ns=0 data type
    ValueRank: Integer;         // -1 scalar, 1 one dimension
    ArrayLen: Integer;
    Writable: Boolean;
    Tag: Integer;               // >= 0: OnReadTag / OnWriteTag, < 0: TAG_xxx
    Value: TUAVariant;          // value for TAG_CONST
    IsAbstract, Symmetric: Boolean;
    InverseName: string;
    procedure AddRef(ARefType: Cardinal; ATarget: TUANode);
  end;

  TUAReadTagEvent = function(Tag: Integer; out V: TUAVariant): Boolean of object;
  TUAWriteTagEvent = function(Tag: Integer; const V: TUAVariant): Cardinal of object;

  { TUAServer }

  TUAServer = class
  private
    FNodes: TStringList;        // NodeIdKey -> TUANode
    FNamespaces: array of string;
    FListen: LongInt;
    FListener: TThread;
    FConns: TList;
    FConnLock: TCriticalSection;
    FLogLock: TCriticalSection;
    FLog: TStringList;
    FPort: Integer;
    FRunning: Boolean;
    FStartTime: Int64;
    FNextId: LongInt;
    FOnReadTag: TUAReadTagEvent;
    FOnWriteTag: TUAWriteTagEvent;
    function Std(Id: Cardinal; NC: Integer; const Name: string; ATypeDef: Cardinal = 0): TUANode;
    function StdVar(Parent: TUANode; RefType, Id: Cardinal; const Name: string; ADataType: Cardinal;
      ARank: Integer; ATypeDef: Cardinal; ATag: Integer): TUANode;
    procedure BuildStandardNodes;
    procedure LinkNodes;
    procedure AddConn(Sock: LongInt; const Peer: string);
    function ServerStatusValue: TUAVariant;
  public
    constructor Create;
    destructor Destroy; override;
    function AddNamespace(const Uri: string): Word;
    function AddNode(const AId: TUANodeId; NC: Integer; const AName: TUAQName; ATypeDef: Cardinal): TUANode;
    function FindNode(const AId: TUANodeId): TUANode;
    function NodeByNum(Num: Cardinal): TUANode;
    function ObjectsFolder: TUANode;
    function AddObject(Parent: TUANode; Ns: Word; const IdStr, Name: string): TUANode;
    { DataType = built-in type id (vtFloat ...), AArrayLen 0 = scalar }
    function AddVariable(Parent: TUANode; Ns: Word; const IdStr, Name: string; ADataType: Byte;
      AArrayLen: Integer; AWritable: Boolean; ATag: Integer): TUANode;
    function Start(APort: Integer; out Err: string): Boolean;
    procedure Stop;
    function ClientCount: Integer;
    procedure Log(const S: string);
    procedure TakeLog(Dest: TStrings);
    { attribute service, used by the connections (thread safe) }
    function GetValue(N: TUANode; out V: TUAVariant): Boolean;
    function ReadAttr(N: TUANode; Attr: Cardinal; const Range: string; TS: Integer): TUADataValue;
    function WriteValue(N: TUANode; const Range: string; const DV: TUADataValue): Cardinal;
    function NextId: Cardinal;
    property Running: Boolean read FRunning;
    property Port: Integer read FPort;
    property OnReadTag: TUAReadTagEvent read FOnReadTag write FOnReadTag;
    property OnWriteTag: TUAWriteTagEvent read FOnWriteTag write FOnWriteTag;
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
  POLICY_NONE = 'http://opcfoundation.org/UA/SecurityPolicy#None';
  TRANSPORT_BINARY = 'http://opcfoundation.org/UA-Profile/Transport/uatcp-uasc-uabinary';
  RECV_BUF = 65536;             // our receive buffer = largest chunk we accept
  MAX_MESSAGE = 16 * 1024 * 1024;
  MAX_CONNECTIONS = 16;
  MAX_SUBSCRIPTIONS = 20;
  MAX_PUBLISH_QUEUE = 20;
  MIN_INTERVAL = 50.0;          // fastest publishing / sampling interval (ms)
  IPPROTO_TCP_ = 6;
  TCP_NODELAY_ = 1;

type
  EUAClosed = class(Exception);

  TReqHeader = record
    Token: TUANodeId;
    Handle: Cardinal;
    Timeout: Cardinal;
  end;

  TRefDesc = record
    RefType: Cardinal;
    Forward: Boolean;
    Target: TUANode;
  end;
  TRefDescs = array of TRefDesc;

  TBrowseCont = record
    Id: Cardinal;
    Refs: TRefDescs;
  end;

  TPubReq = record
    ReqId, Handle: Cardinal;
    Deadline: QWord;            // 0 = no timeout
    AckCount: Integer;
  end;

  { TMonItem }

  TMonItem = class
    Id, ClientHandle: Cardinal;
    Node: TUANode;
    Attr: Cardinal;
    Range: string;
    TS: Integer;
    Mode: Integer;              // 0 disabled, 1 sampling, 2 reporting
    Interval: Double;
    NextSample: QWord;
    Last: TBytes;
    HasLast: Boolean;
    Pending: Boolean;
    PendingDV: TUADataValue;
  end;

  { TSubscr }

  TSubscr = class
    Id: Cardinal;
    Interval: Double;
    Lifetime, MaxKeep, MaxNotif: Cardinal;
    Enabled: Boolean;
    NextPub: QWord;
    KeepCtr: Cardinal;
    SeqNo: Cardinal;
    WantData, WantKeep: Boolean;
    Items: TFPList;
    constructor Create;
    destructor Destroy; override;
    function Find(AId: Cardinal): TMonItem;
  end;

  { TUAListener }

  TUAListener = class(TThread)
  private
    FServer: TUAServer;
  protected
    procedure Execute; override;
  public
    constructor Create(AServer: TUAServer);
  end;

  { TUAConn }

  TUAConn = class(TThread)
  private
    FServer: TUAServer;
    FSock: LongInt;
    FPeer: string;
    FChannelId, FTokenId, FSendSeq: Cardinal;
    FSendChunk: Integer;
    FEndpointUrl: string;
    FPartial: TBytes;
    FW, FChunk: TUAWriter;
    FHasSession, FActivated: Boolean;
    FSessionId, FAuthToken: TUANodeId;
    FSessionName: string;
    FSubs: TFPList;
    FPubQ: array of TPubReq;
    FConts: array of TBrowseCont;
    FNextItemId: Cardinal;
    function WaitData(Ms: Integer): Boolean;
    procedure RecvExact(var Buf; Count: Integer);
    procedure SendAll(W: TUAWriter);
    procedure SendError(Code: Cardinal; const Reason: string);
    procedure SendMsg(ReqId: Cardinal; const Body: TBytes);
    function HandleChunk(const MsgType: string; ChunkType: Char; const Body: TBytes): Boolean;
    function HandleOpen(const Body: TBytes): Boolean;
    procedure DispatchRequest(ReqId: Cardinal; const Body: TBytes);
    procedure Resp(TypeNum, AHandle: Cardinal; Status: Cardinal = UA_GOOD);
    procedure Fault(ReqId, AHandle, Status: Cardinal);
    function Url(const Requested: string): string;
    procedure WriteAppDesc(const AUrl: string);
    procedure WriteEndpoint(const AUrl: string);
    function Nonce: TBytes;
    function FindSub(AId: Cardinal): TSubscr;
    procedure DeleteSubs;
    procedure FlushPublish(Status: Cardinal);
    procedure CollectRefs(N: TUANode; Dir: Integer; const RefFilter: TUANodeId; Subtypes: Boolean;
      ClassMask: Cardinal; out Refs: TRefDescs);
    procedure WriteBrowseResult(const Refs: TRefDescs; MaxRefs: Cardinal);
    procedure SvcGetEndpoints(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
    procedure SvcFindServers(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
    procedure SvcCreateSession(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
    procedure SvcActivateSession(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
    procedure SvcCloseSession(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
    procedure SvcBrowse(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
    procedure SvcBrowseNext(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
    procedure SvcTranslate(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
    procedure SvcRegisterNodes(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
    procedure SvcRead(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
    procedure SvcWrite(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
    procedure SvcCreateSubscription(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
    procedure SvcModifySubscription(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
    procedure SvcSetPublishingMode(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
    procedure SvcDeleteSubscriptions(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
    procedure SvcCreateMonitoredItems(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
    procedure SvcModifyMonitoredItems(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
    procedure SvcSetMonitoringMode(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
    procedure SvcDeleteMonitoredItems(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
    procedure SvcPublish(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
    procedure Sample(M: TMonItem);
    procedure SendPublish(S: TSubscr);
    procedure ServiceSubscriptions;
  protected
    procedure Execute; override;
  public
    constructor Create(AServer: TUAServer; ASock: LongInt; const APeer: string);
    destructor Destroy; override;
    procedure Shutdown;
    property Peer: string read FPeer;
  end;

{ ---------------------------------------------------------------------------- }

function RefParent(RT: Cardinal): Cardinal;
begin
  case RT of
    rtHierarchical, rtNonHierarchical: Result := rtReferences;
    rtHasChild, rtOrganizes: Result := rtHierarchical;
    rtAggregates, rtHasSubtype: Result := rtHasChild;
    rtHasComponent, rtHasProperty: Result := rtAggregates;
    rtHasTypeDefinition: Result := rtNonHierarchical;
  else
    Result := 0;
  end;
end;

function IsSubtype(RT, Base: Cardinal): Boolean;
var
  I: Integer;
begin
  for I := 0 to 7 do
  begin
    if RT = Base then Exit(True);
    if RT = 0 then Break;
    RT := RefParent(RT);
  end;
  Result := False;
end;

function RefMatches(RT: Cardinal; const Filter: TUANodeId; Subtypes: Boolean): Boolean;
begin
  if IsNullNodeId(Filter) then Exit(True);
  if (Filter.Ns <> 0) or (Filter.IdType <> idNumeric) then Exit(False);
  if Subtypes then
    Result := IsSubtype(RT, Filter.Num)
  else
    Result := RT = Filter.Num;
end;

function EncodeToBytes(const N: TUANodeId): TBytes;
var
  W: TUAWriter;
begin
  W := TUAWriter.Create;
  try
    W.NodeId(N);
    Result := W.Data;
  finally
    W.Free;
  end;
end;

function QNameBytes(const Q: TUAQName): TBytes;
var
  W: TUAWriter;
begin
  W := TUAWriter.Create;
  try
    W.QName(Q);
    Result := W.Data;
  finally
    W.Free;
  end;
end;

function VarLText(const S: string): TUAVariant;
begin
  Result := VarString(S);
  Result.VType := vtLText;
end;

{ IndexRange 'a' or 'a:b' }
function ParseRange(const S: string; out Lo, Hi: Integer): Boolean;
var
  P: Integer;
begin
  P := Pos(':', S);
  if P = 0 then
  begin
    Result := TryStrToInt(S, Lo) and (Lo >= 0);
    Hi := Lo;
  end
  else
    Result := TryStrToInt(Copy(S, 1, P - 1), Lo) and TryStrToInt(Copy(S, P + 1, MaxInt), Hi) and
      (Lo >= 0) and (Hi > Lo);
end;

function BytesEqual(const A, B: TBytes): Boolean;
begin
  Result := (Length(A) = Length(B)) and ((Length(A) = 0) or CompareMem(@A[0], @B[0], Length(A)));
end;

{ next time of a fixed-rate timer: no drift, but no catching up after a long pause }
function NextTick(Last: QWord; Interval: Double; Now: QWord): QWord;
begin
  Result := Last + QWord(Round(Interval));
  if Result <= Now then
    Result := Now + QWord(Round(Interval));
end;

function ReviseInterval(X: Double): Double;
begin
  if IsNan(X) or (X < MIN_INTERVAL) then
    Result := MIN_INTERVAL
  else if X > 60000 then
    Result := 60000
  else
    Result := X;
end;

{ ---------------------------------------------------------------------------- }
{ TUANode }

procedure TUANode.AddRef(ARefType: Cardinal; ATarget: TUANode);
var
  N: Integer;
begin
  N := Length(Refs);
  SetLength(Refs, N + 1);
  Refs[N].RefType := ARefType;
  Refs[N].Target := ATarget;
end;

{ ---------------------------------------------------------------------------- }
{ TSubscr }

constructor TSubscr.Create;
begin
  Items := TFPList.Create;
  SeqNo := 1;
end;

destructor TSubscr.Destroy;
var
  I: Integer;
begin
  for I := 0 to Items.Count - 1 do
    TMonItem(Items[I]).Free;
  Items.Free;
  inherited Destroy;
end;

function TSubscr.Find(AId: Cardinal): TMonItem;
var
  I: Integer;
begin
  for I := 0 to Items.Count - 1 do
    if TMonItem(Items[I]).Id = AId then
      Exit(TMonItem(Items[I]));
  Result := nil;
end;

{ ---------------------------------------------------------------------------- }
{ TUAServer }

constructor TUAServer.Create;
begin
  FNodes := TStringList.Create;
  FNodes.Sorted := True;
  FNodes.Duplicates := dupError;
  FNodes.CaseSensitive := True;
  FConns := TList.Create;
  FConnLock := TCriticalSection.Create;
  FLogLock := TCriticalSection.Create;
  FLog := TStringList.Create;
  FListen := -1;
  FNamespaces := ['http://opcfoundation.org/UA/', APP_URI];
  Randomize;
  BuildStandardNodes;
end;

destructor TUAServer.Destroy;
var
  I: Integer;
begin
  Stop;
  for I := 0 to FNodes.Count - 1 do
    FNodes.Objects[I].Free;
  FNodes.Free;
  FConns.Free;
  FConnLock.Free;
  FLogLock.Free;
  FLog.Free;
  inherited Destroy;
end;

function TUAServer.AddNamespace(const Uri: string): Word;
var
  I: Integer;
begin
  for I := 0 to High(FNamespaces) do
    if FNamespaces[I] = Uri then
      Exit(I);
  Result := Length(FNamespaces);
  SetLength(FNamespaces, Result + 1);
  FNamespaces[Result] := Uri;
end;

function TUAServer.AddNode(const AId: TUANodeId; NC: Integer; const AName: TUAQName;
  ATypeDef: Cardinal): TUANode;
begin
  Result := TUANode.Create;
  Result.Id := AId;
  Result.NodeClass := NC;
  Result.BrowseName := AName;
  Result.DisplayName := AName.Name;
  Result.TypeDef := ATypeDef;
  Result.ValueRank := -1;
  Result.Tag := TAG_CONST;
  FNodes.AddObject(NodeIdKey(AId), Result);
end;

function TUAServer.FindNode(const AId: TUANodeId): TUANode;
var
  I: Integer;
begin
  if FNodes.Find(NodeIdKey(AId), I) then
    Result := TUANode(FNodes.Objects[I])
  else
    Result := nil;
end;

function TUAServer.NodeByNum(Num: Cardinal): TUANode;
begin
  Result := FindNode(NumNodeId(0, Num));
end;

function TUAServer.ObjectsFolder: TUANode;
begin
  Result := NodeByNum(85);
end;

function TUAServer.Std(Id: Cardinal; NC: Integer; const Name: string; ATypeDef: Cardinal): TUANode;
begin
  Result := AddNode(NumNodeId(0, Id), NC, QN(0, Name), ATypeDef);
end;

function TUAServer.StdVar(Parent: TUANode; RefType, Id: Cardinal; const Name: string;
  ADataType: Cardinal; ARank: Integer; ATypeDef: Cardinal; ATag: Integer): TUANode;
begin
  Result := Std(Id, ncVariable, Name, ATypeDef);
  Result.DataType := ADataType;
  Result.ValueRank := ARank;
  Result.Tag := ATag;
  Parent.AddRef(RefType, Result);
end;

procedure TUAServer.BuildStandardNodes;

  function Sub(Parent: TUANode; Id: Cardinal; NC: Integer; const Name: string;
    Abstract: Boolean = False): TUANode;
  begin
    Result := Std(Id, NC, Name);
    Result.IsAbstract := Abstract;
    Parent.AddRef(rtHasSubtype, Result);
  end;

  function RefT(Parent: TUANode; Id: Cardinal; const Name, Inverse: string;
    Abstract: Boolean = False): TUANode;
  begin
    Result := Sub(Parent, Id, ncReferenceType, Name, Abstract);
    Result.InverseName := Inverse;
  end;

var
  Root, Objs, Types, Srv, Status, F, T, Num: TUANode;
  V: TUANode;
begin
  Root := Std(84, ncObject, 'Root', 61);
  Objs := Std(85, ncObject, 'Objects', 61);
  Types := Std(86, ncObject, 'Types', 61);
  Root.AddRef(rtOrganizes, Objs);
  Root.AddRef(rtOrganizes, Types);
  Root.AddRef(rtOrganizes, Std(87, ncObject, 'Views', 61));

  { object types }
  F := Std(88, ncObject, 'ObjectTypes', 61);
  Types.AddRef(rtOrganizes, F);
  T := Std(58, ncObjectType, 'BaseObjectType');
  F.AddRef(rtOrganizes, T);
  Sub(T, 61, ncObjectType, 'FolderType');
  Sub(T, 2004, ncObjectType, 'ServerType');

  { variable types }
  F := Std(89, ncObject, 'VariableTypes', 61);
  Types.AddRef(rtOrganizes, F);
  T := Std(62, ncVariableType, 'BaseVariableType');
  T.IsAbstract := True;
  F.AddRef(rtOrganizes, T);
  Sub(Sub(T, 63, ncVariableType, 'BaseDataVariableType'), 2138, ncVariableType, 'ServerStatusType');
  Sub(T, 68, ncVariableType, 'PropertyType');

  { data types }
  F := Std(90, ncObject, 'DataTypes', 61);
  Types.AddRef(rtOrganizes, F);
  T := Std(24, ncDataType, 'BaseDataType');
  T.IsAbstract := True;
  F.AddRef(rtOrganizes, T);
  Sub(T, 1, ncDataType, 'Boolean');
  Sub(T, 12, ncDataType, 'String');
  Sub(T, 13, ncDataType, 'DateTime');
  Sub(T, 15, ncDataType, 'ByteString');
  Sub(Sub(T, 22, ncDataType, 'Structure', True), 862, ncDataType, 'ServerStatusDataType');
  Sub(Sub(T, 29, ncDataType, 'Enumeration', True), 852, ncDataType, 'ServerState');
  Num := Sub(T, 26, ncDataType, 'Number', True);
  Sub(Num, 10, ncDataType, 'Float');
  Sub(Num, 11, ncDataType, 'Double');
  V := Sub(Num, 27, ncDataType, 'Integer', True);
  Sub(V, 2, ncDataType, 'SByte');
  Sub(V, 4, ncDataType, 'Int16');
  Sub(V, 6, ncDataType, 'Int32');
  Sub(V, 8, ncDataType, 'Int64');
  V := Sub(Num, 28, ncDataType, 'UInteger', True);
  Sub(V, 3, ncDataType, 'Byte');
  Sub(V, 5, ncDataType, 'UInt16');
  Sub(V, 7, ncDataType, 'UInt32');
  Sub(V, 9, ncDataType, 'UInt64');

  { reference types }
  F := Std(91, ncObject, 'ReferenceTypes', 61);
  Types.AddRef(rtOrganizes, F);
  T := Std(rtReferences, ncReferenceType, 'References');
  T.IsAbstract := True;
  T.Symmetric := True;
  F.AddRef(rtOrganizes, T);
  V := RefT(T, rtHierarchical, 'HierarchicalReferences', 'InverseHierarchicalReferences', True);
  RefT(RefT(T, rtNonHierarchical, 'NonHierarchicalReferences', 'NonHierarchicalReferences', True),
    rtHasTypeDefinition, 'HasTypeDefinition', 'TypeDefinitionOf');
  RefT(V, rtOrganizes, 'Organizes', 'OrganizedBy');
  V := RefT(V, rtHasChild, 'HasChild', 'ChildOf', True);
  RefT(V, rtHasSubtype, 'HasSubtype', 'SubtypeOf');
  V := RefT(V, rtAggregates, 'Aggregates', 'AggregatedBy', True);
  RefT(V, rtHasComponent, 'HasComponent', 'ComponentOf');
  RefT(V, rtHasProperty, 'HasProperty', 'PropertyOf');

  { Server object }
  Srv := Std(2253, ncObject, 'Server', 2004);
  Objs.AddRef(rtOrganizes, Srv);
  V := StdVar(Srv, rtHasProperty, 2254, 'ServerArray', vtString, 1, 68, TAG_CONST);
  V.Value := VarStrings([APP_URI]);
  StdVar(Srv, rtHasProperty, 2255, 'NamespaceArray', vtString, 1, 68, TAG_NSARRAY);
  Status := StdVar(Srv, rtHasComponent, 2256, 'ServerStatus', 862, -1, 2138, TAG_STATUS);
  StdVar(Status, rtHasComponent, 2257, 'StartTime', vtDateTime, -1, 63, TAG_STARTTIME);
  StdVar(Status, rtHasComponent, 2258, 'CurrentTime', vtDateTime, -1, 63, TAG_CURTIME);
  V := StdVar(Status, rtHasComponent, 2259, 'State', 852, -1, 63, TAG_CONST);
  V.Value := VarScalar(vtInt32, 0);                 // Running
  V := StdVar(Srv, rtHasProperty, 2267, 'ServiceLevel', vtByte, -1, 68, TAG_CONST);
  V.Value := VarScalar(vtByte, 255);
end;

function TUAServer.AddObject(Parent: TUANode; Ns: Word; const IdStr, Name: string): TUANode;
begin
  Result := AddNode(StrNodeId(Ns, IdStr), ncObject, QN(Ns, Name), 58);
  if Parent = ObjectsFolder then
    Parent.AddRef(rtOrganizes, Result)
  else
    Parent.AddRef(rtHasComponent, Result);
end;

function TUAServer.AddVariable(Parent: TUANode; Ns: Word; const IdStr, Name: string;
  ADataType: Byte; AArrayLen: Integer; AWritable: Boolean; ATag: Integer): TUANode;
begin
  Result := AddNode(StrNodeId(Ns, IdStr), ncVariable, QN(Ns, Name), 63);
  Result.DataType := ADataType;
  Result.ArrayLen := AArrayLen;
  if AArrayLen > 0 then
    Result.ValueRank := 1;
  Result.Writable := AWritable;
  Result.Tag := ATag;
  Parent.AddRef(rtHasComponent, Result);
end;

procedure TUAServer.LinkNodes;
var
  I, J, K: Integer;
  N, T: TUANode;
begin
  for I := 0 to FNodes.Count - 1 do
  begin
    N := TUANode(FNodes.Objects[I]);
    if (N.TypeDef <> 0) and not N.TypeLinked then
    begin
      T := NodeByNum(N.TypeDef);
      if T <> nil then
        N.AddRef(rtHasTypeDefinition, T);
      N.TypeLinked := True;
    end;
    N.InvRefs := nil;
  end;
  for I := 0 to FNodes.Count - 1 do
  begin
    N := TUANode(FNodes.Objects[I]);
    for J := 0 to High(N.Refs) do
    begin
      T := N.Refs[J].Target;
      K := Length(T.InvRefs);
      SetLength(T.InvRefs, K + 1);
      T.InvRefs[K].RefType := N.Refs[J].RefType;
      T.InvRefs[K].Target := N;
    end;
  end;
end;

function TUAServer.Start(APort: Integer; out Err: string): Boolean;
var
  Addr: TInetSockAddr;
  One: LongInt;
begin
  Err := '';
  if FRunning then Exit(True);
  LinkNodes;
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
  FStartTime := UANow;
  FRunning := True;
  FListener := TUAListener.Create(Self);
  Log(Format('Server started: opc.tcp://<this PC>:%d/nonlinear/', [APort]));
  Result := True;
end;

procedure TUAServer.Stop;
var
  I: Integer;
  C: TUAConn;
begin
  if not FRunning then Exit;
  FRunning := False;
  FListener.Terminate;
  CloseSocket(FListen);
  FListener.WaitFor;
  FreeAndNil(FListener);
  FListen := -1;
  FConnLock.Enter;
  try
    for I := 0 to FConns.Count - 1 do
      TUAConn(FConns[I]).Shutdown;
    for I := 0 to FConns.Count - 1 do
    begin
      C := TUAConn(FConns[I]);
      C.WaitFor;
      C.Free;
    end;
    FConns.Clear;
  finally
    FConnLock.Leave;
  end;
  Log('Server stopped');
end;

procedure TUAServer.AddConn(Sock: LongInt; const Peer: string);
var
  I: Integer;
  C: TUAConn;
begin
  FConnLock.Enter;
  try
    for I := FConns.Count - 1 downto 0 do      // remove closed connections
    begin
      C := TUAConn(FConns[I]);
      if C.Finished then
      begin
        C.WaitFor;
        C.Free;
        FConns.Delete(I);
      end;
    end;
    if FConns.Count >= MAX_CONNECTIONS then
    begin
      CloseSocket(Sock);
      Log(Peer + ' refused: too many connections');
      Exit;
    end;
    FConns.Add(TUAConn.Create(Self, Sock, Peer));
  finally
    FConnLock.Leave;
  end;
  Log(Peer + ' connected');
end;

function TUAServer.ClientCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  FConnLock.Enter;
  try
    for I := 0 to FConns.Count - 1 do
      if not TUAConn(FConns[I]).Finished then
        Inc(Result);
  finally
    FConnLock.Leave;
  end;
end;

procedure TUAServer.Log(const S: string);
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

procedure TUAServer.TakeLog(Dest: TStrings);
begin
  FLogLock.Enter;
  try
    Dest.AddStrings(FLog);
    FLog.Clear;
  finally
    FLogLock.Leave;
  end;
end;

function TUAServer.NextId: Cardinal;
begin
  Result := Cardinal(InterLockedIncrement(FNextId));
end;

function TUAServer.ServerStatusValue: TUAVariant;
var
  W: TUAWriter;
  LenPos: Integer;
begin
  W := TUAWriter.Create;
  try
    W.NumId(864);                  // ServerStatusDataType, binary encoding
    W.U8(1);
    LenPos := W.Len;
    W.I32(0);
    W.DateTime(FStartTime);
    W.DateTime(UANow);
    W.I32(0);                      // state Running
    W.Str(APP_URI);                // BuildInfo
    W.Str('Nonlinear');
    W.Str(APP_NAME);
    W.Str('1.0');
    W.Str('1');
    W.DateTime(FStartTime);
    W.U32(0);                      // seconds till shutdown
    W.LText('');
    W.PatchI32(LenPos, W.Len - LenPos - 4);
    Result := VarRaw(vtExtObj, W.Data);
  finally
    W.Free;
  end;
end;

function TUAServer.GetValue(N: TUANode; out V: TUAVariant): Boolean;
begin
  Result := True;
  if N.Tag >= 0 then
    Result := Assigned(FOnReadTag) and FOnReadTag(N.Tag, V)
  else
    case N.Tag of
      TAG_NSARRAY: V := VarStrings(FNamespaces);
      TAG_STATUS: V := ServerStatusValue;
      TAG_STARTTIME: V := VarScalar(vtDateTime, FStartTime);
      TAG_CURTIME: V := VarScalar(vtDateTime, UANow);
    else
      V := N.Value;
    end;
end;

function TUAServer.ReadAttr(N: TUANode; Attr: Cardinal; const Range: string; TS: Integer): TUADataValue;
var
  V: TUAVariant;
  Lo, Hi: Integer;
  Bad: Cardinal;
  IsType, IsVar: Boolean;
begin
  Result := Default(TUADataValue);
  Bad := UA_GOOD;
  IsType := N.NodeClass in [ncObjectType, ncVariableType, ncReferenceType, ncDataType];
  IsVar := N.NodeClass in [ncVariable, ncVariableType];
  V := Default(TUAVariant);
  case Attr of
    1: V := VarRaw(vtNodeId, EncodeToBytes(N.Id));
    2: V := VarScalar(vtInt32, N.NodeClass);
    3: V := VarRaw(vtQName, QNameBytes(N.BrowseName));
    4: V := VarLText(N.DisplayName);
    5: V := VarLText(N.Description);
    6, 7: V := VarScalar(vtUInt32, 0);
    8: if IsType then V := VarScalar(vtBoolean, Ord(N.IsAbstract)) else Bad := UA_BadAttributeIdInvalid;
    9: if N.NodeClass = ncReferenceType then V := VarScalar(vtBoolean, Ord(N.Symmetric))
       else Bad := UA_BadAttributeIdInvalid;
    10: if N.NodeClass = ncReferenceType then V := VarLText(N.InverseName)
        else Bad := UA_BadAttributeIdInvalid;
    12: if N.NodeClass = ncObject then V := VarScalar(vtByte, 0) else Bad := UA_BadAttributeIdInvalid;
    13:
      if N.NodeClass <> ncVariable then
        Bad := UA_BadAttributeIdInvalid
      else if not GetValue(N, V) then
        Bad := UA_BadInternalError;
    14: if IsVar then V := VarRaw(vtNodeId, EncodeToBytes(NumNodeId(0, N.DataType)))
        else Bad := UA_BadAttributeIdInvalid;
    15: if IsVar then V := VarScalar(vtInt32, N.ValueRank) else Bad := UA_BadAttributeIdInvalid;
    16:
      if not IsVar then
        Bad := UA_BadAttributeIdInvalid
      else if N.ValueRank = 1 then
        V := VarArray(vtUInt32, [N.ArrayLen]);
    17, 18: if N.NodeClass = ncVariable then V := VarScalar(vtByte, 1 + 2 * Ord(N.Writable))
            else Bad := UA_BadAttributeIdInvalid;
    19: if N.NodeClass = ncVariable then V := VarScalar(vtDouble, MIN_INTERVAL)
        else Bad := UA_BadAttributeIdInvalid;
    20: if N.NodeClass = ncVariable then V := VarScalar(vtBoolean, 0) else Bad := UA_BadAttributeIdInvalid;
    27: if N.NodeClass = ncVariable then V := VarScalar(vtUInt32, 1 + 2 * Ord(N.Writable))
        else Bad := UA_BadAttributeIdInvalid;
  else
    Bad := UA_BadAttributeIdInvalid;
  end;

  if (Bad = UA_GOOD) and (Range <> '') then
  begin
    if not ParseRange(Range, Lo, Hi) then
      Bad := UA_BadIndexRangeInvalid
    else if (Attr <> 13) or not V.IsArray then
      Bad := UA_BadIndexRangeNoData
    else if V.D <> nil then
    begin
      if Lo > High(V.D) then
        Bad := UA_BadIndexRangeNoData
      else
        V.D := Copy(V.D, Lo, Min(Hi, High(V.D)) - Lo + 1);
    end
    else if Lo > High(V.S) then
      Bad := UA_BadIndexRangeNoData
    else
      V.S := Copy(V.S, Lo, Min(Hi, High(V.S)) - Lo + 1);
  end;

  if Bad <> UA_GOOD then
  begin
    Result.Status := Bad;
    if TS in [1, 2] then Result.SrvTime := UANow;
    Exit;
  end;
  Result.HasValue := True;
  Result.Value := V;
  if Attr = 13 then
  begin
    if TS in [0, 2] then Result.SrcTime := UANow;
    if TS in [1, 2] then Result.SrvTime := UANow;
  end
  else if TS in [1, 2] then
    Result.SrvTime := UANow;
end;

function TUAServer.WriteValue(N: TUANode; const Range: string; const DV: TUADataValue): Cardinal;
var
  Cur, V: TUAVariant;
  Lo, Hi, I: Integer;
begin
  if (N.NodeClass <> ncVariable) or not N.Writable or (N.Tag < 0) then
    Exit(UA_BadNotWritable);
  if not DV.HasValue then
    Exit(UA_BadTypeMismatch);
  V := DV.Value;
  if Range <> '' then
  begin
    { write part of an array: read it, patch the elements, write all }
    if not ParseRange(Range, Lo, Hi) then
      Exit(UA_BadIndexRangeInvalid);
    if not GetValue(N, Cur) then
      Exit(UA_BadInternalError);
    if not Cur.IsArray or (Cur.D = nil) or (Hi > High(Cur.D)) then
      Exit(UA_BadIndexRangeNoData);
    if not VarIsNumeric(V) or (Length(V.D) <> Hi - Lo + 1) then
      Exit(UA_BadTypeMismatch);
    for I := Lo to Hi do
      Cur.D[I] := V.D[I - Lo];
    V := Cur;
  end;
  if not Assigned(FOnWriteTag) then
    Exit(UA_BadNotWritable);
  Result := FOnWriteTag(N.Tag, V);
end;

{ ---------------------------------------------------------------------------- }
{ TUAListener }

constructor TUAListener.Create(AServer: TUAServer);
begin
  FServer := AServer;
  inherited Create(False);
end;

procedure TUAListener.Execute;
var
  Addr: TInetSockAddr;
  L: TSockLen;
  S: LongInt;
begin
  while not Terminated do
  begin
    L := SizeOf(Addr);
    S := fpAccept(FServer.FListen, @Addr, @L);
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
    FServer.AddConn(S, NetAddrToStr(Addr.sin_addr) + ':' + IntToStr(ntohs(Addr.sin_port)));
  end;
end;

{ ---------------------------------------------------------------------------- }
{ TUAConn - socket I/O }

constructor TUAConn.Create(AServer: TUAServer; ASock: LongInt; const APeer: string);
var
  One: LongInt;
begin
  FServer := AServer;
  FSock := ASock;
  FPeer := APeer;
  FW := TUAWriter.Create;
  FChunk := TUAWriter.Create;
  FSubs := TFPList.Create;
  FSendChunk := 8192;
  FSendSeq := 1;
  One := 1;
  fpSetSockOpt(FSock, IPPROTO_TCP_, TCP_NODELAY_, @One, SizeOf(One));
  inherited Create(False);
end;

destructor TUAConn.Destroy;
begin
  DeleteSubs;
  FSubs.Free;
  FW.Free;
  FChunk.Free;
  inherited Destroy;
end;

procedure TUAConn.Shutdown;
begin
  Terminate;
  fpShutdown(FSock, 2);     // select / recv return at once, Execute closes the socket
end;

function TUAConn.WaitData(Ms: Integer): Boolean;
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
    raise EUAClosed.Create('closed');
  Result := R > 0;
end;

procedure TUAConn.RecvExact(var Buf; Count: Integer);
var
  P: PByte;
  R: LongInt;
begin
  P := @Buf;
  while Count > 0 do
  begin
    R := fpRecv(FSock, P, Count, 0);
    if R <= 0 then
      raise EUAClosed.Create('closed');
    Inc(P, R);
    Dec(Count, R);
  end;
end;

procedure TUAConn.SendAll(W: TUAWriter);
var
  B: TBytes;
  Ofs, R: Integer;
begin
  B := W.Data;
  Ofs := 0;
  while Ofs < Length(B) do
  begin
    R := fpSend(FSock, @B[Ofs], Length(B) - Ofs, 0);
    if R <= 0 then
      raise EUAClosed.Create('closed');
    Inc(Ofs, R);
  end;
end;

procedure TUAConn.SendError(Code: Cardinal; const Reason: string);
begin
  FChunk.Clear;
  FChunk.Bytes(PChar('ERRF')^, 4);
  FChunk.U32(16 + Length(Reason));
  FChunk.U32(Code);
  FChunk.Str(Reason);
  SendAll(FChunk);
  FServer.Log(Format('%s: error 0x%.8x %s', [FPeer, Code, Reason]));
end;

procedure TUAConn.SendMsg(ReqId: Cardinal; const Body: TBytes);
var
  MaxBody, Ofs, N: Integer;
  Last: Boolean;
begin
  MaxBody := FSendChunk - 24;
  Ofs := 0;
  repeat
    N := Min(MaxBody, Length(Body) - Ofs);
    Last := Ofs + N >= Length(Body);
    FChunk.Clear;
    FChunk.Bytes(PChar('MSG')^, 3);
    if Last then FChunk.U8(Ord('F')) else FChunk.U8(Ord('C'));
    FChunk.U32(24 + N);
    FChunk.U32(FChannelId);
    FChunk.U32(FTokenId);
    FChunk.U32(FSendSeq);
    FChunk.U32(ReqId);
    if N > 0 then
      FChunk.Bytes(Body[Ofs], N);
    Inc(FSendSeq);
    SendAll(FChunk);
    Inc(Ofs, N);
  until Last;
end;

procedure TUAConn.Execute;
var
  H: array[0..7] of Byte;
  MsgType: string;
  Size: Cardinal;
  Body: TBytes;
begin
  { a client may write NaN / Inf: no floating point exceptions in this thread }
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  try
    try
      while not Terminated do
      begin
        if WaitData(10) then
        begin
          RecvExact(H, 8);
          SetString(MsgType, PChar(@H[0]), 3);
          Move(H[4], Size, 4);
          Size := LEtoN(Size);
          if (Size < 8) or (Size > RECV_BUF) then
          begin
            SendError(UA_BadTcpMessageTooLarge, 'chunk too large');
            Break;
          end;
          SetLength(Body, Size - 8);
          if Size > 8 then
            RecvExact(Body[0], Size - 8);
          if not HandleChunk(MsgType, Chr(H[3]), Body) then
            Break;
        end;
        ServiceSubscriptions;
      end;
    except
      on E: EUAClosed do ;
      on E: Exception do
        FServer.Log(FPeer + ': ' + E.ClassName + ' ' + E.Message);
    end;
  finally
    CloseSocket(FSock);
    FServer.Log(FPeer + ' disconnected');
  end;
end;

function TUAConn.HandleChunk(const MsgType: string; ChunkType: Char; const Body: TBytes): Boolean;
var
  R: TUAReader;
  RecvBuf, ClientSend: Cardinal;
  ReqId: Cardinal;
  Rest: TBytes;
begin
  Result := True;
  if MsgType = 'HEL' then
  begin
    R := TUAReader.Create(Body);
    try
      R.U32;                       // protocol version
      RecvBuf := R.U32;
      ClientSend := R.U32;
      R.U32;                       // max message size
      R.U32;                       // max chunk count
      FEndpointUrl := R.Str;
    finally
      R.Free;
    end;
    FSendChunk := EnsureRange(Integer(Min(RecvBuf, Cardinal(RECV_BUF))), 8192, RECV_BUF);
    FChunk.Clear;
    FChunk.Bytes(PChar('ACKF')^, 4);
    FChunk.U32(28);
    FChunk.U32(0);
    FChunk.U32(Min(ClientSend, Cardinal(RECV_BUF)));
    FChunk.U32(FSendChunk);
    FChunk.U32(MAX_MESSAGE);
    FChunk.U32(0);
    SendAll(FChunk);
  end
  else if MsgType = 'OPN' then
    Result := HandleOpen(Body)
  else if MsgType = 'MSG' then
  begin
    R := TUAReader.Create(Body);
    try
      R.U32;                       // channel id
      R.U32;                       // token id
      R.U32;                       // sequence number
      ReqId := R.U32;
      Rest := Copy(Body, R.Pos, MaxInt);
    finally
      R.Free;
    end;
    case ChunkType of
      'C':
        begin
          if Length(FPartial) + Length(Rest) > MAX_MESSAGE then
          begin
            SendError(UA_BadTcpMessageTooLarge, 'message too large');
            Exit(False);
          end;
          FPartial := Concat(FPartial, Rest);
        end;
      'A': FPartial := nil;
    else
      Rest := Concat(FPartial, Rest);
      FPartial := nil;
      DispatchRequest(ReqId, Rest);
    end;
  end
  else if MsgType = 'CLO' then
    Result := False
  else
  begin
    SendError(UA_BadTcpMessageTypeInvalid, 'unknown message ' + MsgType);
    Result := False;
  end;
end;

procedure ReadReqHeader(R: TUAReader; out H: TReqHeader);
begin
  H.Token := R.NodeId;
  R.I64;                           // timestamp
  H.Handle := R.U32;
  R.U32;                           // return diagnostics
  R.Str;                           // audit entry id
  H.Timeout := R.U32;
  R.SkipExtObj;                    // additional header
end;

function TUAConn.HandleOpen(const Body: TBytes): Boolean;
var
  R: TUAReader;
  Policy: string;
  ReqId, Lifetime: Cardinal;
  H: TReqHeader;
  ReqType, Mode: LongInt;
begin
  R := TUAReader.Create(Body);
  try
    R.U32;                         // channel id (0 = new)
    Policy := R.Str;
    R.ByteStr;                     // sender certificate
    R.ByteStr;                     // receiver thumbprint
    R.U32;                         // sequence number
    ReqId := R.U32;
    R.NodeId;                      // OpenSecureChannelRequest
    ReadReqHeader(R, H);
    R.U32;                         // client protocol version
    ReqType := R.I32;              // 0 issue, 1 renew
    Mode := R.I32;
    R.ByteStr;                     // client nonce
    Lifetime := R.U32;
  finally
    R.Free;
  end;
  if Policy <> POLICY_NONE then
  begin
    SendError(UA_BadSecurityPolicyRejected, 'only SecurityPolicy None is supported');
    Exit(False);
  end;
  if Mode <> 1 then
  begin
    SendError(UA_BadSecurityModeRejected, 'only MessageSecurityMode None is supported');
    Exit(False);
  end;
  if (ReqType = 0) or (FChannelId = 0) then
    FChannelId := FServer.NextId;
  Inc(FTokenId);
  if (Lifetime = 0) or (Lifetime > 3600000) then
    Lifetime := 3600000;

  FW.Clear;
  FW.NumId(449);
  FW.DateTime(UANow);
  FW.U32(H.Handle);
  FW.U32(UA_GOOD);
  FW.U8(0);
  FW.I32(0);
  FW.NullExtObj;
  FW.U32(0);                       // server protocol version
  FW.U32(FChannelId);
  FW.U32(FTokenId);
  FW.DateTime(UANow);
  FW.U32(Lifetime);
  FW.ByteStr(nil);                 // server nonce

  FChunk.Clear;
  FChunk.Bytes(PChar('OPNF')^, 4);
  FChunk.U32(0);                   // size, patched below
  FChunk.U32(FChannelId);
  FChunk.Str(POLICY_NONE);
  FChunk.NullStr;
  FChunk.NullStr;
  FChunk.U32(FSendSeq);
  FChunk.U32(ReqId);
  FChunk.AddBytes(FW.Data);
  FChunk.PatchI32(4, FChunk.Len);
  Inc(FSendSeq);
  SendAll(FChunk);
  Result := True;
end;

{ ---------------------------------------------------------------------------- }
{ TUAConn - services }

procedure TUAConn.Resp(TypeNum, AHandle: Cardinal; Status: Cardinal);
begin
  FW.Clear;
  FW.NumId(TypeNum);
  FW.DateTime(UANow);
  FW.U32(AHandle);
  FW.U32(Status);
  FW.U8(0);                        // service diagnostics
  FW.I32(0);                       // string table
  FW.NullExtObj;                   // additional header
end;

procedure TUAConn.Fault(ReqId, AHandle, Status: Cardinal);
begin
  Resp(397, AHandle, Status);
  SendMsg(ReqId, FW.Data);
end;

procedure TUAConn.DispatchRequest(ReqId: Cardinal; const Body: TBytes);
var
  R: TUAReader;
  TypeId: TUANodeId;
  H: TReqHeader;
  Svc: Cardinal;
begin
  H := Default(TReqHeader);
  R := TUAReader.Create(Body);
  try
    try
      TypeId := R.NodeId;
      ReadReqHeader(R, H);
      if (TypeId.Ns <> 0) or (TypeId.IdType <> idNumeric) then
        Svc := 0
      else
        Svc := TypeId.Num;
      { session check: GetEndpoints, FindServers, CreateSession and ActivateSession work without }
      if (Svc <> 428) and (Svc <> 422) and (Svc <> 461) and (Svc <> 467) then
      begin
        if not FHasSession or not SameNodeId(H.Token, FAuthToken) then
        begin
          Fault(ReqId, H.Handle, UA_BadSessionIdInvalid);
          Exit;
        end;
        if not FActivated then
        begin
          Fault(ReqId, H.Handle, UA_BadSessionNotActivated);
          Exit;
        end;
      end
      else if (Svc = 467) and (not FHasSession or not SameNodeId(H.Token, FAuthToken)) then
      begin
        Fault(ReqId, H.Handle, UA_BadSessionIdInvalid);
        Exit;
      end;
      case Svc of
        428: SvcGetEndpoints(R, H, ReqId);
        422: SvcFindServers(R, H, ReqId);
        461: SvcCreateSession(R, H, ReqId);
        467: SvcActivateSession(R, H, ReqId);
        473: SvcCloseSession(R, H, ReqId);
        527: SvcBrowse(R, H, ReqId);
        533: SvcBrowseNext(R, H, ReqId);
        554: SvcTranslate(R, H, ReqId);
        560: SvcRegisterNodes(R, H, ReqId);
        566:
          begin
            Resp(569, H.Handle);
            SendMsg(ReqId, FW.Data);
          end;
        631: SvcRead(R, H, ReqId);
        673: SvcWrite(R, H, ReqId);
        787: SvcCreateSubscription(R, H, ReqId);
        793: SvcModifySubscription(R, H, ReqId);
        799: SvcSetPublishingMode(R, H, ReqId);
        847: SvcDeleteSubscriptions(R, H, ReqId);
        751: SvcCreateMonitoredItems(R, H, ReqId);
        763: SvcModifyMonitoredItems(R, H, ReqId);
        769: SvcSetMonitoringMode(R, H, ReqId);
        781: SvcDeleteMonitoredItems(R, H, ReqId);
        826: SvcPublish(R, H, ReqId);
        832: Fault(ReqId, H.Handle, UA_BadMessageNotAvailable);     // Republish
      else
        FServer.Log(Format('%s: service %s not supported', [FPeer, NodeIdText(TypeId)]));
        Fault(ReqId, H.Handle, UA_BadServiceUnsupported);
      end;
    except
      on E: EUADecode do
      begin
        FServer.Log(FPeer + ': decoding error: ' + E.Message);
        Fault(ReqId, H.Handle, UA_BadDecodingError);
      end;
    end;
  finally
    R.Free;
  end;
end;

function TUAConn.Url(const Requested: string): string;
begin
  if Requested <> '' then
    Result := Requested
  else if FEndpointUrl <> '' then
    Result := FEndpointUrl
  else
    Result := Format('opc.tcp://localhost:%d/nonlinear/', [FServer.Port]);
end;

procedure TUAConn.WriteAppDesc(const AUrl: string);
begin
  FW.Str(APP_URI);
  FW.Str(APP_URI);                 // product uri
  FW.LText(APP_NAME);
  FW.I32(0);                       // server
  FW.NullStr;                      // gateway server uri
  FW.NullStr;                      // discovery profile uri
  FW.I32(1);
  FW.Str(AUrl);
end;

procedure TUAConn.WriteEndpoint(const AUrl: string);
begin
  FW.Str(AUrl);
  WriteAppDesc(AUrl);
  FW.NullStr;                      // server certificate
  FW.I32(1);                       // MessageSecurityMode None
  FW.Str(POLICY_NONE);
  FW.I32(1);                       // user token policies
  FW.Str('anonymous');
  FW.I32(0);                       // anonymous
  FW.NullStr;
  FW.NullStr;
  FW.NullStr;
  FW.Str(TRANSPORT_BINARY);
  FW.U8(0);                        // security level
end;

function TUAConn.Nonce: TBytes;
var
  I: Integer;
begin
  SetLength(Result, 32);
  for I := 0 to 31 do
    Result[I] := Random(256);
end;

procedure SkipStrArray(R: TUAReader);
var
  I: Integer;
begin
  for I := 1 to R.ArrLen do
    R.Str;
end;

procedure TUAConn.SvcGetEndpoints(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
var
  U: string;
begin
  U := R.Str;
  SkipStrArray(R);                 // locale ids
  SkipStrArray(R);                 // profile uris
  Resp(431, H.Handle);
  FW.I32(1);
  WriteEndpoint(Url(U));
  SendMsg(ReqId, FW.Data);
end;

procedure TUAConn.SvcFindServers(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
var
  U: string;
begin
  U := R.Str;
  SkipStrArray(R);
  SkipStrArray(R);
  Resp(425, H.Handle);
  FW.I32(1);
  WriteAppDesc(Url(U));
  SendMsg(ReqId, FW.Data);
end;

procedure TUAConn.SvcCreateSession(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
var
  ClientName, U: string;
  Timeout: Double;
begin
  R.Str;                           // client application uri
  R.Str;                           // product uri
  ClientName := R.LText;
  R.I32;
  R.Str;
  R.Str;
  SkipStrArray(R);                 // discovery urls
  R.Str;                           // server uri
  U := R.Str;                      // endpoint url
  FSessionName := R.Str;
  R.ByteStr;                       // client nonce
  R.ByteStr;                       // client certificate
  Timeout := R.F64;
  R.U32;                           // max response message size
  if FHasSession then
  begin
    FlushPublish(UA_BadSessionClosed);
    DeleteSubs;
  end;
  FHasSession := True;
  FActivated := False;
  FSessionId := NumNodeId(1, FServer.NextId);
  FAuthToken := NumNodeId(1, Cardinal(Random($7FFFFFFF)) or $80000000);
  if IsNan(Timeout) or (Timeout < 10000) then Timeout := 10000;
  if Timeout > 3600000 then Timeout := 3600000;

  Resp(464, H.Handle);
  FW.NodeId(FSessionId);
  FW.NodeId(FAuthToken);
  FW.F64(Timeout);
  FW.ByteStr(Nonce);
  FW.NullStr;                      // server certificate
  FW.I32(1);
  WriteEndpoint(Url(U));
  FW.I32(0);                       // server software certificates
  FW.NullStr;                      // signature algorithm
  FW.NullStr;                      // signature
  FW.U32(MAX_MESSAGE);
  SendMsg(ReqId, FW.Data);
  FServer.Log(Format('%s: session "%s" created (%s)', [FPeer, FSessionName, ClientName]));
end;

procedure TUAConn.SvcActivateSession(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
var
  I: Integer;
  TokType: TUANodeId;
  B: TBytes;
begin
  R.Str;                           // client signature
  R.ByteStr;
  for I := 1 to R.ArrLen do        // client software certificates
  begin
    R.ByteStr;
    R.ByteStr;
  end;
  SkipStrArray(R);                 // locale ids
  R.ExtObj(TokType, B);            // user identity token
  if not IsNullNodeId(TokType) and not SameNodeId(TokType, NumNodeId(0, 321)) then
  begin
    FServer.Log(FPeer + ': login refused - only anonymous login is supported');
    Fault(ReqId, H.Handle, UA_BadIdentityTokenInvalid);
    Exit;
  end;
  FActivated := True;
  Resp(470, H.Handle);
  FW.ByteStr(Nonce);
  FW.I32(0);                       // results
  FW.I32(0);                       // diagnostic infos
  SendMsg(ReqId, FW.Data);
end;

procedure TUAConn.SvcCloseSession(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
begin
  R.Bool;                          // delete subscriptions (always done)
  FlushPublish(UA_BadSessionClosed);
  DeleteSubs;
  FHasSession := False;
  FActivated := False;
  FConts := nil;
  Resp(476, H.Handle);
  SendMsg(ReqId, FW.Data);
  FServer.Log(Format('%s: session "%s" closed', [FPeer, FSessionName]));
end;

procedure TUAConn.CollectRefs(N: TUANode; Dir: Integer; const RefFilter: TUANodeId;
  Subtypes: Boolean; ClassMask: Cardinal; out Refs: TRefDescs);

  procedure AddList(const L: array of TUARef; Fwd: Boolean);
  var
    I, K: Integer;
  begin
    for I := 0 to High(L) do
      if RefMatches(L[I].RefType, RefFilter, Subtypes) and
        ((ClassMask = 0) or (ClassMask and Cardinal(L[I].Target.NodeClass) <> 0)) then
      begin
        K := Length(Refs);
        SetLength(Refs, K + 1);
        Refs[K].RefType := L[I].RefType;
        Refs[K].Forward := Fwd;
        Refs[K].Target := L[I].Target;
      end;
  end;

begin
  Refs := nil;
  if Dir in [0, 2] then AddList(N.Refs, True);
  if Dir in [1, 2] then AddList(N.InvRefs, False);
end;

procedure TUAConn.WriteBrowseResult(const Refs: TRefDescs; MaxRefs: Cardinal);
var
  I, N, K: Integer;
  T: TUANode;
begin
  N := Length(Refs);
  FW.U32(UA_GOOD);
  if (MaxRefs > 0) and (Cardinal(N) > MaxRefs) then
  begin
    { keep the rest for BrowseNext }
    N := MaxRefs;
    K := Length(FConts);
    if K >= 50 then
    begin
      Delete(FConts, 0, 1);
      Dec(K);
    end;
    SetLength(FConts, K + 1);
    FConts[K].Id := FServer.NextId;
    FConts[K].Refs := Copy(Refs, N, MaxInt);
    FW.I32(4);
    FW.U32(FConts[K].Id);
  end
  else
    FW.NullStr;                    // no continuation point
  FW.I32(N);
  for I := 0 to N - 1 do
  begin
    T := Refs[I].Target;
    FW.NumId(Refs[I].RefType);
    FW.Bool(Refs[I].Forward);
    FW.NodeId(T.Id);               // ExpandedNodeId without uri / server index
    FW.QName(T.BrowseName);
    FW.LText(T.DisplayName);
    FW.I32(T.NodeClass);
    if T.TypeDef <> 0 then FW.NumId(T.TypeDef) else FW.NumId(0);
  end;
end;

procedure TUAConn.SvcBrowse(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
type
  TDesc = record
    Node: TUANodeId;
    Dir: LongInt;
    RefType: TUANodeId;
    Subtypes: Boolean;
    Mask: Cardinal;
  end;
var
  MaxRefs: Cardinal;
  D: array of TDesc;
  I: Integer;
  N: TUANode;
  Refs: TRefDescs;
begin
  R.NodeId;                        // view
  R.I64;
  R.U32;
  MaxRefs := R.U32;
  SetLength(D, R.ArrLen);
  for I := 0 to High(D) do
  begin
    D[I].Node := R.NodeId;
    D[I].Dir := R.I32;
    D[I].RefType := R.NodeId;
    D[I].Subtypes := R.Bool;
    D[I].Mask := R.U32;
    R.U32;                         // result mask (all fields are always returned)
  end;
  if Length(D) = 0 then
  begin
    Fault(ReqId, H.Handle, UA_BadNothingToDo);
    Exit;
  end;
  Resp(530, H.Handle);
  FW.I32(Length(D));
  for I := 0 to High(D) do
  begin
    N := FServer.FindNode(D[I].Node);
    if (N = nil) or not (D[I].Dir in [0..2]) then
    begin
      if N = nil then FW.U32(UA_BadNodeIdUnknown) else FW.U32(UA_BadBrowseDirectionInvalid);
      FW.NullStr;
      FW.I32(0);
      Continue;
    end;
    CollectRefs(N, D[I].Dir, D[I].RefType, D[I].Subtypes, D[I].Mask, Refs);
    WriteBrowseResult(Refs, MaxRefs);
  end;
  FW.I32(0);
  SendMsg(ReqId, FW.Data);
end;

procedure TUAConn.SvcBrowseNext(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
var
  Release: Boolean;
  CP: array of TBytes;
  I, J, K: Integer;
  Id: Cardinal;
  Refs: TRefDescs;
begin
  Release := R.Bool;
  SetLength(CP, R.ArrLen);
  for I := 0 to High(CP) do
    CP[I] := R.ByteStr;
  Resp(536, H.Handle);
  FW.I32(Length(CP));
  for I := 0 to High(CP) do
  begin
    K := -1;
    if Length(CP[I]) = 4 then
    begin
      Move(CP[I][0], Id, 4);
      Id := LEtoN(Id);
      for J := 0 to High(FConts) do
        if FConts[J].Id = Id then K := J;
    end;
    if K < 0 then
    begin
      FW.U32(UA_BadContinuationPointInvalid);
      FW.NullStr;
      FW.I32(0);
      Continue;
    end;
    Refs := FConts[K].Refs;
    Delete(FConts, K, 1);
    if Release then
    begin
      FW.U32(UA_GOOD);
      FW.NullStr;
      FW.I32(0);
    end
    else
      WriteBrowseResult(Refs, 1000);
  end;
  FW.I32(0);
  SendMsg(ReqId, FW.Data);
end;

procedure TUAConn.SvcTranslate(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
var
  NPaths, P, E, NElem, I, J: Integer;
  StartNode: TUANode;
  Cur, Next: array of TUANode;
  RefType: TUANodeId;
  Inverse, Subtypes: Boolean;
  Target: TUAQName;
  Status: Cardinal;
  Refs: TRefDescs;
  Dir: Integer;
begin
  NPaths := R.ArrLen;
  if NPaths = 0 then
  begin
    Fault(ReqId, H.Handle, UA_BadNothingToDo);
    Exit;
  end;
  Resp(557, H.Handle);
  FW.I32(NPaths);
  for P := 1 to NPaths do
  begin
    StartNode := FServer.FindNode(R.NodeId);
    NElem := R.ArrLen;
    Status := UA_GOOD;
    if StartNode = nil then Status := UA_BadNodeIdUnknown
    else if NElem = 0 then Status := UA_BadNothingToDo;
    Cur := nil;
    if StartNode <> nil then Cur := [StartNode];
    for E := 1 to NElem do
    begin
      RefType := R.NodeId;
      Inverse := R.Bool;
      Subtypes := R.Bool;
      Target := R.QName;
      if Status <> UA_GOOD then Continue;
      if Inverse then Dir := 1 else Dir := 0;
      Next := nil;
      for I := 0 to High(Cur) do
      begin
        CollectRefs(Cur[I], Dir, RefType, Subtypes, 0, Refs);
        for J := 0 to High(Refs) do
          if (Refs[J].Target.BrowseName.Ns = Target.Ns) and
            (Refs[J].Target.BrowseName.Name = Target.Name) then
            Next := Concat(Next, [Refs[J].Target]);
      end;
      Cur := Next;
      if Cur = nil then Status := UA_BadNoMatch;
    end;
    FW.U32(Status);
    if Status <> UA_GOOD then
      FW.I32(0)
    else
    begin
      FW.I32(Length(Cur));
      for I := 0 to High(Cur) do
      begin
        FW.NodeId(Cur[I].Id);
        FW.U32($FFFFFFFF);         // remaining path index: complete
      end;
    end;
  end;
  FW.I32(0);
  SendMsg(ReqId, FW.Data);
end;

procedure TUAConn.SvcRegisterNodes(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
var
  Ids: array of TUANodeId;
  I: Integer;
begin
  SetLength(Ids, R.ArrLen);
  for I := 0 to High(Ids) do
    Ids[I] := R.NodeId;
  Resp(563, H.Handle);
  FW.I32(Length(Ids));
  for I := 0 to High(Ids) do
    FW.NodeId(Ids[I]);
  SendMsg(ReqId, FW.Data);
end;

procedure TUAConn.SvcRead(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
var
  TS: LongInt;
  I, N: Integer;
  Id: TUANodeId;
  Attr: Cardinal;
  Range: string;
  Node: TUANode;
  DV: TUADataValue;
begin
  R.F64;                           // max age
  TS := R.I32;
  N := R.ArrLen;
  if N = 0 then
  begin
    Fault(ReqId, H.Handle, UA_BadNothingToDo);
    Exit;
  end;
  Resp(634, H.Handle);
  FW.I32(N);
  for I := 1 to N do
  begin
    Id := R.NodeId;
    Attr := R.U32;
    Range := R.Str;
    R.QName;                       // data encoding
    Node := FServer.FindNode(Id);
    if Node = nil then
    begin
      DV := Default(TUADataValue);
      DV.Status := UA_BadNodeIdUnknown;
    end
    else
      DV := FServer.ReadAttr(Node, Attr, Range, TS);
    FW.DataValue(DV);
  end;
  FW.I32(0);
  SendMsg(ReqId, FW.Data);
end;

procedure TUAConn.SvcWrite(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
var
  I, N: Integer;
  Id: TUANodeId;
  Attr, St: Cardinal;
  Range: string;
  DV: TUADataValue;
  Node: TUANode;
  Res: array of Cardinal;
begin
  N := R.ArrLen;
  if N = 0 then
  begin
    Fault(ReqId, H.Handle, UA_BadNothingToDo);
    Exit;
  end;
  SetLength(Res, N);
  for I := 0 to N - 1 do
  begin
    Id := R.NodeId;
    Attr := R.U32;
    Range := R.Str;
    DV := R.DataValue;
    Node := FServer.FindNode(Id);
    if Node = nil then
      St := UA_BadNodeIdUnknown
    else if Attr <> 13 then
      St := UA_BadNotWritable
    else
      St := FServer.WriteValue(Node, Range, DV);
    Res[I] := St;
    if St = UA_GOOD then
      FServer.Log(Format('%s: write %s = %s', [FPeer, NodeIdText(Id), VarText(DV.Value)]))
    else
      FServer.Log(Format('%s: write %s refused (0x%.8x)', [FPeer, NodeIdText(Id), St]));
  end;
  Resp(676, H.Handle);
  FW.I32(N);
  for I := 0 to N - 1 do
    FW.U32(Res[I]);
  FW.I32(0);
  SendMsg(ReqId, FW.Data);
end;

{ ---------------------------------------------------------------------------- }
{ TUAConn - subscriptions }

function TUAConn.FindSub(AId: Cardinal): TSubscr;
var
  I: Integer;
begin
  for I := 0 to FSubs.Count - 1 do
    if TSubscr(FSubs[I]).Id = AId then
      Exit(TSubscr(FSubs[I]));
  Result := nil;
end;

procedure TUAConn.DeleteSubs;
var
  I: Integer;
begin
  for I := 0 to FSubs.Count - 1 do
    TSubscr(FSubs[I]).Free;
  FSubs.Clear;
end;

procedure TUAConn.FlushPublish(Status: Cardinal);
var
  I: Integer;
begin
  for I := 0 to High(FPubQ) do
    Fault(FPubQ[I].ReqId, FPubQ[I].Handle, Status);
  FPubQ := nil;
end;

procedure ReviseSub(S: TSubscr; Interval: Double; Lifetime, MaxKeep, MaxNotif: Cardinal);
begin
  S.Interval := ReviseInterval(Interval);
  if MaxKeep = 0 then MaxKeep := 10;
  if MaxKeep > 1000 then MaxKeep := 1000;
  if Lifetime < 3 * MaxKeep then Lifetime := 3 * MaxKeep;
  S.MaxKeep := MaxKeep;
  S.Lifetime := Lifetime;
  S.MaxNotif := MaxNotif;
end;

procedure TUAConn.SvcCreateSubscription(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
var
  S: TSubscr;
  Interval: Double;
  Lifetime, MaxKeep, MaxNotif: Cardinal;
  Enabled: Boolean;
begin
  Interval := R.F64;
  Lifetime := R.U32;
  MaxKeep := R.U32;
  MaxNotif := R.U32;
  Enabled := R.Bool;
  R.U8;                            // priority
  if FSubs.Count >= MAX_SUBSCRIPTIONS then
  begin
    Fault(ReqId, H.Handle, UA_BadTooManySubscriptions);
    Exit;
  end;
  S := TSubscr.Create;
  S.Id := FServer.NextId;
  S.Enabled := Enabled;
  ReviseSub(S, Interval, Lifetime, MaxKeep, MaxNotif);
  S.KeepCtr := S.MaxKeep;          // first cycle without data sends a keep-alive
  S.NextPub := GetTickCount64 + Round(S.Interval);
  FSubs.Add(S);
  Resp(790, H.Handle);
  FW.U32(S.Id);
  FW.F64(S.Interval);
  FW.U32(S.Lifetime);
  FW.U32(S.MaxKeep);
  SendMsg(ReqId, FW.Data);
end;

procedure TUAConn.SvcModifySubscription(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
var
  S: TSubscr;
  Interval: Double;
  Lifetime, MaxKeep, MaxNotif: Cardinal;
begin
  S := FindSub(R.U32);
  Interval := R.F64;
  Lifetime := R.U32;
  MaxKeep := R.U32;
  MaxNotif := R.U32;
  R.U8;
  if S = nil then
  begin
    Fault(ReqId, H.Handle, UA_BadSubscriptionIdInvalid);
    Exit;
  end;
  ReviseSub(S, Interval, Lifetime, MaxKeep, MaxNotif);
  Resp(796, H.Handle);
  FW.F64(S.Interval);
  FW.U32(S.Lifetime);
  FW.U32(S.MaxKeep);
  SendMsg(ReqId, FW.Data);
end;

procedure TUAConn.SvcSetPublishingMode(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
var
  Enabled: Boolean;
  I, N: Integer;
  S: TSubscr;
begin
  Enabled := R.Bool;
  N := R.ArrLen;
  Resp(802, H.Handle);
  FW.I32(N);
  for I := 1 to N do
  begin
    S := FindSub(R.U32);
    if S = nil then
      FW.U32(UA_BadSubscriptionIdInvalid)
    else
    begin
      S.Enabled := Enabled;
      FW.U32(UA_GOOD);
    end;
  end;
  FW.I32(0);
  SendMsg(ReqId, FW.Data);
end;

procedure TUAConn.SvcDeleteSubscriptions(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
var
  I, N: Integer;
  S: TSubscr;
begin
  N := R.ArrLen;
  Resp(850, H.Handle);
  FW.I32(N);
  for I := 1 to N do
  begin
    S := FindSub(R.U32);
    if S = nil then
      FW.U32(UA_BadSubscriptionIdInvalid)
    else
    begin
      FSubs.Remove(S);
      S.Free;
      FW.U32(UA_GOOD);
    end;
  end;
  FW.I32(0);
  SendMsg(ReqId, FW.Data);
  if FSubs.Count = 0 then
    FlushPublish(UA_BadNoSubscription);
end;

procedure ReadMonParams(R: TUAReader; out ClientHandle: Cardinal; out Interval: Double);
begin
  ClientHandle := R.U32;
  Interval := R.F64;
  R.SkipExtObj;                    // filter (deadband is not supported, every change is reported)
  R.U32;                           // queue size (always 1)
  R.Bool;                          // discard oldest
end;

procedure TUAConn.SvcCreateMonitoredItems(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
var
  S: TSubscr;
  TS: LongInt;
  I, N: Integer;
  Id: TUANodeId;
  Attr, CH, St: Cardinal;
  Range: string;
  Mode: LongInt;
  Interval: Double;
  Node: TUANode;
  M: TMonItem;
begin
  S := FindSub(R.U32);
  TS := R.I32;
  N := R.ArrLen;
  if S = nil then
  begin
    Fault(ReqId, H.Handle, UA_BadSubscriptionIdInvalid);
    Exit;
  end;
  if N = 0 then
  begin
    Fault(ReqId, H.Handle, UA_BadNothingToDo);
    Exit;
  end;
  Resp(754, H.Handle);
  FW.I32(N);
  for I := 1 to N do
  begin
    Id := R.NodeId;
    Attr := R.U32;
    Range := R.Str;
    R.QName;
    Mode := R.I32;
    ReadMonParams(R, CH, Interval);
    Node := FServer.FindNode(Id);
    St := UA_GOOD;
    if Node = nil then
      St := UA_BadNodeIdUnknown
    else if not (Mode in [0..2]) then
      St := UA_BadMonitoringModeInvalid
    else if FServer.ReadAttr(Node, Attr, '', 3).Status = UA_BadAttributeIdInvalid then
      St := UA_BadAttributeIdInvalid;
    if St <> UA_GOOD then
    begin
      FW.U32(St);
      FW.U32(0);
      FW.F64(0);
      FW.U32(0);
      FW.NullExtObj;
      Continue;
    end;
    M := TMonItem.Create;
    Inc(FNextItemId);
    M.Id := FNextItemId;
    M.ClientHandle := CH;
    M.Node := Node;
    M.Attr := Attr;
    M.Range := Range;
    M.TS := TS;
    M.Mode := Mode;
    if Interval < 0 then Interval := S.Interval;
    M.Interval := ReviseInterval(Interval);
    M.NextSample := 0;             // sample at once
    S.Items.Add(M);
    FW.U32(UA_GOOD);
    FW.U32(M.Id);
    FW.F64(M.Interval);
    FW.U32(1);
    FW.NullExtObj;
  end;
  FW.I32(0);
  SendMsg(ReqId, FW.Data);
end;

procedure TUAConn.SvcModifyMonitoredItems(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
var
  S: TSubscr;
  TS: LongInt;
  I, N: Integer;
  M: TMonItem;
  CH: Cardinal;
  Interval: Double;
begin
  S := FindSub(R.U32);
  TS := R.I32;
  N := R.ArrLen;
  if S = nil then
  begin
    Fault(ReqId, H.Handle, UA_BadSubscriptionIdInvalid);
    Exit;
  end;
  Resp(766, H.Handle);
  FW.I32(N);
  for I := 1 to N do
  begin
    M := S.Find(R.U32);
    ReadMonParams(R, CH, Interval);
    if M = nil then
    begin
      FW.U32(UA_BadMonitoredItemIdInvalid);
      FW.F64(0);
      FW.U32(0);
    end
    else
    begin
      M.ClientHandle := CH;
      M.TS := TS;
      if Interval < 0 then Interval := S.Interval;
      M.Interval := ReviseInterval(Interval);
      FW.U32(UA_GOOD);
      FW.F64(M.Interval);
      FW.U32(1);
    end;
    FW.NullExtObj;
  end;
  FW.I32(0);
  SendMsg(ReqId, FW.Data);
end;

procedure TUAConn.SvcSetMonitoringMode(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
var
  S: TSubscr;
  Mode: LongInt;
  I, N: Integer;
  M: TMonItem;
begin
  S := FindSub(R.U32);
  Mode := R.I32;
  N := R.ArrLen;
  if S = nil then
  begin
    Fault(ReqId, H.Handle, UA_BadSubscriptionIdInvalid);
    Exit;
  end;
  if not (Mode in [0..2]) then
  begin
    Fault(ReqId, H.Handle, UA_BadMonitoringModeInvalid);
    Exit;
  end;
  Resp(772, H.Handle);
  FW.I32(N);
  for I := 1 to N do
  begin
    M := S.Find(R.U32);
    if M = nil then
      FW.U32(UA_BadMonitoredItemIdInvalid)
    else
    begin
      if (Mode = 2) and (M.Mode <> 2) then
        M.HasLast := False;        // report the current value again
      M.Mode := Mode;
      if Mode <> 2 then M.Pending := False;
      FW.U32(UA_GOOD);
    end;
  end;
  FW.I32(0);
  SendMsg(ReqId, FW.Data);
end;

procedure TUAConn.SvcDeleteMonitoredItems(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
var
  S: TSubscr;
  I, N: Integer;
  M: TMonItem;
begin
  S := FindSub(R.U32);
  N := R.ArrLen;
  if S = nil then
  begin
    Fault(ReqId, H.Handle, UA_BadSubscriptionIdInvalid);
    Exit;
  end;
  Resp(784, H.Handle);
  FW.I32(N);
  for I := 1 to N do
  begin
    M := S.Find(R.U32);
    if M = nil then
      FW.U32(UA_BadMonitoredItemIdInvalid)
    else
    begin
      S.Items.Remove(M);
      M.Free;
      FW.U32(UA_GOOD);
    end;
  end;
  FW.I32(0);
  SendMsg(ReqId, FW.Data);
end;

procedure TUAConn.SvcPublish(R: TUAReader; const H: TReqHeader; ReqId: Cardinal);
var
  I, N, K: Integer;
begin
  N := R.ArrLen;                   // acknowledgements (no retransmission queue is kept)
  for I := 1 to N do
  begin
    R.U32;
    R.U32;
  end;
  if FSubs.Count = 0 then
  begin
    Fault(ReqId, H.Handle, UA_BadNoSubscription);
    Exit;
  end;
  if Length(FPubQ) >= MAX_PUBLISH_QUEUE then
  begin
    Fault(FPubQ[0].ReqId, FPubQ[0].Handle, UA_BadTooManyPublishRequests);
    Delete(FPubQ, 0, 1);
  end;
  K := Length(FPubQ);
  SetLength(FPubQ, K + 1);
  FPubQ[K].ReqId := ReqId;
  FPubQ[K].Handle := H.Handle;
  FPubQ[K].AckCount := N;
  if H.Timeout > 0 then
    FPubQ[K].Deadline := GetTickCount64 + H.Timeout
  else
    FPubQ[K].Deadline := 0;
end;

procedure TUAConn.Sample(M: TMonItem);
var
  DV, Key: TUADataValue;
  W: TUAWriter;
  B: TBytes;
begin
  DV := FServer.ReadAttr(M.Node, M.Attr, M.Range, M.TS);
  Key := DV;                       // compare value + status, not the timestamps
  Key.SrcTime := 0;
  Key.SrvTime := 0;
  W := TUAWriter.Create;
  try
    W.DataValue(Key);
    B := W.Data;
  finally
    W.Free;
  end;
  if M.HasLast and BytesEqual(B, M.Last) then Exit;
  M.Last := B;
  M.HasLast := True;
  if M.Mode = 2 then
  begin
    M.Pending := True;
    M.PendingDV := DV;
  end;
end;

procedure TUAConn.SendPublish(S: TSubscr);
var
  Q: TPubReq;
  I, Count, Total, LenPos: Integer;
  M: TMonItem;
begin
  Q := FPubQ[0];
  Delete(FPubQ, 0, 1);
  Total := 0;
  for I := 0 to S.Items.Count - 1 do
    if TMonItem(S.Items[I]).Pending then Inc(Total);
  Count := Total;
  if (S.MaxNotif > 0) and (Cardinal(Count) > S.MaxNotif) then
    Count := S.MaxNotif;
  if not S.Enabled then
    Count := 0;

  Resp(829, Q.Handle);
  FW.U32(S.Id);
  FW.I32(0);                       // available sequence numbers
  FW.Bool(Count < Total);          // more notifications
  FW.U32(S.SeqNo);
  FW.DateTime(UANow);
  if Count = 0 then
    FW.I32(0)                      // keep-alive (sequence number not used up)
  else
  begin
    FW.I32(1);
    FW.NumId(811);                 // DataChangeNotification
    FW.U8(1);
    LenPos := FW.Len;
    FW.I32(0);
    FW.I32(Count);
    I := 0;
    while Count > 0 do
    begin
      M := TMonItem(S.Items[I]);
      Inc(I);
      if not M.Pending then Continue;
      FW.U32(M.ClientHandle);
      FW.DataValue(M.PendingDV);
      M.Pending := False;
      Dec(Count);
    end;
    FW.I32(0);                     // diagnostic infos
    FW.PatchI32(LenPos, FW.Len - LenPos - 4);
    Inc(S.SeqNo);
  end;
  FW.I32(Q.AckCount);              // acknowledgement results
  for I := 1 to Q.AckCount do
    FW.U32(UA_GOOD);
  FW.I32(0);
  SendMsg(Q.ReqId, FW.Data);
  S.WantKeep := False;
  S.KeepCtr := 0;
  S.WantData := False;
  for I := 0 to S.Items.Count - 1 do
    if TMonItem(S.Items[I]).Pending then S.WantData := S.Enabled;
end;

procedure TUAConn.ServiceSubscriptions;
var
  T: QWord;
  I, J: Integer;
  S: TSubscr;
  M: TMonItem;
  HasPending: Boolean;
begin
  if FSubs.Count = 0 then Exit;
  T := GetTickCount64;
  for I := High(FPubQ) downto 0 do
    if (FPubQ[I].Deadline <> 0) and (T > FPubQ[I].Deadline) then
    begin
      Fault(FPubQ[I].ReqId, FPubQ[I].Handle, UA_BadTimeout);
      Delete(FPubQ, I, 1);
    end;
  for I := 0 to FSubs.Count - 1 do
  begin
    S := TSubscr(FSubs[I]);
    HasPending := False;
    for J := 0 to S.Items.Count - 1 do
    begin
      M := TMonItem(S.Items[J]);
      if (M.Mode > 0) and (T >= M.NextSample) then
      begin
        M.NextSample := NextTick(M.NextSample, M.Interval, T);
        Sample(M);
      end;
      if M.Pending then HasPending := True;
    end;
    if T >= S.NextPub then
    begin
      S.NextPub := NextTick(S.NextPub, S.Interval, T);
      if S.Enabled and HasPending then
        S.WantData := True
      else
      begin
        Inc(S.KeepCtr);
        if S.KeepCtr >= S.MaxKeep then
          S.WantKeep := True;
      end;
    end;
    if (S.WantData or S.WantKeep) and (Length(FPubQ) > 0) then
      SendPublish(S);
  end;
end;

end.

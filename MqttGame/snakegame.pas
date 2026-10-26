{ ============================================================================
  snakegame - the rules of Snake Arena (server side, not thread safe: the
  server calls everything under its own lock)
    - grid W x H, walls (or wrap around), every tick all snakes move one cell
    - food: +1 score and +1 length; a dead snake becomes food
    - crash into a wall, any body or another head = dead, respawn after 3 s
    - crashing into another snake gives that snake a kill and +3 score
    - best score per player, bots with a small look-ahead (flood fill)
  ============================================================================ }
unit snakegame;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, snakeproto;

type

  { TPlayer }

  TPlayer = class
    Key, Name: string;
    Color: LongWord;
    IsBot: Boolean;
    Body: TCells;                 // head first
    Dir: Char;
    Queue: string;                // turns not used yet (max 2)
    Alive: Boolean;
    RespawnAt: Int64;             // tick
    Score, Best, Kills: Integer;
    Grow: Integer;
    LastSeen: QWord;              // ms, last command (players only)
  end;

  { TSnakeGame }

  TSnakeGame = class
  private
    FGrid: array of Integer;      // 0 = free, else player index + 1 (rebuilt when needed)
    FNextBot: Integer;
    procedure BuildGrid;
    function Inside(X, Y: Integer): Boolean;
    function Wrapped(C: TCell): TCell;
    function FreeCell(X, Y: Integer): Boolean;
    function HasFood(C: TCell; out Index: Integer): Boolean;
    function Spawn(P: TPlayer): Boolean;
    procedure AddFood(N: Integer);
    procedure BotThink(P: TPlayer);
    function FloodCount(Start: TCell; Limit: Integer): Integer;
    procedure Event(const S: string);
  public
    W, H: Integer;
    Wrap: Boolean;
    FoodCount: Integer;           // food kept on the field (plus dead snakes)
    StartLength: Integer;
    RespawnTicks: Integer;
    Tick: Int64;
    Players: TFPList;             // TPlayer, owned
    Food: TCells;
    Events: TStringList;          // new events, taken by the server
    constructor Create(AW, AH: Integer; AWrap: Boolean);
    destructor Destroy; override;
    function Find(const Key: string): TPlayer;
    function Join(const Key, AName: string; AColor: LongWord; ABot: Boolean = False): TPlayer;
    procedure Leave(const Key: string);
    procedure Turn(const Key: string; D: Char);
    procedure SetBots(N: Integer);
    function BotCount: Integer;
    procedure Step;
    function State(TickMs: Integer): TGameState;
  end;

implementation

const
  BOT_NAMES: array[0..11] of string = ('Ada', 'Bit', 'Cobra', 'Dash', 'Echo', 'Fang', 'Gizmo',
    'Hex', 'Ivy', 'Jinx', 'Kilo', 'Luna');
  BOT_COLORS: array[0..7] of LongWord = ($E0E0E0, $FFB347, $77DD77, $AEC6CF, $CBAACB, $FDFD96,
    $FF6961, $84B6F4);

{ TSnakeGame }

constructor TSnakeGame.Create(AW, AH: Integer; AWrap: Boolean);
begin
  W := EnsureRange(AW, 16, 200);
  H := EnsureRange(AH, 12, 200);
  Wrap := AWrap;
  FoodCount := 8;
  StartLength := 4;
  RespawnTicks := 30;
  Players := TFPList.Create;
  Events := TStringList.Create;
  SetLength(FGrid, W * H);
end;

destructor TSnakeGame.Destroy;
var
  I: Integer;
begin
  for I := 0 to Players.Count - 1 do
    TPlayer(Players[I]).Free;
  Players.Free;
  Events.Free;
  inherited Destroy;
end;

procedure TSnakeGame.Event(const S: string);
begin
  Events.Add(S);
end;

function TSnakeGame.Inside(X, Y: Integer): Boolean;
begin
  Result := (X >= 0) and (Y >= 0) and (X < W) and (Y < H);
end;

function TSnakeGame.Wrapped(C: TCell): TCell;
begin
  Result := C;
  if Wrap then
  begin
    Result.X := (C.X + W) mod W;
    Result.Y := (C.Y + H) mod H;
  end;
end;

procedure TSnakeGame.BuildGrid;
var
  I, J: Integer;
  P: TPlayer;
begin
  FillChar(FGrid[0], Length(FGrid) * SizeOf(Integer), 0);
  for I := 0 to Players.Count - 1 do
  begin
    P := TPlayer(Players[I]);
    if not P.Alive then Continue;
    for J := 0 to High(P.Body) do
      if Inside(P.Body[J].X, P.Body[J].Y) then
        FGrid[P.Body[J].Y * W + P.Body[J].X] := I + 1;
  end;
end;

function TSnakeGame.FreeCell(X, Y: Integer): Boolean;
begin
  Result := Inside(X, Y) and (FGrid[Y * W + X] = 0);
end;

function TSnakeGame.HasFood(C: TCell; out Index: Integer): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(Food) do
    if (Food[I].X = C.X) and (Food[I].Y = C.Y) then
    begin
      Index := I;
      Exit(True);
    end;
  Index := -1;
  Result := False;
end;

function TSnakeGame.Find(const Key: string): TPlayer;
var
  I: Integer;
begin
  for I := 0 to Players.Count - 1 do
    if TPlayer(Players[I]).Key = Key then
      Exit(TPlayer(Players[I]));
  Result := nil;
end;

{ a free straight line of StartLength cells + 3 free cells in front; the snake faces
  the far wall, so a new player has time to react }
function TSnakeGame.Spawn(P: TPlayer): Boolean;
var
  Try_, I, X, Y, K: Integer;
  D: Char;
  Ok: Boolean;
  Room: array[1..4] of Integer;
begin
  BuildGrid;
  for Try_ := 1 to 300 do
  begin
    X := 2 + Random(W - 4);
    Y := 2 + Random(H - 4);
    Room[1] := Y;                                    // U R D L: cells to the wall
    Room[2] := W - 1 - X;
    Room[3] := H - 1 - Y;
    Room[4] := X;
    K := 1;
    for I := 2 to 4 do
      if Room[I] > Room[K] then K := I;
    if Wrap then
      D := DIRS[1 + Random(4)]
    else
      D := DIRS[K];
    Ok := True;
    for K := -StartLength + 1 to 3 do                // body behind, room in front
      if not FreeCell(X + DirDX(D) * K, Y + DirDY(D) * K) then
      begin
        Ok := False;
        Break;
      end;
    if not Ok then Continue;
    SetLength(P.Body, StartLength);
    for I := 0 to StartLength - 1 do
      P.Body[I] := Cell(X - DirDX(D) * I, Y - DirDY(D) * I);
    P.Dir := D;
    P.Queue := '';
    P.Grow := 0;
    P.Alive := True;
    Exit(True);
  end;
  Result := False;                                   // arena full, try again next tick
end;

procedure TSnakeGame.AddFood(N: Integer);
var
  I, Try_, K: Integer;
  C: TCell;
begin
  BuildGrid;
  for I := 1 to N do
    for Try_ := 1 to 50 do
    begin
      C := Cell(Random(W), Random(H));
      if FreeCell(C.X, C.Y) and not HasFood(C, K) then
      begin
        SetLength(Food, Length(Food) + 1);
        Food[High(Food)] := C;
        Break;
      end;
    end;
end;

function TSnakeGame.Join(const Key, AName: string; AColor: LongWord; ABot: Boolean): TPlayer;
begin
  Result := Find(Key);
  if Result = nil then
  begin
    Result := TPlayer.Create;
    Result.Key := Key;
    Players.Add(Result);
    Result.Alive := False;
    Result.RespawnAt := Tick;                       // next tick
    Event(AName + ' joined');
  end
  else if not Result.Alive then
    Result.RespawnAt := Min(Result.RespawnAt, Tick); // join again = respawn at once
  Result.Name := AName;
  Result.Color := AColor and $FFFFFF;
  Result.IsBot := ABot;
  Result.LastSeen := GetTickCount64;
end;

procedure TSnakeGame.Leave(const Key: string);
var
  P: TPlayer;
begin
  P := Find(Key);
  if P = nil then Exit;
  Event(P.Name + ' left (best ' + IntToStr(Max(P.Best, P.Score)) + ')');
  Players.Remove(P);
  P.Free;
end;

procedure TSnakeGame.Turn(const Key: string; D: Char);
var
  P: TPlayer;
begin
  P := Find(Key);
  if P = nil then Exit;
  P.LastSeen := GetTickCount64;
  if Pos(D, DIRS) = 0 then Exit;
  if Length(P.Queue) < 2 then
    P.Queue := P.Queue + D;
end;

function TSnakeGame.BotCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to Players.Count - 1 do
    if TPlayer(Players[I]).IsBot then Inc(Result);
end;

procedure TSnakeGame.SetBots(N: Integer);
var
  I: Integer;
begin
  N := EnsureRange(N, 0, 20);
  while BotCount < N do
  begin
    Inc(FNextBot);
    Join('bot' + IntToStr(FNextBot), 'Bot ' + BOT_NAMES[(FNextBot - 1) mod Length(BOT_NAMES)],
      BOT_COLORS[(FNextBot - 1) mod Length(BOT_COLORS)], True);
  end;
  for I := Players.Count - 1 downto 0 do
    if (BotCount > N) and TPlayer(Players[I]).IsBot then
      Leave(TPlayer(Players[I]).Key);
end;

{ free cells reachable from Start (stops at Limit), on the grid of the current bodies }
function TSnakeGame.FloodCount(Start: TCell; Limit: Integer): Integer;
var
  Seen: array of Boolean;
  Q: TCells;
  QH, QT, K: Integer;
  C, N: TCell;
begin
  Result := 0;
  Start := Wrapped(Start);
  if not FreeCell(Start.X, Start.Y) then Exit;
  SetLength(Seen, W * H);
  SetLength(Q, Limit + 4);
  QH := 0;
  QT := 1;
  Q[0] := Start;
  Seen[Start.Y * W + Start.X] := True;
  while (QH < QT) and (Result < Limit) do
  begin
    C := Q[QH];
    Inc(QH);
    Inc(Result);
    for K := 1 to 4 do
    begin
      N := Wrapped(Cell(C.X + DirDX(DIRS[K]), C.Y + DirDY(DIRS[K])));
      if FreeCell(N.X, N.Y) and not Seen[N.Y * W + N.X] and (QT < Length(Q)) then
      begin
        Seen[N.Y * W + N.X] := True;
        Q[QT] := N;
        Inc(QT);
      end;
    end;
  end;
end;

{ the safe direction with the most room, then the nearest food }
procedure TSnakeGame.BotThink(P: TPlayer);
var
  K, I, Room, Dist, Best, Score: Integer;
  D, BestD: Char;
  C: TCell;
begin
  BestD := P.Dir;
  Best := MaxInt;
  for K := 1 to 4 do
  begin
    D := DIRS[K];
    if (D = OppositeDir(P.Dir)) and (Length(P.Body) > 1) then Continue;
    C := Wrapped(Cell(P.Body[0].X + DirDX(D), P.Body[0].Y + DirDY(D)));
    Room := FloodCount(C, Length(P.Body) * 2 + 10);
    if Room = 0 then
      Score := 100000                                 // certain crash
    else
    begin
      Dist := W + H;
      for I := 0 to High(Food) do
        Dist := Min(Dist, Abs(Food[I].X - C.X) + Abs(Food[I].Y - C.Y));
      Score := Dist + Random(3);
      if Room < Length(P.Body) * 2 + 10 then
        Score := Score + 1000 - Room;                 // a pocket: avoid if possible
    end;
    if Score < Best then
    begin
      Best := Score;
      BestD := D;
    end;
  end;
  P.Queue := BestD;
end;

procedure TSnakeGame.Step;
var
  I, J, N, K, F, Owner: Integer;
  P, Q: TPlayer;
  Heads: TCells;
  Dead, Eat, Drop: array of Boolean;
  D: Char;
  C: TCell;
begin
  Inc(Tick);
  N := Players.Count;
  { respawn }
  for I := 0 to N - 1 do
  begin
    P := TPlayer(Players[I]);
    if not P.Alive and (P.RespawnAt <= Tick) then
      Spawn(P);
  end;
  BuildGrid;
  for I := 0 to N - 1 do
    if TPlayer(Players[I]).Alive and TPlayer(Players[I]).IsBot then
      BotThink(TPlayer(Players[I]));

  { turns and new heads }
  SetLength(Heads, N);
  SetLength(Dead, N);
  SetLength(Eat, N);
  SetLength(Drop, N);
  for I := 0 to N - 1 do
  begin
    P := TPlayer(Players[I]);
    Dead[I] := False;
    Eat[I] := False;
    Drop[I] := False;
    if not P.Alive then Continue;
    while P.Queue <> '' do
    begin
      D := P.Queue[1];
      Delete(P.Queue, 1, 1);
      if (D <> P.Dir) and ((D <> OppositeDir(P.Dir)) or (Length(P.Body) <= 1)) then
      begin
        P.Dir := D;
        Break;                                        // one turn per tick, the next stays queued
      end;
    end;
    Heads[I] := Wrapped(Cell(P.Body[0].X + DirDX(P.Dir), P.Body[0].Y + DirDY(P.Dir)));
    Eat[I] := Inside(Heads[I].X, Heads[I].Y) and HasFood(Heads[I], F);
    Drop[I] := not Eat[I] and (P.Grow = 0);           // the tail moves away this tick
  end;

  { collisions against the bodies after the tails moved }
  FillChar(FGrid[0], Length(FGrid) * SizeOf(Integer), 0);
  for I := 0 to N - 1 do
  begin
    P := TPlayer(Players[I]);
    if not P.Alive then Continue;
    for J := 0 to High(P.Body) - Ord(Drop[I]) do
      if Inside(P.Body[J].X, P.Body[J].Y) then
        FGrid[P.Body[J].Y * W + P.Body[J].X] := I + 1;
  end;
  for I := 0 to N - 1 do
  begin
    P := TPlayer(Players[I]);
    if not P.Alive then Continue;
    if not Inside(Heads[I].X, Heads[I].Y) then
    begin
      Dead[I] := True;
      Event(P.Name + ' hit the wall');
      Continue;
    end;
    Owner := FGrid[Heads[I].Y * W + Heads[I].X];
    if Owner > 0 then
    begin
      Dead[I] := True;
      if Owner - 1 = I then
        Event(P.Name + ' bit itself')
      else
      begin
        Q := TPlayer(Players[Owner - 1]);
        Inc(Q.Kills);
        Inc(Q.Score, 3);
        Event(P.Name + ' crashed into ' + Q.Name);
      end;
    end;
    for J := 0 to I - 1 do                            // head to head: both are out
      if TPlayer(Players[J]).Alive and (Heads[J].X = Heads[I].X) and (Heads[J].Y = Heads[I].Y) then
      begin
        Dead[I] := True;
        if not Dead[J] then
          Event(P.Name + ' and ' + TPlayer(Players[J]).Name + ' crashed head to head');
        Dead[J] := True;
      end;
  end;

  { move, eat, die }
  for I := 0 to N - 1 do
  begin
    P := TPlayer(Players[I]);
    if not P.Alive then Continue;
    if Dead[I] then
    begin
      for J := 0 to High(P.Body) do                   // every 2nd cell becomes food
        if (J mod 2 = 0) and Inside(P.Body[J].X, P.Body[J].Y) and not HasFood(P.Body[J], K) and
          (Length(Food) < FoodCount + 150) then
        begin
          SetLength(Food, Length(Food) + 1);
          Food[High(Food)] := P.Body[J];
        end;
      if P.Score > P.Best then
      begin
        if P.Score >= 10 then
          Event(Format('%s: new best %d', [P.Name, P.Score]));
        P.Best := P.Score;
      end;
      P.Score := 0;
      P.Alive := False;
      P.Body := nil;
      P.RespawnAt := Tick + RespawnTicks;
      Continue;
    end;
    C := Heads[I];
    if Eat[I] then
    begin
      HasFood(C, F);
      Delete(Food, F, 1);
      Inc(P.Score);
      Inc(P.Grow);
    end;
    if Drop[I] then
      Move(P.Body[0], P.Body[1], (Length(P.Body) - 1) * SizeOf(TCell))
    else
    begin
      SetLength(P.Body, Length(P.Body) + 1);
      Move(P.Body[0], P.Body[1], (Length(P.Body) - 1) * SizeOf(TCell));
      Dec(P.Grow);
    end;
    P.Body[0] := C;
  end;
  if Length(Food) < FoodCount then
    AddFood(FoodCount - Length(Food));
end;

function TSnakeGame.State(TickMs: Integer): TGameState;
var
  I: Integer;
  P: TPlayer;
begin
  Result.Tick := Tick;
  Result.W := W;
  Result.H := H;
  Result.TickMs := TickMs;
  Result.Wrap := Wrap;
  Result.Food := Copy(Food);
  SetLength(Result.Snakes, Players.Count);
  for I := 0 to Players.Count - 1 do
  begin
    P := TPlayer(Players[I]);
    Result.Snakes[I].Key := P.Key;
    Result.Snakes[I].Name := P.Name;
    Result.Snakes[I].Color := P.Color;
    Result.Snakes[I].Alive := P.Alive;
    Result.Snakes[I].IsBot := P.IsBot;
    Result.Snakes[I].Score := P.Score;
    Result.Snakes[I].Best := Max(P.Best, P.Score);
    Result.Snakes[I].Kills := P.Kills;
    Result.Snakes[I].Dir := P.Dir;
    Result.Snakes[I].Body := Copy(P.Body);
  end;
end;

end.

{ ============================================================================
  snakeproto - the MQTT protocol of Snake Arena, shared by the game server
  and both clients. Plain text, one item per line, so any MQTT tool can read
  it and a state of 10 snakes is about 2 KB.

  client -> server   snake/cmd/<key>     (key = the client id, one level)
      join <RRGGBB> <name>     enter the arena (again) with a colour and name
      dir U|R|D|L              turn (two turns are queued per tick)
      ping                     I am still here (every 5 s, else removed after 30 s)
      leave                    also set as last will, so a dropped client leaves

  server -> clients
      snake/state    every tick:
          S <tick> <width> <height> <tick ms> <wrap 0/1>
          F x y x y ...                                  food cells
          P <key> <RRGGBB> <alive> <score> <best> <kills> <bot> <dir> <name>
          B x y x y ...                                  body, head first
      snake/event    text for the log ("Anna ate Bob")
      snake/info     retained: <width> <height> <tick ms> <wrap>
      snake/status   retained: online
  ============================================================================ }
unit snakeproto;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

const
  SNAKE_ROOT = 'snake';
  DIRS = 'URDL';                   // index 1..4, opposite = (i + 1) mod 4 + 1

type
  TCell = record
    X, Y: Integer;
  end;
  TCells = array of TCell;

  TSnakeInfo = record
    Key, Name: string;
    Color: LongWord;               // $RRGGBB
    Alive, IsBot: Boolean;
    Score, Best, Kills: Integer;
    Dir: Char;
    Body: TCells;                  // head first
  end;

  TGameState = record
    Tick: Int64;
    W, H, TickMs: Integer;
    Wrap: Boolean;
    Food: TCells;
    Snakes: array of TSnakeInfo;
  end;

function Cell(X, Y: Integer): TCell;
function DirDX(D: Char): Integer;
function DirDY(D: Char): Integer;
function OppositeDir(D: Char): Char;
function EncodeState(const S: TGameState): string;
function DecodeState(const Text: string; out S: TGameState): Boolean;
function FindSnake(const S: TGameState; const Key: string): Integer;
{ a client id as one topic level: letters, digits, - and _ only }
function SafeKey(const S: string): string;
function ColorHex(C: LongWord): string;
function HexColor(const S: string; Default: LongWord): LongWord;
{ ms from the performance counter (tick timing and smooth animation need better than 15 ms) }
function MsNow: Double;

implementation

{$IFDEF WINDOWS}
uses
  Windows;
{$ENDIF}

function MsNow: Double;
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

function Cell(X, Y: Integer): TCell;
begin
  Result.X := X;
  Result.Y := Y;
end;

function DirDX(D: Char): Integer;
begin
  case D of
    'R': Result := 1;
    'L': Result := -1;
  else
    Result := 0;
  end;
end;

function DirDY(D: Char): Integer;
begin
  case D of
    'D': Result := 1;
    'U': Result := -1;
  else
    Result := 0;
  end;
end;

function OppositeDir(D: Char): Char;
begin
  case D of
    'U': Result := 'D';
    'D': Result := 'U';
    'L': Result := 'R';
    'R': Result := 'L';
  else
    Result := ' ';
  end;
end;

function ColorHex(C: LongWord): string;
begin
  Result := IntToHex(C and $FFFFFF, 6);
end;

function HexColor(const S: string; Default: LongWord): LongWord;
var
  V: LongInt;
begin
  if (Length(S) = 6) and TryStrToInt('$' + S, V) then
    Result := LongWord(V)
  else
    Result := Default;
end;

function SafeKey(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    if S[I] in ['A'..'Z', 'a'..'z', '0'..'9', '-', '_'] then
      Result := Result + S[I]
    else
      Result := Result + '_';
  Result := Copy(Result, 1, 64);
end;

function CellsText(const C: TCells): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(C) do
    Result := Result + ' ' + IntToStr(C[I].X) + ' ' + IntToStr(C[I].Y);
end;

function EncodeState(const S: TGameState): string;
var
  I: Integer;
  P: TSnakeInfo;
begin
  Result := Format('S %d %d %d %d %d', [S.Tick, S.W, S.H, S.TickMs, Ord(S.Wrap)]) + #10 +
    'F' + CellsText(S.Food) + #10;
  for I := 0 to High(S.Snakes) do
  begin
    P := S.Snakes[I];
    Result := Result + Format('P %s %s %d %d %d %d %d %s %s',
      [P.Key, ColorHex(P.Color), Ord(P.Alive), P.Score, P.Best, P.Kills, Ord(P.IsBot), P.Dir,
       P.Name]) + #10 + 'B' + CellsText(P.Body) + #10;
  end;
end;

{ ---- decoding ---- }

type
  TTokens = record
    S: string;
    P: Integer;
  end;

function NextTok(var T: TTokens): string;
var
  Start: Integer;
begin
  while (T.P <= Length(T.S)) and (T.S[T.P] = ' ') do Inc(T.P);
  Start := T.P;
  while (T.P <= Length(T.S)) and (T.S[T.P] <> ' ') do Inc(T.P);
  Result := Copy(T.S, Start, T.P - Start);
end;

function NextInt(var T: TTokens; out V: Integer): Boolean;
begin
  Result := TryStrToInt(NextTok(T), V);
end;

function Rest(var T: TTokens): string;
begin
  while (T.P <= Length(T.S)) and (T.S[T.P] = ' ') do Inc(T.P);
  Result := Copy(T.S, T.P, MaxInt);
  T.P := Length(T.S) + 1;
end;

function ParseCells(var T: TTokens; out C: TCells): Boolean;
var
  X, Y, N: Integer;
begin
  C := nil;
  N := 0;
  while T.P <= Length(T.S) do
  begin
    if not NextInt(T, X) then Break;        // end of line (or trailing blanks)
    if not NextInt(T, Y) then Exit(False);
    if N >= Length(C) then SetLength(C, N * 2 + 16);
    C[N] := Cell(X, Y);
    Inc(N);
  end;
  SetLength(C, N);
  Result := True;
end;

function DecodeState(const Text: string; out S: TGameState): Boolean;
var
  Lines: TStringArray;
  I, N, V: Integer;
  T: TTokens;
  Tag, D: string;
  P: TSnakeInfo;
  Tick: Integer;
begin
  S := Default(TGameState);
  Result := False;
  Lines := Text.Split([#10]);
  N := 0;
  for I := 0 to High(Lines) do
  begin
    T.S := Lines[I];
    T.P := 1;
    Tag := NextTok(T);
    if Tag = 'S' then
    begin
      if not (NextInt(T, Tick) and NextInt(T, S.W) and NextInt(T, S.H) and NextInt(T, S.TickMs) and
        NextInt(T, V)) then Exit;
      S.Tick := Tick;
      S.Wrap := V <> 0;
      if (S.W < 4) or (S.H < 4) or (S.W > 500) or (S.H > 500) then Exit;
    end
    else if Tag = 'F' then
    begin
      if not ParseCells(T, S.Food) then Exit;
    end
    else if Tag = 'P' then
    begin
      P := Default(TSnakeInfo);
      P.Key := NextTok(T);
      P.Color := HexColor(NextTok(T), $808080);
      if not NextInt(T, V) then Exit;
      P.Alive := V <> 0;
      if not (NextInt(T, P.Score) and NextInt(T, P.Best) and NextInt(T, P.Kills)) then Exit;
      if not NextInt(T, V) then Exit;
      P.IsBot := V <> 0;
      D := NextTok(T);
      if D <> '' then P.Dir := D[1] else P.Dir := 'R';
      P.Name := Rest(T);
      if N >= Length(S.Snakes) then SetLength(S.Snakes, N * 2 + 8);
      S.Snakes[N] := P;
      Inc(N);
    end
    else if (Tag = 'B') and (N > 0) then
    begin
      if not ParseCells(T, S.Snakes[N - 1].Body) then Exit;
    end;
  end;
  SetLength(S.Snakes, N);
  Result := S.W > 0;
end;

function FindSnake(const S: TGameState; const Key: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(S.Snakes) do
    if S.Snakes[I].Key = Key then
      Exit(I);
  Result := -1;
end;

end.

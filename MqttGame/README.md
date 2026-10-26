# Snake Arena: MQTT game server (Lazarus)

A multiplayer Snake game that runs **inside an MQTT broker**, written in Free Pascal / Lazarus with normal forms. No DLL, no library: the broker is the one from [MqttSim](../MqttSim/README.md).

There are two game clients. Both run the same game and differ only in how they draw it:

| Client | Drawing |
|---|---|
| [SnakeLCL](../SnakeLCL/README.md) | standard LCL Canvas (double buffer) |
| [SnakeBGRA](../SnakeBGRA/README.md) | BGRABitmap: smooth 60 fps movement, anti-aliasing, glow, particles |

Players with either client play in the same arena, together with the server's bots. Any MQTT tool can watch the game (`mosquitto_sub -p 1886 -t "snake/#" -v`) or even play it.

## Build and run

```bash
C:\lazarus\lazbuild.exe MqttGame\GameServer.lpi
C:\lazarus\lazbuild.exe SnakeLCL\SnakeLCL.lpi
C:\lazarus\lazbuild.exe SnakeBGRA\SnakeBGRA.lpi
```

1. Start `GameServer.exe` and press **Start** (`F5`).
2. Start one or more clients, enter your name and colour, and press **Connect**.
3. Steer with the arrow keys or W A S D.

Clients on other PCs connect to this PC's address. Port 1886 must be allowed in the firewall.

## Server window

- **Port** (default 1886; 1883 = Mosquitto, 1884 = MqttSim, 1885 = MqttStream).
- **Arena** size in cells (48 × 32), **Tick** in ms (100 = 10 moves per second), **Wrap around** (no walls). These are set at start.
- **Bots** (0 … 20) and **Food** (1 … 200) can be changed while the game runs.
- Live player table sorted by score: type, alive / respawning, score, best, kills, length, colour, client id.
- The status line shows clients, players, bots, the tick, and the size of the state stream (about 0.4 kB per tick with 3 bots, so a few kB/s per client).
- The log shows connects, subscriptions and every game event.
- Settings are saved in `GameServer.ini`.

## Rules

- Every tick all snakes move one cell. Food gives +1 score and +1 length.
- A snake dies when it hits a wall, any body (its own too), or another head (then both die).
  - The snake it crashed into gets **+3 and a kill**.
  - A dead snake turns into food (every second cell), loses its score, and keeps its best.
- Respawn comes after 3 s, or at once with Join (Enter in the clients).
  - A new snake gets a free straight spot facing the far wall, so a new player has time to react.
- Two turns are queued per player, so a quick U-turn (up, then left) works within one tick. Turning straight back is ignored.
- **Bots** check the three possible moves with a flood fill. They avoid moves into a pocket smaller than about twice their length, then go for the nearest food.

## Protocol (`snakeproto.pas`)

Plain text, so it is easy to read with any MQTT tool.

**Client → server** on `snake/cmd/<client id>` (the id is one topic level: letters, digits, `-`, `_`):

| Payload | |
|---|---|
| `join <RRGGBB> <name>` | enter, change name / colour, or respawn now |
| `dir U` / `R` / `D` / `L` | turn |
| `ping` | still here: the client sends it every 5 s, and a player without any message for 30 s is removed |
| `leave` | quit. The clients also set it as their **last will**, so a crashed or unplugged client is removed at once |

**Server → clients:**

```
snake/state   (every tick, QoS 0)
  S <tick> <width> <height> <tick ms> <wrap 0/1>
  F x y x y ...                                     food
  P <id> <RRGGBB> <alive> <score> <best> <kills> <bot> <dir> <name>
  B x y x y ...                                     body, head first (empty while respawning)
snake/event   "Anna crashed into Bot Ada", "Bob joined", ...
snake/info    (retained)  <width> <height> <tick ms> <wrap>
snake/status  (retained)  online
```

Commands are taken by the server and not routed to other clients. A client id that starts with `bot` is renamed, so no client can steer a server bot.

## IPC version

[IpcGame](../IpcGame/README.md) builds this server window and both clients with `-dIPC`. The game then runs on one PC over SimpleIPC + shared memory, without a broker.

## Files

```
GameServer.lpi / .lpr     project
ugameserver.pas / .lfm    server window (designer form)
ugamehost.pas             game thread (performance counter, 1 ms timer), commands, state publishing
snakegame.pas             the rules: moving, food, collisions, respawn, bots
snakeproto.pas            the MQTT text protocol (shared with the clients)
snakeclient.pas           the game side of a client: join / turn / ping / will, last two states
                          (shared by SnakeLCL and SnakeBGRA)
../MqttSim/mqttbroker.pas, mqttcodec.pas   MQTT broker
```

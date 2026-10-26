# MQTT Simulator (Lazarus)

An MQTT broker with the simulated HV PLC, written in Free Pascal / Lazarus. It needs no DLL and no library: the MQTT protocol is implemented in `mqttbroker.pas`.

The PLC logic and the nonlinear HV plant are the same as in `Tools/s7sim.py` (the unit `uplcsim.pas` is shared with `OpcUaSim/`). The topics and payloads are the same as in `Tools/mqttsim.py`, so a client works with both.

## Build and run

Open `MqttSim.lpi` in Lazarus and press Run, or:

```bash
C:\lazarus\lazbuild.exe MqttSim\MqttSim.lpi
```

1. Set the **Port** (default 1884) and the **Topic prefix** (default `nonlinear`).
2. Choose **Curve points**: 10 = Set 1, or 2 = Set 2 with input protection.
3. Press **Start** (`F5`).

The settings are saved in `MqttSim.ini` next to the exe. *Start at program start* starts the broker automatically. `IntervalMs=100` in the ini sets how often changed values are published.

The window shows:
- the broker URL, the number of connected clients and of retained topics
- a live table of every simulator topic with its current payload
- a log of connects, subscriptions, last wills and writes (with the value, or the reason the write was refused)

## Connection

| | |
|---|---|
| Address | `tcp://<PC>:1884` |
| Protocol | MQTT 3.1.1 or 3.1 (MQTT 5 clients are refused, set the client to 3.1.1) |
| Security | no TLS, anonymous (user name / password are accepted and ignored) |

Port 1883 is used by Mosquitto on this PC, so the default is 1884.

## Topics

Every topic is **retained** and published only when its value changes.

| Topic | Payload | Access |
|---|---|---|
| `nonlinear/DB_HMI/VoltSP_kV`, `CurSP_mA` | number, `7.5` | read / write |
| `nonlinear/DB_HMI/VoltAct_kV`, `CurAct_mA`, `AO0_V`, `AO1_V`, `AI0_V`, `AI1_V` | number | read |
| `nonlinear/DB_HMI/AO0_Raw`, `AO1_Raw`, `AI0_Raw`, `AI1_Raw`, `Heartbeat` | integer | read |
| `nonlinear/DB_HMI/Enable` | `true` / `false` | read / write |
| `nonlinear/DB_HMI/Valid_VSP` / `VAct` / `CSP` / `CAct`, `AI0_Fault`, `AI1_Fault` | `true` / `false` | read |
| `nonlinear/DB_HMI/Curve_VSP` (also `VAct`, `CSP`, `CAct`) | `{"Eng": [..], "Volt": [..]}`, 10 or 2 values each | read / write |
| `nonlinear/DB_HMI/Err_VSP` … `Err_CAct` (Set 2 only, write 0 = acknowledge) | integer | read / write |
| `nonlinear/DB_HMI/VSP_Limited`, `CSP_Limited` (Set 2 only) | `true` / `false` | read |
| `nonlinear/Sim/Counter` (+1 per 100 ms), `Sine`, `Toggle` (every 2 s) | number / `true` / `false` | read |
| `nonlinear/Sim/Clock` | `2026-10-26T08:17:41.846+00:00` (UTC) | read |
| `nonlinear/status` | `online` | read |

### Writing

Publish to the topic plus `/set`:

```bash
"C:\Program Files (x86)\Mosquitto\mosquitto_pub.exe" -p 1884 -t nonlinear/DB_HMI/VoltSP_kV/set -m 7.5
```

- `Enable/set` accepts `1`, `0`, `true`, `false`, `on`, `off`.
- `Curve_xxx/set` takes the JSON object as one block. Both parts are written in the same PLC cycle, so Set 2 never checks a half-written curve. A missing `Eng` or `Volt` part keeps its values.
- A write to a read-only or unknown topic, a wrong value or a wrong array length is refused and shown in the log. The message is not routed to other clients.
- **PLC rules:** a write goes straight into the simulated DB10, and the next PLC cycle (every 50 ms) applies the same rules as the real PLC. In Set 2, a bad calibration is rejected (`Err_xxx`, the old curve comes back) and setpoints are clamped to X0..X1.

Watch everything:

```bash
"C:\Program Files (x86)\Mosquitto\mosquitto_sub.exe" -p 1884 -t "nonlinear/#" -v
```

## What the broker supports

- **Pub / sub for any client:** other topics are routed like in any broker, so two clients can use it to talk to each other.
- **Wildcards** `+` and `#`. `$` topics only match filters that start with `$`.
- **Retained messages:** sent after SUBACK. An empty retained payload deletes the topic.
- **QoS 0, 1 and 2** in both directions. A message goes out with the lower QoS of the publish and the subscription.
- **Last will**, sent when a client drops without DISCONNECT. It goes the same way as the client's own messages, so a will on a `/set` topic writes to the simulator (and the game server sees a will `leave`).
- **Keep alive:** a client that sends nothing for 1.5 × keep alive is closed.
- **Client id takeover:** a new connection with the same client id closes the old one. An empty client id gets `auto-n`.
- **Clients:** up to 32 at once. A client that can't keep up (4 MB unsent) is closed.

Not supported: persistent sessions (every connect starts clean, session present = 0), resending unacknowledged QoS 1 / 2 messages after a reconnect, TLS, authentication, MQTT 5.

## Files

```
MqttSim.lpi / .lpr    project
umqttmain.pas / .lfm  main window (designer form)
mqttbroker.pas        MQTT broker: TCP, client threads, routing, retained, will
mqttcodec.pas         packet encoding / decoding, topic matching (also used by ../MqttClient, ../MqttStream)
usimtopics.pas        simulator tags <-> topics, JSON payloads, /set writes, publish thread
../OpcUaSim/uplcsim.pas  PLC logic (Set 1 / Set 2) and HV plant, 50 ms cycle thread
                      (with uaencode / uaserver, whose value types and status codes it uses)
```

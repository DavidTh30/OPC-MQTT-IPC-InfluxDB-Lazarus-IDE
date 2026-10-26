# MQTT Stream Server (Lazarus)

An MQTT broker that **streams data**, written in Free Pascal / Lazarus with normal forms. No DLL, no library. The broker is the same as in [MqttSim](../MqttSim/README.md) (`mqttbroker.pas` / `mqttcodec.pas` are shared), so any MQTT 3.1 / 3.1.1 client can connect, including [MqttClient](../MqttClient/README.md), Mosquitto and loggers.

There are two stream sources, and they can run at the same time:

- **Generator:** test signals (sine, triangle, square, …). **Every sample** is published at the rate, not only the values that changed. Use it to test loggers, charts and dashboards at a known rate.
- **CSV replay:** a [PLC Data Logger](../DataLogger/README.md) CSV file, played back as a live stream with its recorded timing (x0.1 … x100), or one row per rate.

## Build and run

Open `MqttStream.lpi` in Lazarus and press Run, or:

```bash
C:\lazarus\lazbuild.exe MqttStream\MqttStream.lpi
```

Press **Start** (`F5`). The defaults are port **1885** (1883 = Mosquitto, 1884 = MqttSim) and topic prefix `stream`. The settings, the channels and the CSV file are saved in `MqttStream.ini` next to the exe.

Watch the stream:

```bash
"C:\Program Files (x86)\Mosquitto\mosquitto_sub.exe" -p 1885 -t "stream/#" -v
```

## Output (for both sources)

| Setting | |
|---|---|
| Rate (ms) | 5 … 60000, the generator sample interval (and the CSV interval in *one row per Rate* mode). The timing uses the performance counter and a 1 ms timer, and the next sample time is kept exact, so the rate doesn't drift. Measured: 100 ms → mean 99.9 ms, 10 ms → mean 9.98 ms |
| Payload | `Value only`: `1.234`, or `JSON`: `{"t": "2026-10-26T08:47:27.022Z", "v": 1.234}` |
| QoS | 0 / 1 / 2 of the published messages |
| Retain | the last sample stays on the broker for new subscribers (off by default, because it's a stream) |
| Combined JSON topic | one more message per sample with all values: `stream/gen`, `stream/csv` |

## Generator

A table of channels: **On**, **Name** (the topic `stream/gen/<name>`), **Shape**, **Amplitude**, **Offset**, **Period (s)**, **Decimals**, plus the live value. You can change everything while streaming. Use **Add channel** / **Delete channel** to change the list, and **Pause generator** / **Run generator** to stop or start it.

| Shape | Value (p = phase 0..1 within the period) |
|---|---|
| Sine | Offset + A·sin(2π·p) |
| Triangle | Offset − A … Offset + A … Offset − A |
| Square | Offset + A for the first half, Offset − A for the second |
| Sawtooth | Offset − A rising to Offset + A |
| Ramp | Offset rising to Offset + A, then back to Offset |
| Random | uniform in Offset ± A, a new value every sample |
| RandomWalk | steps of 5 % of A, kept inside Offset ± A |
| Constant | Offset |

Combined: `stream/gen` = `{"t": "2026-10-26T08:46:53.782Z", "Sine": -6.374, "Triangle": 6.100, ...}` (t = UTC).

## CSV replay

1. Press **Open...** and choose a Data Logger file (`DataLogger\Logs\mm-yyyy\dd-mm-yyyy.csv`).
2. Choose the **Speed** and **Loop**, then press **Play** / **Pause** / **Stop**. The progress bar and the table show the row and the last values.

- **Format:** `Date,Time,Status,<tags>` with `.` as the decimal point. A new header line inside the file (the tag list changed) switches to its new columns.
- **Topics:** `stream/csv/Status` plus one topic per column. The name is the header without the address in brackets: `Voltage SP kV (DB10.DBD0)` → `stream/csv/Voltage_SP_kV`.
- **Values** are published exactly as they are written in the file (`1.1`, `ON`, `T#1s_200ms`). In JSON, a number stays a number and other text becomes a string. `t` is the **recorded** time of the row (local time, as in the file).
- **Combined:** `stream/csv` = `{"t": "2026-10-25T16:28:20.999", "Status": "OK", "Heartbeat": 5666, "Voltage_SP_kV": 1.1, ...}`.
- **Speed:**
  - *x1* plays the rows with the time steps of the recording, x10 ten times faster, and so on.
  - *one row per Rate* ignores the recorded time.
  - After a gap in the recording (for example the logger was stopped), playback waits for the gap scaled by the speed.

## Control over MQTT

Any client can control the stream (the window follows):

| Topic | Payload |
|---|---|
| `stream/control/gen/set` | `run` / `pause` (also `1` / `0`, `on` / `off`) |
| `stream/control/csv/set` | `play` / `pause` / `stop` |
| `stream/control/rate/set` | rate in ms, 5 … 60000 |
| `stream/control/speed/set` | CSV speed factor, `0` = one row per rate |

`stream/stats` (retained, every second) = `{"rate_ms": 100, "generator": "running", "csv": "playing", "csv_row": 120, "csv_rows": 18973, "messages_per_s": 69.3, "messages": 427}`. `stream/status` = `online`.

## Files

```
MqttStream.lpi / .lpr       project
ustreammain.pas / .lfm      main window (designer form)
ustreams.pas                stream engine: generator, CSV replay, timing thread, control topics, stats
uwaves.pas                  signal shapes (also used by ../InfluxSignalGen)
../MqttSim/mqttbroker.pas   MQTT broker (shared with MqttSim)
../MqttSim/mqttcodec.pas    packet encoding / decoding (shared)
```

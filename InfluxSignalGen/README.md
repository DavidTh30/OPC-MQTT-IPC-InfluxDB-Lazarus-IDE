# InfluxDB Signal Generator (Lazarus)

Writes test signals into an InfluxDB database, live at a fixed rate or as **history (backfill)**, so a Grafana dashboard or a client has data to show at once. It is written in Free Pascal / Lazarus with normal forms, without a DLL, and works with InfluxDB 1.x, [InfluxServer](../InfluxServer/README.md), or InfluxDB 2.x through its v1 API.

## Build and run

```bash
C:\lazarus\lazbuild.exe InfluxSignalGen\InfluxSignalGen.lpi
```

1. Enter the URL, database and measurement. **Test** checks the server and creates the database.
2. Press **Start live** for the current data, or **Backfill** for a past range.

You can do both: the wave time is the Unix time, so the history and the live data join without a jump.

| Setting | |
|---|---|
| Channels | **On**, **Name** (= field), **Shape**, Amplitude, Offset, Period (s), **Noise** (± uniform), Decimals. The live value is shown in the table. *Add / Delete channel*. Changes work at once |
| Shapes | Sine, Triangle, Square, Sawtooth, Ramp, Random, RandomWalk, Constant (the same as the MQTT Stream Server, `../MqttStream/uwaves.pas`) |
| Layout | **one point, channels as fields**: `signals,source=generator temperature=21.3,flow=48.5 …`<br>or **one point per channel**: `signals,channel=temperature,source=generator value=21.3 …` (for `GROUP BY channel`) |
| Tags | added to every point: `site=lab, line=2` |
| Rate / Send | one sample every *Rate* ms, with time stamps aligned to the rate (1000 ms → full seconds); a batch sent every *Send* ms |
| Backfill | the last 1 h / 6 h / 24 h / 2 d / 7 d / 30 d, one sample every *Step* s (aligned), as fast as the database takes it. *Cancel* stops it |

The defaults are six channels of a small plant: temperature (sine 21 ± 3, 1 h, noise 0.1), pressure (random walk), flow (triangle), valve (square 0 / 1), power (sawtooth), counter (ramp 0…1000 per hour).

**Sending:**
- batches of at most 5000 lines, POST `/write?precision=ms`;
- the server not reachable → the points wait (up to 200,000) and are sent again every 2 s;
- "database not found" (InfluxDB 1.x) → `CREATE DATABASE`, then the batch again;
- a 400 (partial write) is not sent again;
- the status line shows LIVE / stopped, points sent and per second, the queue, errors and the last error.

The settings and channels are saved in `InfluxSignalGen.ini`. **The password is not saved.**

**Command line:** `--start` (live), `--backfill=<s> [--step=<s>]`, `--exit-when-done` (closes when the backfill is sent).

## Tests

Against InfluxServer with *Create databases on write* **off**, so the generator has to create the database itself:

| Test | Result |
|---|---|
| Backfill 24 h, step 10 s, 6 channels | 8,641 samples written and confirmed in **1.8 s** (program start included). Every value is on its formula (sine, triangle, square, sawtooth, ramp with their noise and decimals; random walk inside offset ± amplitude); no gaps, all on the 10 s grid |
| Then live, 8 s | 8 more samples, exactly 1000 ms apart on full seconds, right after the backfill |
| Layout *one point per channel*, 1 h, step 60 s | tag `channel` with the 6 names, field `value`, all values on the formulas |
| [InfluxClient](../InfluxClient/README.md) on the generated data | `mean()` per 5 min of temperature / power and `max(valve)` shown as a table and a chart; the tree shows both layouts down to the tag values |

## Files

```
InfluxSignalGen.lpi / .lpr   project
usiggenmain.pas / .lfm       window: settings, channel table, live / backfill, log
usiggen.pas                  generator thread: samples, backfill chunks, queue, batches, retry, CREATE DATABASE
../MqttStream/uwaves.pas     signal shapes (shared with the MQTT Stream Server)
../InfluxClient/uinfluxapi.pas   InfluxDB HTTP calls (shared with the InfluxDB Client)
```

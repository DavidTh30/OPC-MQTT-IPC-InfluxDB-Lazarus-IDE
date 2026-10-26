# OPC UA Simulator (Lazarus)

An OPC UA server with the simulated HV PLC, written in Free Pascal / Lazarus. It needs no DLL and no library: the OPC UA binary protocol (UA TCP) is implemented in `uaserver.pas` / `uaencode.pas`.

The PLC logic and the nonlinear HV plant are the same as in `Tools/s7sim.py` and `Tools/opcuasim.py`. The tag names and NodeIds are the same as in `Tools/opcuasim.py`, so a client works with both.

## Build and run

Open `OpcUaSim.lpi` in Lazarus and press Run, or:

```bash
C:\lazarus\lazbuild.exe OpcUaSim\OpcUaSim.lpi
```

1. Set the **Port** (default 4841).
2. Choose **Curve points**: 10 = Set 1, or 2 = Set 2 with input protection.
3. Press **Start** (`F5`).

The settings are saved in `OpcUaSim.ini` next to the exe. *Start server at program start* starts the server automatically.

The window shows:
- the endpoint URL and the number of connected clients
- a live table of every tag
- a log of connects, sessions and writes (with the value, or the reason the write was refused)

## Connection

| | |
|---|---|
| Endpoint | `opc.tcp://<PC>:4841/nonlinear/` |
| Security | None (MessageSecurityMode None, SecurityPolicy None) |
| Login | anonymous |
| Namespace | `urn:nonlinear:hv` = ns=2 |

Port 4840 is used on this PC by the OPC UA Local Discovery Server, so the default is 4841.

## Tags

| NodeId | Type | Access |
|---|---|---|
| `ns=2;s=DB_HMI.VoltSP_kV`, `DB_HMI.CurSP_mA` | Float | read / write |
| `DB_HMI.VoltAct_kV`, `CurAct_mA`, `AO0_V`, `AO1_V`, `AI0_V`, `AI1_V` | Float | read |
| `DB_HMI.AO0_Raw`, `AO1_Raw`, `AI0_Raw`, `AI1_Raw`, `Heartbeat` | Int16 | read |
| `DB_HMI.Enable` | Boolean | read / write |
| `DB_HMI.Valid_VSP` / `VAct` / `CSP` / `CAct`, `AI0_Fault`, `AI1_Fault` | Boolean | read |
| `DB_HMI.Curve_VSP.Eng` / `.Volt` (also `VAct`, `CSP`, `CAct`) | Float[10] or Float[2] | read / write |
| `DB_HMI.Err_VSP` … `Err_CAct` (Set 2 only, write 0 = acknowledge) | Int16 | read / write |
| `DB_HMI.VSP_Limited`, `CSP_Limited` (Set 2 only) | Boolean | read |
| `Sim.Counter` (+1 per 100 ms), `Sim.Sine`, `Sim.Toggle` (every 2 s), `Sim.Clock` | UInt16, Double, Boolean, DateTime | read |

- **Accepted values:** any numeric type is converted to the tag type, so a Double can be written to a Float tag.
  - A wrong type or a wrong array length is refused with `BadTypeMismatch`.
  - A read-only tag refuses writes with `BadNotWritable`.
- **PLC rules:** a write goes straight into the simulated DB10, and the next PLC cycle (every 50 ms) applies the same rules as the real PLC. In Set 2, a bad calibration is rejected (`Err_xxx`, the old curve comes back) and setpoints are clamped to X0..X1.
- **NaN / Inf:** the simulation keeps running. A NaN setpoint counts as 0 in Set 1 and as X0 in Set 2.

## What the server supports

- **Discovery:** GetEndpoints, FindServers.
- **Sessions:** CreateSession, ActivateSession (anonymous only), CloseSession.
- **Browse:** Browse with continuation points, BrowseNext, TranslateBrowsePathsToNodeIds, Register / UnregisterNodes.
- **Read:**
  - all attributes, with IndexRange on arrays and the four TimestampsToReturn modes
  - the standard `Server` object: NamespaceArray, ServerArray, ServerStatus (also as a structure), CurrentTime, State, ServiceLevel
  - the standard type nodes, so a client like UaExpert shows the type names
- **Write:** the Value attribute, also with IndexRange (for example one point of a curve).
- **Subscriptions:**
  - Create / Modify / Delete / SetPublishingMode
  - MonitoredItems: Create / Modify / Delete / SetMonitoringMode
  - Publish with keep-alive and Publish timeouts
  - fastest sampling and publishing interval: 50 ms; every change is reported (queue size 1, no deadband)
- **Messages:** large requests and responses are split into chunks (64 KB).
- **Clients:** up to 16 at once, one session per connection.

Not supported: encryption / signing and user name login (refused when a client asks for them), events, history, methods, Republish.

## Files

```
OpcUaSim.lpi / .lpr   project
umain.pas / .lfm      main window (designer form)
uaserver.pas          OPC UA server: TCP, secure channel, services, address space
uaencode.pas          OPC UA binary encoding (Variant, DataValue, NodeId, ...)
uplcsim.pas           PLC logic (Set 1 / Set 2) and HV plant, 50 ms cycle thread
                      (also used by ../MqttSim)
```

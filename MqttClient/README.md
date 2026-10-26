# MQTT Client (Lazarus)

A general MQTT 3.1 / 3.1.1 client, written in Free Pascal / Lazarus with normal forms. It needs no DLL and no library: the protocol is in `umqttclient.pas`, and the packet helpers (`mqttcodec.pas`) are shared with the broker in `MqttSim/`.

It works with any MQTT 3.1 / 3.1.1 broker: [MqttSim](../MqttSim/README.md), `Tools/mqttsim.py`, Mosquitto, … The defaults (`127.0.0.1:1884`, subscription `nonlinear/#`) connect to the HV simulator.

## Build and run

Open `MqttClient.lpi` in Lazarus and press Run, or:

```bash
C:\lazarus\lazbuild.exe MqttClient\MqttClient.lpi
```

Enter the broker and press **Connect** (`F5`, `F6` = Disconnect).

## Window

- **Connection** (top):
  - Host, Port, Client ID, Keep alive, MQTT 3.1.1 or 3.1.
  - User and Password (sent only with a user name).
  - Clean session, Auto reconnect (every 3 s, the subscriptions are sent again), Connect at start.
  - Last will: topic (empty = no will), payload, QoS, retain. The broker sends it when the connection drops without a Disconnect.
  - The status line shows the state, received / sent counts, the QoS 1 / 2 messages still waiting for an answer ("in flight"), and the number of topics.
- **Subscribe**: a filter with `+` / `#` and its QoS. Subscriptions you add while disconnected are sent when the client connects. Select one and press **Unsubscribe** to remove it. The log shows the QoS the broker granted, or REFUSED.
- **Publish**: topic, payload (several lines are allowed, `Ctrl+Enter` = Publish), QoS, Retain. A retained message with an empty payload deletes the retained topic on the broker.
- **Topic table**: the last value of every topic received, sorted by topic, with QoS, retained flag, count and time. Control characters are shown as `.`, and long payloads are cut at 300 characters.
  - **Double-click** a row: its topic + `/set` and its value go to Publish, ready to write a simulator tag. For example, double-click `nonlinear/DB_HMI/VoltSP_kV`, type `7.5`, then press Ctrl+Enter.
  - Right-click: *Copy topic and value to Publish* (without `/set`), *Clear table*.
- **Log** (bottom): connects, subscriptions, publishes and errors. With *Log every message*, each received message gets a line as well (`<-`; your publishes are `->`).

The settings and subscriptions are saved in `MqttClient.ini` next to the exe. **The password is not saved.** `ConnectTimeoutMs=3000` in `[Connection]` sets the timeout for the TCP connect and the CONNACK.

## Protocol support

- QoS 0, 1 and 2 in both directions (PUBACK / PUBREC / PUBREL / PUBCOMP). A QoS 2 message that is sent again before PUBREL is shown only once.
- PINGREQ when nothing was sent for ¾ of the keep alive time. The connection is closed when PINGRESP doesn't arrive in time.
- CONNACK codes are shown as text (bad user name or password, not authorized, …). After a refusal the client doesn't keep reconnecting, except for "server unavailable".
- Old brokers that close the connection on a CONNECT they don't support (Mosquitto 1.2 with 3.1.1) get the hint to try MQTT 3.1.

Not supported: TLS, MQTT 5, resending unacknowledged QoS 1 / 2 messages after a reconnect.

## Files

```
MqttClient.lpi / .lpr     project
uclientmain.pas / .lfm    main window (designer form)
umqttclient.pas           MQTT client: worker thread, QoS, keep alive, reconnect, queues for the GUI
../MqttSim/mqttcodec.pas  packet encoding / decoding and topic matching (shared with the broker)
```

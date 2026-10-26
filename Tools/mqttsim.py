"""
mqttsim.py - MQTT broker + simulator (same PLC logic and HV plant as s7sim.py).

 - A small MQTT 3.1 / 3.1.1 broker on tcp://<host>:1884, anonymous, no TLS, no extra packages.
   1884 because 1883 on this PC is used by Mosquitto. Any client can also publish / subscribe
   its own topics: wildcards + and #, retained messages, QoS 0/1/2, last will, keep alive.
 - The simulated DB10 is published (retained, only on change) under the prefix "nonlinear":
     nonlinear/DB_HMI/VoltSP_kV   5.0           nonlinear/DB_HMI/Enable   true
     nonlinear/DB_HMI/Curve_VSP   {"Eng": [..], "Volt": [..]}   (also VAct, CSP, CAct)
     nonlinear/DB_HMI/Err_VSP     0             (--points 2 only, also VAct, CSP, CAct)
     nonlinear/Sim/Counter, Sine, Toggle, Clock  test values for a logger
     nonlinear/status             online / offline
 - Write: publish to "<tag topic>/set", for example
     nonlinear/DB_HMI/VoltSP_kV/set  7.5
     nonlinear/DB_HMI/Enable/set     1 | 0 | true | false | on | off
     nonlinear/DB_HMI/Curve_VSP/set  {"Eng": [..], "Volt": [..]}   (one block, both parts optional)
   Only setpoints, Enable, curves and Err_xxx are writable. A write goes straight into the
   simulated DB10, so every rule of s7sim (Set 2 reject / clamp) applies the same way.

Usage:  python mqttsim.py [--port 1884] [--points 10|2] [--prefix nonlinear] [--interval 0.1]
"""
import argparse
import asyncio
import datetime
import json
import math
import struct
import time

import s7sim as plc

# name, DB10 offset key or (offset key, bit), type ("f" Real, "i" Int, "b" Bool), client may write
TAGS = [("VoltSP_kV", "VoltSP", "f", True),
        ("CurSP_mA", "CurSP", "f", True),
        ("VoltAct_kV", "VoltAct", "f", False),
        ("CurAct_mA", "CurAct", "f", False),
        ("AO0_V", "AO0_V", "f", False),
        ("AO1_V", "AO1_V", "f", False),
        ("AI0_V", "AI0_V", "f", False),
        ("AI1_V", "AI1_V", "f", False),
        ("AO0_Raw", "AO0_Raw", "i", False),
        ("AO1_Raw", "AO1_Raw", "i", False),
        ("AI0_Raw", "AI0_Raw", "i", False),
        ("AI1_Raw", "AI1_Raw", "i", False),
        ("Enable", ("Bits", 0), "b", True),
        ("Valid_VSP", ("Bits", 1), "b", False),
        ("Valid_VAct", ("Bits", 2), "b", False),
        ("Valid_CSP", ("Bits", 3), "b", False),
        ("Valid_CAct", ("Bits", 4), "b", False),
        ("AI0_Fault", ("Bits", 5), "b", False),
        ("AI1_Fault", ("Bits", 6), "b", False),
        ("Heartbeat", "Heartbeat", "i", False)]
TAGS_SET2 = [("Err_VSP", "Err_VSP", "i", True),
             ("Err_VAct", "Err_VAct", "i", True),
             ("Err_CSP", "Err_CSP", "i", True),
             ("Err_CAct", "Err_CAct", "i", True),
             ("VSP_Limited", ("Limited", 0), "b", False),
             ("CSP_Limited", ("Limited", 1), "b", False)]
CURVES = ("Curve_VSP", "Curve_VAct", "Curve_CSP", "Curve_CAct")

CONNECT, CONNACK, PUBLISH, PUBACK, PUBREC, PUBREL, PUBCOMP = 1, 2, 3, 4, 5, 6, 7
SUBSCRIBE, SUBACK, UNSUBSCRIBE, UNSUBACK, PINGREQ, PINGRESP, DISCONNECT = 8, 9, 10, 11, 12, 13, 14


def fmt_real(v):
    """float32 from DB10 as short text (7 significant digits, no 4.99999952)"""
    return float(f"{v:.7g}")


def get_tag(key, t):
    """value of one tag from the simulated DB10 (call with plc.lock held)"""
    if isinstance(key, tuple):
        return plc.gbit(plc.OFS[key[0]], key[1])
    if t == "f":
        return fmt_real(plc.gr(plc.OFS[key]))
    return plc.gi(plc.OFS[key])


def set_tag(key, t, text):
    if t == "b":
        s = text.strip().lower()
        if s not in ("1", "0", "true", "false", "on", "off"):
            raise ValueError("expected 1/0/true/false/on/off")
        plc.sbit(plc.OFS[key[0]], key[1], s in ("1", "true", "on"))
    elif t == "f":
        plc.sr(plc.OFS[key], float(text))
    else:
        plc.si(plc.OFS[key], int(float(text)))


def set_curve(name, text):
    """{"Eng": [..], "Volt": [..]} -> DB10 as one block (a missing part keeps its values)"""
    d = json.loads(text)
    e, v = plc.curve(name)
    e = [float(x) for x in d.get("Eng", e)]
    v = [float(x) for x in d.get("Volt", v)]
    if len(e) != plc.NL or len(v) != plc.NL:
        raise ValueError(f"expected {plc.NL} values per part")
    plc.write_curve(name, e, v)


def enc_len(n):
    out = bytearray()
    while True:
        b, n = n & 0x7F, n >> 7
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)


def enc_str(s):
    b = s.encode() if isinstance(s, str) else s
    return struct.pack(">H", len(b)) + b


def packet(ptype, flags, body=b""):
    return bytes([(ptype << 4) | flags]) + enc_len(len(body)) + body


def topic_match(flt, topic):
    """MQTT filter with + and # against a topic name ($ topics only match explicit filters)"""
    f, t = flt.split("/"), topic.split("/")
    if topic.startswith("$") and f[0] in ("+", "#"):
        return False
    for i, p in enumerate(f):
        if p == "#":
            return True
        if i >= len(t) or (p != "+" and p != t[i]):
            return False
    return len(f) == len(t)


def valid_filter(flt):
    parts = flt.split("/")
    return flt != "" and all(("#" not in p or (p == "#" and i == len(parts) - 1)) and
                             ("+" not in p or p == "+") for i, p in enumerate(parts))


class Client:
    def __init__(self, broker, reader, writer):
        self.broker = broker
        self.reader = reader
        self.writer = writer
        self.peer = writer.get_extra_info("peername")
        self.cid = None
        self.subs = {}              # filter -> granted QoS
        self.will = None            # (topic, payload, qos, retain)
        self.next_id = 0
        self.qos2_in = set()        # packet ids of QoS 2 messages waiting for PUBREL

    def send(self, data):
        if not self.writer.is_closing():
            self.writer.write(data)

    def deliver(self, topic, payload, qos, retain):
        flags = (qos << 1) | (1 if retain else 0)
        body = enc_str(topic)
        if qos:
            self.next_id = self.next_id % 0xFFFF + 1
            body += struct.pack(">H", self.next_id)
        self.send(packet(PUBLISH, flags, body + payload))

    async def read_packet(self, timeout):
        h = await asyncio.wait_for(self.reader.readexactly(1), timeout)
        n, mult = 0, 1
        for _ in range(4):
            b = (await self.reader.readexactly(1))[0]
            n += (b & 0x7F) * mult
            mult <<= 7
            if not b & 0x80:
                break
        else:
            raise ConnectionError("bad remaining length")
        return h[0] >> 4, h[0] & 0x0F, await self.reader.readexactly(n)

    async def run(self):
        clean = False
        try:
            ptype, _, body = await self.read_packet(10)
            if ptype != CONNECT or not self.connect(body):
                return
            while True:
                ptype, flags, body = await self.read_packet(self.timeout)
                if ptype == PUBLISH:
                    self.on_publish(flags, body)
                elif ptype == PUBREL:
                    pid = struct.unpack(">H", body[:2])[0]
                    self.qos2_in.discard(pid)
                    self.send(packet(PUBCOMP, 0, body[:2]))
                elif ptype == PUBREC:                       # our QoS 2 delivery
                    self.send(packet(PUBREL, 2, body[:2]))
                elif ptype in (PUBACK, PUBCOMP):
                    pass
                elif ptype == SUBSCRIBE:
                    self.on_subscribe(body)
                elif ptype == UNSUBSCRIBE:
                    self.on_unsubscribe(body)
                elif ptype == PINGREQ:
                    self.send(packet(PINGRESP, 0))
                elif ptype == DISCONNECT:
                    clean = True
                    return
                else:
                    print(f"{self.cid}: unexpected packet type {ptype}, closing")
                    return
                await self.writer.drain()
        except (asyncio.IncompleteReadError, asyncio.TimeoutError, ConnectionError, OSError, ValueError,
                IndexError, struct.error, UnicodeDecodeError):
            pass
        finally:
            self.broker.remove(self)
            if self.will and not clean:
                self.broker.publish(*self.will)
            self.writer.close()
            if self.cid is not None:
                print(f"client closed {self.cid} {self.peer}")

    def connect(self, b):
        n = struct.unpack(">H", b[:2])[0]
        proto, level, cflags = b[2:2 + n], b[2 + n], b[3 + n]
        keep = struct.unpack(">H", b[4 + n:6 + n])[0]
        p = 6 + n

        def field():
            nonlocal p
            ln = struct.unpack(">H", b[p:p + 2])[0]
            p += 2 + ln
            return b[p - ln:p]

        if (proto, level) not in ((b"MQTT", 4), (b"MQIsdp", 3)):
            self.send(packet(CONNACK, 0, b"\x00\x01"))      # unacceptable protocol version
            print(f"refused {self.peer}: protocol {proto!r} level {level} (MQTT 3.1 / 3.1.1 only)")
            return False
        self.cid = field().decode() or f"auto-{id(self):x}"
        if cflags & 0x04:
            topic = field().decode()
            self.will = (topic, field(), (cflags >> 3) & 3, bool(cflags & 0x20))
        self.timeout = keep * 1.5 if keep else None
        self.broker.add(self)
        self.send(packet(CONNACK, 0, b"\x00\x00"))           # no persistent sessions
        print(f"client {self.cid} {self.peer} keepalive={keep}s")
        return True

    def on_publish(self, flags, b):
        qos, retain = (flags >> 1) & 3, bool(flags & 1)
        n = struct.unpack(">H", b[:2])[0]
        topic = b[2:2 + n].decode()
        p = 2 + n
        if qos:
            pid = b[p:p + 2]
            p += 2
        payload = b[p:]
        if qos == 1:
            self.send(packet(PUBACK, 0, pid))
        elif qos == 2:
            self.send(packet(PUBREC, 0, pid))
            if struct.unpack(">H", pid)[0] in self.qos2_in:  # duplicate before PUBREL
                return
            self.qos2_in.add(struct.unpack(">H", pid)[0])
        if "+" in topic or "#" in topic:
            return
        if self.broker.on_write is not None and self.broker.on_write(topic, payload):
            return                                           # a simulator write, not routed
        self.broker.publish(topic, payload, qos, retain)

    def on_subscribe(self, b):
        pid, p, codes, new = b[:2], 2, bytearray(), []
        while p < len(b):
            n = struct.unpack(">H", b[p:p + 2])[0]
            flt = b[p + 2:p + 2 + n].decode()
            qos = b[p + 2 + n] & 3
            p += 3 + n
            if not valid_filter(flt) or qos > 2:
                codes.append(0x80)
                continue
            self.subs[flt] = qos
            codes.append(qos)
            new.append((flt, qos))
            print(f"{self.cid} subscribe {flt} qos={qos}")
        self.send(packet(SUBACK, 0, pid + bytes(codes)))
        for flt, qos in new:                                 # retained messages after SUBACK
            for topic, (payload, rqos) in self.broker.retained.items():
                if topic_match(flt, topic):
                    self.deliver(topic, payload, min(qos, rqos), True)

    def on_unsubscribe(self, b):
        p = 2
        while p < len(b):
            n = struct.unpack(">H", b[p:p + 2])[0]
            self.subs.pop(b[p + 2:p + 2 + n].decode(), None)
            p += 2 + n
        self.send(packet(UNSUBACK, 0, b[:2]))


class Broker:
    def __init__(self):
        self.clients = {}           # client id -> Client
        self.retained = {}          # topic -> (payload, qos)
        self.on_write = None        # f(topic, payload) -> True if the simulator took it

    def add(self, c):
        old = self.clients.get(c.cid)
        if old is not None:                                  # same id: the old session is closed
            old.will = None
            old.writer.close()
        self.clients[c.cid] = c

    def remove(self, c):
        if self.clients.get(c.cid) is c:
            del self.clients[c.cid]

    def publish(self, topic, payload, qos=0, retain=False):
        if isinstance(payload, str):
            payload = payload.encode()
        if retain:
            if payload:
                self.retained[topic] = (payload, qos)
            else:
                self.retained.pop(topic, None)               # empty retained = delete
        for c in list(self.clients.values()):
            q = max((sq for flt, sq in c.subs.items() if topic_match(flt, topic)), default=-1)
            if q >= 0:
                c.deliver(topic, payload, min(qos, q), False)


class Sim:
    def __init__(self, broker, prefix, points):
        self.broker = broker
        self.prefix = prefix
        self.items = {}             # topic -> (getter, setter or None)
        self.last = {}              # topic -> last payload published
        db = prefix + "/DB_HMI/"
        for name, key, t, rw in TAGS + (TAGS_SET2 if points == 2 else []):
            self.items[db + name] = (lambda k=key, tt=t: get_tag(k, tt),
                                     (lambda s, k=key, tt=t: set_tag(k, tt, s)) if rw else None)
        for cname in CURVES:
            self.items[db + cname] = (lambda n=cname: dict(zip(("Eng", "Volt"),
                                                               ([fmt_real(x) for x in part]
                                                                for part in plc.curve(n)))),
                                      lambda s, n=cname: set_curve(n, s))
        t0 = time.time()
        for name, fn in (("Counter", lambda: int((time.time() - t0) * 10) & 0xFFFF),
                         ("Sine", lambda: round(math.sin((time.time() - t0) / 2.0) * 50 + 50, 4)),
                         ("Toggle", lambda: int((time.time() - t0) / 2) % 2 == 1),
                         ("Clock", lambda: datetime.datetime.now(datetime.timezone.utc)
                          .isoformat(timespec="milliseconds"))):
            self.items[f"{prefix}/Sim/{name}"] = (fn, None)
        broker.on_write = self.on_write

    def on_write(self, topic, payload):
        """client publish to <tag>/set -> simulated DB10 (the next PLC cycle checks it)"""
        if not topic.endswith("/set") or not topic.startswith(self.prefix + "/"):
            return False
        item = self.items.get(topic[:-4])
        if item is None or item[1] is None:
            print(f"write refused (unknown or read only): {topic}")
            return True
        text = payload.decode(errors="replace")
        try:
            with plc.lock:
                item[1](text)
            print(f"write {topic[:-4]} = {text}")
        except (ValueError, TypeError, AttributeError) as e:
            print(f"write refused {topic}: {text!r} ({e})")
        return True

    def publish(self):
        """DB10 -> retained topics, only the values that changed"""
        with plc.lock:
            vals = {t: g() for t, (g, _) in self.items.items()}
        for t, v in vals.items():
            s = v if isinstance(v, str) else json.dumps(v)
            if s != self.last.get(t):
                self.last[t] = s
                self.broker.publish(t, s, 0, True)


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=1884)
    ap.add_argument("--points", type=int, default=10, choices=(2, 10))
    ap.add_argument("--prefix", default="nonlinear")
    ap.add_argument("--interval", type=float, default=0.1, help="publish interval in s")
    a = ap.parse_args()
    plc.set_points(a.points)
    plc.init_db()
    if plc.NL == 2:
        plc.lin_init()

    broker = Broker()
    sim = Sim(broker, a.prefix, a.points)
    broker.publish(a.prefix + "/status", "online", 0, True)

    async def on_client(reader, writer):
        await Client(broker, reader, writer).run()

    server = await asyncio.start_server(on_client, "0.0.0.0", a.port)
    print(f"MQTT broker + simulator on tcp://0.0.0.0:{a.port}  (topics {a.prefix}/#, {plc.NL} points per curve)")
    plant = plc.Plant()
    async with server:
        t = t_pub = time.time()
        while True:
            await asyncio.sleep(0.05)
            now = time.time()
            plc.plc_cycle(plant, now - t)
            t = now
            if now - t_pub >= a.interval:
                t_pub = now
                sim.publish()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass

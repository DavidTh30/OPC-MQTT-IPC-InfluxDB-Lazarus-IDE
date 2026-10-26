"""
opcuasim.py - OPC UA server simulator (same PLC logic and HV plant as s7sim.py).

 - Endpoint opc.tcp://<host>:4841/nonlinear/  (no security, anonymous login)
   4841 because 4840 on this PC is used by the OPC UA Local Discovery Server.
 - Namespace "urn:nonlinear:hv", string NodeIds "DB_HMI.<tag>" with the same tag names as DB10:
     DB_HMI.VoltSP_kV  Float  rw    DB_HMI.VoltAct_kV  Float  r   ... (see TAGS below)
     DB_HMI.Enable     Boolean rw   DB_HMI.Valid_VSP   Boolean r  ...
     DB_HMI.Curve_VSP.Eng / .Volt   Float[points] rw  (also VAct, CSP, CAct)
     DB_HMI.Err_VSP .. Err_CAct     Int16 rw (--points 2 only, write 0 = acknowledge)
 - Sim.Counter (UInt16, +1 per 100 ms), Sim.Sine (Double), Sim.Toggle (Boolean, every 2 s),
   Sim.Clock (DateTime) for testing a logger.
 - The PLC cycle runs every 50 ms; a client write goes straight into the simulated DB10,
   so every rule of s7sim (Set 2 reject / clamp) applies the same way.

Usage:  python opcuasim.py [--port 4841] [--points 10|2]
Needs:  python -m pip install asyncua
"""
import argparse
import asyncio
import datetime
import math
import time

from asyncua import Server, ua
from asyncua.common.callback import CallbackType

import s7sim as plc

NS_URI = "urn:nonlinear:hv"
# name, DB10 offset key or (offset key, bit), OPC UA type, client may write
TAGS = [("VoltSP_kV", "VoltSP", ua.VariantType.Float, True),
        ("CurSP_mA", "CurSP", ua.VariantType.Float, True),
        ("VoltAct_kV", "VoltAct", ua.VariantType.Float, False),
        ("CurAct_mA", "CurAct", ua.VariantType.Float, False),
        ("AO0_V", "AO0_V", ua.VariantType.Float, False),
        ("AO1_V", "AO1_V", ua.VariantType.Float, False),
        ("AI0_V", "AI0_V", ua.VariantType.Float, False),
        ("AI1_V", "AI1_V", ua.VariantType.Float, False),
        ("AO0_Raw", "AO0_Raw", ua.VariantType.Int16, False),
        ("AO1_Raw", "AO1_Raw", ua.VariantType.Int16, False),
        ("AI0_Raw", "AI0_Raw", ua.VariantType.Int16, False),
        ("AI1_Raw", "AI1_Raw", ua.VariantType.Int16, False),
        ("Enable", ("Bits", 0), ua.VariantType.Boolean, True),
        ("Valid_VSP", ("Bits", 1), ua.VariantType.Boolean, False),
        ("Valid_VAct", ("Bits", 2), ua.VariantType.Boolean, False),
        ("Valid_CSP", ("Bits", 3), ua.VariantType.Boolean, False),
        ("Valid_CAct", ("Bits", 4), ua.VariantType.Boolean, False),
        ("AI0_Fault", ("Bits", 5), ua.VariantType.Boolean, False),
        ("AI1_Fault", ("Bits", 6), ua.VariantType.Boolean, False),
        ("Heartbeat", "Heartbeat", ua.VariantType.Int16, False)]
TAGS_SET2 = [("Err_VSP", "Err_VSP", ua.VariantType.Int16, True),
             ("Err_VAct", "Err_VAct", ua.VariantType.Int16, True),
             ("Err_CSP", "Err_CSP", ua.VariantType.Int16, True),
             ("Err_CAct", "Err_CAct", ua.VariantType.Int16, True),
             ("VSP_Limited", ("Limited", 0), ua.VariantType.Boolean, False),
             ("CSP_Limited", ("Limited", 1), ua.VariantType.Boolean, False)]
CURVES = ("Curve_VSP", "Curve_VAct", "Curve_CSP", "Curve_CAct")


def get_tag(key, vt):
    """value of one tag from the simulated DB10 (call with plc.lock held)"""
    if isinstance(key, tuple):
        return plc.gbit(plc.OFS[key[0]], key[1])
    if vt == ua.VariantType.Float:
        return plc.gr(plc.OFS[key])
    return plc.gi(plc.OFS[key])


def set_tag(key, vt, v):
    if isinstance(key, tuple):
        plc.sbit(plc.OFS[key[0]], key[1], bool(v))
    elif vt == ua.VariantType.Float:
        plc.sr(plc.OFS[key], float(v))
    else:
        plc.si(plc.OFS[key], int(v))


class Sim:
    def __init__(self, server, ns, points):
        self.server = server
        self.ns = ns
        self.tags = TAGS + (TAGS_SET2 if points == 2 else [])
        self.nodes = {}            # NodeId -> (setter, getter, node)
        self.last = {}             # NodeId -> last value published

    async def build(self):
        objs = self.server.nodes.objects
        db = await objs.add_object(ua.NodeId("DB_HMI", self.ns), ua.QualifiedName("DB_HMI", self.ns))
        for name, key, vt, rw in self.tags:
            await self.add(db, "DB_HMI." + name, name, vt, rw,
                           lambda k=key, t=vt: get_tag(k, t), lambda v, k=key, t=vt: set_tag(k, t, v))
        for cname in CURVES:
            c = await db.add_object(ua.NodeId("DB_HMI." + cname, self.ns), ua.QualifiedName(cname, self.ns))
            for part in ("Eng", "Volt"):
                await self.add(c, f"DB_HMI.{cname}.{part}", part, ua.VariantType.Float, True,
                               lambda n=cname, p=part: plc.curve(n)[p == "Volt"],
                               lambda v, n=cname, p=part: self.set_curve(n, p, v))
        sim = await objs.add_object(ua.NodeId("Sim", self.ns), ua.QualifiedName("Sim", self.ns))
        t0 = time.time()
        for name, vt, fn in (("Counter", ua.VariantType.UInt16, lambda: int((time.time() - t0) * 10) & 0xFFFF),
                             ("Sine", ua.VariantType.Double, lambda: math.sin((time.time() - t0) / 2.0) * 50 + 50),
                             ("Toggle", ua.VariantType.Boolean, lambda: int((time.time() - t0) / 2) % 2 == 1),
                             ("Clock", ua.VariantType.DateTime, lambda: datetime.datetime.now(datetime.timezone.utc))):
            await self.add(sim, "Sim." + name, name, vt, False, fn, None)
        self.server.iserver.subscribe_server_callback(CallbackType.PostWrite, self.on_write)

    async def add(self, parent, nid, name, vt, rw, getter, setter):
        with plc.lock:
            v = getter()
        if isinstance(v, list):
            node = await parent.add_variable(ua.NodeId(nid, self.ns), ua.QualifiedName(name, self.ns),
                                             ua.Variant(v, vt), datatype=ua.NodeId(vt.value))
            await node.write_value_rank(1)
            await node.write_array_dimensions([len(v)])
        else:
            node = await parent.add_variable(ua.NodeId(nid, self.ns), ua.QualifiedName(name, self.ns),
                                             ua.Variant(v, vt))
        if rw:
            await node.set_writable()
        self.nodes[node.nodeid] = (setter, getter, node, vt)
        self.last[node.nodeid] = v

    @staticmethod
    def set_curve(name, part, v):
        if len(v) != plc.NL:
            return
        e, volt = plc.curve(name)
        plc.write_curve(name, list(v) if part == "Eng" else e, list(v) if part == "Volt" else volt)

    def on_write(self, event, _dispatcher):
        """client write -> simulated DB10 (the next PLC cycle checks it like a real PLC)"""
        if not event.is_external:                  # our own publish()
            return
        for wv, st in zip(event.request_params.NodesToWrite, event.response_params):
            if wv.AttributeId != ua.AttributeIds.Value or not st.is_good() or wv.NodeId not in self.nodes:
                continue
            setter = self.nodes[wv.NodeId][0]
            if setter is None:
                continue
            v = wv.Value.Value.Value
            with plc.lock:
                setter(v)
            self.last[wv.NodeId] = v               # the node holds this now, publish() corrects it
            print(f"write {wv.NodeId.Identifier} = {v}")

    async def publish(self):
        """DB10 -> OPC UA nodes, only the values that changed (keeps subscriptions quiet)"""
        with plc.lock:
            vals = {nid: g() for nid, (_, g, _, _) in self.nodes.items()}
        for nid, v in vals.items():
            if v != self.last[nid]:
                self.last[nid] = v
                await self.nodes[nid][2].write_value(ua.Variant(v, self.nodes[nid][3]))


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=4841)
    ap.add_argument("--points", type=int, default=10, choices=(2, 10))
    a = ap.parse_args()
    plc.set_points(a.points)
    plc.init_db()
    if plc.NL == 2:
        plc.lin_init()

    server = Server()
    await server.init()
    url = f"opc.tcp://0.0.0.0:{a.port}/nonlinear/"
    server.set_endpoint(url)
    server.set_server_name("Nonlinear HV OPC UA simulator")
    server.set_security_policy([ua.SecurityPolicyType.NoSecurity])
    ns = await server.register_namespace(NS_URI)
    sim = Sim(server, ns, a.points)
    await sim.build()

    plant = plc.Plant()
    async with server:
        print(f"OPC UA simulator on {url}  (ns={ns} {NS_URI}, {plc.NL} points per curve)")
        t = time.time()
        while True:
            await asyncio.sleep(0.05)
            now = time.time()
            plc.plc_cycle(plant, now - t)
            t = now
            await sim.publish()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass

"""
s7sim.py - tiny S7-1200 simulator for testing the HMIs without hardware.

 - Listens on TCP 102 (ISO-on-TCP), answers COTP connect, S7 setup,
   read var (1..20 items per request, I / M / DB10 / DB20) / write var (byte + bit) for DB10.
 - DB20 (read only) = date / time test values for the PLC Data Logger:
     DBW0 DATE, DBD2 TIME (uptime), DBD6 TOD, DBB10 DT, DBB18 DTL, DBD30 UNIXTIME, DBW34 counter
 - Runs the same logic as FB_NonlinearHV every 50 ms and simulates
   a nonlinear HV supply (AO -> plant -> AI) with first-order lag.

Usage:  python s7sim.py [--port 102] [--db 10] [--points 10|2]
        --points 2 simulates PLC Set 2 (2-point linear, FC_Lin_Scale) incl. its input
                   protection: bad calibrations rejected (Err code), setpoints clamped to X0..X1
Then point the HMI at 127.0.0.1 (rack 0, slot 1).
"""
import argparse
import datetime
import math
import socket
import struct
import threading
import time

NL = 10          # points per curve, set by --points
DB_SIZE = 364
OFS = dict(VoltSP=0, CurSP=4, VoltAct=8, CurAct=12, AO0_V=16, AO1_V=20, AI0_V=24, AI1_V=28,
           AO0_Raw=32, AO1_Raw=34, AI0_Raw=36, AI1_Raw=38, Bits=40, Heartbeat=42)


def set_points(n):
    """layout of DB10: the 4 curves follow each other from byte 44, n*8 bytes each"""
    global NL, DB_SIZE, db
    NL = n
    for k, name in enumerate(("Curve_VSP", "Curve_VAct", "Curve_CSP", "Curve_CAct")):
        OFS[name] = 44 + k * n * 8
    DB_SIZE = 44 + 4 * n * 8
    if n == 2:   # Set 2 protection fields after the curves
        OFS.update(Err_VSP=108, Err_VAct=110, Err_CSP=112, Err_CAct=114, Limited=116)
        DB_SIZE += 10
    db = bytearray(DB_SIZE)

lock = threading.Lock()
db = bytearray(DB_SIZE)


T_START = time.time()


def bcd(v):
    return ((v // 10) << 4) | (v % 10)


def db20():
    """date / time test block (live PC clock)"""
    now = datetime.datetime.now()
    ms = now.microsecond // 1000
    b = bytearray(36)
    struct.pack_into(">H", b, 0, (now.date() - datetime.date(1990, 1, 1)).days)
    struct.pack_into(">i", b, 2, int((time.time() - T_START) * 1000))
    struct.pack_into(">I", b, 6, ((now.hour * 60 + now.minute) * 60 + now.second) * 1000 + ms)
    b[10:18] = bytes([bcd(now.year % 100), bcd(now.month), bcd(now.day), bcd(now.hour), bcd(now.minute),
                      bcd(now.second), bcd(ms // 10), ((ms % 10) << 4) | (now.isoweekday() % 7 + 1)])
    struct.pack_into(">HBBBBBBI", b, 18, now.year, now.month, now.day, now.isoweekday() % 7 + 1,
                     now.hour, now.minute, now.second, now.microsecond * 1000)
    struct.pack_into(">I", b, 30, int(time.time()))
    struct.pack_into(">H", b, 34, int(time.time() - T_START) & 0xFFFF)
    return bytes(b)


def gr(o):
    return struct.unpack_from(">f", db, o)[0]


def sr(o, v):
    struct.pack_into(">f", db, o, v)


def gi(o):
    return struct.unpack_from(">h", db, o)[0]


def si(o, v):
    struct.pack_into(">h", db, o, max(-32768, min(32767, int(round(v)))))


def gbit(o, b):
    return bool(db[o] & (1 << b))


def sbit(o, b, v):
    if v:
        db[o] |= (1 << b)
    else:
        db[o] &= ~(1 << b) & 0xFF


def curve(name):
    o = OFS[name]
    eng = [gr(o + i * 4) for i in range(NL)]
    volt = [gr(o + NL * 4 + i * 4) for i in range(NL)]
    return eng, volt


def init_db():
    for name, full in (("Curve_VSP", 15.0), ("Curve_VAct", 15.0), ("Curve_CSP", 20.0), ("Curve_CAct", 20.0)):
        for i in range(NL):
            sr(OFS[name] + i * 4, full * i / (NL - 1))
            sr(OFS[name] + NL * 4 + i * 4, 10.0 * i / (NL - 1))


def interp(x, xs, ys, xfull, yfull, ymin, ymax):
    """same as FC_NL_Interp (10 points) / FC_Lin_Scale (2 points)"""
    if NL == 2:
        valid = xs[1] > xs[0] and ys[1] > ys[0]
    else:
        valid = all(xs[i] > xs[i - 1] for i in range(1, NL))
    if valid and NL == 2:
        y = ys[0] + (x - xs[0]) * (ys[1] - ys[0]) / (xs[1] - xs[0])   # line, extended
    elif valid:
        xx = min(max(x, xs[0]), xs[NL - 1])
        k = 0
        for i in range(1, NL - 1):
            if xx >= xs[i]:
                k = i
        y = ys[k] + (ys[k + 1] - ys[k]) * (xx - xs[k]) / (xs[k + 1] - xs[k])
    else:
        y = x * yfull / xfull if xfull > 0 else 0.0
    return min(max(y, ymin), ymax), valid


# ---------------------------------------------------------------------------
#  Set 2 protection (same rules as PLC_Linear FC_Lin_Check / FC_Lin_Accept)
# ---------------------------------------------------------------------------
LIN = (("Curve_VSP", 15.0, "Err_VSP"), ("Curve_VAct", 15.0, "Err_VAct"),
       ("Curve_CSP", 20.0, "Err_CSP"), ("Curve_CAct", 20.0, "Err_CAct"))
ACT = {}                      # active (accepted) calibrations
LAST_SP = {"VoltSP": 0.0, "CurSP": 0.0}


def lin_check(e, v, full):
    def inside(x, hi):        # NaN fails every comparison
        return x >= 0.0 and x <= hi
    if not (inside(e[0], full) and inside(e[1], full)):
        return 1
    if not (inside(v[0], 10.0) and inside(v[1], 10.0)):
        return 2
    if not e[1] > e[0]:
        return 3
    if not v[1] > v[0]:
        return 4
    if e[1] - e[0] < 0.1 * full:
        return 5
    if v[1] - v[0] < 1.0:
        return 6
    return 0


def write_curve(name, e, v):
    o = OFS[name]
    for i in range(NL):
        sr(o + i * 4, e[i])
        sr(o + NL * 4 + i * 4, v[i])


def lin_init():
    for name, full, _ in LIN:
        e, v = curve(name)
        ACT[name] = (e, v) if lin_check(e, v, full) == 0 else ([0.0, full], [0.0, 10.0])


def lin_accept():
    for name, full, err in LIN:
        e, v = curve(name)
        code = lin_check(e, v, full)
        if code:
            si(OFS[err], code)              # latched reason
            write_curve(name, *ACT[name])   # restore last good calibration
        elif (e, v) != ACT[name]:
            ACT[name] = (e, v)
            si(OFS[err], 0)
    for bit, (_, _, err) in zip((1, 2, 3, 4), LIN):
        sbit(40, bit, gi(OFS[err]) == 0)


def lin_setpoint(key, name, bit):
    sp = gr(OFS[key])
    e0, e1 = ACT[name][0]
    if e0 <= sp <= e1:
        if sp != LAST_SP[key]:
            sbit(OFS["Limited"], bit, False)
    elif sp > e1:
        sp = e1
        sbit(OFS["Limited"], bit, True)
    else:                                   # below X0 or NaN
        sp = e0
        sbit(OFS["Limited"], bit, True)
    sr(OFS[key], sp)
    sp = gr(OFS[key])                       # as float32, like the PLC
    LAST_SP[key] = sp
    return sp


class Plant:
    """nonlinear HV supply: real kV = 15*(ao/10)^1.25, monitor slightly nonlinear"""

    def __init__(self):
        self.kv = 0.0
        self.ma = 0.0

    def step(self, ao0, ao1, dt):
        kv_target = 15.0 * (ao0 / 10.0) ** 1.25
        self.kv += (kv_target - self.kv) * min(1.0, dt / 0.8)
        load_ma = self.kv * 1.1                     # resistive load
        limit_ma = 20.0 * (ao1 / 10.0) ** 0.9
        self.ma += (min(load_ma, limit_ma) - self.ma) * min(1.0, dt / 0.3)
        ai0 = 10.0 * (self.kv / 15.0) ** 0.92 + 0.01 * math.sin(time.time() * 3)
        ai1 = 10.0 * (self.ma / 20.0) ** 1.05 + 0.01 * math.sin(time.time() * 5)
        return max(ai0, 0.0), max(ai1, 0.0)


def plc_cycle(plant, dt):
    with lock:
        if NL == 2:
            lin_accept()
            sp_v = lin_setpoint("VoltSP", "Curve_VSP", 0)
            sp_i = lin_setpoint("CurSP", "Curve_CSP", 1)
            e, v = ACT["Curve_VSP"]
            ao0, _ = interp(sp_v, e, v, 15, 10, v[0], v[1])
            e, v = ACT["Curve_CSP"]
            ao1, _ = interp(sp_i, e, v, 20, 10, v[0], v[1])
        else:
            sp_v = min(max(gr(OFS["VoltSP"]), 0), 15)
            sp_i = min(max(gr(OFS["CurSP"]), 0), 20)
            e, v = curve("Curve_VSP")
            ao0, ok = interp(sp_v, e, v, 15, 10, 0, 10)
            sbit(40, 1, ok)
            e, v = curve("Curve_CSP")
            ao1, ok = interp(sp_i, e, v, 20, 10, 0, 10)
            sbit(40, 3, ok)
        if not gbit(40, 0):
            ao0 = ao1 = 0.0
        sr(OFS["AO0_V"], ao0)
        sr(OFS["AO1_V"], ao1)
        si(OFS["AO0_Raw"], ao0 * 2764.8)
        si(OFS["AO1_Raw"], ao1 * 2764.8)
    ai0, ai1 = plant.step(ao0, ao1, dt)
    with lock:
        r0, r1 = int(round(ai0 * 2764.8)), int(round(ai1 * 2764.8))
        si(OFS["AI0_Raw"], r0)
        si(OFS["AI1_Raw"], r1)
        sbit(40, 5, r0 > 32511)
        sbit(40, 6, r1 > 32511)
        v0, v1 = min(r0 / 2764.8, 10), min(r1 / 2764.8, 10)
        sr(OFS["AI0_V"], v0)
        sr(OFS["AI1_V"], v1)
        if NL == 2:
            e, v = ACT["Curve_VAct"]
            sr(OFS["VoltAct"], interp(v0, v, e, 10, 15, 0, 15)[0])
            e, v = ACT["Curve_CAct"]
            sr(OFS["CurAct"], interp(v1, v, e, 10, 20, 0, 20)[0])
        else:
            e, v = curve("Curve_VAct")
            y, ok = interp(v0, v, e, 10, 15, 0, 15)
            sr(OFS["VoltAct"], y)
            sbit(40, 2, ok)
            e, v = curve("Curve_CAct")
            y, ok = interp(v1, v, e, 10, 20, 0, 20)
            sr(OFS["CurAct"], y)
            sbit(40, 4, ok)
        hb = gi(OFS["Heartbeat"])
        si(OFS["Heartbeat"], 0 if hb >= 32767 else hb + 1)


def plc_loop():
    plant = Plant()
    t = time.time()
    while True:
        time.sleep(0.05)
        now = time.time()
        plc_cycle(plant, now - t)
        t = now


def recv_exact(c, n):
    b = b""
    while len(b) < n:
        chunk = c.recv(n - len(b))
        if not chunk:
            raise ConnectionError
        b += chunk
    return b


def tpkt(payload):
    return struct.pack(">BBH", 3, 0, len(payload) + 4) + payload


MK = bytearray(256)                                   # M area: MW0 = counter (+1 per read)


def read_area(area, dbn, dbnum, start, cnt):
    """bytes of one read item, None = refused"""
    if area == 0x81 and start + cnt <= 16:            # inputs: I0.1 toggles every 3 s
        ib = bytearray(16)
        if int(time.time() / 3) % 2:
            ib[0] |= 0x02
        return bytes(ib[start:start + cnt])
    if area == 0x83 and start + cnt <= len(MK):
        struct.pack_into(">H", MK, 0, (struct.unpack_from(">H", MK, 0)[0] + 1) & 0xFFFF)
        return bytes(MK[start:start + cnt])
    if area == 0x84 and dbn == 20 and start + cnt <= 36:
        return db20()[start:start + cnt]
    if area == 0x84 and dbn == dbnum and start + cnt <= DB_SIZE:
        with lock:
            return bytes(db[start:start + cnt])
    return None


def ack(ref, params, data=b""):
    hdr = struct.pack(">BBHHHHBB", 0x32, 3, 0, ref, len(params), len(data), 0, 0)
    return tpkt(b"\x02\xf0\x80" + hdr + params + data)


def handle(c, addr, dbnum):
    print("client", addr)
    try:
        while True:
            h = recv_exact(c, 4)
            ln = struct.unpack(">H", h[2:4])[0]
            p = h + recv_exact(c, ln - 4)
            if p[5] == 0xE0:                       # COTP connect request
                c.sendall(tpkt(bytes([0x11, 0xD0, 0, 1, 0, 1, 0]) + p[11:22]))
                continue
            s = p[7:]
            ref = struct.unpack(">H", s[4:6])[0]
            plen = struct.unpack(">H", s[6:8])[0]
            par = s[10:10 + plen]
            dat = s[10 + plen:]
            fn = par[0]
            if s[1] == 0x07 and par[5] == 0x47:    # userdata: read clock -> PC time (BCD)
                now = datetime.datetime.now()
                def bcd(v):
                    return ((v // 10) << 4) | (v % 10)
                ms = now.microsecond // 1000
                clock = bytes([0, bcd(now.year // 100), bcd(now.year % 100), bcd(now.month), bcd(now.day),
                               bcd(now.hour), bcd(now.minute), bcd(now.second), bcd(ms // 10),
                               ((ms % 10) << 4) | (now.isoweekday() % 7 + 1)])
                params = bytes([0, 1, 0x12, 8, 0x12, 0x87, 1, 1, 0, 0, 0, 0])
                hdr = struct.pack(">BBHHHH", 0x32, 7, 0, ref, len(params), 4 + len(clock))
                c.sendall(tpkt(b"\x02\xf0\x80" + hdr + params + b"\xff\x09" + struct.pack(">H", len(clock)) + clock))
                continue
            if s[1] == 0x07:                       # userdata: read SZL 0x0424 -> CPU RUN
                szl = struct.pack(">HHHH", 0x0424, 0, 20, 1) + bytes([0x51, 0x44, 0xFF, 0x08]) + bytes(16)
                params = bytes([0, 1, 0x12, 8, 0x12, 0x84, 1, 1, 0, 0, 0, 0])
                hdr = struct.pack(">BBHHHH", 0x32, 7, 0, ref, len(params), 4 + len(szl))
                c.sendall(tpkt(b"\x02\xf0\x80" + hdr + params + b"\xff\x09" + struct.pack(">H", len(szl)) + szl))
                continue
            if fn == 0xF0:                         # setup communication
                c.sendall(ack(ref, bytes([0xF0, 0, 0, 1, 0, 1, 0, 240])))
            elif fn == 0x04:                       # read var, 1..20 items (multi-item read)
                n = par[1]
                out = b""
                for k in range(n):
                    it = par[2 + 12 * k:14 + 12 * k]
                    cnt, dbn, area = *struct.unpack(">HH", it[4:8]), it[8]
                    start = int.from_bytes(it[9:12], "big") >> 3
                    d = read_area(area, dbn, dbnum, start, cnt)
                    if d is None:
                        print(f"read rejected: DB{dbn} area={area:02x} start={start} n={cnt}")
                        item = b"\x0a\x00\x00\x00"
                    else:
                        item = b"\xff\x04" + struct.pack(">H", cnt * 8) + d
                    if k < n - 1 and len(item) % 2:
                        item += b"\x00"                # fill byte between items
                    out += item
                c.sendall(ack(ref, bytes([0x04, n]), out))
            elif fn == 0x05:                       # write var
                ts, cnt, dbn, area = par[5], *struct.unpack(">HH", par[6:10]), par[10]
                a = int.from_bytes(par[11:14], "big")
                if dbn != dbnum or area != 0x84:
                    c.sendall(ack(ref, b"\x05\x01", b"\x0a"))
                    continue
                with lock:
                    if ts == 0x01:                 # bit
                        sbit(a >> 3, a & 7, dat[4] != 0)
                    else:
                        start = a >> 3
                        db[start:start + cnt] = dat[4:4 + cnt]
                c.sendall(ack(ref, b"\x05\x01", b"\xff"))
                print(f"write DB{dbn} @{a >> 3}.{a & 7} ts={ts} n={cnt}")
            else:
                c.sendall(ack(ref, par[:2], b"\x0a"))
    except (ConnectionError, OSError):
        pass
    finally:
        c.close()
        print("client closed", addr)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=102)
    ap.add_argument("--db", type=int, default=10)
    ap.add_argument("--points", type=int, default=10, choices=(2, 10))
    a = ap.parse_args()
    set_points(a.points)
    init_db()
    if NL == 2:
        lin_init()
    threading.Thread(target=plc_loop, daemon=True).start()
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", a.port))
    srv.listen(4)
    print(f"S7 simulator on port {a.port}, DB{a.db} ({DB_SIZE} bytes, {NL} points per curve)")
    while True:
        c, addr = srv.accept()
        threading.Thread(target=handle, args=(c, addr, a.db), daemon=True).start()


if __name__ == "__main__":
    main()

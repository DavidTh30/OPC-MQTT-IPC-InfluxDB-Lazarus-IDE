"""
s7poke.py - write raw values into DB10 WITHOUT any check, like a third-party
HMI that does no input validation. Used to test that the PLC protects itself.

Usage:
  python s7poke.py HOST real OFFSET VALUE      write a Real   (VALUE may be nan)
  python s7poke.py HOST bit  OFFSET.BIT 0|1    write a Bool in DB10
  python s7poke.py HOST mbit BYTE.BIT 0|1      write a marker bit (e.g. 0.5 = M0.5)
  python s7poke.py HOST cal  OFFSET E0 E1 V0 V1  write a 2-point calibration (16 bytes)
  python s7poke.py HOST read OFFSET COUNT      read COUNT Reals from OFFSET
Rack 0 / slot 1, DB number 10.
"""
import socket
import struct
import sys

DB = 10


def tpkt(payload):
    return struct.pack(">BBH", 3, 0, len(payload) + 4) + payload


def recv(s):
    h = s.recv(4)
    n = struct.unpack(">H", h[2:4])[0]
    d = b""
    while len(d) < n - 4:
        d += s.recv(n - 4 - len(d))
    return h + d


def connect(host):
    s = socket.create_connection((host, 102), timeout=3)
    s.sendall(tpkt(bytes([0x11, 0xE0, 0, 0, 0, 1, 0, 0xC0, 1, 0x0A, 0xC1, 2, 1, 0, 0xC2, 2, 1, 1])))
    recv(s)
    s.sendall(tpkt(b"\x02\xf0\x80" + bytes([0x32, 1, 0, 0, 0, 1, 0, 8, 0, 0, 0xF0, 0, 0, 1, 0, 1, 0, 240])))
    recv(s)
    return s


def write(s, start, data, bit=None, area=0x84, db=DB):
    if bit is None:
        ts, n, addr, dts, bits = 2, len(data), start * 8, 4, len(data) * 8
    else:
        ts, n, addr, dts, bits = 1, 1, start * 8 + bit, 3, 1
    par = bytes([5, 1, 0x12, 0x0A, 0x10, ts]) + struct.pack(">HH", n, db) + bytes([area]) + addr.to_bytes(3, "big")
    dat = bytes([0, dts]) + struct.pack(">H", bits) + data
    hdr = struct.pack(">BBHHHH", 0x32, 1, 0, 2, len(par), len(dat))
    s.sendall(tpkt(b"\x02\xf0\x80" + hdr + par + dat))
    r = recv(s)
    return r[21] == 0xFF


def read(s, start, n):
    par = bytes([4, 1, 0x12, 0x0A, 0x10, 2]) + struct.pack(">HH", n, DB) + bytes([0x84]) + (start * 8).to_bytes(3, "big")
    hdr = struct.pack(">BBHHHH", 0x32, 1, 0, 3, len(par), 0)
    s.sendall(tpkt(b"\x02\xf0\x80" + hdr + par))
    r = recv(s)
    return r[25:25 + n]


def main():
    host, cmd = sys.argv[1], sys.argv[2]
    s = connect(host)
    if cmd == "real":
        ok = write(s, int(sys.argv[3]), struct.pack(">f", float(sys.argv[4])))
    elif cmd == "bit":
        b, bit = sys.argv[3].split(".")
        ok = write(s, int(b), bytes([int(sys.argv[4])]), bit=int(bit))
    elif cmd == "mbit":                     # marker bit, e.g. mbit 0.5 1 = M0.5 := TRUE
        b, bit = sys.argv[3].split(".")
        ok = write(s, int(b), bytes([int(sys.argv[4])]), bit=int(bit), area=0x83, db=0)
    elif cmd == "cal":
        e0, e1, v0, v1 = (float(x) for x in sys.argv[4:8])
        ok = write(s, int(sys.argv[3]), struct.pack(">4f", e0, e1, v0, v1))
    elif cmd == "read":
        d = read(s, int(sys.argv[3]), 4 * int(sys.argv[4]))
        print(" ".join(f"{v:.4f}" for v in struct.unpack(">%df" % int(sys.argv[4]), d)))
        return
    elif cmd == "ints":
        d = read(s, int(sys.argv[3]), 2 * int(sys.argv[4]))
        print(" ".join(str(v) for v in struct.unpack(">%dh" % int(sys.argv[4]), d)))
        return
    else:
        raise SystemExit(__doc__)
    print("write OK" if ok else "write REFUSED")


if __name__ == "__main__":
    main()

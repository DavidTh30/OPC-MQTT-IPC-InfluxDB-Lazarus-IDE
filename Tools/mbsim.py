"""
mbsim.py - small Modbus TCP slave for testing the PLC Data Logger without hardware.

Usage:  python mbsim.py [--port 502]

Values (Modicon numbers):
  40001  INT    counter +1 every 100 ms
  40002  INT    sine * 1000
  40003  REAL   sine * 50 + 50          (2 registers, ABCD)
  40005  REAL   same value, word-swapped (2 registers, CDAB -> use 40005:REALSW)
  40007  DINT   seconds since start * 1000
  30001  INT    input register: 1234
  00001  coil   toggles every 2 s
  10001  input  inverse of coil 00001
Function codes 01, 02, 03, 04. Other / out-of-range requests -> exception 01 / 02.
"""
import argparse
import math
import socket
import struct
import threading
import time

SIZE = 100
T0 = time.time()


def registers():
    t = time.time() - T0
    s = math.sin(t / 2.0)
    hr = [0] * SIZE
    hr[0] = int(t * 10) & 0xFFFF
    hr[1] = int(s * 1000) & 0xFFFF
    real = struct.pack(">f", s * 50 + 50)
    hr[2], hr[3] = struct.unpack(">HH", real)
    hr[5], hr[4] = struct.unpack(">HH", real)          # CDAB
    hr[6], hr[7] = struct.unpack(">HH", struct.pack(">i", int(t * 1000)))
    ir = [0] * SIZE
    ir[0] = 1234
    coil = int(t / 2) % 2
    return hr, ir, [coil] + [0] * (SIZE - 1), [1 - coil] + [0] * (SIZE - 1)


def handle(c, addr):
    print("client", addr)
    try:
        while True:
            h = b""
            while len(h) < 7:
                d = c.recv(7 - len(h))
                if not d:
                    raise ConnectionError
                h += d
            tid, pid, ln, uid = struct.unpack(">HHHB", h)
            pdu = b""
            while len(pdu) < ln - 1:
                d = c.recv(ln - 1 - len(pdu))
                if not d:
                    raise ConnectionError
                pdu += d
            fc = pdu[0]
            hr, ir, coils, dis = registers()
            if fc in (1, 2, 3, 4) and len(pdu) >= 5:
                start, qty = struct.unpack(">HH", pdu[1:5])
                if start + qty > SIZE or qty == 0:
                    resp = bytes([fc | 0x80, 2])                  # illegal data address
                elif fc in (3, 4):
                    regs = (hr if fc == 3 else ir)[start:start + qty]
                    resp = bytes([fc, qty * 2]) + struct.pack(">%dH" % qty, *regs)
                else:
                    bits = (coils if fc == 1 else dis)[start:start + qty]
                    nb = (qty + 7) // 8
                    data = bytearray(nb)
                    for i, b in enumerate(bits):
                        if b:
                            data[i // 8] |= 1 << (i % 8)
                    resp = bytes([fc, nb]) + bytes(data)
            else:
                resp = bytes([fc | 0x80, 1])                      # illegal function
            c.sendall(struct.pack(">HHHB", tid, 0, len(resp) + 1, uid) + resp)
    except (ConnectionError, OSError):
        pass
    finally:
        c.close()
        print("client closed", addr)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=502)
    a = ap.parse_args()
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", a.port))
    srv.listen(4)
    print(f"Modbus TCP slave on port {a.port}")
    while True:
        c, addr = srv.accept()
        threading.Thread(target=handle, args=(c, addr), daemon=True).start()


if __name__ == "__main__":
    main()

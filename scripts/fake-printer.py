"""A pretend Bambu printer, for trying the iPhone app and widget in the simulator without a printer.

    python3 scripts/fake-printer.py [RUNNING|PREPARE|PAUSE|FAILED|FINISH|IDLE]

Listens on 127.0.0.1:8883 with TLS MQTT (a throwaway self-signed certificate) and answers each
pushall with one report in that state. In the iPhone app, use IP 127.0.0.1 and any serial and
access code. Restart it with another state, then reopen the app, to see the widget change.
It logs each client ID and topic, never the password.
"""
import json
import os
import socket
import ssl
import subprocess
import sys
import tempfile

STATE = (sys.argv[1] if len(sys.argv) > 1 else "RUNNING").upper()

TRAYS = [
    {"id": "0", "tray_type": "PLA", "tray_info_idx": "GFA01", "remain": 80, "tray_color": "F5C6A0FF"},
    {"id": "1", "tray_type": "PLA", "tray_info_idx": "GFA00", "remain": 12, "tray_color": "000000FF"},
    {"id": "2"},
    {"id": "3", "tray_type": "PETG", "tray_info_idx": "GFG02", "remain": 40, "tray_color": "2850E0FF"},
]


def report():
    p = {
        "command": "push_status",
        "gcode_state": STATE,
        "mc_percent": 52,
        "mc_remaining_time": 84,
        "subtask_name": "Benchy",
        "task_id": "1",
        "layer_num": 18,
        "total_layer_num": 29,
        "stg_cur": 0,
        "ams": {"tray_now": "0", "ams": [{"id": "0", "humidity": "4", "tray": TRAYS}]},
    }
    if STATE == "PREPARE":
        p.update(gcode_state="RUNNING", stg_cur=2, layer_num=0, mc_percent=0)
    if STATE == "PAUSE":
        p["hms"] = [{"attr": 0x07002000, "code": 0x00020001}]
    if STATE == "FAILED":
        p.update(print_error=0x0300806E, mc_percent=37)
    if STATE in ("FINISH", "IDLE"):
        p.update(mc_percent=100 if STATE == "FINISH" else 0, mc_remaining_time=0)
    return json.dumps({"print": p}).encode()


def remaining_length(n):
    out = bytearray()
    while True:
        b, n = n % 128, n // 128
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)


def read_exactly(s, n):
    data = b""
    while len(data) < n:
        chunk = s.recv(n - len(data))
        if not chunk:
            raise EOFError
        data += chunk
    return data


def read_packet(s):
    kind = read_exactly(s, 1)[0]
    mult, length = 1, 0
    while True:
        b = read_exactly(s, 1)[0]
        length += (b & 127) * mult
        mult *= 128
        if not b & 128:
            return kind >> 4, read_exactly(s, length)


def serve(s):
    serial = "SERIAL"
    while True:
        kind, body = read_packet(s)
        if kind == 1:  # CONNECT: protocol name, level, flags, keep-alive, then the client ID
            cid_len = int.from_bytes(body[10:12], "big")
            print("connect", body[12 : 12 + cid_len].decode(), flush=True)
            s.sendall(b"\x20\x02\x00\x00")
        elif kind == 8:  # SUBSCRIBE
            topic = body[4 : 4 + int.from_bytes(body[2:4], "big")].decode()
            serial = topic.split("/")[1] if topic.count("/") >= 2 else serial
            print("subscribe", topic, flush=True)
            s.sendall(b"\x90\x03" + body[:2] + b"\x00")
        elif kind == 3:  # PUBLISH: answer every request with one full report
            tlen = int.from_bytes(body[0:2], "big")
            print("publish", body[2 : 2 + tlen].decode(), body[2 + tlen :].decode(), flush=True)
            topic = f"device/{serial}/report".encode()
            vh = len(topic).to_bytes(2, "big") + topic + report()
            s.sendall(b"\x30" + remaining_length(len(vh)) + vh)
        elif kind == 12:  # PINGREQ
            s.sendall(b"\xd0\x00")
        elif kind == 14:  # DISCONNECT
            return


def main():
    certs = tempfile.mkdtemp(prefix="fake-printer-")
    cert, key = os.path.join(certs, "cert.pem"), os.path.join(certs, "key.pem")
    subprocess.run(
        ["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key,
         "-out", cert, "-days", "1", "-subj", "/CN=fake-printer"],
        check=True, capture_output=True,
    )
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 8883))
    srv.listen()
    print(f"fake printer on 127.0.0.1:8883, {STATE}", flush=True)
    while True:
        conn, _ = srv.accept()
        try:
            with ctx.wrap_socket(conn, server_side=True) as s:
                serve(s)
        except (ssl.SSLError, OSError, EOFError):
            pass
        print("hung up", flush=True)


if __name__ == "__main__":
    main()

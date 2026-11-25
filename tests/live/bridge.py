"""Run a Q-SYS plugin against real devices, without a Core.

The plugin runs in Lua 5.3 on the offline mock runtime (tests/live/bridge.lua); this script
relays its WebSocket traffic to the real device, drives the mock clock in real time, and
prints the plugin's controls at the end. Python 3 standard library only.

usage: python tests/live/bridge.py SECONDS PLUGIN IP [Prop=value ...] [@Control=value ...]
           [--at T "SET Control Field Value" | --at T "PRESS Control"] [--log]
e.g.   python tests/live/bridge.py 20 plugins/Shelly-Gen2.qplug 192.168.61.207 \
           Switches=0 Inputs=0 "Presence Zones=1" Illuminance=true
"""
import base64, os, queue, shutil, socket, struct, subprocess, sys, threading, time

def ws_connect(host, port, path):
    s = socket.create_connection((host, int(port)), timeout=5)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall((f"GET {path} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = s.recv(4096)
        if not chunk: raise IOError("closed during handshake")
        buf += chunk
    head, _, rest = buf.partition(b"\r\n\r\n")
    if b" 101" not in head.split(b"\r\n")[0]: raise IOError(head.split(b"\r\n")[0].decode())
    s.settimeout(None)
    return s, rest

def ws_send(s, data, opcode=1):
    data = data.encode() if isinstance(data, str) else data
    mask = os.urandom(4); n = len(data)
    hdr = bytes([0x80 | opcode]) + (bytes([0x80 | n]) if n < 126 else
          bytes([0x80 | 126]) + struct.pack(">H", n) if n < 65536 else bytes([0x80 | 127]) + struct.pack(">Q", n))
    s.sendall(hdr + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

def main():
    args = sys.argv[1:]
    secs, plugin, ip = float(args[0]), args[1], args[2]
    rest, actions, show_log = args[3:], [], False
    props = []
    i = 0
    while i < len(rest):
        if rest[i] == "--at": actions.append((float(rest[i + 1]), rest[i + 2])); i += 3
        elif rest[i] == "--log": show_log = True; i += 1
        else: props.append(rest[i]); i += 1
    lua = shutil.which("lua5.3") or shutil.which("lua53") or "lua"
    p = subprocess.Popen([lua, "tests/live/bridge.lua", plugin, ip] + props, stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, text=True, encoding="utf-8", bufsize=1)
    lock = threading.Lock()
    def to_lua(line):
        with lock:
            try: p.stdin.write(line.replace("\n", " ") + "\n"); p.stdin.flush()
            except (BrokenPipeError, OSError): pass
    socks = {}
    t0 = time.time()
    def stamp(): return f"{time.time() - t0:6.2f}"

    def reader(sid, s, buf):
        try:
            while True:
                while len(buf) >= 2:
                    op, ln, j = buf[0] & 0x0F, buf[1] & 0x7F, 2
                    if ln == 126: ln = struct.unpack(">H", buf[2:4])[0]; j = 4
                    elif ln == 127: ln = struct.unpack(">Q", buf[2:10])[0]; j = 10
                    if len(buf) < j + ln: break
                    payload, buf = buf[j:j + ln], buf[j + ln:]
                    if op == 1:
                        txt = payload.decode(errors="replace")
                        if show_log: print(stamp(), f"<{sid}", txt[:300], flush=True)
                        to_lua(f"DATA {sid} {txt}")
                    elif op == 9: ws_send(s, payload, 10)
                    elif op == 8: raise IOError("close frame")
                d = s.recv(65536)
                if not d: raise IOError("closed")
                buf += d
        except Exception as e:
            if sid in socks:
                del socks[sid]
                print(stamp(), f"socket {sid} closed: {e}", flush=True)
                to_lua(f"CLOSED {sid}")

    def lua_out():
        for line in p.stdout:
            line = line.rstrip("\n")
            parts = line.split(" ", 2)
            if parts[0] == "OPEN":
                sid = parts[1]; host, port, path = line.split(" ")[2:5]
                try:
                    s, buf = ws_connect(host, port, path); socks[sid] = s
                    print(stamp(), f"socket {sid} open ws://{host}:{port}{path}", flush=True)
                    to_lua(f"CONNECTED {sid}")
                    threading.Thread(target=reader, args=(sid, s, buf), daemon=True).start()
                except Exception as e:
                    print(stamp(), f"socket {sid} failed: {e}", flush=True); to_lua(f"CLOSED {sid}")
            elif parts[0] == "SEND":
                s = socks.get(parts[1])
                if show_log: print(stamp(), f">{parts[1]}", parts[2][:300], flush=True)
                if s: ws_send(s, parts[2])
            elif parts[0] == "CLOSE":
                s = socks.pop(parts[1], None)
                if s: s.close()
            elif parts[0] == "CTL": print("  " + " ".join(parts[1:]), flush=True)
            else: print(stamp(), line, flush=True)
    threading.Thread(target=lua_out, daemon=True).start()

    actions.sort()
    while time.time() - t0 < secs:
        time.sleep(0.05)
        to_lua("TICK 0.05")
        while actions and time.time() - t0 >= actions[0][0]:
            print(stamp(), "ACTION", actions[0][1], flush=True); to_lua(actions.pop(0)[1])
    print(stamp(), "--- controls ---", flush=True)
    to_lua("DUMP"); time.sleep(0.5); to_lua("QUIT")
    try: p.wait(3)
    except subprocess.TimeoutExpired: p.kill()

main()

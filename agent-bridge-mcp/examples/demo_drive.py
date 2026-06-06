#!/usr/bin/env python3
# 临时"大脑"：通过 AgentBridge(TCP 8970) 观察世界，然后在玩家附近盖几座结构。
# 这就是 opc-ourworlds 之后要做的事，只不过它由 GPT-5.5 按心跳驱动。
import socket, json, time

HOST, PORT = "127.0.0.1", 8970
sock = socket.create_connection((HOST, PORT), timeout=10)
buf = b""
_id = 0

def call(tool, args=None):
    global buf, _id
    _id += 1
    sock.sendall((json.dumps({"id": _id, "tool": tool, "args": args or {}}) + "\n").encode())
    while b"\n" not in buf:
        chunk = sock.recv(65536)
        if not chunk:
            raise RuntimeError("connection closed")
        buf += chunk
    line, buf = buf.split(b"\n", 1)
    return json.loads(line)

obs = call("observe").get("result", {})
px, py, pz = obs.get("pos", [0, 40, 0])
print("AI 观察: pos=%s region=%s time=%s selected=%s"
      % (obs.get("pos"), obs.get("region"), obs.get("time_of_day", {}).get("clock"), obs.get("selected_block")))
call("say", {"text": "我来给这片草原添点东西～"})

plan = [
    ("campfire",     px + 3, pz + 2),
    ("garden",       px - 4, pz + 3),
    ("beacon_tower", px + 7, pz - 4),
    ("bridge",       px - 2, pz - 7),
]
total = 0
for tmpl, x, z in plan:
    g = call("goto", {"x": x, "z": z}).get("result", {})
    sy = g.get("surface_y", py)
    call("say", {"text": "在 (%d,%d) 盖一个 %s" % (x, z, tmpl)})
    r = call("build", {"template": tmpl, "x": x, "y": sy + 1, "z": z, "rotation": 0})
    res = r.get("result") or r.get("error")
    changed = (r.get("result") or {}).get("changed", 0)
    total += changed
    print("  建造 %-12s @ (%d,%d,%d) -> %s" % (tmpl, x, sy + 1, z, res))
    time.sleep(0.5)

call("goto", {"x": px, "z": pz})
call("say", {"text": "搞定！一共放了 %d 块。" % total})
print("DONE total_blocks=%d" % total)
sock.close()

import socket, json, sys
s = socket.create_connection(("127.0.0.1", 8970), timeout=10)
buf = b""
def call(t, a=None):
    global buf
    s.sendall((json.dumps({"id": 1, "tool": t, "args": a or {}}) + "\n").encode())
    while b"\n" not in buf:
        buf += s.recv(65536)
    line, buf2 = buf.split(b"\n", 1)
    globals()["buf"] = buf2
    return json.loads(line)

p0 = call("observe").get("result", {}).get("pos")
print("AI 初始位置(应在出生点旁):", p0)
g = call("goto", {"x": 70, "z": 70}).get("result", {})
print("goto(70,70) ->", g)
p1 = call("observe").get("result", {}).get("pos")
print("goto 后 AI 位置(应≈70,_,70):", p1)
y = int(g.get("surface_y", 40)) + 1
b = call("build", {"template": "beacon_tower", "x": 70, "y": y, "z": 70}).get("result", {})
print("build ->", b)
ok = p1 and abs(p1[0] - 70) <= 2 and abs(p1[2] - 70) <= 2 and b.get("changed", 0) > 0
print("VERIFY", "PASS ✅ (AI 小人被驱动、建造成功)" if ok else "FAIL ❌")
sys.exit(0 if ok else 1)

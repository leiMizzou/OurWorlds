import os, socket, json, subprocess
# 你本地 openclaw.mjs 的路径（用 OPENCLAW_MJS 环境变量覆盖；默认假设在 ~/.openclaw 下）
OC = os.environ.get("OPENCLAW_MJS", os.path.expanduser("~/.openclaw/openclaw.mjs"))
s = socket.create_connection(("127.0.0.1", 8970), timeout=10)
s.sendall(b'{"id":1,"tool":"observe","args":{}}\n')
buf = b""
while b"\n" not in buf:
    buf += s.recv(65536)
obs = json.loads(buf.split(b"\n")[0])["result"]
msg = ("WORLD:\n" + json.dumps(obs, ensure_ascii=False)
       + "\nMEMORY:\n{}\nReply with your JSON action array now (JSON only, no prose).")
import time as _t
num = "+1555" + str(int(_t.time()) % 10000000).zfill(7)
p = subprocess.run(["node", OC, "agent", "--agent", "opc-ourworlds", "--model", "codex/gpt-5.4-mini",
                    "--to", num, "--message", msg, "--timeout", "120"],
                   capture_output=True, text=True, timeout=150)
print("===== RAW STDOUT (前 3500 字) =====")
print(p.stdout[:3500])
print("===== STDERR 尾 =====")
print(p.stderr[-400:])

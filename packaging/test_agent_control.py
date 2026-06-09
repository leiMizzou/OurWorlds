#!/usr/bin/env python3
# Agent Control Panel 自检（standalone）—— 完全不触碰真实服务。
#   - 把 serve_web.subprocess.run 换成桩：记录 argv、永不真正 launchctl 任何东西。
#   - 发现目录指向临时目录里的假 plist（含一个必须被排除的 play-server 诱饵）。
#   - 覆盖：admin 关闭 -> 503；缺/错 token -> 403；GET /api/agents 只列 resident-*；
#           start/stop/kick 拼出正确 argv 且仅接受白名单 label；
#           注入式 / 非 resident label -> 404 且绝不触达 subprocess。
# 用法: python3 packaging/test_agent_control.py    （PASS/FAIL，失败 exit 非 0）
import importlib
import json
import os
import socket
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from urllib.parse import quote

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

_fails = []
_oks = 0


def check(cond, msg):
    global _oks
    if cond:
        _oks += 1
        print("  ok   " + msg)
    else:
        _fails.append(msg)
        print("  FAIL " + msg)


def _free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def _req(method, url, headers=None, body=None):
    data = None
    h = dict(headers or {})
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        h.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(url, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            raw = r.read().decode("utf-8")
            try:
                return r.status, json.loads(raw)
            except Exception:
                return r.status, {"_raw": raw}
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8")
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"_raw": raw}


# ---- 一个假的 CompletedProcess + 可记录调用的 subprocess.run 桩 ----
class _FakeCP:
    def __init__(self, returncode=0, stdout="", stderr=""):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


class _SubprocessStub:
    """记录每次 launchctl argv；对 print 返回可配置状态，对动作返回 rc=0。"""

    def __init__(self):
        self.calls = []
        self.running_labels = set()   # 这些 label 的 print 会带 pid（=运行中）

    def run(self, argv, capture_output=False, text=False, timeout=None):
        # 安全断言：永远是 argv 列表、第一个永远是 launchctl、绝无 shell。
        assert isinstance(argv, list), "subprocess.run must get an argv LIST, got %r" % type(argv)
        assert argv and argv[0] == "launchctl", "first arg must be launchctl, got %r" % (argv[:1])
        self.calls.append(list(argv))
        sub = argv[1] if len(argv) > 1 else ""
        if sub == "print":
            target = argv[2] if len(argv) > 2 else ""
            label = target.rsplit("/", 1)[-1]
            if label in self.running_labels:
                return _FakeCP(0, "\tstate = running\n\tpid = 4242\n", "")
            # 默认：当作"未加载"（rc!=0），模拟停止态。
            return _FakeCP(1, "", "Could not find service.")
        # bootstrap / bootout / kickstart：装作成功。
        return _FakeCP(0, "", "")


def _make_fake_launchagents(d):
    """在 d 里造两个真 resident plist + 一个必须被排除的 play-server 诱饵 + 一个 .bak。"""
    def w(name):
        with open(os.path.join(d, name), "w") as f:
            f.write("<?xml version='1.0'?><plist><dict/></plist>\n")
    w("app.ourworlds.resident-codexbot.plist")
    w("app.ourworlds.resident-gardenbot.plist")
    w("app.ourworlds.play-server.plist")               # 诱饵：核心服务，绝不可出现/被操作
    w("app.ourworlds.resident-old.plist.bak-20260101")  # .bak：不匹配 glob


def main():
    tmp = tempfile.mkdtemp(prefix="ow_agentctl_test_")
    la_dir = os.path.join(tmp, "LaunchAgents")
    os.makedirs(la_dir)
    _make_fake_launchagents(la_dir)

    FAKE_UID = "501"

    # ---------- 阶段 A：admin 关闭（无 OW_ADMIN_TOKEN）-> 全部 503 ----------
    os.environ.pop("OW_ADMIN_TOKEN", None)
    os.environ["OW_LAUNCHAGENTS_DIR"] = la_dir
    os.environ["OW_LAUNCHCTL_UID"] = FAKE_UID
    # 限频窗口给足，避免误判 429。
    os.environ["OW_PORTAL_RATE_MAX"] = "1000"
    os.environ["OW_PORTAL_RATE_WINDOW"] = "600"

    import serve_web
    importlib.reload(serve_web)
    stub = _SubprocessStub()
    serve_web.subprocess.run = stub.run   # 关键：彻底拦截，绝不触碰真实 launchctl

    # 单元层先验证发现集合：只含两个 resident，诱饵/.bak 不在内。
    disc = serve_web._discover_residents()
    check(set(os.path.basename(p) for p in disc.values()) ==
          {"app.ourworlds.resident-codexbot.plist", "app.ourworlds.resident-gardenbot.plist"},
          "discovery lists only resident-* plists (decoy play-server + .bak excluded)")
    check("app.ourworlds.play-server" not in disc, "core service NOT in controllable set")

    port = _free_port()
    httpd = serve_web._ReusableTCPServer(("127.0.0.1", port), serve_web.CrossOriginIsolatedHandler)
    th = threading.Thread(target=httpd.serve_forever, daemon=True)
    th.start()
    for _ in range(50):
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                break
        except OSError:
            time.sleep(0.05)
    base = "http://127.0.0.1:%d" % port
    try:
        code, body = _req("GET", base + "/api/agents")
        check(code == 503 and body.get("error") == "admin disabled",
              "admin disabled (no token) -> GET /api/agents 503")
        code, body = _req("POST", base + "/api/agents/app.ourworlds.resident-codexbot/start", body={})
        check(code == 503 and body.get("error") == "admin disabled",
              "admin disabled -> POST start 503")
        check(len(stub.calls) == 0, "admin-disabled path never reached subprocess")
    finally:
        httpd.shutdown(); httpd.server_close()

    # ---------- 阶段 B：admin 开启 ----------
    ADMIN = "s3cr3t-admin"
    os.environ["OW_ADMIN_TOKEN"] = ADMIN
    importlib.reload(serve_web)
    stub = _SubprocessStub()
    serve_web.subprocess.run = stub.run

    port = _free_port()
    httpd = serve_web._ReusableTCPServer(("127.0.0.1", port), serve_web.CrossOriginIsolatedHandler)
    th = threading.Thread(target=httpd.serve_forever, daemon=True)
    th.start()
    for _ in range(50):
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                break
        except OSError:
            time.sleep(0.05)
    base = "http://127.0.0.1:%d" % port
    try:
        # 缺 token -> 403
        code, body = _req("GET", base + "/api/agents")
        check(code == 403 and body.get("error") == "forbidden", "missing token -> 403 forbidden")
        # 错 token -> 403
        code, body = _req("GET", base + "/api/agents", headers={"X-OW-Admin": "wrong"})
        check(code == 403 and body.get("error") == "forbidden", "wrong token -> 403 forbidden")
        check(len(stub.calls) == 0, "auth failures never reached subprocess")

        H = {"X-OW-Admin": ADMIN}

        # GET /api/agents：只列 resident，name 去前缀，状态来自 print。
        stub.running_labels = {"app.ourworlds.resident-codexbot"}  # codexbot 在跑，gardenbot 停
        code, body = _req("GET", base + "/api/agents", headers=H)
        agents = body.get("agents", [])
        labels = sorted(a["label"] for a in agents)
        check(code == 200 and labels ==
              ["app.ourworlds.resident-codexbot", "app.ourworlds.resident-gardenbot"],
              "GET /api/agents lists exactly the two resident labels")
        names = sorted(a["name"] for a in agents)
        check(names == ["codexbot", "gardenbot"], "name = label minus resident- prefix")
        by = {a["label"]: a for a in agents}
        check(by["app.ourworlds.resident-codexbot"]["running"] is True and
              by["app.ourworlds.resident-codexbot"]["loaded"] is True,
              "codexbot reported running (pid in print)")
        check(by["app.ourworlds.resident-gardenbot"]["running"] is False and
              by["app.ourworlds.resident-gardenbot"]["loaded"] is False,
              "gardenbot reported stopped (print rc!=0)")
        check(all(a["label"] != "app.ourworlds.play-server" for a in agents),
              "play-server never appears in /api/agents")

        # ---- start：正确 argv = bootstrap gui/<uid> <plist> ----
        stub.calls.clear()
        plist = os.path.join(la_dir, "app.ourworlds.resident-gardenbot.plist")
        code, body = _req("POST", base + "/api/agents/app.ourworlds.resident-gardenbot/start",
                          headers=H, body={})
        action_calls = [c for c in stub.calls if c[1] == "bootstrap"]
        check(code == 200 and body.get("ok") is True, "start -> 200 ok")
        check(action_calls and action_calls[0] == ["launchctl", "bootstrap", "gui/501", plist],
              "start builds argv: launchctl bootstrap gui/501 <plist>")

        # ---- stop：正确 argv = bootout gui/<uid>/<label> ----
        stub.calls.clear()
        code, body = _req("POST", base + "/api/agents/app.ourworlds.resident-codexbot/stop",
                          headers=H, body={})
        boot = [c for c in stub.calls if c[1] == "bootout"]
        check(code == 200 and body.get("ok") is True, "stop -> 200 ok")
        check(boot and boot[0] == ["launchctl", "bootout", "gui/501/app.ourworlds.resident-codexbot"],
              "stop builds argv: launchctl bootout gui/501/<label>")

        # ---- kick：正确 argv = kickstart -k gui/<uid>/<label> ----
        stub.calls.clear()
        code, body = _req("POST", base + "/api/agents/app.ourworlds.resident-gardenbot/kick",
                          headers=H, body={})
        ks = [c for c in stub.calls if c[1] == "kickstart"]
        check(code == 200 and body.get("ok") is True, "kick -> 200 ok")
        check(ks and ks[0] == ["launchctl", "kickstart", "-k", "gui/501/app.ourworlds.resident-gardenbot"],
              "kick builds argv: launchctl kickstart -k gui/501/<label>")

        # ---- token 也可来自 body（无 header） ----
        stub.calls.clear()
        code, body = _req("POST", base + "/api/agents/app.ourworlds.resident-gardenbot/stop",
                          body={"token": ADMIN})
        check(code == 200 and body.get("ok") is True, "admin token accepted via JSON body too")

        # ---- 白名单/注入：以下都必须 404 且绝不触达 subprocess ----
        for bad, why in [
            ("app.ourworlds.play-server", "core service label"),
            ("app.ourworlds.play-web", "core service label"),
            ("app.ourworlds.resident-nope", "resident-shaped but no such plist"),
            ("resident-x", "missing app.ourworlds. prefix"),
            ("app.ourworlds.resident-x;rm -rf", "injection chars"),
            ("app.ourworlds.resident-UPPER", "uppercase not allowed by regex"),
        ]:
            stub.calls.clear()
            # 用 path 段（已 quote）打 start
            code, body = _req("POST", base + "/api/agents/" + quote(bad, safe="") + "/start",
                              headers=H, body={})
            ok = (code == 404 and body.get("error") == "unknown agent" and len(stub.calls) == 0)
            check(ok, "reject non-whitelisted label (%s) -> 404, no subprocess" % why)

        # 路径穿越式：/api/agents/../../etc/start —— 经 URL 规范化后不应命中动作路由（404，无 subprocess）。
        stub.calls.clear()
        code, body = _req("POST", base + "/api/agents/..%2F..%2Fetc/start", headers=H, body={})
        check(code == 404 and len(stub.calls) == 0,
              "path-traversal-ish label -> 404, no subprocess")

        # 未知动作 verb -> 不匹配动作路由 -> 404
        stub.calls.clear()
        code, body = _req("POST", base + "/api/agents/app.ourworlds.resident-codexbot/nuke",
                          headers=H, body={})
        check(code == 404 and len(stub.calls) == 0, "unknown action verb -> 404, no subprocess")

        # ---- 页面可服务 ----
        code, body = _req("GET", base + "/agents")
        raw = body.get("_raw", "")
        check(code == 200 and "<!DOCTYPE html>" in raw and "OurWorlds" in raw,
              "/agents serves the control-panel HTML (no auth needed for the page)")
    finally:
        httpd.shutdown(); httpd.server_close()

    # ---------- 汇总 ----------
    print("-" * 40)
    if _fails:
        print("RESULT: FAIL  (%d ok, %d failed)" % (_oks, len(_fails)))
        for m in _fails:
            print("  - " + m)
        sys.exit(1)
    print("RESULT: PASS  (%d checks)" % _oks)
    sys.exit(0)


if __name__ == "__main__":
    main()

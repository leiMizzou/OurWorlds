#!/usr/bin/env python3
# Agent Control Panel 自检（standalone）—— 完全不触碰真实服务。
#   - 把 serve_web.subprocess.run 换成桩：记录 argv、永不真正 launchctl 任何东西。
#   - 发现目录指向临时目录里的假 plist（含一个必须被排除的 play-server 诱饵）。
#   - 任务/日志/配置目录也指向临时目录（OW_RESIDENT_TASK_DIR / OW_RESIDENT_LOG_DIR /
#     OW_RESIDENT_CONFIG_DIR）。
#   - 覆盖（v1）：admin 关闭 -> 503；缺/错 token -> 403；GET /api/agents 只列 resident-*；
#           start/stop/kick 拼出正确 argv 且仅接受白名单 label；
#           注入式 / 非 resident label -> 404 且绝不触达 subprocess。
#   - 覆盖（v2）：/api/agents 含 interval；/log 行数钳制 + 缺失=空；/task GET/写回 +
#           >8192B=413 + 非 resident label 不写文件；/config 可读默认值、可保存 persona/
#           runtime/avatar/goal；interval 校验 + ThrottleInterval 真改 + 重载是 argv；
#           stop-all/start-all 只动发现集合（play-server 诱饵不被触碰）；
#           所有新端点 admin 关闭=503、错 token=403。
# 用法: python3 packaging/test_agent_control.py    （PASS/FAIL，失败 exit 非 0）
import importlib
import json
import os
import plistlib
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
    """在 d 里造两个真 resident plist（含 ThrottleInterval）+ 一个必须被排除的
    play-server 诱饵 + 一个 .bak。resident plist 用真 plistlib 写，便于 /config 往返校验。"""
    def w_resident(name, interval):
        data = {
            "Label": "app.ourworlds.resident-%s" % name,
            "ProgramArguments": ["/bin/sh", "/tmp/resident-%s.sh" % name],
            "RunAtLoad": True,
            "KeepAlive": True,
            "ThrottleInterval": interval,
        }
        with open(os.path.join(d, "app.ourworlds.resident-%s.plist" % name), "wb") as f:
            plistlib.dump(data, f)
    w_resident("codexbot", 240)
    w_resident("gardenbot", 300)
    # 诱饵：核心服务，绝不可出现/被操作。用真 plistlib 写（含 ThrottleInterval 作哨兵）。
    with open(os.path.join(d, "app.ourworlds.play-server.plist"), "wb") as f:
        plistlib.dump({"Label": "app.ourworlds.play-server", "ThrottleInterval": 10}, f)
    # .bak：不匹配 glob。
    with open(os.path.join(d, "app.ourworlds.resident-old.plist.bak-20260101"), "w") as f:
        f.write("<?xml version='1.0'?><plist><dict/></plist>\n")


def main():
    tmp = tempfile.mkdtemp(prefix="ow_agentctl_test_")
    la_dir = os.path.join(tmp, "LaunchAgents")
    task_dir = os.path.join(tmp, "tasks")
    log_dir = os.path.join(tmp, "logs")
    config_dir = os.path.join(tmp, "configs")
    os.makedirs(la_dir)
    os.makedirs(task_dir)
    os.makedirs(log_dir)
    os.makedirs(config_dir)
    _make_fake_launchagents(la_dir)

    FAKE_UID = "501"

    # ---------- 阶段 A：admin 关闭（无 OW_ADMIN_TOKEN）-> 全部 503 ----------
    os.environ.pop("OW_ADMIN_TOKEN", None)
    os.environ["OW_LAUNCHAGENTS_DIR"] = la_dir
    os.environ["OW_LAUNCHCTL_UID"] = FAKE_UID
    os.environ["OW_RESIDENT_TASK_DIR"] = task_dir
    os.environ["OW_RESIDENT_LOG_DIR"] = log_dir
    os.environ["OW_RESIDENT_CONFIG_DIR"] = config_dir
    # 限频窗口给足，避免误判 429。
    os.environ["OW_PORTAL_RATE_MAX"] = "1000"
    os.environ["OW_ADMIN_RATE_MAX"] = "1000"
    os.environ["OW_PORTAL_RATE_WINDOW"] = "600"
    os.environ["OW_ADMIN_RATE_WINDOW"] = "600"

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
        # v2 端点在 admin 关闭时也必须 503。
        code, body = _req("GET", base + "/api/agents/app.ourworlds.resident-codexbot/log")
        check(code == 503 and body.get("error") == "admin disabled", "admin disabled -> GET /log 503")
        code, body = _req("GET", base + "/api/agents/app.ourworlds.resident-codexbot/task")
        check(code == 503 and body.get("error") == "admin disabled", "admin disabled -> GET /task 503")
        code, body = _req("GET", base + "/api/agents/app.ourworlds.resident-codexbot/config")
        check(code == 503 and body.get("error") == "admin disabled", "admin disabled -> GET /config 503")
        code, body = _req("POST", base + "/api/agents/app.ourworlds.resident-codexbot/task",
                          body={"text": "x"})
        check(code == 503 and body.get("error") == "admin disabled", "admin disabled -> POST /task 503")
        code, body = _req("POST", base + "/api/agents/app.ourworlds.resident-codexbot/config",
                          body={"interval": 240})
        check(code == 503 and body.get("error") == "admin disabled", "admin disabled -> POST /config 503")
        code, body = _req("POST", base + "/api/agents/stop-all", body={})
        check(code == 503 and body.get("error") == "admin disabled", "admin disabled -> stop-all 503")
        code, body = _req("POST", base + "/api/agents/start-all", body={})
        check(code == 503 and body.get("error") == "admin disabled", "admin disabled -> start-all 503")
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
        # v2 端点错 token 也必须 403。
        W = {"X-OW-Admin": "wrong"}
        code, _ = _req("GET", base + "/api/agents/app.ourworlds.resident-codexbot/log", headers=W)
        check(code == 403, "wrong token -> GET /log 403")
        code, _ = _req("GET", base + "/api/agents/app.ourworlds.resident-codexbot/task", headers=W)
        check(code == 403, "wrong token -> GET /task 403")
        code, _ = _req("GET", base + "/api/agents/app.ourworlds.resident-codexbot/config", headers=W)
        check(code == 403, "wrong token -> GET /config 403")
        code, _ = _req("POST", base + "/api/agents/app.ourworlds.resident-codexbot/task",
                       headers=W, body={"text": "x"})
        check(code == 403, "wrong token -> POST /task 403")
        code, _ = _req("POST", base + "/api/agents/app.ourworlds.resident-codexbot/config",
                       headers=W, body={"interval": 240})
        check(code == 403, "wrong token -> POST /config 403")
        code, _ = _req("POST", base + "/api/agents/stop-all", headers=W, body={})
        check(code == 403, "wrong token -> stop-all 403")
        code, _ = _req("POST", base + "/api/agents/start-all", headers=W, body={})
        check(code == 403, "wrong token -> start-all 403")
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
        # v2：/api/agents 应带每个 agent 的 ThrottleInterval（来自 plist）。
        check(by["app.ourworlds.resident-codexbot"].get("interval") == 240 and
              by["app.ourworlds.resident-gardenbot"].get("interval") == 300,
              "GET /api/agents includes interval (ThrottleInterval) per agent")
        check(by["app.ourworlds.resident-codexbot"].get("display_name") == "codexbot" and
              by["app.ourworlds.resident-codexbot"].get("runtime") == "codex" and
              by["app.ourworlds.resident-codexbot"].get("mode") == "explore",
              "GET /api/agents includes default resident config summary")

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

        # ================= v2：log / task / config / stop-all / start-all =================

        # ---- GET /log：缺失日志 -> {"lines":[]} ----
        code, body = _req("GET", base + "/api/agents/app.ourworlds.resident-codexbot/log", headers=H)
        check(code == 200 and body.get("lines") == [], "missing log -> {lines: []}")

        # 造一个 100 行的日志，验证默认 40 行 + ?lines=N 钳制（1..200）。
        log_path = os.path.join(log_dir, "resident-codexbot.log")
        with open(log_path, "w", encoding="utf-8") as f:
            for i in range(1, 101):
                f.write("line-%03d\n" % i)
        code, body = _req("GET", base + "/api/agents/app.ourworlds.resident-codexbot/log", headers=H)
        lines = body.get("lines", [])
        check(code == 200 and len(lines) == 40 and lines[0] == "line-061" and lines[-1] == "line-100",
              "GET /log default = last 40 lines")
        code, body = _req("GET", base + "/api/agents/app.ourworlds.resident-codexbot/log?lines=5", headers=H)
        check(body.get("lines") == ["line-096", "line-097", "line-098", "line-099", "line-100"],
              "GET /log?lines=5 -> last 5 lines")
        code, body = _req("GET", base + "/api/agents/app.ourworlds.resident-codexbot/log?lines=999", headers=H)
        check(len(body.get("lines", [])) == 100, "GET /log?lines=999 clamps to <=200 (all 100 here)")
        code, body = _req("GET", base + "/api/agents/app.ourworlds.resident-codexbot/log?lines=0", headers=H)
        check(len(body.get("lines", [])) == 1, "GET /log?lines=0 clamps up to 1")

        # ---- GET /task：缺失 -> 空串 ----
        code, body = _req("GET", base + "/api/agents/app.ourworlds.resident-gardenbot/task", headers=H)
        check(code == 200 and body.get("text") == "", "missing task file -> empty string")

        # ---- POST /task 写入 + GET 往返 ----
        msg = "今天去河边盖一座桥 / build a bridge by the river"
        code, body = _req("POST", base + "/api/agents/app.ourworlds.resident-gardenbot/task",
                          headers=H, body={"text": msg})
        check(code == 200 and body.get("ok") is True and body.get("bytes") == len(msg.encode("utf-8")),
              "POST /task -> ok + byte count")
        task_path = os.path.join(task_dir, "resident-gardenbot-task.txt")
        check(os.path.isfile(task_path) and open(task_path, encoding="utf-8").read() == msg,
              "task file actually written with exact text")
        code, body = _req("GET", base + "/api/agents/app.ourworlds.resident-gardenbot/task", headers=H)
        check(code == 200 and body.get("text") == msg, "GET /task round-trips the written text")

        # ---- POST /task 超 8192 字节 -> 413（且不覆盖既有文件）----
        big = "x" * 8193
        code, body = _req("POST", base + "/api/agents/app.ourworlds.resident-gardenbot/task",
                          headers=H, body={"text": big})
        check(code == 413, "POST /task > 8192 bytes -> 413")
        check(open(task_path, encoding="utf-8").read() == msg, "413 did not overwrite the task file")
        # 恰好 8192 字节应被接受（边界）。
        exact = "y" * 8192
        code, body = _req("POST", base + "/api/agents/app.ourworlds.resident-gardenbot/task",
                          headers=H, body={"text": exact})
        check(code == 200 and body.get("bytes") == 8192, "POST /task exactly 8192 bytes -> 200")

        # ---- 非 resident / 注入 label 对 /task GET+POST 必须 404 且绝不落盘 ----
        before = set(os.listdir(task_dir))
        for bad in ["app.ourworlds.play-server", "app.ourworlds.resident-nope",
                    "app.ourworlds.resident-x;rm -rf", "..%2F..%2Fetc"]:
            code, _ = _req("GET", base + "/api/agents/" + quote(bad, safe="") + "/task", headers=H)
            ok_get = (code == 404)
            code, _ = _req("POST", base + "/api/agents/" + quote(bad, safe="") + "/task",
                           headers=H, body={"text": "should-never-write"})
            ok_post = (code == 404)
            check(ok_get and ok_post, "non-whitelisted label (%s) -> /task 404" % bad)
        check(set(os.listdir(task_dir)) == before, "rejected /task labels wrote NO file")

        # ---- GET /config：缺失配置文件 -> 默认配置（interval 来自 plist）----
        code, body = _req("GET", base + "/api/agents/app.ourworlds.resident-gardenbot/config", headers=H)
        cfg = body.get("config", {})
        check(code == 200 and cfg.get("display_name") == "gardenbot" and
              cfg.get("runtime") == "codex" and cfg.get("mode") == "explore" and
              cfg.get("interval") == 300,
              "GET /config missing file -> defaults + plist interval")

        # ---- POST /config：保存完整配置；不含 interval 时不 reload ----
        stub.calls.clear()
        saved_cfg = {
            "display_name": "Garden Keeper",
            "runtime": "codex",
            "mode": "build",
            "model": "gpt-5",
            "avatar": "builder",
            "color": "#7ee0a0",
            "goal": "Build a bridge by the river.",
            "persona": "Keep the garden paths tidy and report progress.",
        }
        code, body = _req("POST", base + "/api/agents/app.ourworlds.resident-gardenbot/config",
                          headers=H, body=saved_cfg)
        cfg = body.get("config", {})
        check(code == 200 and body.get("ok") is True and body.get("reloaded") is False,
              "POST /config without interval -> saves config without launchctl reload")
        check(cfg.get("display_name") == "Garden Keeper" and cfg.get("mode") == "build" and
              cfg.get("goal") == "Build a bridge by the river.",
              "POST /config echoes saved fields")
        check(len([c for c in stub.calls if c[1] in ("bootout", "bootstrap")]) == 0,
              "POST /config without interval did not touch launchctl")
        cfg_path = os.path.join(config_dir, "gardenbot.json")
        with open(cfg_path, "r", encoding="utf-8") as f:
            on_disk_cfg = json.load(f)
        check(on_disk_cfg.get("display_name") == "Garden Keeper" and
              on_disk_cfg.get("persona") == "Keep the garden paths tidy and report progress.",
              "POST /config wrote the resident JSON file")
        code, body = _req("GET", base + "/api/agents/app.ourworlds.resident-gardenbot/config", headers=H)
        cfg = body.get("config", {})
        check(code == 200 and cfg.get("display_name") == "Garden Keeper" and
              cfg.get("avatar") == "builder" and cfg.get("color") == "#7ee0a0",
              "GET /config round-trips saved config")
        code, body = _req("GET", base + "/api/agents", headers=H)
        by = {a["label"]: a for a in body.get("agents", [])}
        check(by["app.ourworlds.resident-gardenbot"].get("display_name") == "Garden Keeper" and
              by["app.ourworlds.resident-gardenbot"].get("mode") == "build",
              "GET /api/agents reflects saved config summary")

        # ---- POST /config：类型/格式校验 ----
        code, body = _req("POST", base + "/api/agents/app.ourworlds.resident-gardenbot/config",
                          headers=H, body={"color": "green"})
        check(code == 400, "config invalid color -> 400")
        code, body = _req("POST", base + "/api/agents/app.ourworlds.resident-gardenbot/config",
                          headers=H, body={"display_name": 123})
        check(code == 400, "config non-string display_name -> 400")

        # ---- POST /config：interval 校验（拒 5、拒 999999、收 240）----
        stub.calls.clear()
        code, body = _req("POST", base + "/api/agents/app.ourworlds.resident-codexbot/config",
                          headers=H, body={"interval": 5})
        check(code == 400 and len(stub.calls) == 0, "config interval 5 -> 400, no reload")
        code, body = _req("POST", base + "/api/agents/app.ourworlds.resident-codexbot/config",
                          headers=H, body={"interval": 999999})
        check(code == 400 and len(stub.calls) == 0, "config interval 999999 -> 400, no reload")
        code, body = _req("POST", base + "/api/agents/app.ourworlds.resident-codexbot/config",
                          headers=H, body={"interval": True})
        check(code == 400, "config interval bool -> 400 (bool is not a valid int)")

        # accept 240（codexbot 此前是 240，改成 600 以证明真的变了）----
        stub.calls.clear()
        code, body = _req("POST", base + "/api/agents/app.ourworlds.resident-codexbot/config",
                          headers=H, body={"interval": 600})
        check(code == 200 and body.get("ok") is True and body.get("interval") == 600,
              "config interval 600 -> 200 ok")
        # plist 里 ThrottleInterval 真的变成 600（用真 plistlib 读回）。
        codex_plist = os.path.join(la_dir, "app.ourworlds.resident-codexbot.plist")
        with open(codex_plist, "rb") as f:
            reloaded = plistlib.load(f)
        check(reloaded.get("ThrottleInterval") == 600,
              "config actually rewrote ThrottleInterval in the plist (240 -> 600)")
        check(reloaded.get("Label") == "app.ourworlds.resident-codexbot" and reloaded.get("KeepAlive") is True,
              "config preserved other plist keys")
        # 重载是 argv：bootout 然后 bootstrap（顺序）。
        boot_calls = [c for c in stub.calls if c[1] in ("bootout", "bootstrap")]
        check(boot_calls[:2] == [
                  ["launchctl", "bootout", "gui/501/app.ourworlds.resident-codexbot"],
                  ["launchctl", "bootstrap", "gui/501", codex_plist]],
              "config reload is argv: bootout then bootstrap (no shell)")

        # config 对非 resident label -> 404 且不改任何 plist / 不 reload。
        stub.calls.clear()
        play_plist = os.path.join(la_dir, "app.ourworlds.play-server.plist")
        with open(play_plist, "rb") as f:
            play_before = plistlib.load(f)
        code, body = _req("POST", base + "/api/agents/app.ourworlds.play-server/config",
                          headers=H, body={"interval": 240})
        check(code == 404 and len(stub.calls) == 0, "config on core service -> 404, no reload")
        with open(play_plist, "rb") as f:
            check(plistlib.load(f) == play_before, "config 404 did NOT touch play-server.plist")

        # ---- stop-all：只对发现集合 bootout；play-server 诱饵绝不出现 ----
        stub.calls.clear()
        code, body = _req("POST", base + "/api/agents/stop-all", headers=H, body={})
        targets = [c[2].rsplit("/", 1)[-1] for c in stub.calls if c[1] == "bootout"]
        check(code == 200 and body.get("ok") is True, "stop-all -> 200 ok")
        check(sorted(targets) == ["app.ourworlds.resident-codexbot", "app.ourworlds.resident-gardenbot"],
              "stop-all booted out exactly the two residents")
        check(all("play-server" not in c[2] for c in stub.calls), "stop-all NEVER touched play-server decoy")
        res_labels = sorted(r["label"] for r in body.get("results", []))
        check(res_labels == ["app.ourworlds.resident-codexbot", "app.ourworlds.resident-gardenbot"],
              "stop-all results cover only the two residents")

        # ---- start-all：只对发现集合 bootstrap <plist>；诱饵绝不出现 ----
        stub.calls.clear()
        code, body = _req("POST", base + "/api/agents/start-all", headers=H, body={})
        bs = [c for c in stub.calls if c[1] == "bootstrap"]
        # argv = [launchctl, bootstrap, gui/<uid>, <plist>] —— plist 在索引 3。
        bs_plists = sorted(c[3] for c in bs)
        check(code == 200 and body.get("ok") is True, "start-all -> 200 ok")
        check(bs_plists == sorted([
                  os.path.join(la_dir, "app.ourworlds.resident-codexbot.plist"),
                  os.path.join(la_dir, "app.ourworlds.resident-gardenbot.plist")]),
              "start-all bootstrapped exactly the two resident plists")
        check(all("play-server" not in " ".join(c) for c in stub.calls), "start-all NEVER touched play-server decoy")

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

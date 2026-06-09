#!/usr/bin/env python3
# 本地起一个带 COOP/COEP 头的静态服务器，供 Godot Web(WASM, 多线程) 在浏览器里跑。
# 多线程 Web 需要 SharedArrayBuffer，浏览器要求这两个跨源隔离响应头才放行。
#   python3 packaging/serve_web.py [port]      # 然后浏览器打开 http://localhost:8060/
#
# 此外还托管 Agent Onboarding Portal（门户）：
#   GET  /onboard               -> web/portal/onboard.html
#   GET  /install-agent.sh      -> web/portal/install-agent.sh   （curl … | sh 一行装桥）
#   GET  /ourworlds-agent.mjs   -> web/portal/ourworlds-agent.mjs（打包好的单文件桥）
#   POST /api/agent-token       -> 邀请码门控 + 限频，签发 ow_* token 并写入 OW_AGENT_TOKEN_FILE
#
# 以及 Agent Control Panel（管理面板，需独立 admin token）：
#   GET  /agents                          -> web/portal/agents.html（启停常驻 agent 的页面）
#   GET  /api/agents                      -> 列出常驻 agent（由 plist 发现）及其状态
#   POST /api/agents/<label>/start        -> launchctl bootstrap gui/<uid> <plist>
#   POST /api/agents/<label>/stop         -> launchctl bootout   gui/<uid>/<label>
#   POST /api/agents/<label>/kick         -> launchctl kickstart -k gui/<uid>/<label>（立刻跑一班）
# 端点配置（环境变量）：
#   OW_PORTAL_GATE        必填的邀请码（未设/为空 => 签发功能关闭，503）
#   OW_AGENT_TOKEN_FILE   token JSON 文件路径（未设/为空 => 签发功能关闭，503）
#   OW_ADMIN_TOKEN        管理面板 token（与邀请码分开；未设/为空 => 管理 API 全部关闭，503）
#   OW_LAUNCHAGENTS_DIR   plist 发现目录（默认 ~/Library/LaunchAgents；仅供测试覆盖）
#   OW_LAUNCHCTL_UID      launchctl 域 uid（默认 os.getuid()；仅供测试覆盖）
# 其余一切仍是 build/web 的静态文件服务，未改动。
import glob
import http.server
import json
import os
import re
import secrets
import socketserver
import subprocess
import sys
import threading
import time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8060
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
WEB_DIR = os.path.normpath(os.path.join(BASE_DIR, "..", "build", "web"))
PORTAL_DIR = os.path.normpath(os.path.join(BASE_DIR, "..", "web", "portal"))

# ---- 限频：每个客户端 IP 在窗口内最多签发 N 个 token ----
RATE_MAX = int(os.environ.get("OW_PORTAL_RATE_MAX", "5"))          # 每 IP 每窗口最多签发数
RATE_WINDOW_SEC = int(os.environ.get("OW_PORTAL_RATE_WINDOW", "600"))  # 窗口长度（秒），默认 10 分钟
LABEL_MAX = 40

# token 文件读改写需串行（ThreadingTCPServer 并发）；限频表同锁保护。
_FILE_LOCK = threading.Lock()
_RATE_HITS = {}   # ip -> [unix_ts, ...]（窗口内的签发时刻）


def _gate() -> str:
    return os.environ.get("OW_PORTAL_GATE", "") or ""


def _token_file() -> str:
    return os.environ.get("OW_AGENT_TOKEN_FILE", "") or ""


def _issuance_enabled() -> bool:
    # 仅当运营者同时配置了邀请码与 token 文件路径时才开启自助签发。
    return _gate().strip() != "" and _token_file().strip() != ""


def _sanitize_label(label) -> str:
    s = "" if label is None else str(label)
    s = s.strip()
    if len(s) > LABEL_MAX:
        s = s[:LABEL_MAX].strip()
    return s or "agent"


def issue_token(label, token_file: str = None) -> str:
    """铸造一个 ow_<hex> token，把记录追加进 token 文件（JSON），返回 token。

    读改写在 _FILE_LOCK 下串行；文件/父目录不存在则创建；保留既有 token；
    既有文件畸形则以空集合重写（不抛栈给调用方）。可不经 HTTP 直接单测。
    """
    path = token_file if token_file is not None else _token_file()
    if not path:
        raise ValueError("no token file configured")
    label = _sanitize_label(label)
    token = "ow_" + secrets.token_hex(20)
    record = {"token": token, "label": label, "issued_at": int(time.time())}
    with _FILE_LOCK:
        data = {"version": 1, "tokens": []}
        if os.path.isfile(path):
            try:
                with open(path, "r", encoding="utf-8") as f:
                    existing = json.load(f)
                if isinstance(existing, dict) and isinstance(existing.get("tokens"), list):
                    data = existing
                    data.setdefault("version", 1)
            except Exception:
                # 畸形/不可读：从干净结构重新开始（不丢失新签发的 token）。
                data = {"version": 1, "tokens": []}
        parent = os.path.dirname(os.path.abspath(path))
        if parent and not os.path.isdir(parent):
            os.makedirs(parent, exist_ok=True)
        data["tokens"].append(record)
        # 原子写：先写临时文件再 rename，避免并发读到半截 JSON。
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    return token


def _rate_limited(ip: str) -> bool:
    """记录一次来自 ip 的尝试；若窗口内已超额返回 True（且不计入本次）。"""
    now = time.time()
    cutoff = now - RATE_WINDOW_SEC
    with _FILE_LOCK:
        hits = [t for t in _RATE_HITS.get(ip, []) if t >= cutoff]
        if len(hits) >= RATE_MAX:
            _RATE_HITS[ip] = hits
            return True
        hits.append(now)
        _RATE_HITS[ip] = hits
        return False


# ============================================================================
# Agent Control Panel —— 管理面板：启停常驻 agent（launchd user-agents）。
# 安全要点：
#   1) 独立 admin token（OW_ADMIN_TOKEN），与公开邀请码分开；未配置 => 整组 503。
#   2) 可控集合 = glob ~/Library/LaunchAgents/app.ourworlds.resident-*.plist —— 仅此白名单，
#      核心服务（play-server/web/tunnel）永远不在内、无法被操作。
#   3) label 另行用正则校验，且 plist 必须真实存在，否则 404；
#      所有 launchctl 调用一律以 argv 列表传给 subprocess，绝不拼 shell 字符串、绝不把 label 格式化进命令。
# ============================================================================

# 常驻 agent 的 label 前缀与白名单正则（核心服务不含 "resident-" 故天然被排除）。
RESIDENT_PREFIX = "app.ourworlds.resident-"
RESIDENT_LABEL_RE = re.compile(r"^app\.ourworlds\.resident-[a-z0-9-]+$")
# pid 行：launchctl print 输出里形如 "\tpid = 55142"（仅数字才算在跑）。
_PID_RE = re.compile(r"^\s*pid\s*=\s*(\d+)\s*$", re.MULTILINE)


def _admin_token() -> str:
    return os.environ.get("OW_ADMIN_TOKEN", "") or ""


def _admin_enabled() -> bool:
    # 仅当运营者配置了独立 admin token 时，管理 API 才开启。
    return _admin_token().strip() != ""


def _launchagents_dir() -> str:
    # 默认 ~/Library/LaunchAgents；OW_LAUNCHAGENTS_DIR 仅供测试指向假目录。
    override = os.environ.get("OW_LAUNCHAGENTS_DIR", "").strip()
    if override:
        return override
    return os.path.expanduser("~/Library/LaunchAgents")


def _launch_uid() -> int:
    # launchctl 域 uid；OW_LAUNCHCTL_UID 仅供测试覆盖。
    override = os.environ.get("OW_LAUNCHCTL_UID", "").strip()
    if override:
        try:
            return int(override)
        except ValueError:
            pass
    return os.getuid()


def _discover_residents() -> dict:
    """发现可控的常驻 agent：label -> plist 绝对路径。

    白名单 = glob app.ourworlds.resident-*.plist；额外用正则校验 label，
    确保只有形如 resident-<slug> 的才进入（.plist.bak 等不会匹配 glob）。
    """
    out = {}
    pattern = os.path.join(_launchagents_dir(), RESIDENT_PREFIX + "*.plist")
    for path in sorted(glob.glob(pattern)):
        label = os.path.basename(path)[:-len(".plist")]
        if RESIDENT_LABEL_RE.match(label):
            out[label] = path
    return out


def _resolve_resident(label) -> str:
    """把请求里的 label 解析为它的 plist 路径；非法/未知 => None（调用方回 404）。

    三重把关：正则白名单 + 在发现集合内 + plist 真实存在。任何注入式串都被挡在 subprocess 之外。
    """
    s = "" if label is None else str(label)
    if not RESIDENT_LABEL_RE.match(s):
        return None
    residents = _discover_residents()
    path = residents.get(s)
    if not path or not os.path.isfile(path):
        return None
    return path


def _run_launchctl(args) -> subprocess.CompletedProcess:
    """以 argv 列表运行 launchctl（绝不经 shell）。args 是 launchctl 之后的参数列表。"""
    return subprocess.run(["launchctl"] + list(args),
                          capture_output=True, text=True, timeout=15)


def _agent_running(label: str) -> tuple:
    """返回 (running: bool, loaded: bool)。

    launchctl print gui/<uid>/<label>：rc!=0 => 未加载（停止）；输出含数字 pid => 运行中；否则已加载/空闲。
    """
    uid = _launch_uid()
    try:
        cp = _run_launchctl(["print", "gui/%d/%s" % (uid, label)])
    except Exception:
        return (False, False)
    if cp.returncode != 0:
        return (False, False)
    running = _PID_RE.search(cp.stdout or "") is not None
    return (running, True)


class CrossOriginIsolatedHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=WEB_DIR, **kwargs)

    def end_headers(self):
        # SharedArrayBuffer / 多线程 WASM 的硬性要求
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    # ---- 工具：发一段 body（已带 COOP/COEP/Cache-Control，经由 end_headers）----
    def _send_bytes(self, code: int, body: bytes, content_type: str):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _send_json(self, code: int, obj: dict):
        self._send_bytes(code, json.dumps(obj).encode("utf-8"), "application/json")

    def _serve_portal_file(self, filename: str, content_type: str):
        path = os.path.join(PORTAL_DIR, filename)
        if not os.path.isfile(path):
            self._send_bytes(404, ("Not found: %s is not available on this server.\n" % filename).encode("utf-8"),
                             "text/plain; charset=utf-8")
            return
        with open(path, "rb") as f:
            body = f.read()
        self._send_bytes(200, body, content_type)

    # ---- 门户 GET 路由；其余落到静态 build/web ----
    def _portal_get(self) -> bool:
        # 去掉查询串
        route = self.path.split("?", 1)[0]
        if route in ("/onboard", "/onboard/"):
            self._serve_portal_file("onboard.html", "text/html; charset=utf-8")
            return True
        if route in ("/agents", "/agents/", "/agents.html"):
            self._serve_portal_file("agents.html", "text/html; charset=utf-8")
            return True
        if route == "/install-agent.sh":
            self._serve_portal_file("install-agent.sh", "text/x-sh; charset=utf-8")
            return True
        if route == "/ourworlds-agent.mjs":
            self._serve_portal_file("ourworlds-agent.mjs", "text/javascript; charset=utf-8")
            return True
        return False

    def do_GET(self):
        route = self.path.split("?", 1)[0]
        if route == "/api/agents":
            self._handle_agents_list()
            return
        if self._portal_get():
            return
        super().do_GET()

    def do_HEAD(self):
        if self._portal_get():
            return
        super().do_HEAD()

    def do_POST(self):
        route = self.path.split("?", 1)[0]
        if route == "/api/agent-token":
            self._handle_agent_token()
            return
        m = re.match(r"^/api/agents/([^/]+)/(start|stop|kick)$", route)
        if m:
            self._handle_agent_action(m.group(1), m.group(2))
            return
        self.send_error(404, "Not Found")

    # ---- 管理面板：鉴权 + 取请求体（admin token 可来自 header 或 POST body）----
    def _read_json_body(self):
        """读 JSON body；无 body 返回 {}，畸形返回 None。"""
        try:
            length = int(self.headers.get("Content-Length", "0") or "0")
        except ValueError:
            return None
        raw = self.rfile.read(length) if length > 0 else b""
        if not raw:
            return {}
        try:
            payload = json.loads(raw.decode("utf-8"))
        except Exception:
            return None
        return payload if isinstance(payload, dict) else None

    def _admin_check(self, body=None):
        """统一鉴权门：返回 True 表示已放行；否则已发完响应（503/403/429）返回 False。

        admin token 接受 header X-OW-Admin，POST 也接受 body 里的 token/admin 字段。
        """
        if not _admin_enabled():
            self._send_json(503, {"error": "admin disabled"})
            return False
        supplied = self.headers.get("X-OW-Admin", "") or ""
        if not supplied and isinstance(body, dict):
            supplied = str(body.get("token", "") or body.get("admin", "") or "")
        # 常量时间比较，避免计时侧信道。
        expected = _admin_token()
        if not (supplied and secrets.compare_digest(str(supplied), expected)):
            self._send_json(403, {"error": "forbidden"})
            return False
        ip = self.client_address[0] if self.client_address else "unknown"
        if _rate_limited(ip):
            self._send_json(429, {"error": "rate limited, try later"})
            return False
        return True

    def _handle_agents_list(self):
        try:
            if not self._admin_check():
                return
            agents = []
            for label, _path in _discover_residents().items():
                running, loaded = _agent_running(label)
                agents.append({
                    "label": label,
                    "name": label[len(RESIDENT_PREFIX):],
                    "running": running,
                    "loaded": loaded,
                })
            self._send_json(200, {"agents": agents})
        except Exception:
            try:
                self._send_json(500, {"error": "internal error"})
            except Exception:
                pass

    def _handle_agent_action(self, raw_label, action):
        try:
            body = self._read_json_body()
            if body is None:
                self._send_json(400, {"error": "bad request"})
                return
            if not self._admin_check(body):
                return
            # 白名单解析：正则 + 发现集合 + plist 存在，三者缺一即未知 agent（不触达 subprocess）。
            plist = _resolve_resident(raw_label)
            if not plist:
                self._send_json(404, {"error": "unknown agent"})
                return
            label = str(raw_label)  # 已被正则证明安全
            uid = _launch_uid()
            if action == "start":
                argv = ["bootstrap", "gui/%d" % uid, plist]
            elif action == "stop":
                argv = ["bootout", "gui/%d/%s" % (uid, label)]
            else:  # kick —— 立刻跑一班
                argv = ["kickstart", "-k", "gui/%d/%s" % (uid, label)]
            try:
                cp = _run_launchctl(argv)
            except Exception:
                self._send_json(502, {"error": "launchctl failed"})
                return
            # bootstrap 已加载 / bootout 未加载 都会非零 —— 不当致命错，回报最终状态即可。
            running, loaded = _agent_running(label)
            resp = {"ok": True, "running": running, "loaded": loaded,
                    "label": label, "action": action, "rc": cp.returncode}
            if cp.returncode != 0:
                detail = (cp.stderr or cp.stdout or "").strip()
                if detail:
                    resp["detail"] = detail[:200]
            self._send_json(200, resp)
        except Exception:
            try:
                self._send_json(500, {"error": "internal error"})
            except Exception:
                pass

    def _handle_agent_token(self):
        try:
            # 功能开关：邀请码与 token 文件二者缺一即视为关闭。
            if not _issuance_enabled():
                self._send_json(503, {"error": "issuance disabled"})
                return
            length = int(self.headers.get("Content-Length", "0") or "0")
            raw = self.rfile.read(length) if length > 0 else b""
            try:
                payload = json.loads(raw.decode("utf-8")) if raw else {}
            except Exception:
                self._send_json(400, {"error": "bad request"})
                return
            if not isinstance(payload, dict):
                self._send_json(400, {"error": "bad request"})
                return
            gate = str(payload.get("gate", ""))
            if gate != _gate():
                self._send_json(403, {"error": "bad invite code"})
                return
            ip = self.client_address[0] if self.client_address else "unknown"
            if _rate_limited(ip):
                self._send_json(429, {"error": "rate limited, try later"})
                return
            token = issue_token(payload.get("label", "agent"))
            self._send_json(200, {"token": token})
        except Exception:
            # 绝不把栈泄露给客户端。
            try:
                self._send_json(400, {"error": "bad request"})
            except Exception:
                pass


class _ReusableTCPServer(socketserver.ThreadingTCPServer):
    # ThreadingTCPServer：每个请求一个线程，可并发服务多个资源。单线程服务器在慢速隧道上
    # 串行传 35MB WASM 时会阻塞其它并发请求 → 浏览器并行拉取的 index.js/图标超时(503/524) → 卡死打不开。
    # allow_reuse_address：重启时旧端口处于 TIME_WAIT 也能立即重绑（避免 Errno 48 反复重启抢不到端口）。
    allow_reuse_address = True
    daemon_threads = True


def main():
    if not os.path.isdir(WEB_DIR):
        print("未找到 build/web —— 先跑 `bash packaging/build_web.sh` 导出 Web 版。")
        sys.exit(1)
    with _ReusableTCPServer(("127.0.0.1", PORT), CrossOriginIsolatedHandler) as httpd:
        print("OurWorlds Web: http://localhost:%d/  (COOP/COEP 已启用，支持多线程 WASM)" % PORT)
        print("  目录: %s" % WEB_DIR)
        print("  门户: /onboard  ·  签发: %s" % ("已开启" if _issuance_enabled() else "未配置(503)"))
        print("  管理: /agents   ·  admin API: %s" % ("已开启" if _admin_enabled() else "未配置(503)"))
        print("  Ctrl+C 停止")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\n已停止。")


if __name__ == "__main__":
    main()

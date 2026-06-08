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
# 端点配置（环境变量）：
#   OW_PORTAL_GATE        必填的邀请码（未设/为空 => 签发功能关闭，503）
#   OW_AGENT_TOKEN_FILE   token JSON 文件路径（未设/为空 => 签发功能关闭，503）
# 其余一切仍是 build/web 的静态文件服务，未改动。
import http.server
import json
import os
import secrets
import socketserver
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
        if route == "/install-agent.sh":
            self._serve_portal_file("install-agent.sh", "text/x-sh; charset=utf-8")
            return True
        if route == "/ourworlds-agent.mjs":
            self._serve_portal_file("ourworlds-agent.mjs", "text/javascript; charset=utf-8")
            return True
        return False

    def do_GET(self):
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
        self.send_error(404, "Not Found")

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
        print("  Ctrl+C 停止")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\n已停止。")


if __name__ == "__main__":
    main()

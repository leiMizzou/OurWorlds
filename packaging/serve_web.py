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
#   GET  /api/agents                      -> 列出常驻 agent（由 plist 发现）及其状态 + interval
#   POST /api/agents/<label>/start        -> launchctl bootstrap gui/<uid> <plist>
#   POST /api/agents/<label>/stop         -> launchctl bootout   gui/<uid>/<label>
#   POST /api/agents/<label>/kick         -> launchctl kickstart -k gui/<uid>/<label>（立刻跑一班）
#   GET  /api/agents/<label>/log?lines=N  -> 读取该 agent 日志最后 N 行（只读；缺失=空）
#   GET  /api/agents/<label>/task         -> 读取该 agent 任务文件（缺失=空串）
#   POST /api/agents/<label>/task         -> 写任务文件（原子写；>8192B=413）下一班生效
#   GET  /api/agents/<label>/config       -> 读取该 agent 的持久化配置（缺失=默认值）
#   POST /api/agents/<label>/config       -> 保存配置；若含 interval 则改 plist 的 ThrottleInterval 并重载
#   POST /api/agents/stop-all             -> bootout 所有发现到的常驻（只动白名单集合）
#   POST /api/agents/start-all            -> bootstrap 所有发现到的常驻（只动白名单集合）
# 端点配置（环境变量）：
#   OW_PORTAL_GATE        必填的邀请码（未设/为空 => 签发功能关闭，503）
#   OW_AGENT_TOKEN_FILE   token JSON 文件路径（未设/为空 => 签发功能关闭，503）
#   OW_ADMIN_TOKEN        管理面板 token（与邀请码分开；未设/为空 => 管理 API 全部关闭，503）
#   OW_LAUNCHAGENTS_DIR   plist 发现目录（默认 ~/Library/LaunchAgents；仅供测试覆盖）
#   OW_LAUNCHCTL_UID      launchctl 域 uid（默认 os.getuid()；仅供测试覆盖）
#   OW_RESIDENT_TASK_DIR  任务文件目录（默认 ~/.ourworlds；仅供测试覆盖）
#   OW_RESIDENT_LOG_DIR   日志文件目录（默认 ~/Library/Logs/ourworlds；仅供测试覆盖）
#   OW_RESIDENT_CONFIG_DIR 配置目录（默认 ~/.ourworlds/agents；仅供测试覆盖）
#   OW_ADMIN_RATE_MAX / OW_ADMIN_RATE_WINDOW 管理 API 独立限频（默认 120 次 / 60 秒）
# 其余一切仍是 build/web 的静态文件服务，未改动。
import email.utils
import glob
import http.server
import json
import os
import plistlib
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
ADMIN_RATE_MAX = int(os.environ.get("OW_ADMIN_RATE_MAX", "120"))       # 管理 API：每 IP 每窗口最多请求数
ADMIN_RATE_WINDOW_SEC = int(os.environ.get("OW_ADMIN_RATE_WINDOW", "60"))
LABEL_MAX = 40
CONFIG_MAX_BYTES = 16384

# token 文件读改写需串行（ThreadingTCPServer 并发）；限频表同锁保护。
_FILE_LOCK = threading.Lock()
_RATE_HITS = {}   # ip -> [unix_ts, ...]（窗口内的签发时刻）
_ADMIN_RATE_HITS = {}   # ip -> [unix_ts, ...]（管理 API 请求时刻）


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


def _admin_rate_limited(ip: str) -> bool:
    """管理 API 独立限频，避免和 /api/agent-token 的签发限频互相干扰。"""
    now = time.time()
    cutoff = now - ADMIN_RATE_WINDOW_SEC
    with _FILE_LOCK:
        hits = [t for t in _ADMIN_RATE_HITS.get(ip, []) if t >= cutoff]
        if len(hits) >= ADMIN_RATE_MAX:
            _ADMIN_RATE_HITS[ip] = hits
            return True
        hits.append(now)
        _ADMIN_RATE_HITS[ip] = hits
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


def _task_dir() -> str:
    # 任务文件目录，默认 ~/.ourworlds；OW_RESIDENT_TASK_DIR 仅供测试覆盖。
    override = os.environ.get("OW_RESIDENT_TASK_DIR", "").strip()
    if override:
        return override
    return os.path.expanduser("~/.ourworlds")


def _log_dir() -> str:
    # 日志文件目录，默认 ~/Library/Logs/ourworlds；OW_RESIDENT_LOG_DIR 仅供测试覆盖。
    override = os.environ.get("OW_RESIDENT_LOG_DIR", "").strip()
    if override:
        return override
    return os.path.expanduser("~/Library/Logs/ourworlds")


def _config_dir() -> str:
    # Agent 配置目录，默认 ~/.ourworlds/agents；OW_RESIDENT_CONFIG_DIR 仅供测试覆盖。
    override = os.environ.get("OW_RESIDENT_CONFIG_DIR", "").strip()
    if override:
        return override
    return os.path.expanduser("~/.ourworlds/agents")


def _name_of(label: str) -> str:
    """从已白名单化的 label 取出 <name>（去掉 resident- 前缀）。

    label 已经过 RESIDENT_LABEL_RE 校验，故 name 只可能是 [a-z0-9-]+，绝无 / . \\。
    仍在此处断言一次，作为纵深防御——任何带路径分隔符的 name 立刻抛错而不会拼进路径。
    """
    name = label[len(RESIDENT_PREFIX):]
    assert name and not any(c in name for c in ("/", "\\", ".", "\0")), "unsafe resident name"
    return name


def _task_path(label: str) -> str:
    # 用 os.path.join 拼接（绝不字符串格式化路径）；name 已被 _name_of 断言无分隔符。
    return os.path.join(_task_dir(), "resident-%s-task.txt" % _name_of(label))


def _log_path(label: str) -> str:
    return os.path.join(_log_dir(), "resident-%s.log" % _name_of(label))


def _config_path(label: str) -> str:
    return os.path.join(_config_dir(), "%s.json" % _name_of(label))


def _read_interval(plist_path: str):
    """从 plist 读取 ThrottleInterval（int）；缺失/不可读 => None。"""
    try:
        with open(plist_path, "rb") as f:
            data = plistlib.load(f)
        val = data.get("ThrottleInterval")
        return int(val) if isinstance(val, int) else None
    except Exception:
        return None


def _text_field(v, max_len: int) -> str:
    s = "" if v is None else str(v)
    s = s.replace("\r\n", "\n").replace("\r", "\n").strip()
    if len(s.encode("utf-8")) > max_len:
        raise ValueError("field too large")
    return s


def _default_agent_config(label: str, plist_path: str = None) -> dict:
    name = _name_of(label)
    interval = _read_interval(plist_path) if plist_path else None
    return {
        "version": 1,
        "id": name,
        "label": label,
        "display_name": name,
        "runtime": "codex",
        "mode": "explore",
        "model": "",
        "avatar": "default",
        "color": "#5db0ff",
        "goal": "",
        "persona": "",
        "interval": interval,
    }


def _read_agent_config(label: str, plist_path: str = None) -> dict:
    """读取 resident 配置；缺失/畸形时返回默认值，interval 始终以 plist 为准。"""
    cfg = _default_agent_config(label, plist_path)
    path = _config_path(label)
    if os.path.isfile(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                raw = json.load(f)
            if isinstance(raw, dict):
                for k, limit in [
                    ("display_name", 80),
                    ("runtime", 40),
                    ("mode", 32),
                    ("model", 120),
                    ("avatar", 40),
                    ("color", 16),
                    ("goal", 1000),
                    ("persona", CONFIG_MAX_BYTES),
                ]:
                    if k in raw and isinstance(raw.get(k), str):
                        cfg[k] = _text_field(raw.get(k), limit)
        except Exception:
            pass
    cfg["version"] = 1
    cfg["id"] = _name_of(label)
    cfg["label"] = label
    cfg["interval"] = _read_interval(plist_path) if plist_path else None
    if not cfg["display_name"]:
        cfg["display_name"] = cfg["id"]
    if not re.match(r"^#[0-9a-fA-F]{6}$", str(cfg.get("color", ""))):
        cfg["color"] = "#5db0ff"
    return cfg


def _validate_agent_config_payload(label: str, plist_path: str, body: dict) -> dict:
    """合并并校验 POST /config 的 payload；字段缺省表示保留当前配置。"""
    try:
        raw_size = len(json.dumps(body, ensure_ascii=False).encode("utf-8"))
    except Exception:
        raw_size = CONFIG_MAX_BYTES + 1
    if raw_size > CONFIG_MAX_BYTES:
        raise ValueError("config too large")

    cfg = _read_agent_config(label, plist_path)
    aliases = {"name": "display_name"}
    limits = {
        "display_name": 80,
        "runtime": 40,
        "mode": 32,
        "model": 120,
        "avatar": 40,
        "color": 16,
        "goal": 1000,
        "persona": CONFIG_MAX_BYTES,
    }
    for src, dst in aliases.items():
        if src in body and dst not in body:
            body[dst] = body[src]
    for k, limit in limits.items():
        if k not in body:
            continue
        if not isinstance(body.get(k), str):
            raise ValueError("%s must be a string" % k)
        cfg[k] = _text_field(body.get(k), limit)
    if not cfg["display_name"]:
        cfg["display_name"] = cfg["id"]
    if not re.match(r"^#[0-9a-fA-F]{6}$", cfg["color"]):
        raise ValueError("color must be #RRGGBB")
    for k in ("runtime", "mode", "avatar"):
        if cfg[k] and not re.match(r"^[A-Za-z0-9_. -]+$", cfg[k]):
            raise ValueError("%s has unsupported characters" % k)
    if "interval" in body:
        interval = body.get("interval")
        if isinstance(interval, bool) or not isinstance(interval, int):
            raise ValueError("interval must be an integer")
        if interval < 30 or interval > 86400:
            raise ValueError("interval out of range (30..86400)")
        cfg["interval"] = interval
    return cfg


def _write_agent_config(label: str, cfg: dict):
    path = _config_path(label)
    parent = os.path.dirname(os.path.abspath(path))
    if parent and not os.path.isdir(parent):
        os.makedirs(parent, exist_ok=True)
    body = {
        "version": 1,
        "id": cfg.get("id", _name_of(label)),
        "label": label,
        "display_name": cfg.get("display_name", _name_of(label)),
        "runtime": cfg.get("runtime", "codex"),
        "mode": cfg.get("mode", "explore"),
        "model": cfg.get("model", ""),
        "avatar": cfg.get("avatar", "default"),
        "color": cfg.get("color", "#5db0ff"),
        "goal": cfg.get("goal", ""),
        "persona": cfg.get("persona", ""),
        "interval": cfg.get("interval"),
    }
    tmp = path + ".tmp"
    with _FILE_LOCK:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(body, f, ensure_ascii=False, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)


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

    # 大静态资产（wasm/pck/js/图标 及其压缩变体）可被浏览器缓存；页面与 /api 永远 no-store。
    _CACHEABLE_RE = re.compile(r"\.(wasm|pck|js|mjs|png|ico|gz|br)$")

    def end_headers(self):
        # SharedArrayBuffer / 多线程 WASM 的硬性要求
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        # 此前全站 no-store：37MB 的 wasm 每次访问都整包重拉（免费隧道下基本打不开）。
        # 现在大资产 max-age=1h——窗口内零请求，过期后凭 If-Modified-Since 304 复用，近乎零流量。
        p = self.path.split("?", 1)[0]
        if not p.startswith("/api/") and self._CACHEABLE_RE.search(p):
            self.send_header("Cache-Control", "public, max-age=3600")
        else:
            self.send_header("Cache-Control", "no-store")
        super().end_headers()

    # ---- 预压缩资产协商：存在 <file>.br/.gz 且客户端声明支持时直发压缩文件 ----
    # build_web.sh 导出后会生成 index.{wasm,pck,js}.gz（有 brotli 则再加 .br）。
    # 37MB wasm 压到约 1/4——这是免费隧道下网页打得开打不开的关键。
    def send_head(self):
        fs_path = self.translate_path(self.path)
        if os.path.isfile(fs_path):
            accept = self.headers.get("Accept-Encoding", "")
            for enc, ext in (("br", ".br"), ("gzip", ".gz")):
                if enc not in accept:
                    continue
                cpath = fs_path + ext
                if not os.path.isfile(cpath):
                    continue
                try:
                    st = os.stat(cpath)
                    ims = self.headers.get("If-Modified-Since")
                    if ims:
                        try:
                            ims_dt = email.utils.parsedate_to_datetime(ims)
                            if ims_dt is not None and int(st.st_mtime) <= int(ims_dt.timestamp()):
                                self.send_response(304)
                                self.end_headers()
                                return None
                        except (TypeError, ValueError, OverflowError):
                            pass
                    f = open(cpath, "rb")
                except OSError:
                    continue
                self.send_response(200)
                self.send_header("Content-Type", self.guess_type(fs_path))  # 原文件的类型
                self.send_header("Content-Length", str(st.st_size))
                self.send_header("Content-Encoding", enc)
                self.send_header("Vary", "Accept-Encoding")
                self.send_header("Last-Modified", self.date_time_string(int(st.st_mtime)))
                self.end_headers()
                return f
        return super().send_head()

    # ---- 世界在线状态（公开只读）：读游戏服务器周期写的 presence 心跳文件 ----
    # 居民班车据此"无人在线就跳班"省 LLM token；只含计数，无敏感信息，故不设防。
    def _handle_world_status(self):
        path = os.environ.get("OW_PRESENCE_FILE", "") or os.path.expanduser(
            "~/Library/Application Support/Godot/app_userdata/OurWorlds/presence.json")
        out = {"online": False, "humans": 0, "agents": 0, "age_sec": None}
        try:
            with open(path, "r", encoding="utf-8") as f:
                doc = json.load(f)
            age = int(time.time()) - int(doc.get("t", 0))
            out = {"online": age <= 60, "humans": int(doc.get("humans", 0)),
                   "agents": int(doc.get("agents", 0)), "age_sec": age}
        except (OSError, ValueError):
            pass
        self._send_json(200, out)

    # ---- Token 管理（管理员）：列出 / 吊销已签发的接入 token ----
    # 吊销 = 从 OW_AGENT_TOKEN_FILE 删除该记录；网关的 AgentTokenStore 按 mtime 热加载，几秒内失效。
    def _handle_tokens_list(self):
        if not self._admin_check():
            return
        toks = []
        tf = os.environ.get("OW_AGENT_TOKEN_FILE", "")
        if tf and os.path.isfile(tf):
            try:
                with open(tf, "r", encoding="utf-8") as f:
                    doc = json.load(f)
                for t in doc.get("tokens", []):
                    toks.append({"token": str(t.get("token", "")), "label": str(t.get("label", "")),
                                 "issued_at": int(t.get("issued_at", 0))})
            except (OSError, ValueError):
                pass
        self._send_json(200, {"tokens": toks})

    def _handle_token_revoke(self):
        if not self._admin_check():
            return
        body = self._read_json_body()
        if body is None:
            self._send_json(400, {"error": "bad request"})
            return
        target = str(body.get("token", ""))
        tf = os.environ.get("OW_AGENT_TOKEN_FILE", "")
        if not target or not tf or not os.path.isfile(tf):
            self._send_json(404, {"error": "unknown token"})
            return
        with _FILE_LOCK:
            try:
                with open(tf, "r", encoding="utf-8") as f:
                    doc = json.load(f)
            except (OSError, ValueError):
                self._send_json(500, {"error": "token file unreadable"})
                return
            before = doc.get("tokens", [])
            after = [t for t in before if str(t.get("token", "")) != target]
            if len(after) == len(before):
                self._send_json(404, {"error": "unknown token"})
                return
            doc["tokens"] = after
            tmp = tf + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(doc, f, ensure_ascii=False, indent=2)
            os.replace(tmp, tf)
        self._send_json(200, {"ok": True, "remaining": len(after)})

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
        if route in ("/tokens", "/tokens/", "/tokens.html"):
            self._serve_portal_file("tokens.html", "text/html; charset=utf-8")
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
        if route == "/api/world/status":
            self._handle_world_status()
            return
        if route == "/api/tokens":
            self._handle_tokens_list()
            return
        if route == "/api/agents":
            self._handle_agents_list()
            return
        m = re.match(r"^/api/agents/([^/]+)/log$", route)
        if m:
            self._handle_agent_log(m.group(1))
            return
        m = re.match(r"^/api/agents/([^/]+)/task$", route)
        if m:
            self._handle_agent_task_get(m.group(1))
            return
        m = re.match(r"^/api/agents/([^/]+)/config$", route)
        if m:
            self._handle_agent_config_get(m.group(1))
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
        if route == "/api/tokens/revoke":
            self._handle_token_revoke()
            return
        if route == "/api/agent-token":
            self._handle_agent_token()
            return
        if route in ("/api/agents/stop-all", "/api/agents/start-all"):
            self._handle_agents_bulk("stop" if route.endswith("stop-all") else "start")
            return
        m = re.match(r"^/api/agents/([^/]+)/(start|stop|kick)$", route)
        if m:
            self._handle_agent_action(m.group(1), m.group(2))
            return
        m = re.match(r"^/api/agents/([^/]+)/task$", route)
        if m:
            self._handle_agent_task_post(m.group(1))
            return
        m = re.match(r"^/api/agents/([^/]+)/config$", route)
        if m:
            self._handle_agent_config(m.group(1))
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
        if _admin_rate_limited(ip):
            self._send_json(429, {"error": "rate limited, try later"})
            return False
        return True

    def _handle_agents_list(self):
        try:
            if not self._admin_check():
                return
            agents = []
            for label, path in _discover_residents().items():
                running, loaded = _agent_running(label)
                cfg = _read_agent_config(label, path)
                agents.append({
                    "label": label,
                    "name": label[len(RESIDENT_PREFIX):],
                    "display_name": cfg.get("display_name", label[len(RESIDENT_PREFIX):]),
                    "runtime": cfg.get("runtime", "codex"),
                    "mode": cfg.get("mode", "explore"),
                    "avatar": cfg.get("avatar", "default"),
                    "color": cfg.get("color", "#5db0ff"),
                    "goal": cfg.get("goal", ""),
                    "running": running,
                    "loaded": loaded,
                    "interval": _read_interval(path),
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

    def _handle_agent_log(self, raw_label):
        """GET /api/agents/<label>/log?lines=N —— 只读该 agent 日志最后 N 行（默认 40，钳到 1..200）。"""
        try:
            if not self._admin_check():
                return
            if not _resolve_resident(raw_label):
                self._send_json(404, {"error": "unknown agent"})
                return
            label = str(raw_label)  # 已被白名单证明安全
            # 解析 ?lines=N（无效/越界即钳到 [1,200]，默认 40）。
            n = 40
            qs = self.path.split("?", 1)
            if len(qs) == 2:
                m = re.search(r"(?:^|&)lines=(\d+)", qs[1])
                if m:
                    try:
                        n = int(m.group(1))
                    except ValueError:
                        n = 40
            n = max(1, min(200, n))
            path = _log_path(label)
            lines = []
            if os.path.isfile(path):
                # 读尾部即可：文件可能很大，只取末尾约 256KB 再切最后 n 行，避免整文件载入。
                try:
                    with open(path, "rb") as f:
                        f.seek(0, os.SEEK_END)
                        size = f.tell()
                        chunk = min(size, 262144)
                        f.seek(size - chunk)
                        raw = f.read()
                    text = raw.decode("utf-8", errors="replace")
                    all_lines = text.splitlines()
                    lines = all_lines[-n:]
                except Exception:
                    lines = []
            self._send_json(200, {"lines": lines})
        except Exception:
            try:
                self._send_json(500, {"error": "internal error"})
            except Exception:
                pass

    def _handle_agent_task_get(self, raw_label):
        """GET /api/agents/<label>/task —— 返回任务文件内容（缺失=空串）。"""
        try:
            if not self._admin_check():
                return
            if not _resolve_resident(raw_label):
                self._send_json(404, {"error": "unknown agent"})
                return
            label = str(raw_label)
            path = _task_path(label)
            text = ""
            if os.path.isfile(path):
                try:
                    with open(path, "r", encoding="utf-8", errors="replace") as f:
                        text = f.read()
                except Exception:
                    text = ""
            self._send_json(200, {"text": text})
        except Exception:
            try:
                self._send_json(500, {"error": "internal error"})
            except Exception:
                pass

    def _handle_agent_task_post(self, raw_label):
        """POST /api/agents/<label>/task body {"text": "..."} —— 原子写任务文件（>8192B=413）。"""
        try:
            body = self._read_json_body()
            if body is None:
                self._send_json(400, {"error": "bad request"})
                return
            if not self._admin_check(body):
                return
            # 白名单解析必须在任何文件写入之前。
            if not _resolve_resident(raw_label):
                self._send_json(404, {"error": "unknown agent"})
                return
            label = str(raw_label)
            text = body.get("text", "")
            if not isinstance(text, str):
                self._send_json(400, {"error": "text must be a string"})
                return
            encoded = text.encode("utf-8")
            if len(encoded) > 8192:
                self._send_json(413, {"error": "task too large (max 8192 bytes)"})
                return
            path = _task_path(label)
            parent = os.path.dirname(os.path.abspath(path))
            if parent and not os.path.isdir(parent):
                os.makedirs(parent, exist_ok=True)
            # 原子写：临时文件 + os.replace，避免 agent 读到半截任务。
            with _FILE_LOCK:
                tmp = path + ".tmp"
                with open(tmp, "wb") as f:
                    f.write(encoded)
                    f.flush()
                    os.fsync(f.fileno())
                os.replace(tmp, path)
            self._send_json(200, {"ok": True, "bytes": len(encoded)})
        except Exception:
            try:
                self._send_json(500, {"error": "internal error"})
            except Exception:
                pass

    def _handle_agent_config_get(self, raw_label):
        """GET /api/agents/<label>/config —— 返回持久化配置；缺失时返回默认配置。"""
        try:
            if not self._admin_check():
                return
            plist = _resolve_resident(raw_label)
            if not plist:
                self._send_json(404, {"error": "unknown agent"})
                return
            label = str(raw_label)
            self._send_json(200, {"config": _read_agent_config(label, plist)})
        except Exception:
            try:
                self._send_json(500, {"error": "internal error"})
            except Exception:
                pass

    def _handle_agent_config(self, raw_label):
        """POST /api/agents/<label>/config —— 保存配置；interval 变更会同步 plist 并重载。"""
        try:
            body = self._read_json_body()
            if body is None:
                self._send_json(400, {"error": "bad request"})
                return
            if not self._admin_check(body):
                return
            plist = _resolve_resident(raw_label)
            if not plist:
                self._send_json(404, {"error": "unknown agent"})
                return
            label = str(raw_label)
            try:
                cfg = _validate_agent_config_payload(label, plist, body)
            except ValueError as e:
                self._send_json(400, {"error": str(e)})
                return

            reloaded = False
            rc = 0
            # interval 仍以 launchd plist 为运行时来源；只要请求里包含 interval，就保持旧行为：写 plist 并重载。
            if "interval" in body:
                interval = int(cfg.get("interval"))
                try:
                    with _FILE_LOCK:
                        with open(plist, "rb") as f:
                            data = plistlib.load(f)
                        if not isinstance(data, dict):
                            data = {}
                        data["ThrottleInterval"] = interval
                        tmp = plist + ".tmp"
                        with open(tmp, "wb") as f:
                            plistlib.dump(data, f)
                            f.flush()
                            os.fsync(f.fileno())
                        os.replace(tmp, plist)
                except Exception:
                    self._send_json(500, {"error": "failed to write plist"})
                    return
                uid = _launch_uid()
                try:
                    _run_launchctl(["bootout", "gui/%d/%s" % (uid, label)])
                    cp = _run_launchctl(["bootstrap", "gui/%d" % uid, plist])
                    rc = cp.returncode
                    reloaded = True
                except Exception:
                    self._send_json(502, {"error": "launchctl reload failed"})
                    return

            cfg["interval"] = _read_interval(plist)
            try:
                _write_agent_config(label, cfg)
            except Exception:
                self._send_json(500, {"error": "failed to write config"})
                return
            resp = {
                "ok": True,
                "interval": cfg.get("interval"),
                "label": label,
                "config": cfg,
                "reloaded": reloaded,
                "rc": rc,
            }
            if reloaded and rc != 0:
                detail = (cp.stderr or cp.stdout or "").strip()
                if detail:
                    resp["detail"] = detail[:200]
            self._send_json(200, resp)
        except Exception:
            try:
                self._send_json(500, {"error": "internal error"})
            except Exception:
                pass

    def _handle_agents_bulk(self, action):
        """POST /api/agents/{stop-all,start-all} —— 只对发现到的常驻集合 bootout/bootstrap。

        绝不触及核心服务：操作集合 == _discover_residents()（白名单 glob + 正则）。
        """
        try:
            body = self._read_json_body()
            if body is None:
                self._send_json(400, {"error": "bad request"})
                return
            if not self._admin_check(body):
                return
            uid = _launch_uid()
            results = []
            for label, plist in _discover_residents().items():
                if action == "stop":
                    argv = ["bootout", "gui/%d/%s" % (uid, label)]
                else:  # start
                    argv = ["bootstrap", "gui/%d" % uid, plist]
                try:
                    cp = _run_launchctl(argv)
                    rc = cp.returncode
                except Exception:
                    rc = -1
                running, loaded = _agent_running(label)
                results.append({"label": label, "rc": rc,
                                "running": running, "loaded": loaded})
            self._send_json(200, {"ok": True, "action": action, "results": results})
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

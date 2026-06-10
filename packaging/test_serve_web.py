#!/usr/bin/env python3
# serve_web 门户 token 端点自检（standalone）：
#   - issue_token：返回 ow_…，把记录追加进 OW_AGENT_TOKEN_FILE
#   - HTTP：503(未配置) / 403(错码) / 200(对码+token) / 429(限频)
#   - GET /onboard、/install-agent.sh 能取回内容
# 用法: python3 packaging/test_serve_web.py    （PASS/FAIL，失败 exit 非 0）
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


def _post(url, obj):
    body = json.dumps(obj).encode("utf-8")
    req = urllib.request.Request(url, data=body, method="POST",
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8")
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"_raw": raw}


def _get(url):
    try:
        with urllib.request.urlopen(url, timeout=5) as r:
            return r.status, r.read().decode("utf-8", "replace"), r.headers.get("Content-Type", "")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace"), e.headers.get("Content-Type", "")


def main():
    GATE = "let-me-in-42"
    tmpdir = tempfile.mkdtemp(prefix="ow_portal_test_")
    token_file = os.path.join(tmpdir, "nested", "agent_tokens.json")  # 父目录不存在，测试自动创建

    # 配置环境后再 import serve_web（限频上限调低以便快速触发 429）。
    os.environ["OW_PORTAL_GATE"] = GATE
    os.environ["OW_AGENT_TOKEN_FILE"] = token_file
    os.environ["OW_PORTAL_RATE_MAX"] = "3"
    os.environ["OW_PORTAL_RATE_WINDOW"] = "600"

    import serve_web
    importlib.reload(serve_web)  # 确保拿到当前 env 下的模块级常量（RATE_MAX 等）

    # ---------- 单元：issue_token ----------
    t1 = serve_web.issue_token("Explorer")
    check(isinstance(t1, str) and t1.startswith("ow_") and len(t1) == 3 + 40, "issue_token returns ow_<40hex>")
    check(os.path.isfile(token_file), "issue_token created the token file (incl. parent dir)")
    with open(token_file, "r", encoding="utf-8") as f:
        doc = json.load(f)
    check(doc.get("version") == 1 and isinstance(doc.get("tokens"), list), "token file has version+tokens[]")
    check(len(doc["tokens"]) == 1 and doc["tokens"][0]["token"] == t1, "token appended to file")
    check(doc["tokens"][0]["label"] == "Explorer" and isinstance(doc["tokens"][0]["issued_at"], int),
          "record has label + issued_at")

    t2 = serve_web.issue_token("Builder")
    with open(token_file, "r", encoding="utf-8") as f:
        doc = json.load(f)
    check(len(doc["tokens"]) == 2 and doc["tokens"][1]["token"] == t2, "second issue_token preserves existing + appends")

    # label 清洗：超长截断、空 -> 默认 agent
    long_label = "x" * 200
    serve_web.issue_token(long_label)
    serve_web.issue_token("   ")
    with open(token_file, "r", encoding="utf-8") as f:
        doc = json.load(f)
    check(len(doc["tokens"][2]["label"]) <= 40, "label capped at ~40 chars")
    check(doc["tokens"][3]["label"] == "agent", "blank label defaults to 'agent'")

    # ---------- HTTP：起一个 server 实例（spare port）----------
    port = _free_port()
    httpd = serve_web._ReusableTCPServer(("127.0.0.1", port), serve_web.CrossOriginIsolatedHandler)
    th = threading.Thread(target=httpd.serve_forever, daemon=True)
    th.start()
    # 等端口就绪
    for _ in range(50):
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                break
        except OSError:
            time.sleep(0.05)

    base = "http://127.0.0.1:%d" % port
    try:
        # 403：错误邀请码
        code, body = _post(base + "/api/agent-token", {"gate": "wrong", "label": "x"})
        check(code == 403 and body.get("error") == "bad invite code", "bad gate -> 403")

        # 200：正确邀请码，拿到 ow_ token，并被追加进文件
        before = len(doc["tokens"])
        code, body = _post(base + "/api/agent-token", {"gate": GATE, "label": "viaHTTP"})
        check(code == 200 and isinstance(body.get("token"), str) and body["token"].startswith("ow_"),
              "good gate -> 200 + ow_ token")
        with open(token_file, "r", encoding="utf-8") as f:
            doc2 = json.load(f)
        check(len(doc2["tokens"]) == before + 1 and doc2["tokens"][-1]["token"] == body["token"],
              "HTTP-issued token appended to file")

        # 400：畸形 JSON body
        req = urllib.request.Request(base + "/api/agent-token", data=b"{not json",
                                     method="POST", headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                code = r.status
        except urllib.error.HTTPError as e:
            code = e.code
        check(code == 400, "malformed JSON body -> 400")

        # 429：限频（RATE_MAX=3；上面 good-gate 已用 1 次，再发到超额）
        last = None
        for _ in range(6):
            last = _post(base + "/api/agent-token", {"gate": GATE, "label": "spam"})
        check(last is not None and last[0] == 429 and last[1].get("error") == "rate limited, try later",
              "exceeding per-IP rate -> 429")

        # GET /onboard 返回页面 HTML
        code, text, ctype = _get(base + "/onboard")
        check(code == 200 and "<!DOCTYPE html>" in text and "OurWorlds" in text, "/onboard returns the portal HTML")
        check("text/html" in ctype, "/onboard content-type is text/html")

        # GET /install-agent.sh 返回脚本
        code, text, ctype = _get(base + "/install-agent.sh")
        check(code == 200 and text.startswith("#!/bin/sh") and "agent-bridge.mjs" in text,
              "/install-agent.sh returns the installer script")

        # COOP/COEP 头未回归：门户文件经 end_headers 仍带跨源隔离头。
        req = urllib.request.Request(base + "/onboard")
        with urllib.request.urlopen(req, timeout=5) as r:
            coop = r.headers.get("Cross-Origin-Opener-Policy", "")
            coep = r.headers.get("Cross-Origin-Embedder-Policy", "")
            onboard_cc = r.headers.get("Cache-Control", "")
        check(coop == "same-origin" and coep == "require-corp", "/onboard still carries COOP/COEP headers")

        # ---------- 缓存策略 + 预压缩协商（37MB wasm 的加载修复）----------
        check(onboard_cc == "no-store", "/onboard (page) stays no-store")

        def _get_raw(url, headers=None):
            rq = urllib.request.Request(url, headers=headers or {})
            try:
                with urllib.request.urlopen(rq, timeout=5) as r:
                    return r.status, r.read(), r.headers
            except urllib.error.HTTPError as e:
                return e.code, e.read(), e.headers

        # 静态根换成临时目录（绝不写真实 build/web）；handler 每请求读模块全局，热切换即生效。
        webtmp = os.path.join(tmpdir, "web")
        os.makedirs(webtmp, exist_ok=True)
        serve_web.WEB_DIR = webtmp
        original = b"WASMDATA" * 512
        with open(os.path.join(webtmp, "index.wasm"), "wb") as f:
            f.write(original)
        import gzip as _gzip
        gz_bytes = _gzip.compress(original, 9)
        with open(os.path.join(webtmp, "index.wasm.gz"), "wb") as f:
            f.write(gz_bytes)

        code, body, hs = _get_raw(base + "/index.wasm")
        check(code == 200 and body == original and not hs.get("Content-Encoding"),
              "no Accept-Encoding -> original bytes, no Content-Encoding")
        check(hs.get("Cache-Control", "") == "public, max-age=3600", "big asset gets public max-age cache header")

        code, body, hs = _get_raw(base + "/index.wasm", {"Accept-Encoding": "gzip"})
        check(code == 200 and hs.get("Content-Encoding") == "gzip" and body == gz_bytes,
              "Accept-Encoding gzip -> serves the precompressed .gz bytes")
        check(hs.get("Vary", "") == "Accept-Encoding", "compressed response carries Vary: Accept-Encoding")
        check(hs.get("Cache-Control", "") == "public, max-age=3600", "compressed asset also cacheable")

        import email.utils as _eut
        future = _eut.formatdate(time.time() + 3600, usegmt=True)
        code, body, hs = _get_raw(base + "/index.wasm",
                                  {"Accept-Encoding": "gzip", "If-Modified-Since": future})
        check(code == 304, "If-Modified-Since (fresh) on compressed asset -> 304")

        code, body, hs = _get_raw(base + "/api/agent-token")
        check(hs.get("Cache-Control", "") == "no-store", "/api responses stay no-store")
    finally:
        httpd.shutdown()
        httpd.server_close()

    # ---------- 503：未配置（gate 缺失）----------
    os.environ.pop("OW_PORTAL_GATE", None)
    os.environ["OW_AGENT_TOKEN_FILE"] = token_file
    importlib.reload(serve_web)
    port2 = _free_port()
    httpd2 = serve_web._ReusableTCPServer(("127.0.0.1", port2), serve_web.CrossOriginIsolatedHandler)
    th2 = threading.Thread(target=httpd2.serve_forever, daemon=True)
    th2.start()
    for _ in range(50):
        try:
            with socket.create_connection(("127.0.0.1", port2), timeout=0.2):
                break
        except OSError:
            time.sleep(0.05)
    try:
        code, body = _post("http://127.0.0.1:%d/api/agent-token" % port2, {"gate": "anything", "label": "x"})
        check(code == 503 and body.get("error") == "issuance disabled", "gate unset -> 503 issuance disabled")
    finally:
        httpd2.shutdown()
        httpd2.server_close()

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

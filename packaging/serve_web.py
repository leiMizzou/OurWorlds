#!/usr/bin/env python3
# 本地起一个带 COOP/COEP 头的静态服务器，供 Godot Web(WASM, 多线程) 在浏览器里跑。
# 多线程 Web 需要 SharedArrayBuffer，浏览器要求这两个跨源隔离响应头才放行。
#   python3 packaging/serve_web.py [port]      # 然后浏览器打开 http://localhost:8060/
import http.server
import os
import socketserver
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8060
WEB_DIR = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "build", "web"))


class CrossOriginIsolatedHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=WEB_DIR, **kwargs)

    def end_headers(self):
        # SharedArrayBuffer / 多线程 WASM 的硬性要求
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


if not os.path.isdir(WEB_DIR):
    print("未找到 build/web —— 先跑 `bash packaging/build_web.sh` 导出 Web 版。")
    sys.exit(1)

class _ReusableTCPServer(socketserver.ThreadingTCPServer):
    # ThreadingTCPServer：每个请求一个线程，可并发服务多个资源。单线程服务器在慢速隧道上
    # 串行传 35MB WASM 时会阻塞其它并发请求 → 浏览器并行拉取的 index.js/图标超时(503/524) → 卡死打不开。
    # allow_reuse_address：重启时旧端口处于 TIME_WAIT 也能立即重绑（避免 Errno 48 反复重启抢不到端口）。
    allow_reuse_address = True
    daemon_threads = True


with _ReusableTCPServer(("127.0.0.1", PORT), CrossOriginIsolatedHandler) as httpd:
    print("OurWorlds Web: http://localhost:%d/  (COOP/COEP 已启用，支持多线程 WASM)" % PORT)
    print("  目录: %s" % WEB_DIR)
    print("  Ctrl+C 停止")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止。")

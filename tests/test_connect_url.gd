extends SceneTree
# 网页端"要连哪个服务器"的纯逻辑（无头可测——只调 Main 的 static 纯函数，不建场景/不碰 JavaScriptBridge）：
#   1) 显式 ?connect= 永远优先；2) 否则按页面来源自动推导同源 wss://<host>/ws；
#   3) 本地开发(localhost/127.0.0.1)不自动连 → 留空=单机。
#   godot --headless --path . --script res://tests/test_connect_url.gd
const Main = preload("res://scripts/Main.gd")
var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	# 显式 ?connect= 优先（含 URL 解码），即便有来源也用它
	check(Main._resolve_web_connect_url("?connect=ws%3A%2F%2F1.2.3.4%3A8971", "https://play.ourworlds.app") == "ws://1.2.3.4:8971", "显式 ?connect= 优先（解码）")
	# 无 ?connect= → 按 https 来源自动推导 wss://host/ws（单二级域名 + 路径路由）
	check(Main._resolve_web_connect_url("", "https://play.ourworlds.app") == "wss://play.ourworlds.app/ws", "https 来源 → wss://host/ws")
	check(Main._resolve_web_connect_url("?x=1", "https://play.ourworlds.app") == "wss://play.ourworlds.app/ws", "无 connect 参数 → 仍自动")
	# 带端口的来源保留端口
	check(Main._resolve_web_connect_url("", "https://example.com:8443") == "wss://example.com:8443/ws", "保留来源端口")
	# http 非本地 → ws://host/ws
	check(Main._resolve_web_connect_url("", "http://example.com:8060") == "ws://example.com:8060/ws", "http 非本地 → ws://host/ws")
	# 本地开发不自动连（保持单机），避免本地预览误连
	check(Main._resolve_web_connect_url("", "http://localhost:8060") == "", "localhost 不自动连")
	check(Main._resolve_web_connect_url("", "http://127.0.0.1:8060") == "", "127.0.0.1 不自动连")
	check(Main._resolve_web_connect_url("", "") == "", "空来源 → 空")
	# _query_param 仍作为纯 static 可用
	check(Main._query_param("?connect=abc&x=1", "connect") == "abc", "_query_param 取值")
	check(Main._query_param("?x=1", "connect") == "", "_query_param 缺失 → 空")

	if failed == 0: print("✅ ALL CONNECT URL TESTS PASSED")
	else: printerr("❌ ", failed, " 个 connect-url 测试失败")
	quit(0 if failed == 0 else 1)

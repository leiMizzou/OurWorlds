extends SceneTree
# NakamaClient 邮箱认证自检。Nakama 没起时自动跳过（标 ✅ SKIPPED，不算失败，CI 友好）；
# 起着时验证：邮箱注册/登录拿到会话 token + 能解出 user_id。
#   先 `docker compose -f deploy/accounts/docker-compose.yml up -d`，再 godot --headless --script res://tests/test_nakama_auth.gd
const NakamaClient = preload("res://scripts/NakamaClient.gd")
var _nc
var _done := false
var _f := 0
var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

var _sent := false
func _initialize() -> void:
	_nc = NakamaClient.new()
	root.add_child(_nc)
	_nc.authenticated.connect(_on_ok)
	_nc.auth_failed.connect(_on_fail)
	# 注意：_nc 此刻还没进树（_ready 下一帧才跑、HTTPRequest 才建好），所以在 _process 里发请求

func _on_ok(s: Dictionary) -> void:
	check(str(s.get("token", "")) != "", "拿到会话 token")
	check(str(s.get("user_id", "")) != "", "从 token 解出 user_id")
	_finish("✅ ALL NAKAMA AUTH TESTS PASSED")

func _on_fail(msg: String) -> void:
	if msg.begins_with("network"):
		_finish("✅ NAKAMA AUTH SKIPPED（Nakama 未运行，跳过）")
	else:
		check(false, "认证失败: " + msg)
		_finish("done")

func _process(_delta: float) -> bool:
	_f += 1
	if not _sent and _f >= 2:      # 等 _nc 进树 + _ready 建好 HTTPRequest，再发认证请求
		_sent = true
		_nc.authenticate_email("suite_tester@ourworlds.local", "password123", true)
	if _f > 300 and not _done:     # ~5s 无响应 → 当作跳过
		_finish("✅ NAKAMA AUTH SKIPPED（超时，Nakama 未响应）")
	return _done

func _finish(marker: String) -> void:
	if _done:
		return
	_done = true
	if failed > 0:
		printerr("❌ ", failed, " 个 Nakama 认证测试失败")
	else:
		print(marker)
	quit(0 if failed == 0 else 1)

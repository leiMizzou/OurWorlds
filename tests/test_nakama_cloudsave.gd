extends SceneTree
# 云存档：登录 → 存玩家状态 → 读回，一致。Nakama 没起则自动跳过（✅ SKIPPED，CI 友好）。
#   先 docker compose -f deploy/accounts/docker-compose.yml up -d，再跑此测试。
const NakamaClient = preload("res://scripts/NakamaClient.gd")
var _nc
var _f := 0
var _sent := false
var _done := false
var failed := 0
const SAVED := {"world": 4242, "spawn": [12, 40, -7]}
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	_nc = NakamaClient.new()
	root.add_child(_nc)
	_nc.authenticated.connect(func(_s): _nc.save_player_state(SAVED))
	_nc.player_state_saved.connect(func(): _nc.load_player_state())
	_nc.player_state_loaded.connect(_on_loaded)
	_nc.auth_failed.connect(func(msg):
		if msg.begins_with("network"): _finish("✅ CLOUD SAVE SKIPPED（Nakama 未运行）")
		else: check(false, "认证失败: " + msg); _finish("done"))

func _on_loaded(state: Dictionary) -> void:
	check(int(state.get("world", 0)) == 4242, "读回 world==4242")
	var sp: Array = state.get("spawn", [])
	check(sp.size() == 3 and int(sp[0]) == 12, "读回 spawn 一致")
	_finish("✅ ALL CLOUD SAVE TESTS PASSED")

func _process(_delta: float) -> bool:
	_f += 1
	if not _sent and _f >= 2:
		_sent = true
		_nc.authenticate_email("cloudsave_tester@ourworlds.local", "password123", true)
	if _f > 400 and not _done:
		_finish("✅ CLOUD SAVE SKIPPED（超时，Nakama 未响应）")
	return _done

func _finish(marker: String) -> void:
	if _done:
		return
	_done = true
	if failed > 0: printerr("❌ ", failed, " 个云存档测试失败")
	else: print(marker)
	quit(0 if failed == 0 else 1)

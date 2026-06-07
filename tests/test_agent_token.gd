extends SceneTree
const AgentTokenStore = preload("res://scripts/AgentTokenStore.gd")
var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	# "label:token" pairs, comma-separated; bare token allowed (label == token).
	var store := AgentTokenStore.new("Alice:aaa111, Bob:bbb222 , ccc333")
	check(store.is_valid("aaa111"), "valid token accepted")
	check(store.label_for("aaa111") == "Alice", "label resolved")
	check(store.is_valid("ccc333") and store.label_for("ccc333") == "ccc333", "bare token uses itself as label")
	check(not store.is_valid("nope"), "unknown token rejected")
	check(not store.is_valid(""), "empty token rejected")
	check(AgentTokenStore.new("").count() == 0, "empty config -> no tokens")
	if failed == 0: print("✅ ALL AGENT TOKEN TESTS PASSED")
	else: printerr("❌ ", failed, " agent-token failures")
	quit(0 if failed == 0 else 1)

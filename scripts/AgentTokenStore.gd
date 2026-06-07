extends RefCounted
var _by_token := {}   # token -> label
func _init(spec: String) -> void:
	for raw in spec.split(",", false):
		var part := raw.strip_edges()
		if part == "": continue
		var label := part
		var token := part
		var colon := part.find(":")
		if colon > 0:
			label = part.substr(0, colon).strip_edges()
			token = part.substr(colon + 1).strip_edges()
		if token != "":
			_by_token[token] = label
func is_valid(token: String) -> bool:
	return token != "" and _by_token.has(token)
func label_for(token: String) -> String:
	return str(_by_token.get(token, ""))
func count() -> int:
	return _by_token.size()

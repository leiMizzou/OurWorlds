extends Node
# OurWorlds 账号客户端：用 HTTPRequest 直连 Nakama 的 REST API（不依赖完整 Nakama-Godot SDK，够轻）。
# 负责：邮箱/密码 注册+登录 → 拿到会话 token + user_id。社交登录(Google/GitHub/Twitter)后续在此扩展。
# token 之后用于"入场票"：客户端带着它连 Godot 世界服务器，服务器校验后放行（M4 握手）。

signal authenticated(session: Dictionary)   # {token, refresh_token, created, user_id}
signal auth_failed(message: String)

# Main 注入：联机时指向你的 Nakama（本地 docker 默认 127.0.0.1:7350）。server_key 与 nakama-config.yml 一致。
var base_url := "http://127.0.0.1:7350"
var server_key := "CHANGE_ME_server_key"

var _http: HTTPRequest

func _ready() -> void:
	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)

# 邮箱注册/登录（create=true：不存在则注册，存在则登录——幂等）。结果走 authenticated / auth_failed 信号。
func authenticate_email(email: String, password: String, create: bool = true) -> int:
	if _http == null:   # 需先进场景树（_ready 建 HTTPRequest）；防御性，不崩
		auth_failed.emit("client not ready")
		return ERR_UNCONFIGURED
	var url := "%s/v2/account/authenticate/email?create=%s" % [base_url, ("true" if create else "false")]
	var basic := "Basic " + Marshalls.utf8_to_base64(server_key + ":")
	var headers := PackedStringArray(["Authorization: " + basic, "Content-Type: application/json"])
	var body := JSON.stringify({"email": email, "password": password})
	return _http.request(url, headers, HTTPClient.METHOD_POST, body)

func _on_request_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		auth_failed.emit("network error (%d)" % result)   # Nakama 未运行/不可达
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	var data: Dictionary = parsed if typeof(parsed) == TYPE_DICTIONARY else {}
	if code != 200 or not data.has("token"):
		auth_failed.emit(str(data.get("message", "auth failed (HTTP %d)" % code)))
		return
	var token := str(data.get("token", ""))
	authenticated.emit({
		"token": token,
		"refresh_token": str(data.get("refresh_token", "")),
		"created": bool(data.get("created", false)),
		"user_id": _user_id_from_token(token),
	})

# 从 JWT 取 uid（payload 的 "uid"）。仅本地解码取值，不校验签名——签名校验在服务端。
func _user_id_from_token(token: String) -> String:
	var parts := token.split(".")
	if parts.size() != 3:
		return ""
	var payload: String = parts[1].replace("-", "+").replace("_", "/")   # base64url → base64
	while payload.length() % 4 != 0:
		payload += "="
	var p: Variant = JSON.parse_string(Marshalls.base64_to_utf8(payload))
	if typeof(p) == TYPE_DICTIONARY:
		return str((p as Dictionary).get("uid", ""))
	return ""

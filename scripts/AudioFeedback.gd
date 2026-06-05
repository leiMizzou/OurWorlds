extends Node
# 程序化短音效：每次反馈实时合成一小段 16-bit WAV 播放，不依赖外部素材。
# 复音对象池 + 频率/幅度抖动 + 噪声瞬态，UI/系统音走 2D，世界事件走 3D 方位声。

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")

const MIX_RATE := 44100
const POOL_SIZE := 4
const WORLD_POOL_SIZE := 4

# 世界内 3D 声源衰减参数：让"挖/放/营火"有空间感而不至于太远还很响。
const WORLD_UNIT_SIZE := 6.0
const WORLD_MAX_DISTANCE := 48.0

var volume := 0.65

# 复音池：2D 用于 UI/系统反馈，3D 用于世界内带坐标的事件。
var _pool: Array[AudioStreamPlayer] = []
var _pool_next := 0
var _world_pool: Array[AudioStreamPlayer3D] = []
var _world_pool_next := 0

var _audio_enabled := true
var _rng := RandomNumberGenerator.new()

var _last_kind := ""
var _last_label := ""
var _last_pattern := []
var _last_world_feedback_frame := -1
var _last_world_feedback_kind := ""
var _suppress_world_place_frame := -1

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rng.randomize()
	_audio_enabled = not _is_headless_run()
	if not _audio_enabled:
		return
	for i in range(POOL_SIZE):
		var p := AudioStreamPlayer.new()
		p.name = "Voice%d" % i
		add_child(p)
		_pool.append(p)
	for i in range(WORLD_POOL_SIZE):
		var p3 := AudioStreamPlayer3D.new()
		p3.name = "WorldVoice%d" % i
		p3.unit_size = WORLD_UNIT_SIZE
		p3.max_distance = WORLD_MAX_DISTANCE
		p3.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		add_child(p3)
		_world_pool.append(p3)

func _exit_tree() -> void:
	for p in _pool:
		if p != null:
			p.stop()
			p.stream = null
	for p3 in _world_pool:
		if p3 != null:
			p3.stop()
			p3.stream = null

func _is_headless_run() -> bool:
	if OS.has_feature("headless"):
		return true
	if DisplayServer.get_name().to_lower().contains("headless"):
		return true
	return OS.get_cmdline_args().has("--headless")

func set_volume(value: float) -> void:
	volume = clampf(value, 0.0, 1.0)

func bind(player_node, world_node) -> void:
	if player_node != null and player_node.has_signal("action_feedback"):
		player_node.action_feedback.connect(_on_feedback)
	if player_node != null and player_node.has_signal("world_feedback"):
		player_node.world_feedback.connect(_on_world_feedback)
	if player_node != null and player_node.has_signal("footstep"):
		player_node.footstep.connect(func(id): play_footstep(id))
	if player_node != null and player_node.has_signal("landed"):
		player_node.landed.connect(func(_id): play_land())
	if player_node != null and player_node.has_signal("splashed"):
		player_node.splashed.connect(func(): play_splash())
	if world_node != null and world_node.has_signal("save_feedback"):
		world_node.save_feedback.connect(_on_feedback)
	if world_node != null and world_node.has_signal("edit_feedback"):
		world_node.edit_feedback.connect(_on_feedback)

func bind_discovery(discovery_node) -> void:
	if discovery_node != null and discovery_node.has_signal("discovery_feedback"):
		discovery_node.discovery_feedback.connect(_on_feedback)

func bind_weather(weather_node) -> void:
	if weather_node != null and weather_node.has_signal("weather_changed"):
		weather_node.weather_changed.connect(_on_feedback)

func play_feedback(kind: String, label: String = "") -> void:
	_on_feedback(kind, label)

func play_block_feedback(kind: String, block_id: int) -> void:
	_record_and_play(kind, "block:%d" % block_id, _pattern_for_block_feedback(kind, block_id))

# ---- 新增交互音 API（仅提供方法，触发交给后续 wave） ----

# 脚步：按所踩方块材质给不同质感，世界内可挂坐标产生方位感。
func play_footstep(block_id: int, world_pos = null) -> void:
	_play_at(_pattern_for_footstep(block_id), world_pos)

# 落地：稍重的双段闷响。
func play_land(world_pos = null) -> void:
	_play_at([[150.0, 0.050, 0.34, "thud"], [96.0, 0.070, 0.26, "thud"]], world_pos)

# 入水：短促水花 + 噪声尾巴。
func play_splash(world_pos = null) -> void:
	_play_at([[300.0, 0.060, 0.20, "splash"], [210.0, 0.090, 0.16, "splash"]], world_pos)

# 轻量 UI 音：select / pick / open / close / shutter。
func play_ui(kind: String) -> void:
	_record_and_play(_ui_event_kind(kind), "ui:%s" % kind, _pattern_for_ui(kind))

func last_feedback_kind() -> String:
	return _last_kind

func last_feedback_label() -> String:
	return _last_label

func last_pattern() -> Array:
	return _last_pattern.duplicate(true)

func _on_feedback(kind: String, label: String) -> void:
	_record_and_play(kind, label, _pattern_for_feedback(kind, label))

func _on_world_feedback(kind: String, cell: Vector3i, block_id: int) -> void:
	if kind != "place" and kind != "break" and kind != "campfire" and kind != "bulk_place":
		return
	var frame := Engine.get_process_frames()
	# 方块世界事件挂到方块中心，产生 3D 方位感。
	var world_pos := Vector3(cell) + Vector3(0.5, 0.5, 0.5)
	if kind == "campfire":
		_suppress_world_place_frame = frame
		_record_and_play_at("campfire", "营火", _pattern_for_feedback("campfire", ""), world_pos)
		return
	if kind == "bulk_place":
		_suppress_world_place_frame = frame
		_last_world_feedback_frame = frame
		_last_world_feedback_kind = kind
		_record_and_play_at("bulk_place", _bulk_place_label(block_id), _pattern_for_feedback("bulk_place", ""), world_pos)
		return
	if kind == "place" and frame == _suppress_world_place_frame:
		return
	if frame == _last_world_feedback_frame and kind == _last_world_feedback_kind:
		return
	_last_world_feedback_frame = frame
	_last_world_feedback_kind = kind
	_record_and_play_at(kind, "block:%d" % block_id, _pattern_for_block_feedback(kind, block_id), world_pos)

func _record_and_play(kind: String, label: String, pattern: Array) -> void:
	_record_and_play_at(kind, label, pattern, null)

func _record_and_play_at(kind: String, label: String, pattern: Array, world_pos) -> void:
	_last_kind = kind
	_last_label = label
	_last_pattern = pattern.duplicate(true)
	if not _audio_enabled or volume <= 0.0:
		return
	var wav := _synthesize(_last_pattern)
	if wav == null:
		return
	if world_pos != null and not _world_pool.is_empty():
		_play_world(wav, world_pos)
	else:
		_play_2d(wav)

# 仅播放、不记录为“最后反馈”（脚步/落地/水花等环境音，不应覆盖 last_feedback 让存档/发现等提示丢失）。
func _play_at(pattern: Array, world_pos = null) -> void:
	if not _audio_enabled or volume <= 0.0:
		return
	var wav := _synthesize(pattern)
	if wav == null:
		return
	if world_pos != null and not _world_pool.is_empty():
		_play_world(wav, world_pos)
	else:
		_play_2d(wav)

# ---- 复音池：轮播，优先选空闲声部，否则覆盖最早的（不抢占正在响的全部） ----

func _play_2d(wav: AudioStreamWAV) -> void:
	var p := _pick_player()
	if p == null or not p.is_inside_tree():
		return
	p.stream = wav
	p.play()

func _play_world(wav: AudioStreamWAV, world_pos: Vector3) -> void:
	var p := _pick_world_player()
	if p == null or not p.is_inside_tree():
		return
	p.global_position = world_pos
	p.stream = wav
	p.play()

func _pick_player() -> AudioStreamPlayer:
	if _pool.is_empty():
		return null
	for i in range(_pool.size()):
		var idx := (_pool_next + i) % _pool.size()
		if not _pool[idx].playing:
			_pool_next = (idx + 1) % _pool.size()
			return _pool[idx]
	var fallback := _pool[_pool_next]
	_pool_next = (_pool_next + 1) % _pool.size()
	return fallback

func _pick_world_player() -> AudioStreamPlayer3D:
	if _world_pool.is_empty():
		return null
	for i in range(_world_pool.size()):
		var idx := (_world_pool_next + i) % _world_pool.size()
		if not _world_pool[idx].playing:
			_world_pool_next = (idx + 1) % _world_pool.size()
			return _world_pool[idx]
	var fallback := _world_pool[_world_pool_next]
	_world_pool_next = (_world_pool_next + 1) % _world_pool.size()
	return fallback

# ---- 逻辑音色表：每段 [freq, seconds, amp] 或带第 4 项音色标签的 [freq, seconds, amp, voice] ----
# 注：last_pattern() 暴露这些段供测试断言（材质明暗/段数/厚重度），合成在 _synthesize 内打磨质感。

func _pattern_for_feedback(kind: String, label: String = "") -> Array:
	match kind:
		"break":
			return [[145.0, 0.055, 0.55], [92.0, 0.045, 0.38]]
		"place":
			return [[220.0, 0.045, 0.36], [330.0, 0.060, 0.28]]
		"select":
			return [[520.0, 0.035, 0.22]]
		"pick":
			return [[620.0, 0.032, 0.20], [780.0, 0.045, 0.18]]
		"mode":
			return [[392.0, 0.045, 0.26], [588.0, 0.060, 0.22]]
		"save":
			return [[660.0, 0.055, 0.25], [880.0, 0.070, 0.22]]
		"undo":
			return [[420.0, 0.045, 0.22], [260.0, 0.060, 0.20]]
		"redo":
			return [[260.0, 0.045, 0.20], [420.0, 0.060, 0.22]]
		"discover":
			return [[392.0, 0.055, 0.24], [588.0, 0.070, 0.22], [784.0, 0.090, 0.20]]
		"journey":
			return [[523.0, 0.050, 0.22], [659.0, 0.060, 0.20], [784.0, 0.080, 0.18]]
		"campfire":
			return [[196.0, 0.045, 0.20], [392.0, 0.060, 0.18], [660.0, 0.070, 0.16]]
		"bulk_place":
			return [[164.0, 0.060, 0.30, "thud"], [246.0, 0.074, 0.24, "thud"], [392.0, 0.092, 0.18]]
		"weather":
			if label.contains("雨"):
				return [[310.0, 0.050, 0.18], [246.0, 0.070, 0.14]]
			if label.contains("雪"):
				return [[740.0, 0.055, 0.16], [988.0, 0.075, 0.13]]
			if label.contains("关闭"):
				return [[220.0, 0.045, 0.14]]
			return [[520.0, 0.040, 0.13]]
		"blocked":
			return [[130.0, 0.050, 0.32], [98.0, 0.060, 0.24]]
		_:
			return [[300.0, 0.045, 0.20]]

func _pattern_for_block_feedback(kind: String, block_id: int) -> Array:
	var tone := _block_tone(block_id)
	if kind == "break":
		match tone:
			"glass":
				return [[840.0, 0.026, 0.18, "click"], [1180.0, 0.030, 0.14, "click"], [620.0, 0.035, 0.12]]
			"wood":
				return [[160.0, 0.038, 0.28, "click"], [104.0, 0.050, 0.20]]
			"soft":
				return [[310.0, 0.030, 0.14, "noise"], [220.0, 0.036, 0.12]]
			"water":
				return [[260.0, 0.050, 0.12, "splash"], [190.0, 0.060, 0.10, "splash"]]
			"light":
				return [[760.0, 0.030, 0.16, "click"], [980.0, 0.042, 0.13]]
			_:
				return [[120.0, 0.040, 0.30, "click"], [82.0, 0.052, 0.22]]
	match tone:
		"glass":
			return [[720.0, 0.030, 0.18, "click"], [1040.0, 0.036, 0.14]]
		"wood":
			return [[185.0, 0.040, 0.26, "click"], [246.0, 0.050, 0.18]]
		"soft":
			return [[420.0, 0.034, 0.13, "noise"], [520.0, 0.044, 0.11]]
		"water":
			return [[210.0, 0.052, 0.12, "splash"], [280.0, 0.064, 0.10, "splash"]]
		"light":
			return [[620.0, 0.034, 0.16, "click"], [880.0, 0.050, 0.13]]
		_:
			return [[170.0, 0.040, 0.28, "click"], [230.0, 0.052, 0.20]]

# 脚步：按材质给质感，整体比敲击更轻更闷，叠少量噪声模拟踩踏。
func _pattern_for_footstep(block_id: int) -> Array:
	match _block_tone(block_id):
		"wood":
			return [[150.0, 0.034, 0.20, "click"], [110.0, 0.044, 0.14]]
		"glass":
			return [[640.0, 0.022, 0.14, "click"], [880.0, 0.028, 0.10]]
		"soft":
			return [[240.0, 0.030, 0.13, "noise"], [180.0, 0.040, 0.10, "noise"]]
		"water":
			return [[260.0, 0.044, 0.15, "splash"], [200.0, 0.058, 0.11, "splash"]]
		"light":
			return [[300.0, 0.026, 0.13, "click"], [420.0, 0.034, 0.10]]
		_:
			return [[120.0, 0.032, 0.18, "thud"], [96.0, 0.042, 0.13, "thud"]]

func _pattern_for_ui(kind: String) -> Array:
	match kind:
		"select":
			return [[520.0, 0.035, 0.22, "click"]]
		"pick":
			return [[620.0, 0.032, 0.20, "click"], [780.0, 0.045, 0.18]]
		"open":
			return [[392.0, 0.040, 0.20], [588.0, 0.055, 0.18]]
		"close":
			return [[588.0, 0.040, 0.18], [392.0, 0.055, 0.16]]
		"shutter":
			return [[1200.0, 0.012, 0.22, "click"], [180.0, 0.030, 0.14, "noise"]]
		_:
			return [[480.0, 0.034, 0.18, "click"]]

func _ui_event_kind(kind: String) -> String:
	# select/pick 复用既有反馈语义，其余统一记为 ui，保持公共反馈类型稳定。
	if kind == "select" or kind == "pick":
		return kind
	return "ui"

func _bulk_place_label(block_id: int) -> String:
	match _block_tone(block_id):
		"wood":
			return "结构放置：木作"
		"glass":
			return "结构放置：晶体"
		"soft":
			return "结构放置：景观"
		"light":
			return "结构放置：灯火"
		_:
			return "结构放置：石作"

func _block_tone(block_id: int) -> String:
	match block_id:
		BlockLibrary.LOG, BlockLibrary.PLANKS:
			return "wood"
		BlockLibrary.GLASS, BlockLibrary.BLUE_CRYSTAL:
			return "glass"
		BlockLibrary.LEAVES, BlockLibrary.PINE_LEAVES, BlockLibrary.WILDFLOWER, BlockLibrary.TALL_GRASS, BlockLibrary.RED_MUSHROOM, BlockLibrary.REEDS:
			return "soft"
		BlockLibrary.WATER:
			return "water"
		BlockLibrary.LANTERN, BlockLibrary.MOONSTONE_LAMP:
			return "light"
		_:
			return "stone"

# ---- 合成：16-bit / 44.1kHz，逐段抖动 + 快 attack + 短 decay + 噪声瞬态 ----

func _synthesize(steps: Array) -> AudioStreamWAV:
	var samples := PackedInt32Array()  # 临时收集 16-bit 样本值
	for step in steps:
		var base_freq: float = step[0]
		var seconds: float = step[1]
		var amp: float = step[2]
		var voice: String = step[3] if step.size() > 3 else "tone"
		# 频率 ±3~6% / 幅度 ±10% 随机抖动，避免机械重复
		var freq := base_freq * (1.0 + _rng.randf_range(-0.06, 0.06))
		var gain := amp * volume * (1.0 + _rng.randf_range(-0.10, 0.10))
		var frames := maxi(int(seconds * MIX_RATE), 1)
		# 快 attack(2~5ms) + 短 decay：敲击更脆
		var attack_s := _rng.randf_range(0.002, 0.005)
		var attack := clampi(int(attack_s * MIX_RATE), 1, frames)
		# 瞬态噪声段（敲击/水花）：极短白噪声打头，提升脆/湿质感
		var transient := 0
		var transient_gain := 0.0
		match voice:
			"click":
				transient = clampi(int(0.004 * MIX_RATE), 1, frames)
				transient_gain = gain * 0.9
			"thud":
				transient = clampi(int(0.006 * MIX_RATE), 1, frames)
				transient_gain = gain * 0.5
			"splash":
				transient = clampi(int(0.010 * MIX_RATE), 1, frames)
				transient_gain = gain * 0.8
			"noise":
				transient = clampi(int(0.008 * MIX_RATE), 1, frames)
				transient_gain = gain * 0.6
			_:
				transient = 0
		var prev_noise := 0.0
		for i in range(frames):
			var t := float(i) / float(MIX_RATE)
			# 包络：线性 attack 后指数式 decay，整体收尾干净
			var env: float
			if i < attack:
				env = float(i) / float(attack)
			else:
				var rel := float(i - attack) / float(maxi(frames - attack, 1))
				env = exp(-rel * 4.5)
			var osc := sin(TAU * freq * t)
			var sample := osc * gain * env
			# 瞬态：白噪声（splash/noise 低通柔化更"湿/沙"），随时间快速衰减
			if i < transient:
				var raw := _rng.randf_range(-1.0, 1.0)
				if voice == "splash" or voice == "noise":
					raw = lerpf(prev_noise, raw, 0.45)  # 简易低通
					prev_noise = raw
				var tenv := 1.0 - float(i) / float(maxi(transient, 1))
				sample += raw * transient_gain * tenv * tenv
			var v := clampi(int(round(sample * 32767.0)), -32768, 32767)
			samples.append(v)
	if samples.is_empty():
		return null
	# 打包为 16-bit 小端字节流（单声道）
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in range(samples.size()):
		var v := samples[i]
		if v < 0:
			v += 65536
		bytes[i * 2] = v & 0xff
		bytes[i * 2 + 1] = (v >> 8) & 0xff
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = MIX_RATE
	wav.stereo = false
	wav.data = bytes
	return wav

extends Node3D
# 轻量动态天气：控制天气状态，并在玩家附近绘制低成本体素风雨雪。

signal weather_changed(kind: String, label: String)

const MAX_DROPS := 260
const MAX_FLAKES := 190
const RAIN_AREA := 42.0
const RAIN_TOP := 26.0
const RAIN_BOTTOM := -8.0
const SNOW_AREA := 44.0
const SNOW_TOP := 22.0
const SNOW_BOTTOM := -6.0

# 环境声床：程序生成滤波白噪声循环，雨声/风声各一条，音量随强度线性绑定。
const AMBIENT_MIX_RATE := 44100
const AMBIENT_LOOP_SECONDS := 2.0
const AMBIENT_DB_MIN := -40.0   # 强度趋零时近乎静音
const AMBIENT_DB_MAX := -6.0    # 强度满时的最大响度

var target: Node3D
var enabled := true
var intensity := 0.0

var _target_intensity := 0.0
var _state := "clear"
var _label := "晴朗"
var _region_label := "草原"
var _timer := 0.0
var _rng := RandomNumberGenerator.new()
var _rain: MultiMeshInstance3D
var _snow: MultiMeshInstance3D
var _phase := 0.0
var _snow_phase := 0.0

# 环境声床循环播放器（雨/风），以及尊重总音量的主音量系数。
var _rain_sfx: AudioStreamPlayer
var _wind_sfx: AudioStreamPlayer
var _master_volume := 1.0
var _audio_enabled := true

func setup(track_target: Node3D, world_seed: int, weather_enabled: bool = true) -> void:
	target = track_target
	_rng.seed = int(world_seed) + 90210
	_audio_enabled = not _is_headless_run()
	_build_rain()
	_build_snow()
	_build_ambient()
	set_enabled(weather_enabled)

func _is_headless_run() -> bool:
	if OS.has_feature("headless"):
		return true
	if DisplayServer.get_name().to_lower().contains("headless"):
		return true
	return OS.get_cmdline_args().has("--headless")

# 总音量（0~1），尊重玩家音量设置；由后续 wave 调用，默认全音量。
func set_master_volume(value: float) -> void:
	_master_volume = clampf(value, 0.0, 1.0)
	_update_ambient_volume()

func set_enabled(value: bool) -> void:
	enabled = value
	if not enabled:
		_set_weather("off", "天气关闭", 0.0, true, true)
		return
	_timer = 0.0
	_choose_next(true)

func weather_label() -> String:
	return _effective_label()

func set_region_label(label: String) -> void:
	var before := _effective_label()
	_region_label = label if label != "" else "草原"
	_update_precipitation(0.0)
	var after := _effective_label()
	if enabled and after != before:
		weather_changed.emit("weather", after)

func force_weather(kind: String) -> void:
	enabled = true
	match kind:
		"clear":
			_set_weather("clear", "晴朗", 0.0, true, true)
		"drizzle":
			_set_weather("drizzle", "细雨", 0.38, true, true)
		"rain":
			_set_weather("rain", "阵雨", 0.78, true, true)
		"snow":
			_set_weather("snow", "飘雪", 0.58, true, true)
		_:
			_set_weather("clear", "晴朗", 0.0, true, true)
	_timer = 9999.0

func _process(delta: float) -> void:
	if not enabled:
		return
	_timer -= delta
	if _timer <= 0.0:
		_choose_next(false)
	intensity = lerpf(intensity, _target_intensity, minf(delta * 0.42, 1.0))
	_update_precipitation(delta)
	_update_ambient_volume()

func _choose_next(immediate: bool) -> void:
	var roll := _rng.randf()
	if roll < 0.52:
		_timer = _rng.randf_range(45.0, 90.0)
		_set_weather("clear", "晴朗", 0.0, true, immediate)
	elif roll < 0.78:
		_timer = _rng.randf_range(30.0, 58.0)
		_set_weather("drizzle", "细雨", 0.38, true, immediate)
	elif roll < 0.93:
		_timer = _rng.randf_range(24.0, 48.0)
		_set_weather("rain", "阵雨", 0.78, true, immediate)
	else:
		_timer = _rng.randf_range(28.0, 54.0)
		_set_weather("snow", "飘雪", 0.58, true, immediate)

func _set_weather(kind: String, label: String, target_value: float, emit_change: bool, immediate: bool) -> void:
	var before := _effective_label()
	var changed := _state != kind or _label != label
	_state = kind
	_label = label
	_target_intensity = clampf(target_value, 0.0, 1.0)
	if immediate:
		intensity = _target_intensity
		_update_precipitation(0.0)
		_update_ambient_volume()
	var after := _effective_label()
	if emit_change and (changed or after != before):
		weather_changed.emit("weather", after)

func _build_rain() -> void:
	if _rain != null:
		return
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.58, 0.78, 1.0, 0.40)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = MAX_DROPS
	mm.visible_instance_count = 0

	_rain = MultiMeshInstance3D.new()
	_rain.name = "Rain"
	_rain.multimesh = mm
	_rain.material_override = mat
	_rain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_rain.visible = false
	add_child(_rain)

func _build_snow() -> void:
	if _snow != null:
		return
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.92, 0.98, 1.0, 0.72)
	mat.emission_enabled = true
	mat.emission = Color(0.70, 0.88, 1.0) * 0.18
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = MAX_FLAKES
	mm.visible_instance_count = 0

	_snow = MultiMeshInstance3D.new()
	_snow.name = "Snow"
	_snow.multimesh = mm
	_snow.material_override = mat
	_snow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_snow.visible = false
	add_child(_snow)

# ---- 环境声床：程序生成的循环白噪声（雨=较亮的沙沙声，风=低频起伏的呼啸） ----

func _build_ambient() -> void:
	if not _audio_enabled or _rain_sfx != null:
		return
	_rain_sfx = AudioStreamPlayer.new()
	_rain_sfx.name = "RainBed"
	_rain_sfx.stream = _make_noise_loop("rain")
	_rain_sfx.volume_db = -80.0
	add_child(_rain_sfx)

	_wind_sfx = AudioStreamPlayer.new()
	_wind_sfx.name = "WindBed"
	_wind_sfx.stream = _make_noise_loop("wind")
	_wind_sfx.volume_db = -80.0
	add_child(_wind_sfx)

# 生成无缝循环的滤波白噪声 WAV（16-bit/44.1kHz，整周期循环）。
func _make_noise_loop(kind: String) -> AudioStreamWAV:
	var frames := int(AMBIENT_LOOP_SECONDS * AMBIENT_MIX_RATE)
	var noise_rng := RandomNumberGenerator.new()
	noise_rng.seed = _rng.seed + (101 if kind == "rain" else 202)
	# 雨：偏高频沙沙（轻低通）；风：强低通 + 缓慢幅度起伏（呼啸感）。
	var lp_alpha := 0.5 if kind == "rain" else 0.08
	var base_amp := 0.55 if kind == "rain" else 0.42
	var samples := PackedFloat32Array()
	samples.resize(frames)
	var prev := 0.0
	for i in range(frames):
		var raw := noise_rng.randf_range(-1.0, 1.0)
		prev = lerpf(prev, raw, lp_alpha)
		var v := prev
		if kind == "wind":
			# 缓慢正弦起伏，让风声有强弱呼吸
			var gust := 0.55 + 0.45 * (0.5 + 0.5 * sin(TAU * float(i) / float(frames) * 3.0))
			v *= gust
		samples[i] = v * base_amp
	# 交叉淡入淡出首尾，保证无缝循环（消除接缝爆音）
	var fade := int(0.05 * AMBIENT_MIX_RATE)
	for i in range(fade):
		var w := float(i) / float(fade)
		var head := samples[i]
		var tail := samples[frames - fade + i]
		samples[i] = lerpf(tail, head, w)
		samples[frames - fade + i] = lerpf(tail, head, w)
	# 打包 16-bit 小端单声道
	var bytes := PackedByteArray()
	bytes.resize(frames * 2)
	for i in range(frames):
		var s := clampi(int(round(samples[i] * 32767.0)), -32768, 32767)
		if s < 0:
			s += 65536
		bytes[i * 2] = s & 0xff
		bytes[i * 2 + 1] = (s >> 8) & 0xff
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = AMBIENT_MIX_RATE
	wav.stereo = false
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_begin = 0
	wav.loop_end = frames
	wav.data = bytes
	return wav

# 把已算好的雨/雪强度线性映射到 volume_db；强度趋零则停，尊重总音量。
func _update_ambient_volume() -> void:
	if not _audio_enabled or _rain_sfx == null or _wind_sfx == null:
		return
	var rain_level := 0.0
	var wind_level := 0.0
	if enabled and _master_volume > 0.0:
		if (_state == "drizzle" or _state == "rain") and not _is_cold_region():
			rain_level = clampf(intensity, 0.0, 1.0)
		# 雪天 / 寒区降水 / 阵雨都伴随风声（雪用风声铺底）
		if _state == "snow" or ((_state == "drizzle" or _state == "rain") and _is_cold_region()):
			wind_level = clampf(intensity, 0.0, 1.0)
		elif _state == "rain":
			wind_level = clampf(intensity * 0.5, 0.0, 1.0)  # 阵雨叠一点风
	_apply_bed(_rain_sfx, rain_level)
	_apply_bed(_wind_sfx, wind_level)

func _apply_bed(player: AudioStreamPlayer, level: float) -> void:
	if level <= 0.001:
		if player.playing:
			player.stop()
		player.volume_db = -80.0
		return
	# 线性映射强度到 dB，并叠加总音量（线性转 dB）做衰减
	var db := lerpf(AMBIENT_DB_MIN, AMBIENT_DB_MAX, clampf(level, 0.0, 1.0))
	db += linear_to_db(clampf(_master_volume, 0.0001, 1.0))
	player.volume_db = db
	if not player.playing and player.is_inside_tree():
		player.play()

func _update_precipitation(delta: float) -> void:
	_update_rain(delta)
	_update_snow(delta)

func _update_rain(delta: float) -> void:
	if _rain == null or _rain.multimesh == null:
		return
	var rain_strength := intensity if (_state == "drizzle" or _state == "rain") and not _is_cold_region() else 0.0
	var active := int(round(float(MAX_DROPS) * clampf(rain_strength, 0.0, 1.0)))
	_rain.multimesh.visible_instance_count = active
	_rain.visible = active > 0
	if active <= 0 or target == null:
		return

	var span := RAIN_TOP - RAIN_BOTTOM
	_phase = fmod(_phase + delta * (24.0 + intensity * 34.0), span)
	var origin := target.global_position if target.is_inside_tree() else target.position
	for i in range(active):
		var x := origin.x + (_hash01(i, 17) - 0.5) * RAIN_AREA
		var z := origin.z + (_hash01(i, 41) - 0.5) * RAIN_AREA
		var fall := fmod(_phase + float(i) * 2.37, span)
		var y := origin.y + RAIN_TOP - fall
		var basis := Basis.IDENTITY.scaled(Vector3(0.028, 1.2 + intensity * 0.65, 0.028))
		_rain.multimesh.set_instance_transform(i, Transform3D(basis, Vector3(x, y, z)))

func _update_snow(delta: float) -> void:
	if _snow == null or _snow.multimesh == null:
		return
	var snow_strength := intensity if _state == "snow" or ((_state == "drizzle" or _state == "rain") and _is_cold_region()) else 0.0
	var active := int(round(float(MAX_FLAKES) * clampf(snow_strength, 0.0, 1.0)))
	_snow.multimesh.visible_instance_count = active
	_snow.visible = active > 0
	if active <= 0 or target == null:
		return

	var span := SNOW_TOP - SNOW_BOTTOM
	_snow_phase = fmod(_snow_phase + delta * (4.0 + intensity * 6.0), span)
	var origin := target.global_position if target.is_inside_tree() else target.position
	for i in range(active):
		var drift := sin(_snow_phase * 0.18 + float(i) * 0.73) * 2.2
		var x := origin.x + (_hash01(i, 73) - 0.5) * SNOW_AREA + drift
		var z := origin.z + (_hash01(i, 97) - 0.5) * SNOW_AREA + cos(_snow_phase * 0.14 + float(i) * 0.61) * 1.3
		var fall := fmod(_snow_phase + float(i) * 1.91, span)
		var y := origin.y + SNOW_TOP - fall
		var size := lerpf(0.075, 0.145, _hash01(i, 131))
		var basis := Basis.IDENTITY.rotated(Vector3.UP, _hash01(i, 151) * TAU).scaled(Vector3(size, size * 0.42, size))
		_snow.multimesh.set_instance_transform(i, Transform3D(basis, Vector3(x, y, z)))

static func _hash01(i: int, salt: int) -> float:
	var h := i * 1103515245 + salt * 12345
	h = ((h >> 16) ^ h) * 73244475
	h = (h >> 16) ^ h
	return float(h & 0xffff) / 65535.0

func _effective_label() -> String:
	if _is_cold_region():
		if _state == "drizzle":
			return "小雪"
		if _state == "rain":
			return "山雪"
	return _label

func _is_cold_region() -> bool:
	return _region_label == "雪峰"

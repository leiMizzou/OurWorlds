extends Node
# 程序化环境氛围音乐（无外部素材）：合成一段无缝循环的柔和 pad，低音量长期播放，营造沉浸感。
# 昼/夜用同一段 pad，仅微调音量与低通感（通过音量呼吸），保持安静不抢戏。

const SR := 22050
const LOOP_SEC := 8.0
const BASE_DB := -17.0    # 音乐整体压低，作背景

var _player: AudioStreamPlayer
var _volume := 0.6        # 跟随设置的主音量(0..1)
var _daylight := 1.0

func setup(volume: float = 0.6) -> void:
	_volume = clampf(volume, 0.0, 1.0)
	_player = AudioStreamPlayer.new()
	_player.name = "PadPlayer"
	_player.bus = "Master"
	add_child(_player)
	_apply_volume()
	# pad 合成较重，延后到首帧后做，不拖慢开局。
	call_deferred("_build_and_play")

func _build_and_play() -> void:
	if _player == null:
		return
	_player.stream = _make_pad()
	_player.play()

func set_volume(volume: float) -> void:
	_volume = clampf(volume, 0.0, 1.0)
	_apply_volume()

# 昼夜微调：夜里更轻更静谧（可选，由 Main 每帧或换天时调用）。
func set_atmosphere(daylight: float) -> void:
	_daylight = clampf(daylight, 0.0, 1.0)
	_apply_volume()

func _apply_volume() -> void:
	if _player == null:
		return
	if _volume <= 0.002:
		_player.stream_paused = true
		return
	_player.stream_paused = false
	# 夜里再轻 3dB
	var night_trim := lerpf(-3.0, 0.0, _daylight)
	_player.volume_db = BASE_DB + night_trim + linear_to_db(clampf(_volume, 0.02, 1.0))

# 合成无缝循环 pad：若干正弦分音构成柔和大三和弦 + 缓慢 LFO 呼吸。
# 关键：所有频率吸附为"循环基频(1/LOOP_SEC)的整数倍"，循环点波形连续 -> 无爆音。
func _make_pad() -> AudioStreamWAV:
	var n := int(SR * LOOP_SEC)
	var freqs := [130.81, 196.00, 261.63, 329.63, 392.00, 523.25]   # C3 G3 C4 E4 G4 C5
	var amps := [1.0, 0.6, 0.55, 0.38, 0.26, 0.16]
	var snapped := []
	for f in freqs:
		snapped.append(round(float(f) * LOOP_SEC) / LOOP_SEC)
	var lfo1 := 1.0 / LOOP_SEC
	var lfo2 := 2.0 / LOOP_SEC
	var buf := PackedFloat32Array(); buf.resize(n)
	var peak := 0.0001
	for i in range(n):
		var t := float(i) / float(SR)
		var s := 0.0
		for k in range(snapped.size()):
			var lf: float = lfo1 if (k % 2 == 0) else lfo2
			var lfo := 0.60 + 0.40 * sin(TAU * lf * t + float(k) * 1.3)
			s += float(amps[k]) * lfo * sin(TAU * float(snapped[k]) * t)
		buf[i] = s
		peak = maxf(peak, absf(s))
	var norm := 0.5 / peak
	var data := PackedByteArray(); data.resize(n * 2)
	for i in range(n):
		var v := int(clampf(buf[i] * norm, -1.0, 1.0) * 32767.0)
		data[i * 2] = v & 0xff
		data[i * 2 + 1] = (v >> 8) & 0xff
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SR
	wav.stereo = false
	wav.data = data
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_begin = 0
	wav.loop_end = n
	return wav

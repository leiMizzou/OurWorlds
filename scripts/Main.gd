extends Node3D
# 启动入口：搭天空/雾/太阳，接好世界、玩家、HUD，并驱动昼夜循环。

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
const World = preload("res://scripts/World.gd")
const Player = preload("res://scripts/Player.gd")
const HUD = preload("res://scripts/HUD.gd")
const PauseMenu = preload("res://scripts/PauseMenu.gd")
const AudioFeedback = preload("res://scripts/AudioFeedback.gd")
const MusicDirector = preload("res://scripts/MusicDirector.gd")
const TitleScreen = preload("res://scripts/TitleScreen.gd")
const WorldCatalog = preload("res://scripts/WorldCatalog.gd")
const GameSettings = preload("res://scripts/GameSettings.gd")
const BlockPalette = preload("res://scripts/BlockPalette.gd")
const TravelJournal = preload("res://scripts/TravelJournal.gd")
const WorldMap = preload("res://scripts/WorldMap.gd")
const ActionEffects = preload("res://scripts/ActionEffects.gd")
const WeatherSystem = preload("res://scripts/WeatherSystem.gd")
const AmbientMotes = preload("res://scripts/AmbientMotes.gd")
const DiscoveryTracker = preload("res://scripts/DiscoveryTracker.gd")
const LandmarkMarker = preload("res://scripts/LandmarkMarker.gd")
const HomeBeacon = preload("res://scripts/HomeBeacon.gd")
const PhotoOverlay = preload("res://scripts/PhotoOverlay.gd")
const AgentBridge = preload("res://scripts/AgentBridge.gd")
const AgentAvatar = preload("res://scripts/AgentAvatar.gd")
const ChatHub = preload("res://scripts/ChatHub.gd")
const ChatPanel = preload("res://scripts/ChatPanel.gd")

const DAY_LEN := 180.0   # 一个昼夜 180 秒
const AUTO_SAVE_INTERVAL := 18.0
const SPAWN_MIN_Y := 29
const SPAWN_MAX_Y := 57
const SKY_RADIUS := 190.0
const STAR_COUNT := 120
const JOURNEY_EXPLORE_DISTANCE := 6.0
const SCREENSHOT_DIR := "user://screenshots"
const COVER_CAPTURE_SIZE := Vector2i(512, 288)

var lib: BlockLibrary
var world: World
var player: Player
var hud: HUD
var pause_menu: PauseMenu
var audio_feedback: AudioFeedback
var music: MusicDirector
var action_effects: ActionEffects
var weather_system: WeatherSystem
var ambient_motes: AmbientMotes
var discovery_tracker: DiscoveryTracker
var landmark_marker: LandmarkMarker
var home_beacon: HomeBeacon
var title_screen: TitleScreen
var block_palette: BlockPalette
var travel_journal: TravelJournal
var world_map: WorldMap
var photo_overlay: PhotoOverlay
var chat_hub
var chat_panel: ChatPanel

var _sun: DirectionalLight3D
var _env: Environment
var _sky_mat: ProceduralSkyMaterial
var _sky_root: Node3D
var _sun_disc: MeshInstance3D
var _moon_disc: MeshInstance3D
var _stars: MultiMeshInstance3D
var _sun_disc_mat: StandardMaterial3D
var _moon_disc_mat: StandardMaterial3D
var _star_mat: StandardMaterial3D
var _celestial_tex: ImageTexture
var _cloud_root: Node3D
var _cloud_mat: StandardMaterial3D
var _time := 0.30        # 0..1，开局清晨
var _auto_save_t := 0.0
var _title_active := false
var _title_settings_active := false
var _palette_active := false
var _palette_return_to_pause := false
var _journal_active := false
var _journal_return_to_pause := false
var _map_active := false
var _map_return_to_pause := false
var _photo_mode := false
var _current_seed := 1337
var _settings := {}
var _graphics_quality := "balanced"
var _quality_clouds_enabled := true
var _quality_star_visible_count := STAR_COUNT
var _quality_cloud_alpha := 0.82
var _quality_fog_scale := 1.0
var _last_region_label := ""
var _journey_start_pos := Vector3.ZERO
var _cover_capture_viewport: SubViewport
var _cover_capture_frames := 0
var _cover_capture_overlay_restore := true
var _pending_photo_feedback_kind := ""
var _pending_photo_feedback_label := ""
var _backup_recovery_feedback_shown := false
var _repair_feedback_cells := []
var _repair_feedback_deferred := false
var _landmark_restore_seen := {}
var _nearby_marker_active := false
var _nearby_marker_pos := Vector3.ZERO
var _restoration_marker_active := false
var _restoration_marker_pos := Vector3.ZERO
var _restoration_marker_progress := -1
var _restoration_marker_mode := "repair"

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 字体回退链：主字体是打包的 NotoSansSC 子集（覆盖 UI 静态文案，Web 也能显示中文）。
	# 再挂 ① 系统字体：原生平台补全任意 CJK（玩家/agent 动态输入的生僻字）+ 彩色 emoji；
	#       Web 无系统字体会自动跳过。② emoji 子集：让 🤖🧑🧱 在 Web 上也能显示（黑白）。
	var _ui_font := load("res://ui/fonts/NotoSansSC-OurWorlds.ttf") as FontFile
	if _ui_font != null:
		var _fallbacks: Array[Font] = []
		var _sys := SystemFont.new()
		_sys.font_names = PackedStringArray(["PingFang SC", "Heiti SC", "Noto Sans CJK SC", "Microsoft YaHei", "sans-serif"])
		_fallbacks.append(_sys)
		var _emoji_font := load("res://ui/fonts/NotoEmoji-OurWorlds.ttf") as FontFile
		if _emoji_font != null:
			_fallbacks.append(_emoji_font)
		_ui_font.fallbacks = _fallbacks
	_settings = GameSettings.load_settings()
	_graphics_quality = _sanitize_graphics_quality(str(_settings.get("graphics_quality", "balanced")))
	lib = BlockLibrary.new()
	_setup_environment()
	_setup_clouds()

	world = World.new()
	world.name = "World"
	add_child(world)
	_current_seed = _initial_seed()
	_setup_celestial_bodies()
	var save_file := _save_path_for_seed(_current_seed)
	world.setup(lib, _current_seed, save_file)
	world.set_view_radius(int(_settings.get("view_radius", 4)))
	if OS.has_environment("VC_RADIUS"):
		world.set_view_radius(int(OS.get_environment("VC_RADIUS")))
	_apply_graphics_quality(_graphics_quality)

	var spawn := _find_spawn_position()
	var t0 := Time.get_ticks_msec()
	world.prime(world.chunk_of(int(spawn.x), int(spawn.z)), 1)
	print("脚下区域就绪 ", Time.get_ticks_msec() - t0, " ms（其余边走边加载）")

	player = Player.new()
	player.name = "Player"
	add_child(player)
	player.lib = lib
	player.world = world
	player.global_position = spawn
	_journey_start_pos = spawn
	player.mouse_sensitivity = Player.DEFAULT_SENS * float(_settings.get("sensitivity", 1.0))
	player.set_recent_blocks(_settings.get("recent_blocks", []))
	player.material_picked.connect(_on_player_material_picked)
	world.track_target = player

	hud = HUD.new()
	hud.name = "HUD"
	add_child(hud)
	hud.setup(lib, player)
	player.action_feedback.connect(_on_player_action_progress)
	player.world_feedback.connect(_on_player_world_feedback)
	hud.set_recent_blocks(_settings.get("recent_blocks", []))
	_sync_hud_region(false)
	_sync_hud_journey()
	_sync_hud_save_state()
	world.save_feedback.connect(hud.show_feedback)
	world.edit_feedback.connect(hud.show_feedback)

	audio_feedback = AudioFeedback.new()
	audio_feedback.name = "AudioFeedback"
	add_child(audio_feedback)
	audio_feedback.set_volume(float(_settings.get("volume", 0.65)))
	audio_feedback.bind(player, world)

	music = MusicDirector.new()
	music.name = "MusicDirector"
	add_child(music)
	music.setup(float(_settings.get("volume", 0.65)))

	action_effects = ActionEffects.new()
	action_effects.name = "ActionEffects"
	add_child(action_effects)
	action_effects.setup(lib)
	action_effects.bind(player)

	weather_system = WeatherSystem.new()
	weather_system.name = "WeatherSystem"
	add_child(weather_system)
	weather_system.weather_changed.connect(_on_weather_changed)
	weather_system.setup(player, _current_seed, bool(_settings.get("weather_enabled", true)))
	audio_feedback.bind_weather(weather_system)
	if hud != null:
		hud.set_weather_label(weather_system.weather_label())

	ambient_motes = AmbientMotes.new()
	ambient_motes.name = "AmbientMotes"
	add_child(ambient_motes)
	ambient_motes.setup(player, _current_seed)

	discovery_tracker = DiscoveryTracker.new()
	discovery_tracker.name = "DiscoveryTracker"
	add_child(discovery_tracker)
	discovery_tracker.setup(world, player)
	discovery_tracker.discovery_feedback.connect(_on_discovery_feedback)
	discovery_tracker.landmark_discovered.connect(_on_landmark_discovered)
	discovery_tracker.nearby_hint_changed.connect(_on_nearby_hint_changed)
	audio_feedback.bind_discovery(discovery_tracker)
	if hud != null:
		hud.set_discovery_count(discovery_tracker.discovered_count())
	_sync_hud_restoration()
	_prime_landmark_restore_seen()

	landmark_marker = LandmarkMarker.new()
	landmark_marker.name = "LandmarkMarker"
	add_child(landmark_marker)
	landmark_marker.setup()
	_update_landmark_marker()

	home_beacon = HomeBeacon.new()
	home_beacon.name = "HomeBeacon"
	add_child(home_beacon)
	home_beacon.setup(_journey_start_pos, player)

	pause_menu = PauseMenu.new()
	pause_menu.name = "PauseMenu"
	add_child(pause_menu)
	pause_menu.setup(world.view_radius, audio_feedback.volume, float(_settings.get("sensitivity", 1.0)), bool(_settings.get("weather_enabled", true)), _graphics_quality)
	pause_menu.resume_requested.connect(_on_pause_resume_requested)
	pause_menu.save_requested.connect(_save_from_menu)
	pause_menu.palette_requested.connect(func(): set_palette_active(true))
	pause_menu.journal_requested.connect(func(): set_journal_active(true))
	pause_menu.map_requested.connect(func(): set_world_map_active(true))
	pause_menu.title_requested.connect(_return_to_title_from_pause)
	pause_menu.view_radius_changed.connect(_on_view_radius_changed)
	pause_menu.volume_changed.connect(_on_volume_changed)
	pause_menu.sensitivity_changed.connect(_on_sensitivity_changed)
	pause_menu.weather_enabled_changed.connect(_on_weather_enabled_changed)
	pause_menu.graphics_quality_changed.connect(_on_graphics_quality_changed)

	block_palette = BlockPalette.new()
	block_palette.name = "BlockPalette"
	add_child(block_palette)
	block_palette.setup(lib, _settings.get("recent_blocks", []))
	block_palette.block_selected.connect(_on_palette_block_selected)
	block_palette.close_requested.connect(func(): set_palette_active(false))

	travel_journal = TravelJournal.new()
	travel_journal.name = "TravelJournal"
	add_child(travel_journal)
	travel_journal.setup()
	travel_journal.close_requested.connect(func(): set_journal_active(false))

	world_map = WorldMap.new()
	world_map.name = "WorldMap"
	add_child(world_map)
	world_map.setup()
	world_map.close_requested.connect(func(): set_world_map_active(false))

	photo_overlay = PhotoOverlay.new()
	photo_overlay.name = "PhotoOverlay"
	add_child(photo_overlay)
	photo_overlay.setup()

	title_screen = TitleScreen.new()
	title_screen.name = "TitleScreen"
	add_child(title_screen)
	title_screen.setup(WorldCatalog.list_worlds(), _current_seed, _current_seed)
	title_screen.continue_requested.connect(_continue_selected_world)
	title_screen.new_world_requested.connect(_start_new_world)
	title_screen.delete_world_requested.connect(_delete_world_from_title)
	title_screen.settings_requested.connect(_open_title_settings)
	if OS.has_environment("VC_SKIP_TITLE"):
		set_title_active(false)
	else:
		set_title_active(true)
	_show_backup_recovery_feedback_if_needed()
	chat_hub = ChatHub.new()
	chat_hub.register("player", "你", "human")
	chat_panel = ChatPanel.new()
	add_child(chat_panel)
	chat_panel.setup(chat_hub, "player")
	_setup_agent_bridge()

# 代理桥（仅在设置了 OW_AGENT_PORT 时启用）：让外部 LLM 经 TCP/NDJSON 感知并操作游戏。
# 行为完全在该 flag 之后，正常游玩不受影响。
func _setup_agent_bridge() -> void:
	if not OS.has_environment("OW_AGENT_PORT"):
		return
	var bridge := AgentBridge.new()
	bridge.name = "AgentBridge"
	bridge.world = world
	bridge.player = player
	bridge.hud = hud
	bridge.chat_hub = chat_hub
	# opc-ourworlds 的专属身体：跟玩家分开，桥驱动它
	var ai_avatar := AgentAvatar.new()
	ai_avatar.name = "AgentAvatar"
	world.add_child(ai_avatar)
	ai_avatar.global_position = player.global_position + Vector3(3, 0, 0)
	bridge.avatar = ai_avatar
	add_child(bridge)

func _initial_seed() -> int:
	if OS.has_environment("VC_SEED"):
		return int(OS.get_environment("VC_SEED"))
	return WorldCatalog.latest_seed(1337)

func _save_path_for_seed(seed: int) -> String:
	if OS.has_environment("VC_NO_SAVE"):
		return ""
	return WorldCatalog.save_path_for_seed(seed)

func _find_spawn_position() -> Vector3:
	var best := Vector3(0.5, world.surface_y(0, 0) + 3, 0.5)
	var best_score: float = INF
	for z in range(-96, 97, 8):
		for x in range(-96, 97, 8):
			var h: int = world.surface_y(x, z)
			if h < SPAWN_MIN_Y or h > SPAWN_MAX_Y:
				continue
			var flat: int = abs(h - world.surface_y(x + 4, z)) + abs(h - world.surface_y(x - 4, z)) \
				+ abs(h - world.surface_y(x, z + 4)) + abs(h - world.surface_y(x, z - 4))
			var score: float = float(flat) * 7.0 + Vector2(x, z).length() * 0.08 + abs(float(h - 37)) * 0.7
			if score < best_score:
				best_score = score
				best = Vector3(x + 0.5, h + 3, z + 0.5)
	return best

func _process(delta: float) -> void:
	_process_cover_capture()
	if get_tree().paused:
		return
	_time = fmod(_time + delta / DAY_LEN, 1.0)
	var daylight := clampf(sin(_time * TAU - PI * 0.5) * 0.5 + 0.5, 0.0, 1.0)
	var rain := weather_system.intensity if weather_system != null else 0.0

	# 太阳：白天明亮高悬、清晨黄昏低角暖色，夜里近乎熄灭
	_sun.light_energy = lerpf(0.02, lerpf(1.2, 0.72, rain), daylight)
	_sun.light_color = Color(1.0, 0.6, 0.35).lerp(Color(1.0, 0.96, 0.88).lerp(Color(0.72, 0.82, 0.92), rain), daylight)
	_sun.rotation_degrees = Vector3(lerpf(-6.0, -78.0, daylight), lerpf(-95.0, 95.0, _time), 0)
	_update_celestial_bodies(daylight, rain)
	if ambient_motes != null:
		ambient_motes.set_atmosphere(daylight, rain)
	if music != null:
		music.set_atmosphere(daylight)
	_sync_hud_region(true)
	_update_journey_explore()
	_sync_hud_save_state()

	# 天空 / 雾随昼夜变色
	var day_top := Color(0.24, 0.47, 0.90).lerp(Color(0.20, 0.28, 0.36), rain)
	var night_top := Color(0.02, 0.03, 0.09)
	var day_hor := Color(0.70, 0.83, 0.96).lerp(Color(0.48, 0.56, 0.62), rain)
	var night_hor := Color(0.05, 0.07, 0.14)
	_sky_mat.sky_top_color = night_top.lerp(day_top, daylight)
	_sky_mat.sky_horizon_color = night_hor.lerp(day_hor, daylight)
	_sky_mat.ground_horizon_color = night_hor.lerp(day_hor, daylight)
	_env.fog_light_color = night_hor.lerp(day_hor, daylight)
	_env.fog_density = lerpf(0.0052, 0.0135, rain) * _quality_fog_scale
	_env.ambient_light_energy = lerpf(0.12, 0.6, daylight)
	_env.adjustment_saturation = lerpf(1.06, 0.94, rain)
	if _cloud_root != null:
		_cloud_root.position.x = fmod(_cloud_root.position.x + delta * lerpf(0.35, 0.72, rain) + 256.0, 512.0) - 256.0
	if _cloud_mat != null:
		var cloud_day := Color(1.0, 0.96, 0.88, 0.72).lerp(Color(0.54, 0.60, 0.66, 0.84), rain)
		var cloud_night := Color(0.16, 0.19, 0.26, 0.54).lerp(Color(0.12, 0.14, 0.18, 0.66), rain)
		var cloud_color := cloud_night.lerp(cloud_day, daylight)
		cloud_color.a *= _quality_cloud_alpha
		_cloud_mat.albedo_color = cloud_color
	_auto_save_t += delta
	if _auto_save_t >= AUTO_SAVE_INTERVAL:
		_auto_save_t = 0.0
		if world != null and world.has_unsaved_changes():
			_complete_journey_step("save_world", false)
			world.save_world()
			_sync_hud_save_state()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and world != null:
		world.save_world(true)

func _show_backup_recovery_feedback_if_needed() -> void:
	if _backup_recovery_feedback_shown or world == null or not world.loaded_from_backup():
		return
	if _title_active or hud == null or not hud.visible:
		return
	_backup_recovery_feedback_shown = true
	var label := "已从备份恢复世界，请保存"
	hud.show_feedback("save", label)
	if audio_feedback != null:
		audio_feedback.play_feedback("save", label)

func _unhandled_input(event: InputEvent) -> void:
	if _title_settings_active:
		if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
			_close_title_settings()
		get_viewport().set_input_as_handled()
		return
	if _map_active:
		if event is InputEventKey and event.pressed and not event.echo and (event.keycode == KEY_ESCAPE or event.keycode == KEY_M):
			set_world_map_active(false)
			get_viewport().set_input_as_handled()
		return
	if _journal_active:
		if event is InputEventKey and event.pressed and not event.echo and (event.keycode == KEY_ESCAPE or event.keycode == KEY_J):
			set_journal_active(false)
			get_viewport().set_input_as_handled()
		return
	if _palette_active:
		if event is InputEventKey and event.pressed and not event.echo:
			if event.keycode == KEY_ESCAPE or event.keycode == KEY_E:
				set_palette_active(false)
				get_viewport().set_input_as_handled()
			elif block_palette != null and block_palette.handle_palette_key(event.keycode):
				get_viewport().set_input_as_handled()
		return
	if chat_panel != null and chat_panel.is_open():
		if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
			set_chat_active(false)
			get_viewport().set_input_as_handled()
		return
	if _title_active:
		if event is InputEventKey and event.pressed and not event.echo:
			if event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
				if title_screen != null:
					title_screen.request_continue_selected()
				else:
					set_title_active(false)
				get_viewport().set_input_as_handled()
			elif event.keycode == KEY_LEFT:
				if title_screen != null and title_screen.request_move_selection(-1):
					get_viewport().set_input_as_handled()
			elif event.keycode == KEY_RIGHT:
				if title_screen != null and title_screen.request_move_selection(1):
					get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F1:
		set_photo_mode(not _photo_mode)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F2:
		save_screenshot()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_E:
		set_palette_active(true)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_J:
		set_journal_active(true)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_M:
		set_world_map_active(true)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo and (event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER):
		set_chat_active(true)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		set_game_paused(not get_tree().paused)
		get_viewport().set_input_as_handled()

func set_chat_active(active: bool) -> void:
	if chat_panel == null:
		return
	if active:
		chat_panel.open()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		if player != null:
			player.set_physics_process(false)
			player.set_process_unhandled_input(false)
	else:
		chat_panel.close()
		if player != null:
			player.set_physics_process(true)
			player.set_process_unhandled_input(true)
		if not _title_active and not _palette_active and not _journal_active and not _map_active and not get_tree().paused:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func set_game_paused(paused: bool) -> void:
	if _title_active or _palette_active or _journal_active or _map_active:
		return
	get_tree().paused = paused
	if player != null:
		player.input_enabled = not paused
		if pause_menu != null:
			if paused:
				_open_pause_menu()
			else:
				pause_menu.close()
		if not paused:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_update_photo_overlay()

func set_title_active(active: bool) -> void:
	_title_active = active
	_title_settings_active = false
	_palette_active = false
	_palette_return_to_pause = false
	_journal_active = false
	_journal_return_to_pause = false
	_map_active = false
	_map_return_to_pause = false
	get_tree().paused = active
	if player != null:
		player.input_enabled = not active
	if hud != null:
		hud.visible = not active and not _photo_mode
	if pause_menu != null:
		pause_menu.close()
	if block_palette != null:
		block_palette.close()
	if travel_journal != null:
		travel_journal.close()
	if world_map != null:
		world_map.close()
	if title_screen != null:
		if active:
			_refresh_title_worlds(_current_seed)
			title_screen.open()
		else:
			title_screen.close()
	if active:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_update_landmark_marker()
	_update_photo_overlay()
	if not active:
		_show_backup_recovery_feedback_if_needed()

func _open_title_settings() -> void:
	if not _title_active or pause_menu == null:
		return
	_title_settings_active = true
	get_tree().paused = true
	if player != null:
		player.input_enabled = false
		if hud != null:
			hud.visible = false
		pause_menu.open(true)
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_update_photo_overlay()

func _close_title_settings() -> void:
	if not _title_settings_active:
		return
	_title_settings_active = false
	if pause_menu != null:
		pause_menu.close()
	get_tree().paused = _title_active
	if player != null:
		player.input_enabled = not _title_active
	if hud != null:
		hud.visible = not _title_active and not _photo_mode
		if _title_active:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_update_photo_overlay()

func _on_pause_resume_requested() -> void:
	if _title_settings_active:
		_close_title_settings()
	else:
		set_game_paused(false)

func _return_to_title_from_pause() -> void:
	if _title_active:
		return
	var saved := false
	if world != null:
		saved = world.save_world(true)
		_sync_hud_save_state()
	if saved:
		_queue_world_cover_capture()
	_refresh_title_worlds(_current_seed)
	set_title_active(true)

func _refresh_title_worlds(selected_seed: int) -> void:
	if title_screen == null:
		return
	title_screen.set_worlds(WorldCatalog.list_worlds(), selected_seed)

func set_palette_active(active: bool) -> void:
	if _title_active or _journal_active or _map_active:
		return
	if active:
		_complete_journey_step("open_palette")
		_palette_return_to_pause = get_tree().paused and pause_menu != null and pause_menu.visible
	_palette_active = active
	get_tree().paused = active
	if player != null:
		player.input_enabled = not active
	if pause_menu != null:
		pause_menu.close()
	if block_palette != null:
		if active:
			block_palette.open(player.current_block() if player != null else BlockLibrary.GRASS)
		else:
			block_palette.close()
		if active:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			if _palette_return_to_pause:
				get_tree().paused = true
				if player != null:
					player.input_enabled = false
				_open_pause_menu()
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			else:
				get_tree().paused = false
				if player != null:
					player.input_enabled = true
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			_palette_return_to_pause = false
		_update_photo_overlay()

func set_journal_active(active: bool) -> void:
	if _title_active or _map_active:
		return
	if active:
		_journal_return_to_pause = get_tree().paused and pause_menu != null and pause_menu.visible
		_journal_active = true
		_palette_active = false
		get_tree().paused = true
		if player != null:
			player.input_enabled = false
		if pause_menu != null:
			pause_menu.close()
		if block_palette != null:
			block_palette.close()
		if travel_journal != null:
			travel_journal.open(_journal_data())
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_update_photo_overlay()
		return
	if not _journal_active:
		return
	_journal_active = false
	if travel_journal != null:
		travel_journal.close()
	if _journal_return_to_pause:
		get_tree().paused = true
		if player != null:
			player.input_enabled = false
		_open_pause_menu()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		get_tree().paused = false
		if player != null:
			player.input_enabled = true
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_journal_return_to_pause = false
	_update_photo_overlay()

func set_world_map_active(active: bool) -> void:
	if _title_active or _journal_active:
		return
	if active:
		_complete_journey_step("open_map")
		_map_return_to_pause = get_tree().paused and pause_menu != null and pause_menu.visible
		_map_active = true
		_palette_active = false
		get_tree().paused = true
		if player != null:
			player.input_enabled = false
		if pause_menu != null:
			pause_menu.close()
		if block_palette != null:
			block_palette.close()
		if world_map != null:
			world_map.open(_map_data())
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_update_photo_overlay()
		return
	if not _map_active:
		return
	_map_active = false
	if world_map != null:
		world_map.close()
	if _map_return_to_pause:
		get_tree().paused = true
		if player != null:
			player.input_enabled = false
		_open_pause_menu()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		get_tree().paused = false
		if player != null:
			player.input_enabled = true
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_map_return_to_pause = false
	_update_photo_overlay()

func set_photo_mode(active: bool) -> void:
	_photo_mode = active
	if hud != null:
		hud.visible = not active and not _title_active
	if player != null and player.has_method("set_overlays_visible"):
		player.set_overlays_visible(not active)
	_update_photo_overlay()
	if hud != null and hud.visible:
		if not active and _pending_photo_feedback_label != "":
			hud.show_feedback(_pending_photo_feedback_kind, _pending_photo_feedback_label)
			_pending_photo_feedback_kind = ""
			_pending_photo_feedback_label = ""
		else:
			hud.show_feedback("mode", "界面已显示")

func _update_photo_overlay() -> void:
	if photo_overlay == null:
		return
	var active := _photo_mode \
		and not _title_active \
		and not _title_settings_active \
		and not _palette_active \
		and not _journal_active \
		and not _map_active \
		and not get_tree().paused
	photo_overlay.set_active(active)

func save_screenshot() -> String:
	if DisplayServer.get_name().to_lower().contains("headless"):
		_show_screenshot_feedback(false, "")
		return ""
	var overlay_was_active := photo_overlay != null and photo_overlay.is_active()
	if overlay_was_active:
		photo_overlay.set_active(false)
	var texture := get_viewport().get_texture()
	if texture == null:
		_update_photo_overlay()
		_show_screenshot_feedback(false, "")
		return ""
	var img := texture.get_image()
	if img == null or img.is_empty():
		_update_photo_overlay()
		_show_screenshot_feedback(false, "")
		return ""
	var path := _screenshot_path()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SCREENSHOT_DIR))
	var err := img.save_png(path)
	if err != OK:
		_update_photo_overlay()
		_show_screenshot_feedback(false, "")
		return ""
	_update_photo_overlay()
	_show_screenshot_feedback(true, path)
	return path

func _screenshot_path() -> String:
	var dt: Dictionary = Time.get_datetime_dict_from_system()
	var stamp := "%04d%02d%02d_%02d%02d%02d_%03d" % [
		int(dt.get("year", 0)), int(dt.get("month", 0)), int(dt.get("day", 0)),
		int(dt.get("hour", 0)), int(dt.get("minute", 0)), int(dt.get("second", 0)),
		int(Time.get_ticks_msec() % 1000),
	]
	return "%s/ourworlds_%s.png" % [SCREENSHOT_DIR, stamp]

func _show_screenshot_feedback(ok: bool, path: String) -> void:
	if hud == null:
		return
	var kind := "save" if ok else "blocked"
	var label := "当前渲染驱动无法截图"
	if ok:
		label = "截图已保存：" + path.get_file()
	if not hud.visible:
		if _photo_mode:
			_pending_photo_feedback_kind = kind
			_pending_photo_feedback_label = label
		return
	hud.show_feedback(kind, label)

func _queue_world_cover_capture() -> void:
	if DisplayServer.get_name().to_lower().contains("headless"):
		return
	if world == null or world.save_path == "":
		return
	if player == null or player.camera == null:
		return
	if _cover_capture_viewport != null:
		_cleanup_cover_capture()
	if player.has_method("set_overlays_visible"):
		_cover_capture_overlay_restore = bool(player.overlays_visible)
		player.set_overlays_visible(false)
	var vp := SubViewport.new()
	vp.name = "WorldCoverCapture"
	vp.size = COVER_CAPTURE_SIZE
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.world_3d = get_viewport().world_3d
	var cam := Camera3D.new()
	cam.current = true
	cam.fov = player.camera.fov
	cam.near = player.camera.near
	cam.far = player.camera.far
	cam.global_transform = player.camera.global_transform
	vp.add_child(cam)
	add_child(vp)
	_cover_capture_viewport = vp
	_cover_capture_frames = 2

func _process_cover_capture() -> void:
	if _cover_capture_viewport == null:
		return
	_cover_capture_frames -= 1
	if _cover_capture_frames > 0:
		return
	var texture := _cover_capture_viewport.get_texture()
	var img: Image = texture.get_image() if texture != null else null
	if img != null and not img.is_empty():
		_store_world_cover_from_image(img)
	_cleanup_cover_capture()

func _store_world_cover_from_image(img: Image) -> String:
	if img == null or img.is_empty() or world == null or world.save_path == "":
		return ""
	var out := img.duplicate()
	if out.get_width() != COVER_CAPTURE_SIZE.x or out.get_height() != COVER_CAPTURE_SIZE.y:
		out.resize(COVER_CAPTURE_SIZE.x, COVER_CAPTURE_SIZE.y, Image.INTERPOLATE_LANCZOS)
	var path := WorldCatalog.cover_path_for_seed(_current_seed)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var err: int = out.save_png(path)
	if err != OK:
		return ""
	world.set_cover_path(path)
	world.save_world(true)
	_sync_hud_save_state()
	if _title_active:
		_refresh_title_worlds(_current_seed)
	return path

func _cleanup_cover_capture(restore_overlay: bool = true) -> void:
	if _cover_capture_viewport != null:
		_cover_capture_viewport.queue_free()
		_cover_capture_viewport = null
	_cover_capture_frames = 0
	if restore_overlay and player != null and player.has_method("set_overlays_visible"):
		player.set_overlays_visible(_cover_capture_overlay_restore)

func _journal_data() -> Dictionary:
	var region := _last_region_label
	var region_detail := ""
	var player_pos := player.global_position if player != null else Vector3.ZERO
	if region == "" and world != null and player != null and world.has_method("region_label"):
		region = world.region_label(int(floor(player_pos.x)), int(floor(player_pos.z)))
		if world.has_method("region_description"):
			region_detail = world.region_description(int(floor(player_pos.x)), int(floor(player_pos.z)))
	elif world != null and player != null and world.has_method("region_description"):
		region_detail = world.region_description(int(floor(player_pos.x)), int(floor(player_pos.z)))
	var save_status := "本地会话"
	if world != null and world.save_path != "":
		save_status = "有改动" if world.has_unsaved_changes() else "已保存"
	var landmarks := []
	if discovery_tracker != null and discovery_tracker.has_method("discovered_entries"):
		landmarks = _landmarks_with_navigation(discovery_tracker.discovered_entries())
	var restoration_target := _restoration_target_data(landmarks)
	var visited_regions := world.visited_regions() if world != null and world.has_method("visited_regions") else []
	return {
		"world_name": WorldCatalog.world_name(_current_seed),
		"seed": _current_seed,
		"region": region if region != "" else "未知区域",
		"region_detail": region_detail,
		"weather": weather_system.weather_label() if weather_system != null else "晴朗",
		"save_status": save_status,
		"edit_count": world.edit_count() if world != null else 0,
		"journey_steps": world.journey_steps() if world != null else [],
		"journey_total": world.journey_total() if world != null else WorldCatalog.JOURNEY_TOTAL,
		"visited_regions": visited_regions,
		"region_count": world.region_count() if world != null and world.has_method("region_count") else visited_regions.size(),
		"region_total": world.region_total() if world != null and world.has_method("region_total") else 0,
		"landmarks": landmarks,
		"restoration_target": restoration_target,
		"nearby_distance": discovery_tracker.nearby_hint_distance() if discovery_tracker != null else -1,
		"nearby_direction": discovery_tracker.nearby_hint_direction() if discovery_tracker != null else "",
		"home_distance": _home_distance(),
		"home_direction": _direction_label_to(_journey_start_pos),
	}

func _landmarks_with_navigation(entries: Array) -> Array:
	var result := []
	for raw in entries:
		var entry: Dictionary = raw.duplicate(true)
		var pos := _landmark_entry_world_pos(entry)
		var distance := _flat_distance_to_player(pos)
		var direction := _direction_label_to(pos)
		entry["distance"] = distance
		entry["direction"] = direction
		entry["nav_label"] = _navigation_label(distance, direction)
		result.append(entry)
	result.sort_custom(_compare_landmark_navigation)
	return result

func _compare_landmark_navigation(a: Dictionary, b: Dictionary) -> bool:
	var a_complete := _landmark_entry_complete(a)
	var b_complete := _landmark_entry_complete(b)
	if a_complete != b_complete:
		return not a_complete
	var a_percent := int(a.get("restore_percent", 0))
	var b_percent := int(b.get("restore_percent", 0))
	if a_percent != b_percent:
		return a_percent > b_percent
	return int(a.get("distance", 999999)) < int(b.get("distance", 999999))

func _restoration_target_data(landmarks: Array) -> Dictionary:
	var target := {}
	for raw in landmarks:
		var entry: Dictionary = raw
		if _landmark_entry_complete(entry):
			continue
		if target.is_empty() or _compare_restoration_target(entry, target):
			target = entry
	if target.is_empty() and not landmarks.is_empty():
		target = landmarks[0]
	if target.is_empty():
		return {}
	var pos := _landmark_entry_world_pos(target)
	return {
			"key": String(target.get("key", "")),
			"label": String(target.get("label", "古遗迹")),
			"restore_percent": int(target.get("restore_percent", 0)),
			"restore_label": String(target.get("restore_label", "待修复")),
			"restore_complete": _landmark_entry_complete(target),
			"archive": String(target.get("archive", "")),
			"distance": int(target.get("distance", _flat_distance_to_player(pos))),
			"direction": String(target.get("direction", _direction_label_to(pos))),
			"nav_label": String(target.get("nav_label", _navigation_label(_flat_distance_to_player(pos), _direction_label_to(pos)))),
			"world_pos": pos,
		}

func _compare_restoration_target(a: Dictionary, b: Dictionary) -> bool:
	var a_percent := int(a.get("restore_percent", 0))
	var b_percent := int(b.get("restore_percent", 0))
	if a_percent != b_percent:
		return a_percent > b_percent
	return int(a.get("distance", 999999)) < int(b.get("distance", 999999))

func _landmark_entry_complete(entry: Dictionary) -> bool:
	return bool(entry.get("restore_complete", false)) or int(entry.get("restore_percent", 0)) >= 100

func _landmark_entry_world_pos(entry: Dictionary) -> Vector3:
	var pos := _landmark_entry_pos(entry)
	return Vector3(pos.x, pos.y, pos.z) + Vector3(0.5, 0.5, 0.5)

func _flat_distance_to_player(target_pos: Vector3) -> int:
	if player == null:
		return 0
	var p := player.global_position
	return int(round(Vector2(target_pos.x - p.x, target_pos.z - p.z).length()))

func _navigation_label(distance: int, direction: String) -> String:
	if distance < 18:
		return "附近"
	if direction == "":
		return "%dm" % distance
	return "%s %dm" % [direction, distance]

func _open_pause_menu() -> void:
	if pause_menu == null:
		return
	pause_menu.set_world_summary(_pause_summary_data())
	pause_menu.open()

func _pause_summary_data() -> Dictionary:
	var data := _journal_data()
	var steps: Array = data.get("journey_steps", [])
	data["journey_count"] = steps.size()
	data["next_journey_label"] = _next_journey_label(steps)
	var landmarks: Array = data.get("landmarks", [])
	data["discovered_count"] = landmarks.size()
	var restored := 0
	var best_percent := 0
	var target := {}
	var completed_target := {}
	for raw in landmarks:
		var entry: Dictionary = raw
		var percent := int(entry.get("restore_percent", 0))
		var complete := bool(entry.get("restore_complete", false)) or percent >= 100
		best_percent = max(best_percent, percent)
		if complete:
			restored += 1
			if completed_target.is_empty() or percent >= int(completed_target.get("restore_percent", 0)):
				completed_target = entry
			continue
		if target.is_empty() or percent >= int(target.get("restore_percent", 0)):
			target = entry
	if target.is_empty() and not completed_target.is_empty():
		target = completed_target
	data["restored_count"] = restored
	data["best_restore_percent"] = best_percent
	if not target.is_empty():
		data["restoration_target_label"] = String(target.get("label", "古遗迹"))
		data["restoration_target_percent"] = int(target.get("restore_percent", 0))
	return data

func _next_journey_label(done_steps: Array) -> String:
	for key in World.JOURNEY_STEPS:
		if not done_steps.has(key):
			return _journey_label(key)
	return ""

func _map_data() -> Dictionary:
	var data := _journal_data()
	var player_pos := Vector3.ZERO
	var player_forward := Vector3(0, 0, -1)
	if player != null:
		player_pos = player.global_position
		var basis: Basis = player.global_transform.basis if player.is_inside_tree() else player.transform.basis
		player_forward = -basis.z
	data["player_pos"] = player_pos
	data["player_forward"] = player_forward
	data["home_pos"] = _journey_start_pos
	data["nearby_valid"] = discovery_tracker != null and discovery_tracker.nearby_hint_distance() >= 0
	data["nearby_position"] = discovery_tracker.nearby_hint_position() if discovery_tracker != null else Vector3.ZERO
	data["region_samples"] = _region_map_samples(player_pos)
	return data

func _region_map_samples(center: Vector3) -> Array:
	var samples := []
	if world == null or not world.has_method("region_label"):
		return samples
	var step := 32
	var radius := 160
	for dz in range(-radius, radius + 1, step):
		for dx in range(-radius, radius + 1, step):
			var wx := int(round(center.x)) + dx
			var wz := int(round(center.z)) + dz
			var label: String = world.region_label(wx, wz)
			if label == "":
				continue
			samples.append({
				"world_pos": Vector3(wx, 0.0, wz),
				"region": label,
				"step": step,
			})
	return samples

func _on_palette_block_selected(id: int) -> void:
	if player != null:
		player.select_block_id(id)
	_remember_recent_block(id)
	set_palette_active(false)

func _on_player_material_picked(id: int) -> void:
	_remember_recent_block(id)

func _remember_recent_block(id: int) -> void:
	if lib == null or not lib.has_def(id) or not lib.is_renderable(id):
		return
	var recent: Array = []
	if block_palette != null:
		recent = block_palette.recent_blocks()
	else:
		for raw in _settings.get("recent_blocks", []):
			recent.append(int(raw))
	recent.erase(id)
	recent.push_front(id)
	while recent.size() > 8:
		recent.pop_back()
	_save_setting("recent_blocks", recent)
	var saved_recent: Array = []
	for raw in _settings.get("recent_blocks", []):
		saved_recent.append(int(raw))
	if block_palette != null:
		block_palette.set_recent_blocks(saved_recent)
	if player != null:
		player.set_recent_blocks(saved_recent)
	if hud != null:
		hud.set_recent_blocks(saved_recent)

func _continue_selected_world(seed: int) -> void:
	if seed != _current_seed:
		OS.set_environment("VC_SEED", str(seed))
		get_tree().paused = false
		get_tree().reload_current_scene()
	else:
		set_title_active(false)

func _start_new_world(seed: int = 0) -> void:
	if world != null:
		world.save_world(true)
	var next_seed := seed if seed > 0 else _random_seed()
	OS.set_environment("VC_SEED", str(next_seed))
	get_tree().paused = false
	get_tree().reload_current_scene()

func _delete_world_from_title(seed: int) -> void:
	if world != null:
		world.save_world(true)
	if not WorldCatalog.delete_world(seed):
		return
	var worlds := WorldCatalog.list_worlds()
	if worlds.is_empty():
		OS.set_environment("VC_SEED", str(_random_seed()))
	else:
		var next: Dictionary = worlds[0]
		OS.set_environment("VC_SEED", str(int(next.get("seed", 1337))))
	get_tree().paused = false
	get_tree().reload_current_scene()

func _random_seed() -> int:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return rng.randi_range(1000, 999999999)

func _save_from_menu() -> void:
	if world != null and world.save_path != "":
		_complete_journey_step("save_world", false)
	if world != null and world.save_world(true):
		_queue_world_cover_capture()
		_sync_hud_save_state()
		_refresh_pause_summary_if_visible()
		if hud != null:
			hud.show_feedback("save", "世界已保存")
	else:
		_refresh_pause_summary_if_visible()
		if hud != null:
			hud.show_feedback("save", "未启用存档")

func _refresh_pause_summary_if_visible() -> void:
	if pause_menu == null or not pause_menu.visible or _title_settings_active:
		return
	pause_menu.set_world_summary(_pause_summary_data())

func _on_player_action_progress(kind: String, _label: String) -> void:
	match kind:
		"select", "pick":
			_complete_journey_step("select_material", false)
		"place":
			_complete_journey_step("place_block", false)
			if player != null and player.has_method("build_template_id") and player.build_template_id() != "off":
				_complete_journey_step("use_template")

func _on_player_world_feedback(kind: String, cell: Vector3i, _block_id: int) -> void:
	if kind != "place" or _title_active or hud == null or world == null or discovery_tracker == null:
		return
	_repair_feedback_cells.append(cell)
	if _repair_feedback_deferred:
		return
	_repair_feedback_deferred = true
	call_deferred("_flush_repair_feedback")

func _flush_repair_feedback() -> void:
	_repair_feedback_deferred = false
	if _repair_feedback_cells.is_empty() or hud == null or discovery_tracker == null:
		_repair_feedback_cells.clear()
		return
	var by_key := {}
	for raw_cell in _repair_feedback_cells:
		var cell: Vector3i = raw_cell
		var entry := _landmark_entry_for_cell(cell)
		if entry.is_empty():
			continue
		var key := String(entry.get("key", ""))
		var percent := int(entry.get("restore_percent", 0))
		var bucket := _repair_feedback_bucket(percent)
		var seen := int(_landmark_restore_seen.get(key, 0))
		if bucket <= seen:
			continue
		var existing: Dictionary = by_key.get(key, {})
		if existing.is_empty() or percent > int(existing.get("restore_percent", 0)):
			by_key[key] = entry
	_repair_feedback_cells.clear()
	_sync_hud_restoration()
	var best := {}
	for key in by_key.keys():
		var entry: Dictionary = by_key[key]
		if best.is_empty() \
				or bool(entry.get("restore_complete", false)) \
				or int(entry.get("restore_percent", 0)) > int(best.get("restore_percent", 0)):
			best = entry
	if best.is_empty():
		return
	var best_key := String(best.get("key", ""))
	var best_percent := int(best.get("restore_percent", 0))
	_landmark_restore_seen[best_key] = _repair_feedback_bucket(best_percent)
	var label := String(best.get("label", "古遗迹"))
	var feedback_label := ""
	if bool(best.get("restore_complete", false)):
		feedback_label = "遗迹修复完成：" + label
		hud.show_feedback("journey", feedback_label)
		if audio_feedback != null:
			audio_feedback.play_feedback("journey", feedback_label)
		if action_effects != null and action_effects.has_method("show_restoration"):
			action_effects.show_restoration(Vector3(_landmark_entry_pos(best)) + Vector3(0.5, 0.5, 0.5))
	else:
		feedback_label = "遗迹修复 %d%%：%s" % [best_percent, label]
		hud.show_feedback("journey", feedback_label)
		if audio_feedback != null:
			audio_feedback.play_feedback("journey", feedback_label)

func _prime_landmark_restore_seen() -> void:
	if discovery_tracker == null:
		return
	_landmark_restore_seen.clear()
	for raw in discovery_tracker.discovered_entries():
		var entry: Dictionary = raw
		var key := String(entry.get("key", ""))
		if key == "":
			continue
		_landmark_restore_seen[key] = _repair_feedback_bucket(int(entry.get("restore_percent", 0)))

func _landmark_entry_for_cell(cell: Vector3i) -> Dictionary:
	var entries := discovery_tracker.discovered_entries()
	var best := {}
	var best_distance := INF
	for raw in entries:
		var entry: Dictionary = raw
		var pos := _landmark_entry_pos(entry)
		if abs(pos.x - cell.x) > World.LANDMARK_RESTORE_RADIUS \
				or abs(pos.z - cell.z) > World.LANDMARK_RESTORE_RADIUS \
				or abs(pos.y - cell.y) > World.LANDMARK_RESTORE_VERTICAL_RADIUS:
			continue
		var distance := Vector3(pos).distance_to(Vector3(cell))
		if distance < best_distance:
			best_distance = distance
			best = entry
	return best

func _landmark_entry_pos(entry: Dictionary) -> Vector3i:
	var raw_pos: Variant = entry.get("world_pos", Vector3.ZERO)
	if typeof(raw_pos) == TYPE_VECTOR3I:
		return raw_pos
	if typeof(raw_pos) == TYPE_VECTOR3:
		var p: Vector3 = raw_pos
		return Vector3i(int(round(p.x)), int(round(p.y)), int(round(p.z)))
	var pos_text := String(entry.get("pos", ""))
	var parts := pos_text.split(",")
	if parts.size() == 3:
		return Vector3i(int(parts[0]), int(parts[1]), int(parts[2]))
	return Vector3i.ZERO

func _repair_feedback_bucket(percent: int) -> int:
	if percent >= 100:
		return 4
	if percent >= 75:
		return 3
	if percent >= 50:
		return 2
	if percent >= 25:
		return 1
	return 0

func _update_journey_explore() -> void:
	if player == null:
		return
	var p := player.global_position
	var horizontal_distance := Vector2(p.x - _journey_start_pos.x, p.z - _journey_start_pos.z).length()
	if horizontal_distance >= JOURNEY_EXPLORE_DISTANCE:
		_complete_journey_step("explore")

func _complete_journey_step(key: String, show_feedback: bool = true) -> void:
	if world == null or not world.has_method("mark_journey_step"):
		return
	if not world.mark_journey_step(key):
		return
	_sync_hud_journey()
	if show_feedback and hud != null and not _title_active:
		var label := "旅程完成：" + _journey_label(key)
		hud.show_feedback("journey", label)
		if audio_feedback != null:
			audio_feedback.play_feedback("journey", label)

func _sync_hud_journey() -> void:
	if hud == null or world == null or not world.has_method("journey_steps"):
		return
	hud.set_journey_steps(world.journey_steps(), world.journey_total())

func _sync_hud_save_state() -> void:
	if hud == null or world == null:
		return
	hud.set_save_state(world.has_unsaved_changes(), world.save_path != "")

func _sync_hud_restoration() -> void:
	if hud == null:
		return
	var entries := []
	if discovery_tracker != null and discovery_tracker.has_method("discovered_entries"):
		entries = discovery_tracker.discovered_entries()
	var restored := 0
	var best_percent := 0
	var target := {}
	var completed_target := {}
	for raw in entries:
		var entry: Dictionary = raw
		var percent := int(entry.get("restore_percent", 0))
		var complete := bool(entry.get("restore_complete", false)) or percent >= 100
		best_percent = max(best_percent, percent)
		if complete:
			restored += 1
			if completed_target.is_empty() or percent >= int(completed_target.get("restore_percent", 0)):
				completed_target = entry
			continue
		if target.is_empty() or percent >= int(target.get("restore_percent", 0)):
			target = entry
	if target.is_empty() and not completed_target.is_empty():
		target = completed_target
	var label := ""
	var target_percent := -1
	var target_complete := false
	var target_pos := Vector3.ZERO
	var target_distance := -1
	var target_direction := ""
	if not target.is_empty():
		label = String(target.get("label", "古遗迹"))
		target_percent = int(target.get("restore_percent", -1))
		target_complete = bool(target.get("restore_complete", false)) or target_percent >= 100
		target_pos = _landmark_entry_world_pos(target)
		target_distance = _flat_distance_to_player(target_pos)
		target_direction = _direction_label_to(target_pos)
	hud.set_restoration_goal(label, target_percent, target_complete, restored, best_percent, target_distance, target_direction)
	_restoration_marker_active = label != ""
	_restoration_marker_pos = target_pos
	_restoration_marker_progress = target_percent
	_restoration_marker_mode = "complete" if target_complete else "repair"
	_update_landmark_marker()

func _update_landmark_marker() -> void:
	if landmark_marker == null:
		return
	if _title_active:
		landmark_marker.set_marker(Vector3.ZERO, false)
		return
	if _restoration_marker_active:
		landmark_marker.set_marker(_restoration_marker_pos, true, _restoration_marker_mode, _restoration_marker_progress)
	elif _nearby_marker_active:
		landmark_marker.set_marker(_nearby_marker_pos, true, "hint")
	else:
		landmark_marker.set_marker(Vector3.ZERO, false)

func _sync_hud_region(show_feedback: bool = true) -> void:
	if hud == null or world == null or player == null or not world.has_method("region_label"):
		return
	var p := player.global_position
	var label: String = world.region_label(int(floor(p.x)), int(floor(p.z)))
	if label == "":
		return
	var detail := ""
	if world.has_method("region_description"):
		detail = world.region_description(int(floor(p.x)), int(floor(p.z)))
	var first_visit := false
	if world.has_method("mark_region_visited"):
		first_visit = world.mark_region_visited(label, show_feedback)
		if first_visit:
			_sync_hud_save_state()
	hud.set_region_label(label)
	if ambient_motes != null:
		ambient_motes.set_region_label(label)
	if weather_system != null:
		weather_system.set_region_label(label)
		hud.set_weather_label(weather_system.weather_label())
	if label != _last_region_label:
		_last_region_label = label
		if show_feedback and not _title_active:
			var prefix := "发现新地貌" if first_visit else "进入"
			var feedback := "%s%s：%s" % [prefix, label, detail] if detail != "" else prefix + label
			hud.show_feedback("region", feedback)

func _home_distance() -> int:
	if player == null:
		return 0
	var p := player.global_position
	return int(round(Vector2(p.x - _journey_start_pos.x, p.z - _journey_start_pos.z).length()))

func _direction_label_to(target_pos: Vector3) -> String:
	if player == null:
		return "附近"
	var p := player.global_position
	var flat := Vector3(target_pos.x - p.x, 0.0, target_pos.z - p.z)
	if flat.length_squared() < 0.001:
		return "附近"
	var basis: Basis = player.global_transform.basis if player.is_inside_tree() else player.transform.basis
	var forward: Vector3 = -basis.z
	var right: Vector3 = basis.x
	var angle := atan2(flat.normalized().dot(right), flat.normalized().dot(forward))
	var sector := posmod(int(round(angle / (PI / 4.0))), 8)
	match sector:
		0: return "前方"
		1: return "右前"
		2: return "右侧"
		3: return "右后"
		4: return "后方"
		5: return "左后"
		6: return "左侧"
		_: return "左前"

func _journey_label(key: String) -> String:
	match key:
		"explore":
			return "探索附近地形"
		"select_material":
			return "选择材料"
		"open_palette":
			return "打开材料库"
		"place_block":
			return "放置方块"
		"use_template":
			return "使用建造模板"
		"open_map":
			return "查看世界地图"
		"discover_landmark":
			return "记录遗迹"
		"save_world":
			return "保存世界"
		_:
			return "新的目标"

func _apply_graphics_quality(value: String) -> void:
	_graphics_quality = _sanitize_graphics_quality(value)
	match _graphics_quality:
		"performance":
			_quality_clouds_enabled = false
			_quality_star_visible_count = 54
			_quality_cloud_alpha = 0.0
			_quality_fog_scale = 0.82
			if _sun != null:
				_sun.shadow_enabled = false
				_sun.directional_shadow_max_distance = 72.0
			if _env != null:
				_env.glow_enabled = false
				_env.glow_intensity = 0.0
				_env.ssao_enabled = false
				_env.ssil_enabled = false
				get_viewport().msaa_3d = Viewport.MSAA_DISABLED
				get_viewport().use_taa = false
		"cinematic":
			_quality_clouds_enabled = true
			_quality_star_visible_count = STAR_COUNT
			_quality_cloud_alpha = 1.0
			_quality_fog_scale = 1.12
			if _sun != null:
				_sun.shadow_enabled = true
				_sun.directional_shadow_max_distance = 180.0
			if _env != null:
				_env.glow_enabled = true
				_env.glow_intensity = 0.5
				_env.ssao_enabled = true
				_env.ssil_enabled = true
				get_viewport().msaa_3d = Viewport.MSAA_4X
				get_viewport().use_taa = true
		_:
			_quality_clouds_enabled = true
			_quality_star_visible_count = 90
			_quality_cloud_alpha = 0.82
			_quality_fog_scale = 1.0
			if _sun != null:
				_sun.shadow_enabled = true
				_sun.directional_shadow_max_distance = 120.0
			if _env != null:
				_env.glow_enabled = true
				_env.glow_intensity = 0.34
				_env.ssao_enabled = true
				_env.ssil_enabled = false
				get_viewport().msaa_3d = Viewport.MSAA_2X
				get_viewport().use_taa = false
	if _cloud_root != null:
		_cloud_root.visible = _quality_clouds_enabled
	if _stars != null and _stars.multimesh != null:
		_stars.multimesh.visible_instance_count = clampi(_quality_star_visible_count, 0, STAR_COUNT)

func _sanitize_graphics_quality(value: String) -> String:
	if value == "performance" or value == "balanced" or value == "cinematic":
		return value
	return "balanced"

func _graphics_quality_label(value: String) -> String:
	match _sanitize_graphics_quality(value):
		"performance":
			return "性能"
		"cinematic":
			return "精美"
		_:
			return "均衡"

func _on_view_radius_changed(value: int) -> void:
	if world != null:
		world.set_view_radius(value)
	_save_setting("view_radius", world.view_radius if world != null else value)
	if hud != null:
		hud.show_feedback("save", "视距 %d" % value)

func _on_volume_changed(value: float) -> void:
	if audio_feedback != null:
		audio_feedback.set_volume(value)
	if music != null:
		music.set_volume(value)
	_save_setting("volume", audio_feedback.volume if audio_feedback != null else value)

func _on_sensitivity_changed(value: float) -> void:
	if player != null:
		player.mouse_sensitivity = Player.DEFAULT_SENS * value
	_save_setting("sensitivity", value)

func _on_weather_enabled_changed(value: bool) -> void:
	if weather_system != null:
		weather_system.set_enabled(value)
		if hud != null:
			hud.set_weather_label(weather_system.weather_label())
	_save_setting("weather_enabled", value)

func _on_graphics_quality_changed(value: String) -> void:
	_apply_graphics_quality(value)
	_save_setting("graphics_quality", _graphics_quality)
	if hud != null:
		hud.show_feedback("mode", "画质 " + _graphics_quality_label(_graphics_quality))

func _on_weather_changed(kind: String, label: String) -> void:
	if hud == null:
		return
	hud.set_weather_label(label)
	if not _title_active:
		hud.show_feedback(kind, label)

func _on_discovery_feedback(kind: String, label: String) -> void:
	if hud == null:
		return
	hud.set_discovery_count(discovery_tracker.discovered_count() if discovery_tracker != null else 0)
	hud.set_last_discovery_label(label)
	_sync_hud_restoration()
	if not _title_active:
		hud.show_feedback(kind, label)

func _on_landmark_discovered(_position: Vector3i, _label: String) -> void:
	if hud != null and discovery_tracker != null:
		hud.set_discovery_count(discovery_tracker.discovered_count())
	_sync_hud_restoration()
	_complete_journey_step("discover_landmark")

func _on_nearby_hint_changed(distance: int, direction: String) -> void:
	if hud != null:
		hud.set_nearby_landmark_hint(distance, direction)
	_nearby_marker_active = distance >= 0
	_nearby_marker_pos = discovery_tracker.nearby_hint_position() if discovery_tracker != null else Vector3.ZERO
	_update_landmark_marker()

func _save_setting(key: String, value: Variant) -> void:
	_settings[key] = value
	_settings = GameSettings.sanitize(_settings)
	GameSettings.save_settings(_settings)

func _setup_environment() -> void:
	_sky_mat = ProceduralSkyMaterial.new()
	_sky_mat.sky_top_color = Color(0.30, 0.52, 0.86)
	_sky_mat.sky_horizon_color = Color(0.74, 0.82, 0.90)
	_sky_mat.ground_horizon_color = Color(0.74, 0.82, 0.90)
	_sky_mat.ground_bottom_color = Color(0.55, 0.62, 0.66)
	var sky := Sky.new()
	sky.sky_material = _sky_mat

	_env = Environment.new()
	_env.background_mode = Environment.BG_SKY
	_env.sky = sky
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	_env.ambient_light_energy = 0.6
	_env.fog_enabled = true
	_env.fog_light_color = Color(0.74, 0.82, 0.90)
	_env.fog_density = 0.0052
	_env.fog_sky_affect = 0.25
	_env.tonemap_mode = Environment.TONE_MAPPER_ACES
	_env.tonemap_exposure = 1.05
	_env.tonemap_white = 1.5
	_env.glow_enabled = true
	_env.glow_intensity = 0.34
	_env.glow_strength = 1.1
	_env.glow_bloom = 0.10
	_env.glow_hdr_threshold = 0.95
	_env.glow_hdr_scale = 2.0
	_env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	_env.adjustment_enabled = true
	_env.adjustment_saturation = 1.12
	_env.adjustment_contrast = 1.06
	_env.adjustment_brightness = 1.0
	# 屏幕空间环境光遮蔽：与逐顶点 AO 互补，给方块接缝/凹处加柔和接触阴影
	_env.ssao_enabled = true
	_env.ssao_radius = 1.4
	_env.ssao_intensity = 2.4
	_env.ssao_power = 1.6
	_env.ssao_detail = 0.6
	_env.ssao_horizon = 0.07
	_env.ssao_sharpness = 0.98
	_env.ssao_light_affect = 0.15
	_env.ssao_ao_channel_affect = 0.0

	var we := WorldEnvironment.new()
	we.environment = _env
	add_child(we)

	_sun = DirectionalLight3D.new()
	_sun.rotation_degrees = Vector3(-52, -36, 0)
	_sun.light_energy = 1.15
	_sun.light_color = Color(1.0, 0.96, 0.88)
	_sun.shadow_enabled = true
	_sun.directional_shadow_max_distance = 120.0
	_sun.light_angular_distance = 0.9
	_sun.shadow_blur = 1.1
	_sun.directional_shadow_blend_splits = true
	_sun.shadow_normal_bias = 1.4
	add_child(_sun)

func _setup_celestial_bodies() -> void:
	_sky_root = Node3D.new()
	_sky_root.name = "CelestialSky"
	add_child(_sky_root)
	_celestial_tex = _celestial_texture()

	_sun_disc_mat = _celestial_material(Color(1.0, 0.84, 0.42, 0.95), true)
	_sun_disc = _celestial_quad("SunDisc", Vector2(26.0, 26.0), _sun_disc_mat)
	_sky_root.add_child(_sun_disc)

	_moon_disc_mat = _celestial_material(Color(0.80, 0.88, 1.0, 0.9), false)
	_moon_disc = _celestial_quad("MoonDisc", Vector2(15.0, 15.0), _moon_disc_mat)
	_sky_root.add_child(_moon_disc)

	_star_mat = _celestial_material(Color(0.82, 0.92, 1.0, 0.0), false, false)
	var star_mesh := BoxMesh.new()
	star_mesh.size = Vector3.ONE
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = star_mesh
	mm.instance_count = STAR_COUNT
	mm.visible_instance_count = STAR_COUNT
	for i in range(STAR_COUNT):
		var dir := _star_direction(i)
		var size := 0.18 + _hash_unit(i, 77) * 0.32
		var basis := Basis.IDENTITY.scaled(Vector3(size, size, size))
		mm.set_instance_transform(i, Transform3D(basis, dir * SKY_RADIUS))
	_stars = MultiMeshInstance3D.new()
	_stars.name = "Stars"
	_stars.multimesh = mm
	_stars.material_override = _star_mat
	_stars.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_sky_root.add_child(_stars)

func _celestial_material(color: Color, additive: bool = false, textured: bool = true) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if additive else BaseMaterial3D.BLEND_MODE_MIX
	mat.albedo_color = color
	if textured and _celestial_tex != null:
		mat.albedo_texture = _celestial_tex
		mat.emission_texture = _celestial_tex
	mat.emission_enabled = true
	mat.emission = Color(color.r, color.g, color.b)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat

func _celestial_texture() -> ImageTexture:
	var size := 48
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c := (size - 1) * 0.5
	for y in range(size):
		for x in range(size):
			var dist := Vector2(float(x) - c, float(y) - c).length() / (float(size) * 0.5)
			var a := clampf(1.0 - dist, 0.0, 1.0)
			a = smoothstep(0.0, 1.0, a)
			a = pow(a, 1.5)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	return ImageTexture.create_from_image(img)

func _celestial_quad(name: String, size: Vector2, mat: Material) -> MeshInstance3D:
	var mesh := QuadMesh.new()
	mesh.size = size
	var body := MeshInstance3D.new()
	body.name = name
	body.mesh = mesh
	body.material_override = mat
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return body

func _update_celestial_bodies(daylight: float, rain: float) -> void:
	if _sky_root == null:
		return
	var center := player.global_position if player != null else Vector3.ZERO
	_sky_root.global_position = center

	var sun_dir := _celestial_direction(0.0)
	var moon_dir := _celestial_direction(PI)
	_position_celestial_body(_sun_disc, sun_dir, center)
	_position_celestial_body(_moon_disc, moon_dir, center)

	var cloud_cover := clampf(rain, 0.0, 1.0)
	var sun_alpha := clampf((daylight - 0.08) * 1.45, 0.0, 1.0) * lerpf(1.0, 0.55, cloud_cover)
	var night := clampf((0.55 - daylight) * 2.15, 0.0, 1.0)
	var moon_alpha := night * lerpf(0.86, 0.30, cloud_cover)
	var star_alpha := pow(night, 1.35) * lerpf(0.82, 0.10, cloud_cover)
	_set_material_alpha(_sun_disc_mat, Color(1.0, 0.72, 0.18), sun_alpha)
	_set_material_alpha(_moon_disc_mat, Color(0.74, 0.84, 1.0), moon_alpha)
	_set_material_alpha(_star_mat, Color(0.82, 0.92, 1.0), star_alpha)
	if _sun_disc != null:
		_sun_disc.visible = sun_alpha > 0.02
	if _moon_disc != null:
		_moon_disc.visible = moon_alpha > 0.02
	if _stars != null:
		_stars.visible = _quality_star_visible_count > 0 and star_alpha > 0.02

func _position_celestial_body(body: Node3D, dir: Vector3, center: Vector3) -> void:
	if body == null:
		return
	body.global_position = center + dir * SKY_RADIUS
	body.look_at(center, Vector3.UP)

func _set_material_alpha(mat: StandardMaterial3D, color: Color, alpha: float) -> void:
	if mat == null:
		return
	mat.albedo_color = Color(color.r, color.g, color.b, clampf(alpha, 0.0, 1.0))
	mat.emission = color * clampf(alpha, 0.0, 1.0)

func _celestial_direction(offset: float) -> Vector3:
	var angle := _time * TAU - PI * 0.5 + offset
	return Vector3(cos(angle) * 0.48, sin(angle), -0.88).normalized()

func _star_direction(index: int) -> Vector3:
	var yaw := _hash_unit(index, 11) * TAU
	var y := lerpf(0.08, 0.98, _hash_unit(index, 29))
	var flat := sqrt(maxf(0.0, 1.0 - y * y))
	return Vector3(cos(yaw) * flat, y, sin(yaw) * flat).normalized()

func _hash_unit(index: int, salt: int) -> float:
	var h := index * 1103515245 + salt * 12345 + _current_seed * 97
	h = ((h >> 16) ^ h) * 73244475
	h = (h >> 16) ^ h
	return float(h & 0xffff) / 65535.0

func _setup_clouds() -> void:
	_cloud_root = Node3D.new()
	_cloud_root.name = "BlockyClouds"
	add_child(_cloud_root)

	_cloud_mat = StandardMaterial3D.new()
	_cloud_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_cloud_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_cloud_mat.albedo_color = Color(1.0, 0.96, 0.88, 0.72)
	_cloud_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var centers := [
		Vector3(-95, 112, -65), Vector3(-44, 106, 48), Vector3(18, 118, -88),
		Vector3(74, 109, 24), Vector3(128, 116, -28), Vector3(-134, 111, 76)
	]
	for i in range(centers.size()):
		_add_cloud_puff(centers[i], i, _cloud_mat)

func _add_cloud_puff(center: Vector3, salt: int, mat: Material) -> void:
	var count := 5 + salt % 3
	for i in range(count):
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		var sx := 12.0 + float((i + salt) % 3) * 6.0
		var sy := 3.0 + float(i % 2)
		var sz := 8.0 + float((i * 2 + salt) % 3) * 4.0
		bm.size = Vector3(sx, sy, sz)
		mi.mesh = bm
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position = center + Vector3(float(i - 2) * 8.5, float((i + salt) % 2) * 1.4, float((i * 5 + salt) % 4 - 2) * 5.0)
		_cloud_root.add_child(mi)

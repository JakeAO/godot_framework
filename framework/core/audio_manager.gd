extends Node
## Audio playback on dedicated buses (Master -> Music / SFX / UI).
##
## - BGM: single player with crossfade on track change, loops via the
##   `finished` signal (no import-time loop flag needed).
## - SFX: small round-robin pool so overlapping effects do not cut each other.
## - Bus volumes follow SettingsManager (linear -> dB), ducking supported.
## - BGM fades out when the app goes to background (mobile lifecycle).

const BUS_MUSIC: String = "Music"
const BUS_SFX: String = "SFX"
const BUS_UI: String = "UI"

const BGM_MENU: String = "menu"
const SFX_CLICK: String = "click"
const SFX_SUCCESS: String = "success"
const SFX_FAIL: String = "fail"

const FADE_SEC: float = 0.4
const SILENCE_DB: float = -80.0
const SFX_POOL_SIZE: int = 4

var _bgm_streams: Dictionary = {}
var _sfx_streams: Dictionary = {}
var _ui_streams: Dictionary = {}
var _bgm_player: AudioStreamPlayer
var _sfx_pool: Array[AudioStreamPlayer] = []
var _sfx_index: int = 0
var _ui_player: AudioStreamPlayer
var _current_bgm: String = ""
var _fade_tween: Tween
var _is_backgrounded: bool = false
# Track that was playing when the music toggle muted it, so re-enabling can
# resume (stop_bgm() itself clears _current_bgm by design — see tests).
var _bgm_resume_track: String = ""


func _ready() -> void:
	_bgm_streams[BGM_MENU] = preload("res://assets/audio/bgm_menu.wav")
	_sfx_streams[SFX_CLICK] = preload("res://assets/audio/sfx_click.wav")
	_sfx_streams[SFX_SUCCESS] = preload("res://assets/audio/sfx_success.wav")
	_sfx_streams[SFX_FAIL] = preload("res://assets/audio/sfx_fail.wav")
	_ui_streams[SFX_CLICK] = preload("res://assets/audio/sfx_click.wav")

	_bgm_player = _make_player(BUS_MUSIC)
	_bgm_player.finished.connect(_on_bgm_finished)
	for i in SFX_POOL_SIZE:
		_sfx_pool.append(_make_player(BUS_SFX))
	_ui_player = _make_player(BUS_UI)

	_apply_bus_volumes()
	SettingsManager.music_volume_changed.connect(_apply_music_volume)
	SettingsManager.sfx_volume_changed.connect(_apply_sfx_volume)
	SettingsManager.music_enabled_changed.connect(_on_music_enabled_changed)
	SettingsManager.sfx_enabled_changed.connect(_on_sfx_enabled_changed)
	EventBus.visibility_changed.connect(_on_visibility_changed)
	# Autoloads ready before the main scene's _boot() loads the save, so the
	# persisted enabled flags are only applied once boot has finished.
	EventBus.app_ready.connect(_apply_enabled_state)


func _exit_tree() -> void:
	# Stop playback explicitly before child players are destroyed so the
	# audio server releases its playback objects cleanly at shutdown.
	_kill_fade_tween()
	_bgm_player.stop()
	for p in _sfx_pool:
		p.stop()
	_ui_player.stop()


# --- BGM ------------------------------------------------------------------------

func play_bgm(track_name: String, fade_sec: float = FADE_SEC) -> void:
	if not _bgm_streams.has(track_name):
		push_warning("AudioManager: unknown bgm track '%s'" % track_name)
		return
	if track_name == _current_bgm and _bgm_player.playing:
		return
	_current_bgm = track_name

	if _bgm_player.playing:
		_kill_fade_tween()
		_fade_tween = create_tween()
		_fade_tween.tween_property(_bgm_player, "volume_db", SILENCE_DB, fade_sec)
		_fade_tween.tween_callback(_bgm_player.stop)
		_fade_tween.tween_callback(_start_bgm_track.bind(track_name))
	else:
		_start_bgm_track(track_name)


func stop_bgm(fade_sec: float = FADE_SEC) -> void:
	_current_bgm = ""
	if not _bgm_player.playing:
		return
	if fade_sec <= 0.0:
		_kill_fade_tween()
		_bgm_player.stop()
		return
	_kill_fade_tween()
	_fade_tween = create_tween()
	_fade_tween.tween_property(_bgm_player, "volume_db", SILENCE_DB, fade_sec)
	_fade_tween.tween_callback(_bgm_player.stop)


## Lowers the Music bus while gameplay is running.
func duck_music(target_ratio: float = 0.35, fade_sec: float = FADE_SEC) -> void:
	var target := _volume_to_db(SettingsManager.get_music_volume() * clampf(target_ratio, 0.0, 1.0))
	_fade_bus(BUS_MUSIC, target, fade_sec)


## Restores the Music bus to the user's setting.
func unduck_music(fade_sec: float = FADE_SEC) -> void:
	_fade_bus(BUS_MUSIC, _volume_to_db(SettingsManager.get_music_volume()), fade_sec)


# --- SFX / UI ---------------------------------------------------------------------

func play_sfx(sfx_name: String) -> void:
	if not _sfx_streams.has(sfx_name):
		push_warning("AudioManager: unknown sfx '%s'" % sfx_name)
		return
	var p := _sfx_pool[_sfx_index]
	_sfx_index = (_sfx_index + 1) % _sfx_pool.size()
	p.stream = _sfx_streams[sfx_name]
	p.volume_db = 0.0
	p.play()


func play_ui(ui_name: String) -> void:
	if not _ui_streams.has(ui_name):
		push_warning("AudioManager: unknown ui sound '%s'" % ui_name)
		return
	_ui_player.stream = _ui_streams[ui_name]
	_ui_player.volume_db = 0.0
	_ui_player.play()


# --- Internals ----------------------------------------------------------------------

func _make_player(bus_name: String) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.bus = bus_name
	add_child(p)
	return p


func _start_bgm_track(track_name: String) -> void:
	_bgm_player.stream = _bgm_streams[track_name]
	_bgm_player.volume_db = SILENCE_DB
	_bgm_player.play()
	_kill_fade_tween()
	_fade_tween = create_tween()
	_fade_tween.tween_property(_bgm_player, "volume_db", _volume_to_db(SettingsManager.get_music_volume()), FADE_SEC)


func _on_bgm_finished() -> void:
	# Loop only when not mid-fade-out (crossfade/stop faded us to silence).
	if _bgm_player.volume_db > -70.0 and not _is_backgrounded:
		_bgm_player.play()


func _on_visibility_changed(is_visible: bool) -> void:
	_is_backgrounded = not is_visible
	if not is_visible:
		stop_bgm(FADE_SEC)
	elif not _current_bgm.is_empty():
		play_bgm(_current_bgm, FADE_SEC)


func _on_music_enabled_changed(enabled: bool) -> void:
	if enabled:
		_apply_music_volume(SettingsManager.get_music_volume())
		var track := _current_bgm if _current_bgm != "" else _bgm_resume_track
		if track != "" and not _is_backgrounded:
			play_bgm(track, FADE_SEC)
	else:
		_bgm_resume_track = _current_bgm
		stop_bgm(FADE_SEC)
		_set_bus_volume(AudioServer.get_bus_index(BUS_MUSIC), SILENCE_DB)


func _on_sfx_enabled_changed(enabled: bool) -> void:
	if enabled:
		_apply_sfx_volume(SettingsManager.get_sfx_volume())
	else:
		_set_bus_volume(AudioServer.get_bus_index(BUS_SFX), SILENCE_DB)
		_set_bus_volume(AudioServer.get_bus_index(BUS_UI), SILENCE_DB)


func _apply_enabled_state() -> void:
	if not SettingsManager.is_music_enabled():
		_bgm_resume_track = _current_bgm
		stop_bgm(0.0)
		_set_bus_volume(AudioServer.get_bus_index(BUS_MUSIC), SILENCE_DB)
	if not SettingsManager.is_sfx_enabled():
		_set_bus_volume(AudioServer.get_bus_index(BUS_SFX), SILENCE_DB)
		_set_bus_volume(AudioServer.get_bus_index(BUS_UI), SILENCE_DB)


func _kill_fade_tween() -> void:
	if _fade_tween != null and _fade_tween.is_valid():
		_fade_tween.kill()
	_fade_tween = null


func _apply_bus_volumes() -> void:
	_apply_music_volume(SettingsManager.get_music_volume())
	_apply_sfx_volume(SettingsManager.get_sfx_volume())
	_set_bus_volume(AudioServer.get_bus_index(BUS_UI), 0.0)


func _apply_music_volume(volume: float) -> void:
	_set_bus_volume(AudioServer.get_bus_index(BUS_MUSIC), _volume_to_db(volume))


func _apply_sfx_volume(volume: float) -> void:
	var db := _volume_to_db(volume)
	_set_bus_volume(AudioServer.get_bus_index(BUS_SFX), db)
	_set_bus_volume(AudioServer.get_bus_index(BUS_UI), db)


func _fade_bus(bus_name: String, target_db: float, fade_sec: float) -> void:
	var bus_index := AudioServer.get_bus_index(bus_name)
	if bus_index < 0:
		return
	# Zero-duration tweens never complete their callbacks, so instant changes
	# must bypass the tween entirely.
	if fade_sec <= 0.0:
		_kill_fade_tween()
		AudioServer.set_bus_volume_db(bus_index, target_db)
		return
	_kill_fade_tween()
	_fade_tween = create_tween()
	# NOTE: tween_method must receive a plain one-arg callable. Godot 4.7's
	# MethodTweener mangles arguments when the callable carries bound args,
	# so the bus index is resolved inside the method instead of via .bind().
	_fade_tween.tween_method(_set_music_bus_db, AudioServer.get_bus_volume_db(bus_index), target_db, fade_sec)


func _set_music_bus_db(volume_db: float) -> void:
	var bus_index := AudioServer.get_bus_index(BUS_MUSIC)
	if bus_index >= 0:
		AudioServer.set_bus_volume_db(bus_index, volume_db)


func _set_bus_volume(bus_index: int, volume_db: float) -> void:
	if bus_index >= 0:
		AudioServer.set_bus_volume_db(bus_index, volume_db)


static func _volume_to_db(linear: float) -> float:
	if linear <= 0.0:
		return SILENCE_DB
	return linear_to_db(linear)

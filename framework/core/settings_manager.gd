extends Node
## User preferences persisted in the "settings" save domain.
## Other systems (AudioManager, LocalizationManager) subscribe to change signals.

const DOMAIN: String = "settings"

signal music_volume_changed(volume: float)
signal sfx_volume_changed(volume: float)
signal language_changed(language_code: String)
signal haptics_changed(enabled: bool)
signal music_enabled_changed(enabled: bool)
signal sfx_enabled_changed(enabled: bool)
signal notifications_changed(enabled: bool)
signal reduced_vfx_changed(enabled: bool)

var _music_volume: float = 0.8
var _sfx_volume: float = 1.0
var _language: String = "en"
var _haptics_enabled: bool = true
# The UI exposes on/off toggles (not sliders); volumes stay as the level used
# while a channel is enabled, so a future fine-tuning UI can reuse them.
var _music_enabled: bool = true
var _sfx_enabled: bool = true
var _notifications_enabled: bool = true
var _reduced_vfx_enabled: bool = false


func _ready() -> void:
	# Deliberately passive: the main scene calls init_from_save() AFTER
	# SaveSystem.load_save(), so defaults never clobber a persisted save.
	pass


func init_from_save() -> void:
	var s: Dictionary = SaveSystem.get_domain(DOMAIN)
	_music_volume = clampf(float(s.get("music_volume", 0.8)), 0.0, 1.0)
	_sfx_volume = clampf(float(s.get("sfx_volume", 1.0)), 0.0, 1.0)
	_language = str(s.get("language", "en"))
	_haptics_enabled = bool(s.get("haptics_enabled", true))
	_music_enabled = bool(s.get("music_enabled", true))
	_sfx_enabled = bool(s.get("sfx_enabled", true))
	_notifications_enabled = bool(s.get("notifications_enabled", true))
	_reduced_vfx_enabled = bool(s.get("reduced_vfx_enabled", false))


func persist() -> void:
	SaveSystem.set_domain(DOMAIN, {
		"music_volume": _music_volume,
		"sfx_volume": _sfx_volume,
		"language": _language,
		"haptics_enabled": _haptics_enabled,
		"music_enabled": _music_enabled,
		"sfx_enabled": _sfx_enabled,
		"notifications_enabled": _notifications_enabled,
		"reduced_vfx_enabled": _reduced_vfx_enabled,
	})
	SaveSystem.save_game()


# --- Getters --------------------------------------------------------------------

func get_music_volume() -> float:
	return _music_volume


func get_sfx_volume() -> float:
	return _sfx_volume


func get_language() -> String:
	return _language


func is_haptics_enabled() -> bool:
	return _haptics_enabled


func is_music_enabled() -> bool:
	return _music_enabled


func is_sfx_enabled() -> bool:
	return _sfx_enabled


func is_notifications_enabled() -> bool:
	return _notifications_enabled


func is_reduced_vfx_enabled() -> bool:
	return _reduced_vfx_enabled


# --- Setters --------------------------------------------------------------------

func set_music_volume(volume: float) -> void:
	var v := clampf(volume, 0.0, 1.0)
	if is_equal_approx(v, _music_volume):
		return
	_music_volume = v
	persist()
	music_volume_changed.emit(v)


func set_sfx_volume(volume: float) -> void:
	var v := clampf(volume, 0.0, 1.0)
	if is_equal_approx(v, _sfx_volume):
		return
	_sfx_volume = v
	persist()
	sfx_volume_changed.emit(v)


func set_language(language_code: String) -> void:
	if language_code.is_empty():
		push_warning("SettingsManager: ignoring empty language code")
		return
	var lc := language_code.to_lower().strip_edges()
	if lc == _language:
		return
	_language = lc
	persist()
	language_changed.emit(_language)


func set_haptics_enabled(enabled: bool) -> void:
	if enabled == _haptics_enabled:
		return
	_haptics_enabled = enabled
	persist()
	haptics_changed.emit(_haptics_enabled)


func set_music_enabled(enabled: bool) -> void:
	if enabled == _music_enabled:
		return
	_music_enabled = enabled
	persist()
	music_enabled_changed.emit(_music_enabled)


func set_sfx_enabled(enabled: bool) -> void:
	if enabled == _sfx_enabled:
		return
	_sfx_enabled = enabled
	persist()
	sfx_enabled_changed.emit(_sfx_enabled)


func set_notifications_enabled(enabled: bool) -> void:
	if enabled == _notifications_enabled:
		return
	_notifications_enabled = enabled
	persist()
	notifications_changed.emit(_notifications_enabled)


func set_reduced_vfx_enabled(enabled: bool) -> void:
	if enabled == _reduced_vfx_enabled:
		return
	_reduced_vfx_enabled = enabled
	persist()
	reduced_vfx_changed.emit(_reduced_vfx_enabled)


func reset_to_defaults() -> void:
	_music_volume = 0.8
	_sfx_volume = 1.0
	_language = "en"
	_haptics_enabled = true
	_music_enabled = true
	_sfx_enabled = true
	_notifications_enabled = true
	_reduced_vfx_enabled = false
	persist()
	music_volume_changed.emit(_music_volume)
	sfx_volume_changed.emit(_sfx_volume)
	language_changed.emit(_language)
	haptics_changed.emit(_haptics_enabled)
	music_enabled_changed.emit(_music_enabled)
	sfx_enabled_changed.emit(_sfx_enabled)
	notifications_changed.emit(_notifications_enabled)
	reduced_vfx_changed.emit(_reduced_vfx_enabled)

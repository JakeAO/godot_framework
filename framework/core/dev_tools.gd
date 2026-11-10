extends Node
## Autoload "DevTools". Debug-only developer/QA panel.
##
## Inert in release builds (OS.is_debug_build() == false): no overlay node,
## no input handling, zero cost. In debug builds (the editor binary is a
## debug build, so GUT runs see the panel) it is reachable from anywhere via:
##   - tilde key (~ / `)          through _unhandled_input
##   - 3-finger downward swipe    through _input (>= SWIPE_THRESHOLD_PX travel)
## The overlay lives on its own CanvasLayer ABOVE UIManager's, hidden by
## default (hidden Controls receive no GUI input). The panel is rendered from
## a declarative control registry owned here (get_sections()); DevPanel is a
## generic renderer. Every action is a plain method so tests can drive the
## service headless. See TDD §3.15.

const LAYER: int = 20
const SWIPE_MIN_POINTERS: int = 3
const SWIPE_THRESHOLD_PX: float = 120.0
const SWIPE_DEBOUNCE_SEC: float = 1.0

## Control spec types (TDD §3.15 registry contract).
const CTRL_INT: String = "int"
const CTRL_FLOAT: String = "float"
const CTRL_STRING: String = "string"
const CTRL_BOOL: String = "bool"
const CTRL_ENUM: String = "enum"
const CTRL_ACTION: String = "action"
const CTRL_CONFIRM: String = "confirm"
const CTRL_LABEL: String = "label"

signal panel_toggled(is_open: bool)

var _enabled: bool = false
var _open: bool = false
var _layer: CanvasLayer = null
var _overlay_root: Control = null
var _panel: DevPanel = null
## touch index -> start position (Vector2), for the 3-finger swipe.
var _pointers: Dictionary = {}
var _debounce_until_msec: int = 0
## Cached control registry; rebuilt only when get_structure_key() changes.
var _sections: Array[Dictionary] = []
var _structure_key: String = ""
## Last "Ensure tournaments" outcome (BACKEND section, Phase F4).
var _tournament_ensure_result: String = ""
## Last "Ensure leaderboards" outcome (BACKEND section, Phase E5).
var _leaderboard_ensure_result: String = ""


func _ready() -> void:
	if not OS.is_debug_build():
		return  # Release builds: inert node, no overlay, no input hooks.
	_enabled = true
	_layer = CanvasLayer.new()
	_layer.layer = LAYER
	add_child(_layer)
	_overlay_root = Control.new()
	_pin_full_rect(_overlay_root)
	# STOP while visible so the dimmed backdrop swallows taps; HIDDEN by
	# default — a full-rect STOP control would swallow every tap even while
	# closed, and hidden Controls receive no input at all.
	_overlay_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay_root.visible = false
	_layer.add_child(_overlay_root)


# --- Input: access gestures ----------------------------------------------------

func _input(event: InputEvent) -> void:
	if not _enabled:
		return
	var touch := event as InputEventScreenTouch
	if touch != null:
		if touch.pressed:
			_pointers[touch.index] = touch.position
		else:
			_pointers.erase(touch.index)
		return
	var drag := event as InputEventScreenDrag
	if drag == null or not _pointers.has(drag.index):
		return
	if _pointers.size() < SWIPE_MIN_POINTERS:
		return
	var start_pos: Vector2 = _pointers[drag.index]
	if drag.position.y - start_pos.y < SWIPE_THRESHOLD_PX:
		return
	if Time.get_ticks_msec() < _debounce_until_msec:
		return
	_pointers.clear()
	_debounce_until_msec = Time.get_ticks_msec() + int(SWIPE_DEBOUNCE_SEC * 1000.0)
	_toggle_panel()


func _unhandled_input(event: InputEvent) -> void:
	if not _enabled:
		return
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	# Tilde (0x7e) logically, or the physical backquote key (0x60) on any layout.
	if key.keycode == Key.KEY_ASCIITILDE or key.physical_keycode == Key.KEY_QUOTELEFT:
		get_viewport().set_input_as_handled()
		_toggle_panel()


# --- Panel lifecycle -------------------------------------------------------------

func is_panel_open() -> bool:
	return _open


func toggle_panel() -> void:
	if not _enabled:
		return
	_toggle_panel()


func _toggle_panel() -> void:
	if _open:
		_close_panel()
	else:
		_open_panel()


func _open_panel() -> void:
	if _open or _overlay_root == null:
		return
	_open = true
	_ensure_panel()
	_overlay_root.visible = true
	panel_toggled.emit(true)


func _close_panel() -> void:
	if not _open:
		return
	_open = false
	# The panel stays alive hidden (performance model, TDD §3.15): a hidden
	# full-rect overlay handles no input at all, and the next open refreshes
	# values in place instead of reallocating the whole tree.
	_overlay_root.visible = false
	panel_toggled.emit(false)


## Builds the panel lazily on first open; later opens refresh values in place
## (full rebuild only when the config structure key changed).
func _ensure_panel() -> void:
	var sections := get_sections()
	var key := get_structure_key()
	if is_instance_valid(_panel):
		_panel.refresh(sections, key)
		return
	_panel = DevPanel.new()
	_pin_full_rect(_panel)
	_overlay_root.add_child(_panel)
	_panel.closed_requested.connect(_close_panel)
	_panel.setup(sections, key)


# --- Control registry (TDD §3.15) ------------------------------------------------

## Structure key: changes ONLY when the set of flags or experiments changes
## (i.e. a rebuild is actually needed). Value-only changes never do.
func get_structure_key() -> String:
	var flag_count := RemoteConfig.get_flags().size()
	return "%d|%s" % [flag_count, ",".join(RemoteConfig.get_experiment_names())]


## The declarative control registry DevPanel renders. Cached; rebuilt only on
## structure-key change. Adding a control = one factory line in _rebuild_sections.
func get_sections() -> Array[Dictionary]:
	var key := get_structure_key()
	if _structure_key.is_empty() or key != _structure_key:
		_rebuild_sections(key)
	return _sections


func _rebuild_sections(key: String) -> void:
	_structure_key = key
	_sections.clear()
	_sections.append(_save_section())
	_sections.append(_config_section())
	_sections.append(_systems_section())
	_sections.append(_backend_section())
	_sections.append(_telemetry_section())
	_sections.append(_ads_section())


func _save_section() -> Dictionary:
	var stage_options: Array[String] = []
	for i in StageCatalog.stage_count():
		stage_options.append(str(i + 1))
	return {
		"title": "SAVE",
		"controls": [
			_confirm("Reset all (with confirmation)", "Really reset the save to defaults?", func() -> void: reset_save()),
			_int("Coins", _profile_value("coins"), func(value: Variant) -> void: set_currency("coins", int(value))),
			_int("Gems", _profile_value("gems"), func(value: Variant) -> void: set_currency("gems", int(value))),
			_int("Level", _profile_value("level"), func(value: Variant) -> void: set_level(int(value))),
			_int("XP", _profile_value("xp"), func(value: Variant) -> void: set_xp(int(value))),
			_string("Player name", _profile_value("name", "Player"), _profile_setter("name")),
			_enum("Stage", func() -> Variant: return str(int(SaveSystem.get_value("profile", "stage", 1))), func(value: Variant) -> void: set_stage(int(str(value))), stage_options),
			_int("Piggy bank", func() -> Variant: return SaveSystem.get_value("piggy_bank", "balance", 0), func(value: Variant) -> void: set_piggy_balance(int(value))),
			_action("Clear claim stamps (offers + campaigns)", func() -> void: clear_claim_stamps()),
			_action("Reset gift pile (run + daily counters)", func() -> void: reset_gift_pile()),
		],
	}


func _config_section() -> Dictionary:
	var controls: Array[Dictionary] = []
	controls.append(_action("Refetch config (clears dev overrides)", func() -> void: refetch_config()))
	for flag_key in RemoteConfig.get_flags().keys():
		var flag_name := str(flag_key)
		controls.append(_bool(flag_name, _flag_getter(flag_name), _flag_setter(flag_name)))
	controls.append(_float("Banner refresh (s)", _rc_value("banner_refresh_sec", 30.0), _rc_setter("banner_refresh_sec")))
	controls.append(_int("Round duration (s)", _rc_value("round_duration_sec", 30), _rc_setter("round_duration_sec")))
	controls.append(_int("Win score", _rc_value("win_score", 150), _rc_setter("win_score")))
	controls.append(_int("Daily gift coins", _rc_value("daily_gift_coins", 50), _rc_setter("daily_gift_coins")))
	controls.append(_int("Piggy capacity", _rc_value("piggy_bank_capacity", 200), _rc_setter("piggy_bank_capacity")))
	for experiment_name in RemoteConfig.get_experiment_names():
		var variant_ids := RemoteConfig.get_experiment_variant_ids(experiment_name)
		controls.append(_enum(experiment_name, _exp_getter(experiment_name), _exp_setter(experiment_name), variant_ids))
	return {"title": "CONFIG & EXPERIMENTS", "controls": controls}


func _systems_section() -> Dictionary:
	var locale_options := LocalizationManager.SUPPORTED_LANGUAGES.duplicate()
	return {
		"title": "SYSTEMS",
		"controls": [
			_enum("Locale", func() -> Variant: return SettingsManager.get_language(), func(value: Variant) -> void: set_language(str(value)), locale_options),
			_bool("Music", func() -> Variant: return SettingsManager.is_music_enabled(), func(value: Variant) -> void: set_music_enabled(bool(value))),
			_bool("SFX", func() -> Variant: return SettingsManager.is_sfx_enabled(), func(value: Variant) -> void: set_sfx_enabled(bool(value))),
		],
	}


## Backend connectivity (TDD §3.18): mode/state readouts + the force-offline
## QA seam, which exercises the offline UI without a server.
func _backend_section() -> Dictionary:
	return {
		"title": "BACKEND",
		"controls": [
			_label("mode", func() -> Variant: return "mock" if not OnlineService.is_real_mode() else "real"),
			_label("state", func() -> Variant: return "online" if OnlineService.is_online() else "offline"),
			_bool("Force offline (QA)", func() -> Variant: return OnlineService.is_forced_offline(), func(value: Variant) -> void: OnlineService.force_offline(bool(value))),
			_action("Ensure tournaments (F4)", func() -> void: ensure_tournaments()),
			_label("tournaments", func() -> Variant: return _tournament_ensure_result),
			_action("Ensure leaderboards (E5)", func() -> void: ensure_leaderboards()),
			_label("leaderboards", func() -> Variant: return _leaderboard_ensure_result),
		],
	}


func _telemetry_section() -> Dictionary:
	return {
		"title": "TELEMETRY",
		"controls": [
			_label("device_id", _t_getter("device_id")),
			_label("save_version", _t_getter("save_version")),
			_label("created_at", _t_getter("created_at")),
			_label("last_played_at", _t_getter("last_played_at")),
			_label("session_id", _t_getter("session_id")),
			_label("config_loaded", _t_getter("config_loaded")),
			_label("fps", _t_getter("fps")),
		],
	}


func _ads_section() -> Dictionary:
	var banner_getter := func() -> Variant:
		var t := get_telemetry()
		return "%s / %s" % [str(t.get("banner_state", "")), str(t.get("banner_creative", ""))]
	return {
		"title": "ADS",
		"controls": [
			_action("Refresh banner", func() -> void: refresh_banner()),
			_action("Fail next load", func() -> void: fail_next_banner_load()),
			_action("Fail next RV watch", func() -> void: fail_next_rv()),
			_label("banner", banner_getter),
		],
	}


# --- Spec factories (one line per control) ----------------------------------------

func _int(label: String, getter: Callable, setter: Callable) -> Dictionary:
	return {"label": label, "type": CTRL_INT, "get": getter, "set": setter}


func _float(label: String, getter: Callable, setter: Callable) -> Dictionary:
	return {"label": label, "type": CTRL_FLOAT, "get": getter, "set": setter}


func _string(label: String, getter: Callable, setter: Callable) -> Dictionary:
	return {"label": label, "type": CTRL_STRING, "get": getter, "set": setter}


func _bool(label: String, getter: Callable, setter: Callable) -> Dictionary:
	return {"label": label, "type": CTRL_BOOL, "get": getter, "set": setter}


func _enum(label: String, getter: Callable, setter: Callable, options: Array[String]) -> Dictionary:
	return {"label": label, "type": CTRL_ENUM, "get": getter, "set": setter, "options": options}


func _action(label: String, press: Callable) -> Dictionary:
	return {"label": label, "type": CTRL_ACTION, "press": press}


func _confirm(label: String, text: String, press: Callable) -> Dictionary:
	return {"label": label, "type": CTRL_CONFIRM, "text": text, "press": press}


func _label(label: String, getter: Callable) -> Dictionary:
	return {"label": label, "type": CTRL_LABEL, "get": getter}


# --- Parameter-capture callables (loop-generated bindings bind the right value) ----

func _profile_value(key: String, default_value: Variant = 0) -> Callable:
	return func() -> Variant: return SaveSystem.get_value("profile", key, default_value)


func _profile_setter(key: String) -> Callable:
	return func(value: Variant) -> void:
		SaveSystem.set_value("profile", key, value)
		SaveSystem.save_game()
		EventBus.profile_updated.emit(SaveSystem.get_domain("profile"))


func _flag_getter(flag_name: String) -> Callable:
	return func() -> Variant: return RemoteConfig.is_enabled(flag_name, false)


func _flag_setter(flag_name: String) -> Callable:
	return func(value: Variant) -> void: set_flag(flag_name, bool(value))


func _exp_getter(experiment_name: String) -> Callable:
	return func() -> Variant: return RemoteConfig.get_experiment(experiment_name)


func _exp_setter(experiment_name: String) -> Callable:
	return func(value: Variant) -> void: force_variant(experiment_name, str(value))


func _rc_value(key: String, default_value: Variant) -> Callable:
	return func() -> Variant: return RemoteConfig.get_value(key, default_value)


func _rc_setter(key: String) -> Callable:
	return func(value: Variant) -> void: RemoteConfig.set_value(key, value)


func _t_getter(key: String) -> Callable:
	return func() -> Variant: return get_telemetry().get(key, "")


# --- Service API: save tools -------------------------------------------------------

## Mirrors Settings' reset sequence (settings_screen.gd _on_reset_confirmed).
func reset_save() -> void:
	SaveSystem.clear_save()
	SettingsManager.reset_to_defaults()
	EventBus.profile_updated.emit(SaveSystem.get_domain("profile"))
	EventBus.currency_changed.emit("coins", 0)
	EventBus.currency_changed.emit("gems", 0)


func set_currency(currency: String, amount: int) -> void:
	var value := maxi(amount, 0)
	SaveSystem.set_value("profile", currency, value)
	SaveSystem.save_game()
	EventBus.currency_changed.emit(currency, value)
	EventBus.profile_updated.emit(SaveSystem.get_domain("profile"))


func set_level(level: int) -> void:
	var value := maxi(level, 1)
	SaveSystem.set_value("profile", "level", value)
	SaveSystem.save_game()
	EventBus.profile_updated.emit(SaveSystem.get_domain("profile"))


func set_xp(xp: int) -> void:
	var value := maxi(xp, 0)
	SaveSystem.set_value("profile", "xp", value)
	SaveSystem.save_game()
	EventBus.profile_updated.emit(SaveSystem.get_domain("profile"))


func set_stage(stage: int) -> void:
	var value := clampi(stage, 1, maxi(StageCatalog.stage_count(), 1))
	SaveSystem.set_value("profile", "stage", value)
	SaveSystem.save_game()
	EventBus.profile_updated.emit(SaveSystem.get_domain("profile"))


func set_piggy_balance(amount: int) -> void:
	var value := maxi(amount, 0)
	SaveSystem.set_value("piggy_bank", "balance", value)
	SaveSystem.save_game()


func clear_claim_stamps() -> void:
	SaveSystem.set_domain("offers", {})
	SaveSystem.set_domain("campaign_claims", {})
	SaveSystem.save_game()


## Idempotently creates the configured tournaments on Nakama via the
## tournament_ops server function (TDD §3.23). Real mode + online required;
## the outcome lands in _tournament_ensure_result for the BACKEND label.
func ensure_tournaments() -> void:
	var client: Variant = OnlineService.get_client()
	var session := OnlineService.get_session()
	if not OnlineService.is_real_mode() or not OnlineService.is_online() or client == null or session == null:
		_tournament_ensure_result = "needs real mode + online"
		return
	_ensure_tournaments_async(client, session)


func _ensure_tournaments_async(client: Variant, session: NakamaSession) -> void:
	var lines: Array[String] = []
	for event in RemoteConfig.get_events():
		var kind := str(event.get("kind", ""))
		if kind != TournamentService.KIND_SOLO and kind != TournamentService.KIND_TEAM:
			continue
		var metadata: Variant = event.get("metadata", {})
		var tournament_id := ""
		if typeof(metadata) == TYPE_DICTIONARY:
			tournament_id = str((metadata as Dictionary).get("tournament_id", ""))
		if tournament_id == "":
			lines.append("%s: missing tournament_id" % str(event.get("id", "")))
			continue
		var duration_sec := int(float(event.get("ends_in_hours", 24)) * 3600.0)
		var payload := JSON.stringify({
			"action": "ensure", "id": tournament_id, "title": str(event.get("title", tournament_id)),
			"duration_sec": duration_sec, "event_id": str(event.get("id", "")),
		})
		var rpc: Variant = await client.rpc_async(session, "tournament_ops", payload)
		if rpc.is_exception():
			lines.append("%s: rpc failed" % tournament_id)
			continue
		var parsed: Variant = JSON.parse_string(str(rpc.payload))
		if typeof(parsed) == TYPE_DICTIONARY and bool((parsed as Dictionary).get("ok", false)):
			lines.append("%s: ok (created=%s)" % [tournament_id, str((parsed as Dictionary).get("created", ""))])
		else:
			lines.append("%s: %s" % [tournament_id, str(rpc.payload)])
	_tournament_ensure_result = "; ".join(lines) if lines.size() > 0 else "no kind-bearing events in config"


## Idempotently creates the best-score leaderboard on Nakama via the
## leaderboard_ops server function (TDD §3.26). Real mode + online required;
## the outcome lands in _leaderboard_ensure_result for the BACKEND label.
func ensure_leaderboards() -> void:
	var client: Variant = OnlineService.get_client()
	var session := OnlineService.get_session()
	if not OnlineService.is_real_mode() or not OnlineService.is_online() or client == null or session == null:
		_leaderboard_ensure_result = "needs real mode + online"
		return
	_ensure_leaderboards_async(client, session)


func _ensure_leaderboards_async(client: Variant, session: NakamaSession) -> void:
	var payload := JSON.stringify({"action": "ensure", "id": LeaderboardService.LEADERBOARD_ID})
	var rpc: Variant = await client.rpc_async(session, "leaderboard_ops", payload)
	if rpc.is_exception():
		_leaderboard_ensure_result = "rpc failed"
		return
	var parsed: Variant = JSON.parse_string(str(rpc.payload))
	if typeof(parsed) == TYPE_DICTIONARY and bool((parsed as Dictionary).get("ok", false)):
		_leaderboard_ensure_result = "%s: ok (created=%s)" % [LeaderboardService.LEADERBOARD_ID, str((parsed as Dictionary).get("created", ""))]
	else:
		_leaderboard_ensure_result = str(rpc.payload)


# --- Service API: config / systems ---------------------------------------------------

func refetch_config() -> void:
	RemoteConfig.fetch()


func set_flag(flag_name: String, enabled: bool) -> void:
	RemoteConfig.set_flag(flag_name, enabled)


func force_variant(experiment_name: String, variant_id: String) -> void:
	RemoteConfig.force_variant(experiment_name, variant_id)


func set_language(language_code: String) -> void:
	SettingsManager.set_language(language_code)


func set_music_enabled(enabled: bool) -> void:
	SettingsManager.set_music_enabled(enabled)


func set_sfx_enabled(enabled: bool) -> void:
	SettingsManager.set_sfx_enabled(enabled)


# --- Service API: telemetry ---------------------------------------------------------

func get_telemetry() -> Dictionary:
	var meta := SaveSystem.get_domain("meta")
	return {
		"device_id": RemoteConfig.get_device_id(),
		"save_version": SaveSystem.SAVE_VERSION,
		"created_at": int(meta.get("created_at", 0)),
		"last_played_at": int(meta.get("last_played_at", 0)),
		"session_id": Analytics.get_session_id(),
		"config_loaded": RemoteConfig.is_loaded(),
		"banner_state": AdManager.get_state(),
		"banner_creative": str(AdManager.get_current_creative().get("id", "")),
		# B3: live frame rate (snapshot on panel open; the editor profiler is
		# the tool for deeper CPU/memory breakdowns — see NOTES.md).
		"fps": int(Engine.get_frames_per_second()),
	}


# --- Service API: ads -------------------------------------------------------------------

func refresh_banner() -> void:
	AdManager.refresh()


func fail_next_banner_load() -> void:
	AdManager.debug_fail_next_load()


func fail_next_rv() -> void:
	AdManager.debug_fail_next_rewarded()


func reset_gift_pile() -> void:
	SaveSystem.set_domain("gift_pile", {})
	SaveSystem.save_game()
	EventBus.gift_pile_run_changed.emit(null)


# --- Internals -------------------------------------------------------------------------

## Explicit anchor/offset writes (NOT set_anchors_preset — that locks 0x0
## after tree entry on Godot 4.7; see NOTES.md).
func _pin_full_rect(control: Control) -> void:
	control.anchor_left = 0.0
	control.anchor_top = 0.0
	control.anchor_right = 1.0
	control.anchor_bottom = 1.0
	control.offset_left = 0.0
	control.offset_top = 0.0
	control.offset_right = 0.0
	control.offset_bottom = 0.0

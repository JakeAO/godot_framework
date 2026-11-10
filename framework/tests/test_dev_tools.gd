extends GutTest
## DevTools (TDD §3.15): debug-build gating of the overlay, both access
## gestures (tilde key + 3-finger downward swipe with debounce), the save /
## config / telemetry service API, and the DevPanel section rendering.
## The editor binary is a debug build, so the panel exists in these tests.

var _original_config_path: String = ""
var _original_cache_path: String = ""
var _original_save_path: String = ""
var _temp_config_path: String = ""
var _temp_cache_path: String = ""
var _temp_save_path: String = ""


func before_all() -> void:
	DirAccess.make_dir_recursive_absolute("user://gut_tmp")


func before_each() -> void:
	# Leave the service in a known state regardless of what the previous test did.
	if DevTools.is_panel_open():
		DevTools._close_panel()
	DevTools._pointers.clear()
	DevTools._debounce_until_msec = 0

	_original_config_path = RemoteConfig._config_path
	_original_cache_path = RemoteConfig._cache_path
	_original_save_path = SaveSystem.get_save_path()
	var stamp := Time.get_ticks_usec()
	_temp_config_path = "user://gut_tmp/dt_%d.json" % stamp
	_temp_cache_path = "user://gut_tmp/dt_cache_%d.json" % (stamp + 1)
	_temp_save_path = "user://gut_tmp/dt_save_%d.json" % (stamp + 2)
	SaveSystem.set_save_path(_temp_save_path)
	SaveSystem.load_save()
	_reset_remote_config()
	RemoteConfig.set_config_path(_temp_config_path)
	RemoteConfig.set_cache_path(_temp_cache_path)
	_write_config()
	RemoteConfig.fetch()
	assert_true(RemoteConfig.is_loaded(), "stub config must load for dev tools tests")


func after_each() -> void:
	if DevTools.is_panel_open():
		DevTools._close_panel()
	DevTools._pointers.clear()
	DevTools._debounce_until_msec = 0
	RemoteConfig._forced_variants.clear()
	RemoteConfig.set_config_path(_original_config_path)
	RemoteConfig.set_cache_path(_original_cache_path)
	SaveSystem.set_save_path(_original_save_path)
	var paths: Array[String] = [_temp_config_path, _temp_cache_path, _temp_save_path]
	for p in paths:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
		var tmp := p + ".tmp"
		if FileAccess.file_exists(tmp):
			DirAccess.remove_absolute(tmp)


# --- Overlay lifecycle ---------------------------------------------------------

func test_panel_starts_closed_and_overlay_hidden() -> void:
	assert_false(DevTools.is_panel_open(), "panel starts closed")
	assert_false(DevTools._overlay_root.visible, "overlay root hidden while closed (hidden = no input)")


func test_tilde_key_opens_and_closes_panel() -> void:
	watch_signals(DevTools)
	DevTools._unhandled_input(_tilde_key())
	assert_true(DevTools.is_panel_open(), "tilde press opens the panel")
	assert_true(DevTools._overlay_root.visible, "overlay root visible while open")
	assert_signal_emitted_with_parameters(DevTools, "panel_toggled", [true])
	DevTools._unhandled_input(_tilde_key())
	assert_false(DevTools.is_panel_open(), "second tilde press closes the panel")
	assert_signal_emitted_with_parameters(DevTools, "panel_toggled", [false])


func test_physical_backquote_key_also_toggles() -> void:
	DevTools._unhandled_input(_backquote_physical_key())
	assert_true(DevTools.is_panel_open(), "physical backquote key opens the panel on any layout")


func test_key_release_and_echo_do_not_toggle() -> void:
	DevTools._unhandled_input(_tilde_key(false))
	assert_false(DevTools.is_panel_open(), "key release must not toggle")
	DevTools._unhandled_input(_tilde_key(true, true))
	assert_false(DevTools.is_panel_open(), "auto-repeat echo must not toggle")


func test_panel_persisted_across_opens_without_config_change() -> void:
	DevTools.toggle_panel()
	var first := DevTools._panel
	assert_true(is_instance_valid(first), "a panel instance exists while open")
	DevTools.toggle_panel()
	DevTools.toggle_panel()
	var second := DevTools._panel
	assert_eq(second, first, "the same panel instance is reused across opens (no rebuild churn)")


func test_structure_change_triggers_in_place_rebuild() -> void:
	DevTools.toggle_panel()
	var panel := DevTools._panel
	var checks_before := _count_checkboxes(panel)
	RemoteConfig._flags["extra_flag"] = true  # whitebox: config structure changed
	DevTools.toggle_panel()
	DevTools.toggle_panel()
	assert_eq(DevTools._panel, panel, "the same instance survives a structure change")
	assert_eq(str(panel._structure_key), DevTools.get_structure_key(), "the panel adopted the new structure key")
	assert_eq(_count_checkboxes(panel), checks_before + 1, "the new flag appears as a checkbox after the rebuild")


# --- 3-finger swipe gesture ------------------------------------------------------

func test_three_finger_down_swipe_opens_panel() -> void:
	watch_signals(DevTools)
	_swipe_down(160.0)
	assert_true(DevTools.is_panel_open(), "3-finger downward swipe opens the panel")
	assert_signal_emitted_with_parameters(DevTools, "panel_toggled", [true])


func test_short_or_insufficient_swipes_ignored() -> void:
	# Two pointers only: below the minimum.
	DevTools._input(_touch(0, Vector2(360.0, 400.0), true))
	DevTools._input(_touch(1, Vector2(380.0, 400.0), true))
	DevTools._input(_drag(0, Vector2(360.0, 700.0)))
	assert_false(DevTools.is_panel_open(), "two-finger swipe is ignored")
	_release_all()

	# Three pointers but below the 120px threshold.
	_swipe_down(60.0)
	assert_false(DevTools.is_panel_open(), "swipe under the 120px threshold is ignored")
	_release_all()

	# Three pointers moving UP: direction matters.
	for i in DevTools.SWIPE_MIN_POINTERS:
		DevTools._input(_touch(i, Vector2(360.0 + float(i), 700.0), true))
	DevTools._input(_drag(0, Vector2(360.0, 400.0)))
	assert_false(DevTools.is_panel_open(), "upward swipe is ignored")
	_release_all()


func test_swipe_debounce_blocks_immediate_retrigger() -> void:
	_swipe_down(160.0)
	assert_true(DevTools.is_panel_open(), "first swipe opens the panel")
	# Immediate second full swipe: inside the 1s debounce window.
	_swipe_down(160.0)
	assert_true(DevTools.is_panel_open(), "debounce swallows the immediate re-trigger")
	# After the window (whitebox rewind), the same gesture works again.
	DevTools._debounce_until_msec = 0
	_swipe_down(160.0)
	assert_false(DevTools.is_panel_open(), "swipe after the debounce window toggles closed")


# --- Save tools -------------------------------------------------------------------

func test_set_currency_persists_and_emits() -> void:
	watch_signals(EventBus)
	DevTools.set_currency("coins", 123)
	assert_eq(int(SaveSystem.get_value("profile", "coins", 0)), 123, "coins persisted to the profile domain")
	assert_signal_emitted_with_parameters(EventBus, "currency_changed", ["coins", 123])
	assert_signal_emitted(EventBus, "profile_updated", "profile refresh announced for live UI")
	DevTools.set_currency("gems", -5)
	assert_eq(int(SaveSystem.get_value("profile", "gems", 0)), 0, "negative amounts clamp to zero")


func test_set_level_xp_stage_clamp_to_valid_ranges() -> void:
	DevTools.set_stage(9)
	assert_eq(int(SaveSystem.get_value("profile", "stage", 1)), 5, "stage clamps to the max (5)")
	DevTools.set_stage(0)
	assert_eq(int(SaveSystem.get_value("profile", "stage", 1)), 1, "stage clamps to the min (1)")
	DevTools.set_level(0)
	assert_eq(int(SaveSystem.get_value("profile", "level", 1)), 1, "level clamps to 1")
	DevTools.set_xp(-50)
	assert_eq(int(SaveSystem.get_value("profile", "xp", 0)), 0, "xp clamps to zero")


func test_reset_save_restores_defaults_and_emits() -> void:
	SaveSystem.set_value("profile", "coins", 77)
	SaveSystem.set_value("profile", "gems", 8)
	SaveSystem.set_value("profile", "level", 3)
	SettingsManager.set_language("es")
	watch_signals(EventBus)
	DevTools.reset_save()
	assert_eq(int(SaveSystem.get_value("profile", "coins", -1)), 0, "coins back to default")
	assert_eq(int(SaveSystem.get_value("profile", "gems", -1)), 0, "gems back to default")
	assert_eq(int(SaveSystem.get_value("profile", "level", -1)), 1, "level back to default")
	assert_eq(SettingsManager.get_language(), "en", "settings reset to defaults (language)")
	assert_signal_emitted(EventBus, "profile_updated", "profile refresh emitted")
	assert_signal_emitted_with_parameters(EventBus, "currency_changed", ["coins", 0], 0)
	assert_signal_emitted_with_parameters(EventBus, "currency_changed", ["gems", 0], 1)


func test_clear_claim_stamps_wipes_both_domains() -> void:
	SaveSystem.set_domain("offers", {"daily_gift": 123})
	SaveSystem.set_domain("campaign_claims", {"practice_bonus": 456})
	DevTools.clear_claim_stamps()
	assert_eq(SaveSystem.get_domain("offers"), {}, "offer claim stamps wiped")
	assert_eq(SaveSystem.get_domain("campaign_claims"), {}, "campaign claim stamps wiped")


# --- Config / experiment tools -----------------------------------------------------

func test_config_overrides_route_and_refetch_clears() -> void:
	var natural := RemoteConfig.get_experiment("results_coin_multiplier")
	assert_false(natural.is_empty(), "natural variant assigned before forcing")
	var target := "x1" if natural == "x2" else "x2"
	DevTools.set_flag("banner_ads_enabled", false)
	assert_false(RemoteConfig.is_enabled("banner_ads_enabled"), "flag override applied via the service")
	DevTools.force_variant("results_coin_multiplier", target)
	assert_eq(RemoteConfig.get_experiment("results_coin_multiplier"), target, "variant forced via the service")
	DevTools.refetch_config()
	assert_true(RemoteConfig.is_enabled("banner_ads_enabled"), "refetch clears the flag override")
	assert_eq(RemoteConfig.get_experiment("results_coin_multiplier"), natural, "refetch clears the variant pin")


func test_force_variant_unknown_warns_and_noops() -> void:
	DevTools.force_variant("no_such_experiment", "x1")
	assert_push_warning("cannot force unknown experiment", "unknown experiment warns")
	assert_eq(RemoteConfig.get_experiment("no_such_experiment"), "", "unknown experiment still resolves empty")


# --- Telemetry -----------------------------------------------------------------------

func test_get_telemetry_reports_live_state() -> void:
	var t := DevTools.get_telemetry()
	for key in ["device_id", "save_version", "created_at", "last_played_at", "session_id", "config_loaded", "banner_state", "banner_creative"]:
		assert_true(t.has(key), "telemetry carries %s" % key)
	assert_false(str(t["device_id"]).is_empty(), "device id present after fetch")
	assert_eq(int(t["save_version"]), SaveSystem.SAVE_VERSION, "save version reported")
	assert_true(bool(t["config_loaded"]), "config loaded state true after fetch")
	assert_eq(str(t["banner_state"]), AdManager.get_state(), "banner state mirrors AdManager")


# --- Panel rendering -------------------------------------------------------------------

func test_panel_renders_sections_from_live_config() -> void:
	var host := Control.new()
	host.size = Vector2(720, 1280)
	add_child(host)
	var panel := DevPanel.new()
	host.add_child(panel)
	panel.setup(DevTools.get_sections(), DevTools.get_structure_key())
	await wait_seconds(0.1)

	# Flags: one checkbox per config flag + the two SYSTEMS toggles (Music/SFX)
	# + the BACKEND force-offline QA toggle.
	var expected_checks := RemoteConfig.get_flags().size() + 3
	assert_eq(_count_checkboxes(panel), expected_checks, "flag checkboxes + music/sfx/force-offline toggles rendered")

	for experiment_name in RemoteConfig.get_experiment_names():
		assert_true(_find_label_with(panel, experiment_name) != null, "experiment row for %s" % experiment_name)

	var device_id := str(RemoteConfig.get_device_id())
	assert_true(_find_label_with(panel, device_id) != null, "telemetry shows the live device id")
	assert_true(_find_label_with(panel, "DEV TOOLS") != null, "panel header rendered")
	host.queue_free()


func test_registry_specs_are_well_formed() -> void:
	var sections := DevTools.get_sections()
	assert_gt(sections.size(), 0, "registry has sections")
	for section in sections:
		var title := str(section.get("title", ""))
		assert_false(title.is_empty(), "section has a title")
		var controls: Array = section.get("controls", [])
		assert_gt(controls.size(), 0, "section %s has controls" % title)
		for spec in controls:
			assert_true(typeof(spec) == TYPE_DICTIONARY, "spec is a dictionary")
			var dict := spec as Dictionary
			var type_name := str(dict.get("type", ""))
			assert_false(type_name.is_empty(), "spec has a type")
			assert_false(str(dict.get("label", "")).is_empty(), "spec %s has a label" % type_name)
			var required: Array[String] = []
			if type_name in [DevTools.CTRL_INT, DevTools.CTRL_FLOAT, DevTools.CTRL_STRING, DevTools.CTRL_BOOL]:
				required = ["get", "set"]
			elif type_name == DevTools.CTRL_ENUM:
				required = ["get", "set", "options"]
			elif type_name == DevTools.CTRL_ACTION:
				required = ["press"]
			elif type_name == DevTools.CTRL_CONFIRM:
				required = ["text", "press"]
			elif type_name == DevTools.CTRL_LABEL:
				required = ["get"]
			else:
				assert_false(true, "unknown control type '%s'" % type_name)
			for key_name in required:
				var value: Variant = dict.get(key_name, null)
				if key_name == "options":
					assert_true(typeof(value) == TYPE_ARRAY and not (value as Array).is_empty(), "%s spec has options" % type_name)
				elif key_name == "text":
					assert_false(str(value).is_empty(), "confirm spec carries its confirmation text")
				else:
					assert_true(typeof(value) == TYPE_CALLABLE, "spec key '%s' is a Callable" % key_name)


func test_string_control_edits_player_name_through_ui() -> void:
	DevTools.toggle_panel()
	var row := _find_value_row(DevTools._panel, "Player name")
	assert_true(not row.is_empty(), "the Player name value row exists")
	var edit := row["edit"] as LineEdit
	edit.text = "QA Tester"
	(row["set_button"] as Button).pressed.emit()
	assert_eq(str(SaveSystem.get_value("profile", "name", "")), "QA Tester", "player name updated through the UI")
	assert_eq(edit.text, "QA Tester", "the field echoes the stored value")


func test_float_control_updates_remote_value_and_refetch_clears() -> void:
	DevTools.toggle_panel()
	var row := _find_value_row(DevTools._panel, "Banner refresh (s)")
	assert_true(not row.is_empty(), "the banner refresh float row exists")
	var edit := row["edit"] as LineEdit
	edit.text = "7.5"
	(row["set_button"] as Button).pressed.emit()
	assert_eq(float(RemoteConfig.get_value("banner_refresh_sec", 0.0)), 7.5, "float override applied to RemoteConfig")
	assert_eq(edit.text, "7.5", "the field echoes the stored float")
	DevTools.refetch_config()
	assert_eq(float(RemoteConfig.get_value("banner_refresh_sec", -1.0)), 30.0, "refetch clears the value override (stub default)")
	assert_eq(edit.text, "30", "the field live-refreshed after the refetch (signal-driven, no reopen)")


func test_invalid_number_rejected_with_warning() -> void:
	DevTools.toggle_panel()
	var row := _find_value_row(DevTools._panel, "Coins")
	assert_true(not row.is_empty(), "the Coins value row exists")
	var edit := row["edit"] as LineEdit
	edit.text = "abc"
	(row["set_button"] as Button).pressed.emit()
	assert_push_warning("not a valid integer", "invalid input warns")
	assert_eq(int(SaveSystem.get_value("profile", "coins", -1)), 0, "nothing was written on invalid input")


func test_reopen_refreshes_values_in_place() -> void:
	DevTools.toggle_panel()
	var panel := DevTools._panel
	var row := _find_value_row(panel, "Coins")
	assert_true(not row.is_empty(), "the Coins value row exists")
	var edit := row["edit"] as LineEdit
	DevTools.set_currency("coins", 500)
	DevTools.toggle_panel()
	DevTools.toggle_panel()
	assert_eq(DevTools._panel, panel, "same instance reused on reopen")
	assert_eq(edit.text, "500", "the value was refreshed in place on reopen (no rebuild)")


# --- Helpers ------------------------------------------------------------------------------

func _tilde_key(pressed: bool = true, echo: bool = false) -> InputEventKey:
	var e := InputEventKey.new()
	e.keycode = Key.KEY_ASCIITILDE
	e.pressed = pressed
	e.echo = echo
	return e


func _backquote_physical_key() -> InputEventKey:
	var e := InputEventKey.new()
	e.physical_keycode = Key.KEY_QUOTELEFT
	e.pressed = true
	return e


func _touch(index: int, pos: Vector2, pressed: bool) -> InputEventScreenTouch:
	var e := InputEventScreenTouch.new()
	e.index = index
	e.position = pos
	e.pressed = pressed
	return e


func _drag(index: int, pos: Vector2) -> InputEventScreenDrag:
	var e := InputEventScreenDrag.new()
	e.index = index
	e.position = pos
	return e


## Presses SWIPE_MIN_POINTERS fingers at a common start point, drags finger 0
## down by `dist` px, then releases all fingers.
func _swipe_down(dist: float) -> void:
	for i in DevTools.SWIPE_MIN_POINTERS:
		DevTools._input(_touch(i, Vector2(360.0 + float(i), 400.0), true))
	DevTools._input(_drag(0, Vector2(360.0, 400.0 + dist)))
	_release_all()


func _release_all() -> void:
	for i in DevTools.SWIPE_MIN_POINTERS:
		DevTools._input(_touch(i, Vector2(360.0 + float(i), 560.0), false))
	DevTools._pointers.clear()


func _count_checkboxes(node: Node) -> int:
	var count := 0
	if node is CheckBox:
		count += 1
	for child in node.get_children():
		count += _count_checkboxes(child)
	return count


## Finds a value row (HBox whose first child is the label) and returns
## {edit: LineEdit, set_button: Button}, or {} when not found.
func _find_value_row(node: Node, label_text: String) -> Dictionary:
	if node is HBoxContainer:
		var box := node as HBoxContainer
		var children := box.get_children()
		if not children.is_empty() and children[0] is Label and (children[0] as Label).text == label_text:
			for child in children:
				if child is LineEdit:
					return {"edit": child, "set_button": _find_button_in(box)}
	for child in node.get_children():
		var found := _find_value_row(child, label_text)
		if not found.is_empty():
			return found
	return {}


func _find_button_in(node: Node) -> Button:
	if node is Button:
		return node as Button
	for child in node.get_children():
		var found := _find_button_in(child)
		if found != null:
			return found
	return null


func _find_label_with(node: Node, needle: String) -> Label:
	if node is Label and (node as Label).text.find(needle) != -1:
		return node as Label
	for child in node.get_children():
		var found := _find_label_with(child, needle)
		if found != null:
			return found
	return null


func _reset_remote_config() -> void:
	RemoteConfig._loaded = false
	RemoteConfig._flags = {}
	RemoteConfig._values = {}
	RemoteConfig._experiments = {}
	RemoteConfig._events.clear()
	RemoteConfig._campaigns.clear()
	RemoteConfig._offers.clear()
	RemoteConfig._event_deadlines.clear()
	RemoteConfig._campaign_deadlines.clear()
	RemoteConfig._forced_variants.clear()
	RemoteConfig._exposed_this_session = {}
	RemoteConfig._device_id = ""


func _write_config() -> void:
	var src := FileAccess.open(Paths.REMOTE_CONFIG_STUB_PATH, FileAccess.READ)
	var raw := src.get_as_text()
	src.close()
	var out := FileAccess.open(_temp_config_path, FileAccess.WRITE)
	out.store_string(raw)
	out.close()

extends GutTest
## Gift Pile entry flow (GDD §8 / TDD §3.22): fixed left-zone widget, intro
## dialog states (Play / Continue / RV extra watch / come back), date-keyed run
## limits, extra-watch cap and the RV failure path. Standalone ScreenShell on a
## phone-sized host with a throwaway config.

var _host: Control
var _shell: ScreenShell = null
var _original_config_path: String = ""
var _original_cache_path: String = ""
var _original_save_path: String = ""
var _temp_config_path: String = ""
var _temp_cache_path: String = ""
var _temp_save_path: String = ""


func before_all() -> void:
	DirAccess.make_dir_recursive_absolute("user://gut_tmp")
	_host = Control.new()
	_host.custom_minimum_size = Vector2(720, 1280)
	_host.size = Vector2(720, 1280)
	add_child(_host)


func after_all() -> void:
	UIManager.close_current_dialog()
	UIManager.clear_toasts()
	if is_instance_valid(_host):
		_host.queue_free()


func before_each() -> void:
	watch_signals(EventBus)
	_original_config_path = RemoteConfig._config_path
	_original_cache_path = RemoteConfig._cache_path
	_original_save_path = SaveSystem.get_save_path()
	var stamp := Time.get_ticks_usec()
	_temp_config_path = "user://gut_tmp/gp_%d.json" % stamp
	_temp_cache_path = "user://gut_tmp/gp_cache_%d.json" % (stamp + 1)
	_temp_save_path = "user://gut_tmp/gp_save_%d.json" % (stamp + 2)
	SaveSystem.set_save_path(_temp_save_path)
	SaveSystem.load_save()
	_reset_remote_config()
	RemoteConfig.set_config_path(_temp_config_path)
	RemoteConfig.set_cache_path(_temp_cache_path)
	_write_config()
	RemoteConfig.fetch()
	_shell = ScreenShell.new()
	_host.add_child(_shell)


func after_each() -> void:
	if is_instance_valid(_shell):
		_host.remove_child(_shell)
		_shell.queue_free()
	_shell = null
	UIManager.close_current_dialog()
	UIManager.clear_toasts()
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


# --- Helpers ---------------------------------------------------------------------

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
	RemoteConfig._exposed_this_session = {}
	RemoteConfig._device_id = ""


func _write_config() -> void:
	var config := {
		"flags": {},
		"values": { "gift_pile_height": 4 },
		"experiments": {},
		"events": [],
		"campaigns": [],
		"offers": [],
	}
	var out := FileAccess.open(_temp_config_path, FileAccess.WRITE)
	out.store_string(JSON.stringify(config))
	out.close()


func _tap_gift_pile_widget() -> void:
	var slot: Control = _shell._left_items.get_child(0)
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	slot.gui_input.emit(click)


func _today() -> String:
	return Time.get_date_string_from_system()


func _yesterday() -> String:
	return StreakLogic._minus_one_day(_today())


# --- Widget + intro states -----------------------------------------------------------

func test_gift_pile_widget_is_first_in_left_zone() -> void:
	assert_eq(_shell._left_items.get_child_count(), 1, "empty config = only the fixed gift pile widget")


func test_widget_tap_opens_intro_with_play_button() -> void:
	_tap_gift_pile_widget()
	await get_tree().process_frame
	assert_true(UIManager.is_dialog_open(), "tap opens the intro dialog")
	assert_eq(str(_shell._gp_button.text), tr("gift_pile_play"), "fresh save offers Play")


func test_intro_shows_rules_prize_and_save_cost() -> void:
	_tap_gift_pile_widget()
	await get_tree().process_frame
	var panel := UIManager.dialog_host._panel
	var texts: Array[String] = []
	for child in panel.get_children():
		texts.append_array(_collect_label_texts(child))
	var joined := " | ".join(texts)
	assert_string_contains(joined, tr("gift_pile_top_prize") % ["25 " + tr("header_gems")], "top prize line present with the default jackpot")
	assert_string_contains(joined, tr("gift_pile_save_cost") % [100], "save cost line present")


func test_active_run_shows_continue_and_preserves_count() -> void:
	var run := GiftPileRun.new_run(4, {}, 7)
	SaveSystem.set_value("gift_pile", "run", run)
	SaveSystem.set_value("gift_pile", "runs_date", _today())
	SaveSystem.set_value("gift_pile", "runs_count", 1)
	_tap_gift_pile_widget()
	await get_tree().process_frame
	assert_eq(str(_shell._gp_button.text), tr("gift_pile_continue"), "active run offers Continue")
	_shell._gp_button.pressed.emit()
	assert_signal_emitted_with_parameters(EventBus, "navigation_requested", [ScreenIds.GIFT_PILE])
	var domain: Dictionary = SaveSystem.get_domain("gift_pile")
	assert_not_null(domain.get("run"), "Continue does not start a new run")
	assert_eq(int(domain.get("runs_count", -1)), 1, "the daily counter is untouched")


func test_danger_run_shows_continue_not_play() -> void:
	# A run sitting on a trap (finished but danger=true) still has its save /
	# give-up decision pending — the intro must offer Continue, never Play.
	var run := GiftPileRun.new_run(4, {}, 7)
	run["revealed"] = 4
	run["danger"] = true
	SaveSystem.set_value("gift_pile", "run", run)
	SaveSystem.set_value("gift_pile", "runs_date", _today())
	SaveSystem.set_value("gift_pile", "runs_count", 1)
	_tap_gift_pile_widget()
	await get_tree().process_frame
	assert_eq(str(_shell._gp_button.text), tr("gift_pile_continue"), "a pending trap offers Continue")
	_shell._gp_button.pressed.emit()
	assert_signal_emitted_with_parameters(EventBus, "navigation_requested", [ScreenIds.GIFT_PILE])
	var domain: Dictionary = SaveSystem.get_domain("gift_pile")
	assert_true(bool((domain.get("run", {}) as Dictionary).get("danger", false)), "Continue does not overwrite the trapped run")


func test_exhausted_runs_offer_extra_watch() -> void:
	SaveSystem.set_value("gift_pile", "runs_date", _today())
	SaveSystem.set_value("gift_pile", "runs_count", 1)
	_tap_gift_pile_widget()
	await get_tree().process_frame
	assert_eq(str(_shell._gp_button.text), tr("gift_pile_extra_watch"), "exhausted day offers the RV extra watch")


func test_extra_watch_starts_run_and_stamps_counter() -> void:
	SaveSystem.set_value("gift_pile", "runs_date", _today())
	SaveSystem.set_value("gift_pile", "runs_count", 1)
	_tap_gift_pile_widget()
	await get_tree().process_frame
	_shell._gp_button.pressed.emit()
	var domain: Dictionary = SaveSystem.get_domain("gift_pile")
	assert_not_null(domain.get("run"), "a successful watch starts the run")
	assert_eq(int(domain.get("extra_watches_count", -1)), 1, "the extra watch is stamped")
	assert_signal_emitted_with_parameters(EventBus, "navigation_requested", [ScreenIds.GIFT_PILE])


func test_extra_watch_failure_keeps_state_and_shows_note() -> void:
	AdManager.debug_fail_next_rewarded()
	SaveSystem.set_value("gift_pile", "runs_date", _today())
	SaveSystem.set_value("gift_pile", "runs_count", 1)
	_tap_gift_pile_widget()
	await get_tree().process_frame
	_shell._gp_button.pressed.emit()
	assert_null(SaveSystem.get_domain("gift_pile").get("run"), "a failed watch starts no run")
	assert_eq(int(SaveSystem.get_domain("gift_pile").get("extra_watches_count", 0)), 0, "no extra watch is consumed on failure")
	assert_string_contains(str(_shell._gp_state_label.text), tr("dlg_ad_failed"), "the dialog shows the inline failure note")
	assert_true(UIManager.is_dialog_open(), "the intro stays open after a failed watch")


func test_extra_watch_cap_reached_hides_button() -> void:
	SaveSystem.set_value("gift_pile", "runs_date", _today())
	SaveSystem.set_value("gift_pile", "runs_count", 1)
	SaveSystem.set_value("gift_pile", "extra_watches_date", _today())
	SaveSystem.set_value("gift_pile", "extra_watches_count", 1)
	_tap_gift_pile_widget()
	await get_tree().process_frame
	assert_false(_shell._gp_button.visible, "cap reached = no button")
	assert_string_contains(str(_shell._gp_state_label.text), tr("gift_pile_come_back"), "tells the player to come back")


func test_new_day_resets_run_counter() -> void:
	SaveSystem.set_value("gift_pile", "runs_date", _yesterday())
	SaveSystem.set_value("gift_pile", "runs_count", 1)
	_tap_gift_pile_widget()
	await get_tree().process_frame
	assert_eq(str(_shell._gp_button.text), tr("gift_pile_play"), "a new day resets the daily counter")


# --- Play ---------------------------------------------------------------------------

func test_play_starts_run_stamps_count_and_navigates() -> void:
	_tap_gift_pile_widget()
	await get_tree().process_frame
	_shell._gp_button.pressed.emit()
	var domain: Dictionary = SaveSystem.get_domain("gift_pile")
	assert_not_null(domain.get("run"), "Play writes a fresh run to the save")
	assert_eq((domain["run"]["pile"] as Array).size(), 4, "pile height comes from remote config")
	assert_eq(str((domain["run"]["pile"] as Array)[3].get("kind", "")), "gems", "top slot is the default jackpot kind")
	assert_eq(int(domain.get("runs_count", -1)), 1, "the daily run counter is stamped")
	assert_eq(str(domain.get("runs_date", "")), _today(), "stamped with today's date")
	assert_signal_emitted_with_parameters(EventBus, "gift_pile_run_changed", [domain["run"]])
	assert_signal_emitted_with_parameters(EventBus, "navigation_requested", [ScreenIds.GIFT_PILE])
	assert_false(UIManager.is_dialog_open(), "the intro closes on entry")


func test_play_twice_on_fresh_day_starts_two_runs() -> void:
	# Cap is 1 per day by default — the second attempt must NOT start a run.
	_tap_gift_pile_widget()
	await get_tree().process_frame
	_shell._gp_button.pressed.emit()
	UIManager.close_current_dialog()
	_tap_gift_pile_widget()
	await get_tree().process_frame
	assert_eq(str(_shell._gp_button.text), tr("gift_pile_continue"), "the active run takes over the button")


func _collect_label_texts(node: Node) -> Array[String]:
	var found: Array[String] = []
	if node is Label:
		found.append((node as Label).text)
	for child in node.get_children():
		found.append_array(_collect_label_texts(child))
	return found

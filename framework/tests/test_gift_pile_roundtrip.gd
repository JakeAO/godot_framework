extends GutTest
## Gift Pile round-trip (H5): the FULL navigation path through a local
## ScreenManager instance — home -> gift pile (climb 1) -> exit home -> RV
## extra watch -> climb 2. Screens are cached and reused by ScreenManager, so
## this pins that re-entering the gift pile refreshes its entry state instead
## of showing the previous run's stale result pane ("already completed").

var _host: Control
var _sm: Node = null
var _shell_host: Control = null
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
	_temp_config_path = "user://gut_tmp/gp_rt_%d.json" % stamp
	_temp_cache_path = "user://gut_tmp/gp_rt_cache_%d.json" % (stamp + 1)
	_temp_save_path = "user://gut_tmp/gp_rt_save_%d.json" % (stamp + 2)
	SaveSystem.set_save_path(_temp_save_path)
	SaveSystem.load_save()
	_reset_remote_config()
	RemoteConfig.set_config_path(_temp_config_path)
	RemoteConfig.set_cache_path(_temp_cache_path)
	_write_config()
	RemoteConfig.fetch()
	_sm = load("res://core/screen_manager.gd").new()
	add_child(_sm)
	_shell_host = Control.new()
	_host.add_child(_shell_host)
	_sm.attach(_shell_host)


func after_each() -> void:
	if is_instance_valid(_sm):
		remove_child(_sm)
		_sm.queue_free()
	_sm = null
	if is_instance_valid(_shell_host):
		_host.remove_child(_shell_host)
		_shell_host.queue_free()
	_shell_host = null
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


func _shell() -> ScreenShell:
	return _sm._shell


func _tap_gift_pile_widget() -> void:
	var slot: Control = _shell()._left_items.get_child(0)
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	slot.gui_input.emit(click)


func _gift_pile_screen() -> GiftPileScreen:
	return _sm.get_current_screen() as GiftPileScreen


func _tappable_slots(screen: GiftPileScreen) -> int:
	var count := 0
	for child in screen._pile_box.get_children():
		var button := child as Button
		if button != null and not button.disabled:
			count += 1
	return count


# --- Round trip --------------------------------------------------------------------

func test_second_climb_via_rv_reopens_fresh_run() -> void:
	# Climb 1: Play from the intro dialog.
	_tap_gift_pile_widget()
	await get_tree().process_frame
	assert_eq(str(_shell()._gp_button.text), tr("gift_pile_play"), "fresh save offers Play")
	_shell()._gp_button.pressed.emit()
	for i in 10:
		await get_tree().process_frame
	var screen := _gift_pile_screen()
	assert_not_null(screen, "Play navigates to the gift pile screen")
	assert_eq(str(_sm.get_current_screen_id()), str(ScreenIds.GIFT_PILE), "current screen is the gift pile")
	assert_false(screen._result_box.visible, "climb 1 opens into the play UI")
	assert_eq(screen._pile_box.get_child_count(), 4, "pile height from config rendered")

	# End climb 1 deterministically (mid-pile cash-out, no jackpot timer).
	screen._on_cash_out_pressed()
	await get_tree().process_frame
	assert_true(screen._result_box.visible, "climb 1 ends in the result pane")

	# Back home.
	screen._on_exit_pressed()
	for i in 10:
		await get_tree().process_frame
	assert_eq(str(_sm.get_current_screen_id()), str(ScreenIds.HOME), "exit returns home")

	# Climb 2: the daily run is used up, so the intro must offer the RV extra.
	_tap_gift_pile_widget()
	await get_tree().process_frame
	assert_eq(str(_shell()._gp_button.text), tr("gift_pile_extra_watch"), "exhausted day offers the RV extra watch")
	_shell()._gp_button.pressed.emit()
	for i in 10:
		await get_tree().process_frame

	var screen2 := _gift_pile_screen()
	assert_not_null(screen2, "the RV extra navigates to the gift pile")
	assert_true(screen2 == screen, "ScreenManager reuses the cached screen instance")
	var run2: Dictionary = SaveSystem.get_domain("gift_pile").get("run", {})
	assert_true(GiftPileRun.is_active(run2), "a fresh active run exists in the save")
	assert_false(screen2._result_box.visible, "the stale climb-1 result pane is gone (H5)")
	assert_eq(screen2._pile_box.get_child_count(), 4, "climb 2's pile is rendered")
	assert_eq(_tappable_slots(screen2), 1, "exactly one slot is tappable in the fresh run")


func test_reentry_after_exit_during_jackpot_flash_does_not_settle_stale_run() -> void:
	# Exit while the jackpot flash is still up: the settle never runs, so a
	# finished-but-unsettled run persists. Re-entry settles it (by design) —
	# but a FOLLOWING RV extra must then open a fresh run, not the stale pane.
	var run := GiftPileRun.new_run(4, {}, 7)
	run["revealed"] = 4
	SaveSystem.set_value("gift_pile", "run", run)
	SaveSystem.set_value("gift_pile", "runs_date", Time.get_date_string_from_system())
	SaveSystem.set_value("gift_pile", "runs_count", 1)
	SaveSystem.save_game()

	# Enter once: the finished run settles into the result pane.
	EventBus.navigation_requested.emit(ScreenIds.GIFT_PILE)
	for i in 10:
		await get_tree().process_frame
	var screen := _gift_pile_screen()
	assert_not_null(screen, "navigation reaches the gift pile")
	assert_true(screen._result_box.visible, "finished-but-unsettled run settles on entry")

	screen._on_exit_pressed()
	for i in 10:
		await get_tree().process_frame

	# RV extra starts climb 2 from home.
	_tap_gift_pile_widget()
	await get_tree().process_frame
	assert_eq(str(_shell()._gp_button.text), tr("gift_pile_extra_watch"), "the extra watch is still offered")
	_shell()._gp_button.pressed.emit()
	for i in 10:
		await get_tree().process_frame

	var screen2 := _gift_pile_screen()
	assert_false(screen2._result_box.visible, "climb 2 opens into the play UI, not the stale pane (H5)")
	assert_eq(_tappable_slots(screen2), 1, "the fresh run is tappable")

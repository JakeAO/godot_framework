extends GutTest
## Round-end progression (XP/levels per GDD §5, piggy bank deposits per GDD §6)
## and first-launch FTUE v1 (GDD §8). Screens mount directly on a phone-sized
## host; the save is redirected to a throwaway file per test.

var _host: Control
var _mounted: Array[BaseScreen] = []
var _original_path: String = ""
var _temp_path: String = ""
var _captured_result: Dictionary = {}


func before_all() -> void:
	DirAccess.make_dir_recursive_absolute("user://gut_tmp")
	_host = Control.new()
	# Phone-sized test host: screens are full-rect anchored under it, so their
	# internal layout is computed against a realistic 720x1280 content area.
	_host.custom_minimum_size = Vector2(720, 1280)
	_host.size = Vector2(720, 1280)
	add_child(_host)
	# These tests emit navigation_requested without an attached shell; silence
	# the pre-attach warning for the duration of this file.
	if EventBus.navigation_requested.is_connected(ScreenManager._on_navigation_requested):
		EventBus.navigation_requested.disconnect(ScreenManager._on_navigation_requested)


func after_all() -> void:
	if not EventBus.navigation_requested.is_connected(ScreenManager._on_navigation_requested):
		EventBus.navigation_requested.connect(ScreenManager._on_navigation_requested)
	UIManager.cancel_tutorial()
	UIManager.clear_toasts()
	if is_instance_valid(_host):
		_host.queue_free()


func before_each() -> void:
	_original_path = SaveSystem.get_save_path()
	var stamp := Time.get_ticks_usec()
	_temp_path = "user://gut_tmp/progression_%d.json" % stamp
	SaveSystem.set_save_path(_temp_path)
	SaveSystem.load_save()


func after_each() -> void:
	for screen in _mounted:
		if is_instance_valid(screen):
			screen.queue_free()
	_mounted.clear()
	UIManager.cancel_tutorial()
	UIManager.clear_toasts()
	SaveSystem.set_save_path(_original_path)
	if FileAccess.file_exists(_temp_path):
		DirAccess.remove_absolute(_temp_path)
	var tmp := _temp_path + ".tmp"
	if FileAccess.file_exists(tmp):
		DirAccess.remove_absolute(tmp)


# --- Round end: XP / levels (GDD §5) -------------------------------------------

func test_round_end_grants_xp_and_cascades_levels() -> void:
	var screen := _mount(GameScreen.new())
	watch_signals(EventBus)
	screen._on_round_ended(1500)
	# The coin multiplier (A/B) and campaign modifiers are device-stable, so
	# derive expectations from the same source of truth the screen used.
	var coins := _round_coins(1500)
	var xp_earned := _round_xp(coins)
	assert_true(xp_earned >= 100, "test score must level up under any experiment variant")
	var expected_level := 1
	var leftover := xp_earned
	while leftover >= Scoring.xp_needed_for_level(expected_level):
		leftover -= Scoring.xp_needed_for_level(expected_level)
		expected_level += 1
	assert_eq(SaveSystem.get_value("profile", "coins", -1), coins, "round coins credited")
	assert_eq(SaveSystem.get_value("profile", "xp", -1), leftover, "leftover XP after level-ups stored")
	assert_eq(SaveSystem.get_value("profile", "level", -1), expected_level, "level cascaded to the right value")
	assert_signal_emitted(EventBus, "level_upped", "level-up announced on the bus")


func test_round_end_small_score_keeps_level() -> void:
	var screen := _mount(GameScreen.new())
	watch_signals(EventBus)
	screen._on_round_ended(30)
	var xp_earned := _round_xp(_round_coins(30))
	assert_true(xp_earned < Scoring.xp_needed_for_level(1), "test score stays below the level-2 threshold")
	assert_eq(SaveSystem.get_value("profile", "xp", -1), xp_earned, "XP below the threshold is stored")
	assert_eq(SaveSystem.get_value("profile", "level", -1), 1, "no level-up below threshold")
	assert_signal_not_emitted(EventBus, "level_upped", "no level-up signal for a small round")


func test_round_end_result_carries_xp_earned() -> void:
	var screen := _mount(GameScreen.new())
	_captured_result = {}
	EventBus.gameplay_finished.connect(_on_gameplay_finished_spy)
	screen._on_round_ended(300)
	EventBus.gameplay_finished.disconnect(_on_gameplay_finished_spy)
	var coins := _round_coins(300)
	var xp_earned := _round_xp(coins)
	assert_eq(_captured_result.get("xp_earned", -1), xp_earned, "result carries modifier-scaled xp_earned")
	assert_eq(_captured_result.get("coins_earned", -1), coins, "result carries modifier-scaled coins_earned")


func test_round_end_result_reports_active_modifiers() -> void:
	var screen := _mount(GameScreen.new())
	_captured_result = {}
	EventBus.gameplay_finished.connect(_on_gameplay_finished_spy)
	screen._on_round_ended(300)
	EventBus.gameplay_finished.disconnect(_on_gameplay_finished_spy)
	var modifiers: Variant = _captured_result.get("modifiers_applied", [])
	assert_true(typeof(modifiers) == TYPE_ARRAY, "result carries a modifiers_applied array")
	var reported := 0
	for m in (modifiers as Array):
		if typeof(m) == TYPE_DICTIONARY and str((m as Dictionary).get("stat", "")) == "xp":
			reported += 1
	assert_eq(reported, _count_active_modifiers("xp"), "each active xp modifier is reported once")


# --- Round end: piggy bank deposits (GDD §6, Phase F2 — per-stage on a win) -----

func test_round_end_deposits_per_stage_on_a_win() -> void:
	var screen := _mount(GameScreen.new())
	watch_signals(EventBus)
	screen._on_round_ended(_win_threshold())
	var deposit := maxi(int(RemoteConfig.get_value("piggy_deposit_per_stage", 10)), 0)
	assert_eq(SaveSystem.get_value("piggy_bank", "balance", -1), deposit, "a won round deposits piggy_deposit_per_stage")
	assert_signal_emitted(EventBus, "piggy_bank_changed", "deposit announced on the bus")


func test_round_end_no_deposit_on_a_loss() -> void:
	var screen := _mount(GameScreen.new())
	watch_signals(EventBus)
	screen._on_round_ended(0)
	assert_eq(SaveSystem.get_value("piggy_bank", "balance", -1), 0, "a lost round deposits nothing")
	assert_signal_not_emitted(EventBus, "piggy_bank_changed", "no piggy signal on a loss")


func test_round_end_deposit_capped_at_capacity() -> void:
	SaveSystem.set_value("piggy_bank", "balance", 195)
	var screen := _mount(GameScreen.new())
	screen._on_round_ended(_win_threshold())
	assert_eq(SaveSystem.get_value("piggy_bank", "balance", -1), 200, "balance capped at piggy_bank_capacity")


# --- FTUE v1 (GDD §8) -----------------------------------------------------------

func test_ftue_starts_on_first_launch() -> void:
	var screen := _mount(HomeScreen.new())
	await _settle_layout()
	assert_true(screen._ftue_running, "FTUE flagged running on a fresh save")
	assert_true(UIManager.tutorial_host.is_active(), "tutorial overlay active")


func test_ftue_skipped_when_already_done() -> void:
	SaveSystem.set_value("meta", "ftue_done", true)
	var screen := _mount(HomeScreen.new())
	assert_false(screen._ftue_running, "FTUE never starts once marked done")
	assert_false(UIManager.tutorial_host.is_active(), "no tutorial overlay")


func test_ftue_play_step_forwards_press_and_persists_done() -> void:
	var screen := _mount(HomeScreen.new())
	await _settle_layout()
	watch_signals(EventBus)
	# Step 1: tap the highlighted ladder title (full press+release click).
	var title_center := _center_of(screen._title)
	UIManager.tutorial_host._on_overlay_input(_make_click(title_center))
	UIManager.tutorial_host._on_overlay_input(_make_release(title_center))
	assert_true(UIManager.tutorial_host.is_active(), "second step active after the first tap")
	# Step 2: tap the highlighted PLAY button.
	var play_center := _center_of(screen._ftue_play_button)
	UIManager.tutorial_host._on_overlay_input(_make_click(play_center))
	UIManager.tutorial_host._on_overlay_input(_make_release(play_center))
	assert_true(SaveSystem.get_value("meta", "ftue_done", false), "completion persists meta.ftue_done")
	assert_signal_emitted_with_parameters(EventBus, "navigation_requested", [ScreenIds.GAME])
	assert_false(UIManager.tutorial_host.is_active(), "tutorial finished after the last step")


## Regression guard for the stopped-child bug: clicks must be pushed through
## the REAL viewport GUI pipeline (hit-testing), not handed to a handler
## directly — direct calls bypass the delivery path that broke FTUE.
func test_ftue_advances_with_real_viewport_input() -> void:
	var screen := _mount(HomeScreen.new())
	await _settle_layout()
	assert_true(UIManager.tutorial_host.is_active(), "FTUE active on a fresh save")
	# Step 1 (anywhere): a real click on the highlighted title advances it.
	_push_viewport_click(_center_of(screen._title))
	await _settle_layout()
	assert_true(UIManager.tutorial_host.is_active(), "step 2 active after a real tap")
	# Step 2: a real click on the PLAY button finishes the FTUE.
	_push_viewport_click(_center_of(screen._ftue_play_button))
	await _settle_layout()
	assert_false(UIManager.tutorial_host.is_active(), "FTUE finished via real viewport input")
	assert_true(bool(SaveSystem.get_value("meta", "ftue_done", false)), "completion persisted")


## On touch devices every tap ALSO generates an emulated mouse event
## (device == DEVICE_ID_EMULATION). The twin must be swallowed so one physical
## tap drives a step exactly once — even when it lands on the NEXT step's
## target after the mid-tap transition. Regression guard for the sticky
## _press_handled flag that froze the tutorial (see TutorialHost header).
func test_emulated_mouse_twin_is_swallowed() -> void:
	var screen := _mount(HomeScreen.new())
	await _settle_layout()
	# Step 1 (anywhere): a real touch tap on the title advances to step 2.
	var touch := InputEventScreenTouch.new()
	touch.position = _center_of(screen._title)
	touch.pressed = true
	get_tree().root.push_input(touch, true)
	await get_tree().process_frame
	assert_true(UIManager.tutorial_host.is_active(), "step 2 active after a real touch tap")
	# The emulated mouse twin of that same tap lands on the NEXT step's target
	# (PLAY). It must be swallowed — not finish the FTUE.
	var play_center := _center_of(screen._ftue_play_button)
	var emulated := InputEventMouseButton.new()
	emulated.button_index = MOUSE_BUTTON_LEFT
	emulated.position = play_center
	emulated.global_position = play_center
	emulated.pressed = true
	emulated.device = InputEvent.DEVICE_ID_EMULATION
	get_tree().root.push_input(emulated, true)
	await get_tree().process_frame
	assert_true(UIManager.tutorial_host.is_active(), "emulated twin of the same tap does not advance")
	# A fresh real mouse click on PLAY finishes the FTUE.
	_push_viewport_click(play_center)
	await _settle_layout()
	assert_false(UIManager.tutorial_host.is_active(), "FTUE finished by a subsequent real click")


func test_ftue_exit_without_completion_marks_done() -> void:
	var screen := _mount(HomeScreen.new())
	await _settle_layout()
	assert_true(screen._ftue_running, "FTUE running before exit")
	_mounted.erase(screen)
	screen.queue_free()
	await _settle_layout()
	assert_true(SaveSystem.get_value("meta", "ftue_done", false), "leaving Home mid-FTUE marks it done")
	assert_push_warning("tutorial target left the tree", "stale tutorial self-cancels once its target is gone")


# --- Helpers --------------------------------------------------------------------

func _round_multiplier() -> float:
	return float(RemoteConfig.get_experiment_param("results_coin_multiplier", "multiplier", 1.0))


## Coins a round of `score` yields under the CURRENT config (A/B experiment
## multiplier x active coins-modifier campaigns), mirroring GameScreen §6 order.
func _round_coins(score: int) -> int:
	var base := Scoring.coins_for_score(score, _round_multiplier())
	return int(roundf(float(base) * _active_modifiers("coins")))


## The win threshold for stage 1 under the current config — a score equal to
## this clears the stage (GameScreen uses `>=`), so it is a guaranteed WIN.
func _win_threshold() -> int:
	return maxi(StageCatalog.effective_win_score(1), 0)


func _round_xp(coins: int) -> int:
	return int(roundf(float(coins) * _active_modifiers("xp")))


func _active_modifiers(stat: String) -> float:
	var mult := 1.0
	for campaign in RemoteConfig.get_campaigns():
		if str(campaign.get("action", "")) != "modifier" or str(campaign.get("modifies", "")) != stat:
			continue
		if not RemoteConfig.is_campaign_active(str(campaign.get("id", ""))):
			continue
		var m := float(campaign.get("multiplier", 1.0))
		if m > 0.0:
			mult *= m
	return mult


func _count_active_modifiers(stat: String) -> int:
	var count := 0
	for campaign in RemoteConfig.get_campaigns():
		if str(campaign.get("action", "")) != "modifier" or str(campaign.get("modifies", "")) != stat:
			continue
		if not RemoteConfig.is_campaign_active(str(campaign.get("id", ""))):
			continue
		if float(campaign.get("multiplier", 1.0)) > 0.0:
			count += 1
	return count


func _mount(screen: BaseScreen) -> BaseScreen:
	_host.add_child(screen)
	_mounted.append(screen)
	return screen


func _center_of(control: Control) -> Vector2:
	var rect := control.get_global_rect()
	return rect.position + rect.size * 0.5


func _settle_layout(frames: int = 5) -> void:
	for i in frames:
		await get_tree().process_frame


func _on_gameplay_finished_spy(result: Dictionary) -> void:
	_captured_result = result


func _make_click(pos: Vector2) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = pos
	event.global_position = pos
	event.pressed = true
	return event


func _make_release(pos: Vector2) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = pos
	event.global_position = pos
	event.pressed = false
	return event


## Pushes a full press+release mouse click through the viewport's real GUI
## pipeline (hit-testing included) — unlike _make_click + direct handler calls.
func _push_viewport_click(pos: Vector2) -> void:
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.position = pos
	down.global_position = pos
	down.pressed = true
	get_tree().root.push_input(down, true)
	await get_tree().process_frame
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.position = pos
	up.global_position = pos
	up.pressed = false
	get_tree().root.push_input(up, true)

extends GutTest
## GiftPileScreen (TDD §3.22): resume-on-entry, bottom-up reveal + persistence,
## danger overlay with coin/RV saves and give-up, cash-out grants (currency +
## cosmetics), auto-settle of a finished saved run, and the exit affordance.

var _host: Control
var _mounted: Array[Node] = []
var _original_path: String = ""
var _temp_path: String = ""


func before_all() -> void:
	_host = Control.new()
	_host.custom_minimum_size = Vector2(720, 1280)
	_host.size = Vector2(720, 1280)
	add_child(_host)


func before_each() -> void:
	_original_path = SaveSystem.get_save_path()
	var stamp := Time.get_ticks_usec()
	_temp_path = "user://gut_tmp/gift_pile_%d.json" % stamp
	SaveSystem.set_save_path(_temp_path)
	SaveSystem.load_save()
	RemoteConfig.fetch()
	# These tests drive the legacy direct-slot interaction; the box-selection
	# illusion (H6) has its own section below with boxes enabled.
	RemoteConfig._values["gift_pile_boxes_per_level"] = 0


func after_each() -> void:
	for node in _mounted:
		if is_instance_valid(node):
			node.queue_free()
	_mounted.clear()
	UIManager.clear_toasts()
	SaveSystem.set_save_path(_original_path)
	if FileAccess.file_exists(_temp_path):
		DirAccess.remove_absolute(_temp_path)
	var tmp := _temp_path + ".tmp"
	if FileAccess.file_exists(tmp):
		DirAccess.remove_absolute(tmp)


func after_all() -> void:
	if is_instance_valid(_host):
		_host.queue_free()


# --- Helpers ---------------------------------------------------------------------

func _mount(screen: GiftPileScreen) -> GiftPileScreen:
	_host.add_child(screen)
	_mounted.append(screen)
	return screen


func _settle(frames: int = 5) -> void:
	for i in frames:
		await get_tree().process_frame


func _seed_run(run: Dictionary) -> void:
	SaveSystem.set_value("gift_pile", "run", run)
	SaveSystem.save_game()


func _pile_coins_gems_fail_jackpot() -> Dictionary:
	return {
		"pile": [
			{"kind": "coins", "amount": 25},
			{"kind": "gems", "amount": 3},
			{"kind": "fail"},
			{"kind": "cosmetic", "cosmetic": "portrait_icon:gold"},
			{"kind": "gems", "amount": 25},
		],
		"revealed": 0,
		"banked_coins": 0,
		"banked_gems": 0,
		"danger": false,
	}


func _tappable_slot(screen: GiftPileScreen) -> Button:
	for child in screen._pile_box.get_children():
		var button := child as Button
		if button != null and not button.disabled:
			return button
	return null


# --- Entry / resume ----------------------------------------------------------------

func test_entry_without_run_shows_result_pane() -> void:
	var screen := _mount(GiftPileScreen.new())
	await _settle()
	assert_true(screen._result_box.visible, "no saved run = result pane")
	assert_eq(screen._result_label.text, tr("gift_pile_no_run"), "explains the empty state")
	assert_eq(screen._pile_box.get_child_count(), 0, "no slots rendered")


func test_entry_resumes_saved_active_run() -> void:
	_seed_run(_pile_coins_gems_fail_jackpot())
	var screen := _mount(GiftPileScreen.new())
	await _settle()
	assert_false(screen._result_box.visible, "active run resumes into play UI")
	assert_eq(screen._pile_box.get_child_count(), 5, "one slot per pile entry")
	assert_eq(screen._bank_label.text, "%s 0   %s 0" % [tr("header_coins"), tr("header_gems")], "bank starts empty")
	var tappable := _tappable_slot(screen)
	assert_not_null(tappable, "exactly one slot is tappable at start")


func test_finished_saved_run_settles_on_entry() -> void:
	var run := _pile_coins_gems_fail_jackpot()
	run["revealed"] = 5
	run["banked_coins"] = 25
	run["banked_gems"] = 3 + 25
	var coins_before := int(SaveSystem.get_value("profile", "coins", 0))
	var gems_before := int(SaveSystem.get_value("profile", "gems", 0))
	_seed_run(run)
	var screen := _mount(GiftPileScreen.new())
	await _settle()
	assert_eq(int(SaveSystem.get_value("profile", "coins", -1)), coins_before + 25, "banked coins granted on settle")
	assert_eq(int(SaveSystem.get_value("profile", "gems", -1)), gems_before + 28, "banked gems granted on settle")
	assert_null(SaveSystem.get_domain("gift_pile").get("run"), "settled run is cleared from the save")


# --- Reveal flow -------------------------------------------------------------------

func test_tap_reveals_next_slot_banks_and_persists() -> void:
	watch_signals(EventBus)
	_seed_run(_pile_coins_gems_fail_jackpot())
	var screen := _mount(GiftPileScreen.new())
	await _settle()
	var tappable := _tappable_slot(screen)
	tappable.pressed.emit()
	await _settle(2)
	assert_signal_emitted(EventBus, "gift_pile_run_changed")
	var saved: Dictionary = SaveSystem.get_domain("gift_pile").get("run", {})
	assert_eq(int(saved.get("revealed", -1)), 1, "one slot revealed in the save")
	assert_eq(int(saved.get("banked_coins", -1)), 25, "coin slot banked into the save")
	assert_eq(screen._bank_label.text, "%s 25   %s 0" % [tr("header_coins"), tr("header_gems")], "HUD shows the bank")


func test_only_the_next_slot_is_tappable() -> void:
	_seed_run(_pile_coins_gems_fail_jackpot())
	var screen := _mount(GiftPileScreen.new())
	await _settle()
	var enabled := 0
	for child in screen._pile_box.get_children():
		if not (child as Button).disabled:
			enabled += 1
	assert_eq(enabled, 1, "only the next unrevealed slot accepts taps")


func test_reveal_trap_opens_danger_and_blocks_cash_out() -> void:
	var run := _pile_coins_gems_fail_jackpot()
	run["revealed"] = 2
	_seed_run(run)
	var screen := _mount(GiftPileScreen.new())
	await _settle()
	_tappable_slot(screen).pressed.emit()
	await _settle(2)
	assert_true(screen._overlay.visible, "trap opens the danger overlay")
	assert_true(screen._cash_out_button.disabled, "cash out is disabled while in danger")
	screen._on_cash_out_pressed()
	var saved: Dictionary = SaveSystem.get_domain("gift_pile").get("run", {})
	assert_eq(int(saved.get("revealed", -1)), 3, "a blocked cash-out reveals nothing")
	assert_true(bool(saved.get("danger", false)), "run stays in danger")


# --- Danger overlay actions -----------------------------------------------------------

func test_save_with_coins_deducts_and_clears_danger() -> void:
	watch_signals(EventBus)
	SaveSystem.set_value("profile", "coins", 300)
	var run := _pile_coins_gems_fail_jackpot()
	run["revealed"] = 2
	_seed_run(run)
	var screen := _mount(GiftPileScreen.new())
	await _settle()
	_tappable_slot(screen).pressed.emit()
	await _settle(2)
	screen._on_save_coins_pressed()
	await _settle(2)
	assert_signal_emitted(EventBus, "currency_changed")
	assert_eq(int(SaveSystem.get_value("profile", "coins", -1)), 200, "save cost deducted")
	assert_false(screen._overlay.visible, "overlay closes after a save")
	var saved: Dictionary = SaveSystem.get_domain("gift_pile").get("run", {})
	assert_false(bool(saved.get("danger", false)), "danger cleared in the save")
	assert_eq(int(saved.get("revealed", -1)), 3, "the run continues where it stopped")


func test_save_button_disabled_when_unaffordable() -> void:
	SaveSystem.set_value("profile", "coins", 50)
	var run := _pile_coins_gems_fail_jackpot()
	run["revealed"] = 2
	_seed_run(run)
	var screen := _mount(GiftPileScreen.new())
	await _settle()
	_tappable_slot(screen).pressed.emit()
	await _settle(2)
	assert_true(screen._save_button.disabled, "50 coins cannot pay the 100-coin save")


func test_watch_rv_save_clears_danger() -> void:
	var run := _pile_coins_gems_fail_jackpot()
	run["revealed"] = 2
	_seed_run(run)
	var screen := _mount(GiftPileScreen.new())
	await _settle()
	_tappable_slot(screen).pressed.emit()
	await _settle(2)
	screen._on_watch_rv_pressed()
	await _settle(2)
	assert_false(screen._overlay.visible, "mock RV always succeeds and clears the danger")
	var saved: Dictionary = SaveSystem.get_domain("gift_pile").get("run", {})
	assert_false(bool(saved.get("danger", false)), "danger cleared in the save")


func test_give_up_clears_run_and_shows_lost() -> void:
	watch_signals(EventBus)
	var run := _pile_coins_gems_fail_jackpot()
	run["revealed"] = 2
	_seed_run(run)
	var screen := _mount(GiftPileScreen.new())
	await _settle()
	_tappable_slot(screen).pressed.emit()
	await _settle(2)
	screen._on_give_up_pressed()
	await _settle(2)
	assert_signal_emitted_with_parameters(EventBus, "gift_pile_run_changed", [null])
	assert_null(SaveSystem.get_domain("gift_pile").get("run"), "the run is gone from the save")
	assert_true(screen._result_box.visible, "result pane takes over")
	assert_eq(screen._result_label.text, tr("gift_pile_lost_result"), "tells the player they lost it all")


# --- Final-slot trap (H4) --------------------------------------------------------------

## A pile whose LAST slot is the trap — unreachable in generated runs (the top
## slot is always the jackpot) but legal in a saved/hand-built run.
func _pile_fail_last() -> Dictionary:
	return {
		"pile": [
			{"kind": "coins", "amount": 25},
			{"kind": "gems", "amount": 3},
			{"kind": "fail"},
		],
		"revealed": 0,
		"banked_coins": 0,
		"banked_gems": 0,
		"danger": false,
	}


func _seed_final_trap_state() -> void:
	var run := _pile_fail_last()
	run["revealed"] = 2
	run["banked_coins"] = 25
	run["banked_gems"] = 3
	_seed_run(run)


func test_final_slot_trap_opens_danger_not_cash_out() -> void:
	_seed_final_trap_state()
	var screen := _mount(GiftPileScreen.new())
	await _settle()
	var coins_before := int(SaveSystem.get_value("profile", "coins", -1))
	_tappable_slot(screen).pressed.emit()
	await _settle(2)
	assert_true(screen._overlay.visible, "a last-slot trap opens the danger overlay")
	assert_false(screen._result_box.visible, "no auto cash-out on a trapped run")
	assert_eq(int(SaveSystem.get_value("profile", "coins", -1)), coins_before, "the bank was not paid out")
	var saved: Dictionary = SaveSystem.get_domain("gift_pile").get("run", {})
	assert_true(bool(saved.get("danger", false)), "run stays in danger for the player's decision")


func test_save_on_final_slot_trap_settles_the_bank() -> void:
	SaveSystem.set_value("profile", "coins", 300)
	_seed_final_trap_state()
	var screen := _mount(GiftPileScreen.new())
	await _settle()
	_tappable_slot(screen).pressed.emit()
	await _settle(2)
	assert_true(screen._overlay.visible, "trap overlay first")
	screen._on_save_coins_pressed()
	await _settle(2)
	assert_eq(int(SaveSystem.get_value("profile", "coins", -1)), 300 - 100 + 25, "save cost deducted and banked coins kept")
	assert_eq(int(SaveSystem.get_value("profile", "gems", -1)), 3, "banked gems kept")
	assert_null(SaveSystem.get_domain("gift_pile").get("run"), "settled run is cleared from the save")
	assert_true(screen._result_box.visible, "result pane takes over")


func test_give_up_on_final_slot_trap_loses_everything() -> void:
	var coins_before := int(SaveSystem.get_value("profile", "coins", -1))
	_seed_final_trap_state()
	var screen := _mount(GiftPileScreen.new())
	await _settle()
	_tappable_slot(screen).pressed.emit()
	await _settle(2)
	screen._on_give_up_pressed()
	await _settle(2)
	assert_eq(int(SaveSystem.get_value("profile", "coins", -1)), coins_before, "declining loses the banked coins")
	assert_null(SaveSystem.get_domain("gift_pile").get("run"), "the run is gone from the save")
	assert_eq(screen._result_label.text, tr("gift_pile_lost_result"), "tells the player they lost it all")


func test_reentry_with_final_trap_danger_resumes_overlay() -> void:
	var run := _pile_fail_last()
	run["revealed"] = 3
	run["banked_coins"] = 25
	run["banked_gems"] = 3
	run["danger"] = true
	_seed_run(run)
	var coins_before := int(SaveSystem.get_value("profile", "coins", -1))
	var screen := _mount(GiftPileScreen.new())
	await _settle()
	assert_true(screen._overlay.visible, "a pending trap decision resumes into the overlay")
	assert_false(screen._result_box.visible, "it is never auto-settled on entry")
	assert_eq(int(SaveSystem.get_value("profile", "coins", -1)), coins_before, "no payout while the trap decision is pending")


# --- Box-selection illusion (H6) ---------------------------------------------------------

## Enables the box row for a single test (before_each forces legacy mode).
func _enable_boxes(count: int = 3) -> void:
	RemoteConfig._values["gift_pile_boxes_per_level"] = count


func test_legacy_mode_hides_box_row() -> void:
	_seed_run(_pile_coins_gems_fail_jackpot())
	var screen := _mount(GiftPileScreen.new())
	await _settle()
	assert_false(screen._boxes_row.visible, "legacy mode (0 boxes) hides the row")
	assert_eq(screen._box_buttons.size(), 0, "no box buttons are built")
	assert_not_null(_tappable_slot(screen), "direct slot taps remain the interaction")


func test_boxes_mode_renders_closed_row_and_inert_slots() -> void:
	_enable_boxes(3)
	_seed_run(_pile_coins_gems_fail_jackpot())
	var screen := _mount(GiftPileScreen.new())
	await _settle()
	assert_true(screen._boxes_row.visible, "box row is visible in box mode")
	assert_eq(screen._box_buttons.size(), 3, "one button per configured box")
	for i in 3:
		assert_false(screen._box_buttons[i].disabled, "box %d starts closed" % i)
		assert_eq(screen._box_buttons[i].text, tr("gift_pile_box_closed"), "closed box shows the mystery label")
	var next_slot: Button = null
	for child in screen._pile_box.get_children():
		var b := child as Button
		if b != null and not b.disabled:
			next_slot = b
			break
	assert_not_null(next_slot, "the covered slot still renders as progress")
	assert_true((next_slot.get_signal_connection_list("pressed")).is_empty(), "but it carries no tap handler in box mode")


func test_box_pick_reveals_next_slot_and_banks() -> void:
	_enable_boxes(3)
	_seed_run(_pile_coins_gems_fail_jackpot())  # slot 0 = +25 coins
	var screen := _mount(GiftPileScreen.new())
	await _settle()
	screen._box_buttons[1].pressed.emit()  # the MIDDLE box — any pick works (pure illusion)
	await _settle(2)
	assert_eq(screen._bank_label.text, "%s 25   %s 0" % [tr("header_coins"), tr("header_gems")], "the picked box banked the predetermined slot")
	assert_true(screen._box_buttons[1].disabled, "the picked box is now opened")
	assert_eq(screen._box_buttons[1].text, "+25 " + tr("header_coins"), "opened box shows the real content")


func test_reward_opens_other_boxes_with_fake_labels_and_rebuilds_row() -> void:
	_enable_boxes(3)
	_seed_run(_pile_coins_gems_fail_jackpot())
	var screen := _mount(GiftPileScreen.new())
	await _settle()
	screen._box_buttons[0].pressed.emit()
	await _settle(2)
	var fakes: Array[String] = [tr("gift_pile_fake_coin"), tr("gift_pile_fake_gem"), tr("gift_pile_fake_cosmetic")]
	for i in [1, 2]:
		assert_true(screen._box_buttons[i].disabled, "unpicked box %d opened with a fake reveal" % i)
		assert_true(fakes.has(screen._box_buttons[i].text), "fake label is cosmetic: '%s'" % screen._box_buttons[i].text)
	await get_tree().create_timer(GiftPileScreen.BOX_REVEAL_SEC + 0.4).timeout
	assert_eq(screen._box_buttons.size(), 3, "a fresh row replaces the revealed one")
	for i in 3:
		assert_false(screen._box_buttons[i].disabled, "fresh boxes are closed again")


func test_trap_keeps_remaining_boxes_for_next_pick() -> void:
	_enable_boxes(3)
	SaveSystem.set_value("profile", "coins", 300)
	var run := {
		"pile": [{"kind": "fail"}, {"kind": "coins", "amount": 25}],
		"revealed": 0, "banked_coins": 0, "banked_gems": 0, "danger": false,
	}
	_seed_run(run)
	var screen := _mount(GiftPileScreen.new())
	await _settle()
	screen._box_buttons[0].pressed.emit()
	await _settle(2)
	assert_true(screen._overlay.visible, "trap opens the danger overlay")
	assert_eq(screen._box_buttons[0].text, tr("gift_pile_slot_fail"), "the picked box shows the trap")
	assert_false(screen._box_buttons[1].disabled, "remaining boxes stay closed through the trap")
	screen._on_save_coins_pressed()
	await _settle(2)
	assert_false(screen._overlay.visible, "save clears the danger")
	assert_false(screen._box_buttons[1].disabled, "after the save the remaining boxes are pickable again")
	screen._box_buttons[1].pressed.emit()
	await _settle(2)
	var saved: Dictionary = SaveSystem.get_domain("gift_pile").get("run", {})
	assert_eq(int(saved.get("banked_coins", -1)), 25, "the next pick reveals the predetermined slot")


func test_all_trap_row_exhaustion_rebuilds_fresh_row() -> void:
	_enable_boxes(3)
	SaveSystem.set_value("profile", "coins", 600)
	var run := {
		"pile": [
			{"kind": "fail"}, {"kind": "fail"}, {"kind": "fail"}, {"kind": "coins", "amount": 25},
		],
		"revealed": 0, "banked_coins": 0, "banked_gems": 0, "danger": false,
	}
	_seed_run(run)
	var screen := _mount(GiftPileScreen.new())
	await _settle()
	for pick in 3:
		var idx := -1
		for i in screen._box_buttons.size():
			if not screen._box_buttons[i].disabled:
				idx = i
				break
		assert_true(idx >= 0, "a closed box is available for pick %d" % pick)
		screen._box_buttons[idx].pressed.emit()
		await _settle(2)
		assert_true(screen._overlay.visible, "pick %d hit a trap" % pick)
		screen._on_save_coins_pressed()
		await _settle(2)
	assert_eq(screen._box_buttons.size(), 3, "an exhausted all-trap row is rebuilt")
	for i in 3:
		assert_false(screen._box_buttons[i].disabled, "the fresh row is fully closed")


# --- Cash out ---------------------------------------------------------------------------

func test_cash_out_grants_currency_and_cosmetics() -> void:
	var run := _pile_coins_gems_fail_jackpot()
	# revealed=4 covers slots 0-3 (coins, gems, fail, cosmetic) — the cosmetic is
	# only in the payout once its slot has been revealed.
	run["revealed"] = 4
	run["banked_coins"] = 25
	run["banked_gems"] = 3
	_seed_run(run)
	var coins_before := int(SaveSystem.get_value("profile", "coins", 0))
	var gems_before := int(SaveSystem.get_value("profile", "gems", 0))
	var screen := _mount(GiftPileScreen.new())
	await _settle()
	screen._on_cash_out_pressed()
	await _settle(2)
	assert_eq(int(SaveSystem.get_value("profile", "coins", -1)), coins_before + 25, "banked coins granted")
	assert_eq(int(SaveSystem.get_value("profile", "gems", -1)), gems_before + 3, "banked gems granted")
	var shop: Dictionary = SaveSystem.get_domain("shop")
	assert_true((shop.get("owned_cosmetics", []) as Array).has("portrait_icon:gold"), "revealed cosmetic granted to the shop domain")
	assert_null(SaveSystem.get_domain("gift_pile").get("run"), "cash-out clears the saved run")
	assert_string_contains(screen._result_label.text, str(coins_before + 25), "result pane shows the payout")


func test_cash_out_disabled_without_active_run() -> void:
	var screen := _mount(GiftPileScreen.new())
	await _settle()
	screen._on_cash_out_pressed()
	assert_true(screen._result_box.visible, "no run = nothing to cash out")


func test_cash_out_grants_shards_toward_next_locked() -> void:
	var run := _pile_coins_gems_fail_jackpot()
	# revealed=1 covers only the coins slot — no cosmetic enters the payout.
	run["revealed"] = 1
	run["banked_coins"] = 25
	_seed_run(run)
	var screen := _mount(GiftPileScreen.new())
	await _settle()
	screen._on_cash_out_pressed()
	await _settle(2)
	var shop: Dictionary = SaveSystem.get_domain("shop")
	assert_false((shop.get("owned_cosmetics", []) as Array).has("portrait_icon:gold"), "no cosmetic was revealed, so nothing is owned")
	var progress: Dictionary = shop.get("shard_progress", {})
	assert_eq(int(progress.get("portrait_icon:gold", 0)), GiftPileScreen.DEFAULT_SHARD_REWARD, "the cash-out granted the configured shard reward toward the first locked cosmetic (H8)")


func test_cash_out_shards_accumulate_across_runs() -> void:
	for i in 2:
		var run := _pile_coins_gems_fail_jackpot()
		run["revealed"] = 1
		run["banked_coins"] = 25
		_seed_run(run)
		var screen := _mount(GiftPileScreen.new())
		await _settle()
		screen._on_cash_out_pressed()
		await _settle(2)
	var shop: Dictionary = SaveSystem.get_domain("shop")
	var progress: Dictionary = shop.get("shard_progress", {})
	assert_eq(int(progress.get("portrait_icon:gold", 0)), GiftPileScreen.DEFAULT_SHARD_REWARD * 2, "two cash-outs stack their shard rewards (H8)")


# --- Exit ---------------------------------------------------------------------------

func test_exit_navigates_home_and_keeps_run_saved() -> void:
	watch_signals(EventBus)
	_seed_run(_pile_coins_gems_fail_jackpot())
	var screen := _mount(GiftPileScreen.new())
	await _settle()
	screen._on_exit_pressed()
	assert_signal_emitted_with_parameters(EventBus, "navigation_requested", [ScreenIds.HOME])
	assert_not_null(SaveSystem.get_domain("gift_pile").get("run"), "leaving keeps the run resumable")

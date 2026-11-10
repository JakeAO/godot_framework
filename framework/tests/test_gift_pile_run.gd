extends GutTest
## Pure Gift Pile run logic (core/gift_pile_run.gd, TDD §3.22). No save system,
## no clock — hand-built run dicts and fixed seeds pin determinism and the
## immutability contract (every mutation returns a NEW dict).


const W: Dictionary = {
	"coins": 45,
	"gems": 10,
	"cosmetic": 5,
	"fail": 40,
	"coin_amount": 25,
	"gem_amount": 3,
	"cosmetic_item": "portrait_icon:gold",
}


func _run(pile: Array) -> Dictionary:
	return {
		"pile": pile,
		"revealed": 0,
		"banked_coins": 0,
		"banked_gems": 0,
		"danger": false,
	}


func _coins(amount: int) -> Dictionary:
	return {"kind": "coins", "amount": amount}


func _gems(amount: int) -> Dictionary:
	return {"kind": "gems", "amount": amount}


func _cosmetic(item: String) -> Dictionary:
	return {"kind": "cosmetic", "cosmetic": item}


func _trap() -> Dictionary:
	return {"kind": "fail"}


# --- new_run -------------------------------------------------------------------

func test_new_run_pile_shape_and_jackpot_top() -> void:
	var run := GiftPileRun.new_run(5, W, 42)
	assert_eq((run["pile"] as Array).size(), 5, "one slot per height unit")
	assert_eq(int(run["revealed"]), 0, "fresh run reveals nothing")
	assert_eq(int(run["banked_coins"]), 0, "no banked coins")
	assert_eq(int(run["banked_gems"]), 0, "no banked gems")
	assert_false(bool(run["danger"]), "no danger at start")
	var top: Dictionary = (run["pile"] as Array)[4]
	assert_eq(str(top.get("kind", "")), GiftPileRun.DEFAULT_JACKPOT["kind"], "top slot is the default jackpot kind")
	assert_eq(int(top.get("amount", -1)), int(GiftPileRun.DEFAULT_JACKPOT["amount"]), "top slot carries the default jackpot amount")


func test_new_run_custom_jackpot_forced_on_top() -> void:
	var jackpot := {"kind": "coins", "amount": 999}
	var run := GiftPileRun.new_run(3, W, 7, jackpot)
	var top: Dictionary = (run["pile"] as Array)[2]
	assert_eq(int(top.get("amount", -1)), 999, "caller jackpot wins over the default")


func test_new_run_same_seed_deterministic_different_seed_diverges() -> void:
	var a := GiftPileRun.new_run(10, W, 1234)
	var b := GiftPileRun.new_run(10, W, 1234)
	assert_eq(str(a["pile"]), str(b["pile"]), "same seed reproduces the pile")
	var c := GiftPileRun.new_run(10, W, 4321)
	assert_ne(str(c["pile"]), str(a["pile"]), "different seed changes the pile (probabilistic but pinned by this seed pair)")


func test_new_run_slots_only_valid_kinds() -> void:
	var run := GiftPileRun.new_run(20, W, 99)
	for slot_v in run["pile"]:
		var slot: Dictionary = slot_v
		assert_true(GiftPileRun.SLOT_KINDS.has(str(slot.get("kind", ""))), "slot kind from the weight table")
		match str(slot.get("kind", "")):
			"coins":
				assert_gt(int(slot.get("amount", 0)), 0, "coin slots pay something")
			"gems":
				assert_gt(int(slot.get("amount", 0)), 0, "gem slots pay something")
			"fail":
				pass
			_:
				pass


func test_new_run_empty_weights_falls_back_to_coins() -> void:
	var run := GiftPileRun.new_run(2, {}, 1)
	for i in (run["pile"] as Array).size() - 1:
		assert_eq(str((run["pile"] as Array)[i].get("kind", "")), "coins", "no weights = coin slots")


func test_new_run_zero_height_empty_pile() -> void:
	var run := GiftPileRun.new_run(0, W, 5)
	assert_true((run["pile"] as Array).is_empty(), "height 0 = empty pile, no jackpot")


# --- reveal --------------------------------------------------------------------

func test_reveal_banks_bottom_up_and_is_immutable() -> void:
	var run := _run([_coins(25), _gems(3), _cosmetic("portrait_icon:gold"), _trap(), {"kind": "gems", "amount": 25}])
	var snapshot := str(run)
	var r1 := GiftPileRun.reveal(run)
	assert_eq(str(r1["slot"].get("kind", "")), "coins", "first reveal is the bottom slot")
	assert_eq(int(r1["banked_coins"]), 25, "coin slot banks coins")
	assert_false(bool(r1["danger"]), "reward does not set danger")
	assert_false(bool(r1["over"]), "not over mid-pile")
	var r2 := GiftPileRun.reveal(r1["run"])
	assert_eq(int(r2["banked_gems"]), 3, "gem slot banks gems")
	var r3 := GiftPileRun.reveal(r2["run"])
	assert_eq(str(r3["slot"].get("cosmetic", "")), "portrait_icon:gold", "cosmetic slot reports its item")
	assert_eq(snapshot, str(run), "the input run is never mutated")


func test_reveal_fail_sets_danger_and_blocks_next_reveal() -> void:
	var run := _run([_trap(), _coins(10)])
	var r1 := GiftPileRun.reveal(run)
	assert_true(bool(r1["danger"]), "trap puts the run in danger")
	assert_eq(int(r1["banked_coins"]), 0, "a trap banks nothing")
	var blocked := GiftPileRun.reveal(r1["run"])
	assert_eq(int((blocked["run"] as Dictionary)["revealed"]), 1, "reveal is refused while in danger")
	assert_true(bool(blocked["danger"]), "danger persists until saved")


func test_reveal_last_slot_reports_over() -> void:
	var run := _run([_coins(5), {"kind": "gems", "amount": 25}])
	var r1 := GiftPileRun.reveal(run)
	assert_false(bool(r1["over"]), "one of two is not over")
	var r2 := GiftPileRun.reveal(r1["run"])
	assert_true(bool(r2["over"]), "top slot reveal ends the run")
	assert_eq(int(r2["banked_gems"]), 25, "the jackpot banks into the total")
	var past := GiftPileRun.reveal(r2["run"])
	assert_true(bool(past["over"]), "revealing past the top stays over")
	assert_eq(int((past["run"] as Dictionary)["revealed"]), 2, "no slot is revealed twice")


func test_reveal_empty_pile_over() -> void:
	var r := GiftPileRun.reveal(_run([]))
	assert_true(bool(r["over"]), "empty pile is already over")


# --- save / lose / cash out ------------------------------------------------------

func test_save_run_clears_danger_both_methods() -> void:
	var run := _run([_trap(), _coins(10)])
	var in_danger: Dictionary = GiftPileRun.reveal(run)["run"]
	assert_true(bool(in_danger["danger"]), "precondition: in danger")
	var saved_coins := GiftPileRun.save_run(in_danger, GiftPileRun.SAVE_METHOD_COINS)
	assert_false(bool(saved_coins["danger"]), "coin save clears danger")
	assert_eq(int((saved_coins as Dictionary)["banked_coins"]), 0, "saving banks nothing itself")
	var saved_rv := GiftPileRun.save_run(in_danger, GiftPileRun.SAVE_METHOD_RV)
	assert_false(bool(saved_rv["danger"]), "RV save clears danger")
	assert_true(bool(in_danger["danger"]), "input run keeps its danger (no shared mutation)")


func test_save_run_continues_after_clear() -> void:
	var run := _run([_trap(), _coins(40)])
	var in_danger: Dictionary = GiftPileRun.reveal(run)["run"]
	var saved: Dictionary = GiftPileRun.save_run(in_danger, "rv")
	var after := GiftPileRun.reveal(saved)
	assert_eq(int(after["banked_coins"]), 40, "play resumes after a save")


func test_lose_run_returns_terminal_copy() -> void:
	var run := _run([_trap(), _coins(10)])
	var in_danger: Dictionary = GiftPileRun.reveal(run)["run"]
	var snapshot := str(in_danger)
	var lost := GiftPileRun.lose_run(in_danger)
	assert_true(bool((lost as Dictionary)["danger"]), "a lost run is terminal-danger")
	assert_eq(snapshot, str(in_danger), "input untouched by lose_run")


func test_cash_out_totals_and_derived_cosmetics() -> void:
	var run := _run([_coins(25), _gems(3), _cosmetic("portrait_icon:gold"), _cosmetic("portrait_flair:ring"), _trap()])
	var r1 := GiftPileRun.reveal(run)
	var r2 := GiftPileRun.reveal(r1["run"])
	var r3 := GiftPileRun.reveal(r2["run"])
	var payout := GiftPileRun.cash_out(r3["run"])
	assert_eq(int(payout["coins"]), 25, "banked coins paid out")
	assert_eq(int(payout["gems"]), 3, "banked gems paid out")
	assert_eq((payout["cosmetics"] as Array).size(), 1, "only REVEALED cosmetics are paid (slot 4 unrevealed)")
	assert_eq(str((payout["cosmetics"] as Array)[0]), "portrait_icon:gold", "first revealed cosmetic first")


func test_cash_out_empty_run_zero() -> void:
	var payout := GiftPileRun.cash_out(_run([]))
	assert_eq(int(payout["coins"]), 0, "no coins")
	assert_eq(int(payout["gems"]), 0, "no gems")
	assert_true((payout["cosmetics"] as Array).is_empty(), "no cosmetics")


# --- is_active -------------------------------------------------------------------

func test_is_active_lifecycle() -> void:
	var run := _run([_coins(5), _coins(5)])
	assert_true(GiftPileRun.is_active(run), "fresh run active")
	var r1 := GiftPileRun.reveal(run)
	assert_true(GiftPileRun.is_active(r1["run"]), "mid-run active")
	var r2 := GiftPileRun.reveal(r1["run"])
	assert_false(GiftPileRun.is_active(r2["run"]), "finished run inactive")
	assert_false(GiftPileRun.is_active(_run([])), "empty pile inactive")

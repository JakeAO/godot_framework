class_name GiftPileRun
extends RefCounted
## Pure, immutable state machine for one Gift Pile press-your-luck run (TDD
## §3.22). Every function returns NEW dicts — inputs are never mutated (GUT
## pins this). Seeded so tests are deterministic; the screen owns persistence,
## economy and navigation, this file owns no I/O.
##
## Run dict shape (persisted in the "gift_pile" domain):
##   {pile: Array[slot dicts], revealed: int, banked_coins: int,
##    banked_gems: int, danger: bool}
## Slots are bottom-up (index 0 = bottom); slot dict =
##   {kind: "coins"|"gems"|"cosmetic"|"fail", amount?: int, cosmetic?: String}

const KIND_COINS: String = "coins"
const KIND_GEMS: String = "gems"
const KIND_COSMETIC: String = "cosmetic"
const KIND_FAIL: String = "fail"

const SAVE_METHOD_COINS: String = "coins"
const SAVE_METHOD_RV: String = "rv"

const SLOT_KINDS: Array[String] = [KIND_COINS, KIND_GEMS, KIND_COSMETIC, KIND_FAIL]
## Fallback top-slot prize when the caller passes no jackpot.
const DEFAULT_JACKPOT: Dictionary = {"kind": KIND_GEMS, "amount": 25}

## Weights keys that carry reward TUNING (not slot weights) — one place for
## all generation knobs so new_run() stays pure and config-free.
const WEIGHT_COIN_AMOUNT: String = "coin_amount"
const WEIGHT_GEM_AMOUNT: String = "gem_amount"
const WEIGHT_COSMETIC_ITEM: String = "cosmetic_item"


## Pregenerates a pile of `height` slots bottom-up from the weighted kinds in
## `weights`; the TOP slot is always the jackpot (DEFAULT_JACKPOT when none
## given). Returns the fresh run dict.
static func new_run(height: int, weights: Dictionary, seed: int, jackpot: Dictionary = {}) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var pile: Array = []
	for i in maxi(height - 1, 0):
		pile.append(_roll_slot(rng, weights))
	if height > 0:
		pile.append(jackpot.duplicate(true) if not jackpot.is_empty() else DEFAULT_JACKPOT.duplicate(true))
	return {
		"pile": pile,
		"revealed": 0,
		"banked_coins": 0,
		"banked_gems": 0,
		"danger": false,
	}


## Reveals the next slot (bottom-up) and banks its contents. Returns
## {slot, banked_coins, banked_gems, danger, over, run} — `run` is the NEW
## state; the input dict is untouched. While in danger the reveal is refused
## (the caller must save or give up first); past the top it reports over with
## the unchanged state.
static func reveal(run: Dictionary) -> Dictionary:
	var pile: Array = _pile_of(run)
	var revealed := int(run.get("revealed", 0))
	if bool(run.get("danger", false)) or revealed >= pile.size():
		return {
			"slot": {},
			"banked_coins": int(run.get("banked_coins", 0)),
			"banked_gems": int(run.get("banked_gems", 0)),
			"danger": bool(run.get("danger", false)),
			"over": revealed >= pile.size(),
			"run": run.duplicate(true),
		}
	var slot: Dictionary = (pile[revealed] as Dictionary).duplicate(true)
	var next := run.duplicate(true)
	next["revealed"] = revealed + 1
	next["banked_coins"] = int(run.get("banked_coins", 0))
	next["banked_gems"] = int(run.get("banked_gems", 0))
	next["danger"] = false
	match str(slot.get("kind", "")):
		KIND_COINS:
			next["banked_coins"] += maxi(int(slot.get("amount", 0)), 0)
		KIND_GEMS:
			next["banked_gems"] += maxi(int(slot.get("amount", 0)), 0)
		KIND_FAIL:
			next["danger"] = true
	return {
		"slot": slot,
		"banked_coins": int(next["banked_coins"]),
		"banked_gems": int(next["banked_gems"]),
		"danger": bool(next["danger"]),
		"over": revealed + 1 >= pile.size(),
		"run": next,
	}


## Clears danger after the player paid (coins) or watched RV to keep the bank.
## The caller performs the actual payment; this only advances the state.
static func save_run(run: Dictionary, method: String = SAVE_METHOD_COINS) -> Dictionary:
	assert(method == SAVE_METHOD_COINS or method == SAVE_METHOD_RV, "GiftPileRun.save_run: unknown method '%s'" % method)
	var next := run.duplicate(true)
	next["danger"] = false
	return next


## Ends the run with everything lost; returns a terminal copy. Callers persist
## null to clear the saved run (the domain shape carries no over/lost flag).
static func lose_run(run: Dictionary) -> Dictionary:
	var next := run.duplicate(true)
	next["danger"] = true
	return next


## The banked totals; cosmetics are DERIVED from the revealed slots (the run
## dict keeps no separate list — pile + revealed index are the source of truth).
static func cash_out(run: Dictionary) -> Dictionary:
	var cosmetics: Array = []
	var pile: Array = _pile_of(run)
	var revealed := mini(int(run.get("revealed", 0)), pile.size())
	for i in revealed:
		var slot: Dictionary = pile[i]
		if str(slot.get("kind", "")) == KIND_COSMETIC and str(slot.get("cosmetic", "")) != "":
			cosmetics.append(str(slot["cosmetic"]))
	return {
		"coins": int(run.get("banked_coins", 0)),
		"gems": int(run.get("banked_gems", 0)),
		"cosmetics": cosmetics,
	}


## True while the run can still reveal a slot.
static func is_active(run: Dictionary) -> bool:
	return not _pile_of(run).is_empty() and int(run.get("revealed", 0)) < _pile_of(run).size()


static func _roll_slot(rng: RandomNumberGenerator, weights: Dictionary) -> Dictionary:
	var total := 0
	for kind in SLOT_KINDS:
		total += maxi(int(weights.get(kind, 0)), 0)
	if total <= 0:
		return {"kind": KIND_COINS, "amount": 1}
	var roll := rng.randi_range(0, total - 1)
	for kind in SLOT_KINDS:
		var weight := maxi(int(weights.get(kind, 0)), 0)
		if roll < weight:
			match kind:
				KIND_COINS:
					return {"kind": kind, "amount": maxi(int(weights.get(WEIGHT_COIN_AMOUNT, 25)), 1)}
				KIND_GEMS:
					return {"kind": kind, "amount": maxi(int(weights.get(WEIGHT_GEM_AMOUNT, 3)), 1)}
				KIND_COSMETIC:
					return {"kind": kind, "cosmetic": str(weights.get(WEIGHT_COSMETIC_ITEM, ""))}
				_:
					return {"kind": kind}
		roll -= weight
	return {"kind": KIND_COINS, "amount": 1}


static func _pile_of(run: Dictionary) -> Array:
	var pile: Variant = run.get("pile", [])
	if typeof(pile) != TYPE_ARRAY:
		return []
	return pile as Array

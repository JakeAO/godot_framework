extends GutTest
## ShardLogic (TDD §3.20, H8): pure partial-unlock logic over the `shop` domain —
## grant/accumulate, completion -> owned_cosmetics, percent math, partial bounds,
## deterministic next-lockable targeting. Like ShopLogic: stateless, immutable
## inputs, new dicts out (no save I/O, no signals).


func test_grant_accumulates_and_returns_new_dict() -> void:
	var domain := {"owned_cosmetics": []}
	var out1 := ShardLogic.grant_shards(domain, "portrait_icon:gold", 3, 20)
	assert_not_same(out1, domain, "a new dict is returned")
	assert_eq(int((out1.get("shard_progress", {}) as Dictionary).get("portrait_icon:gold", 0)), 3, "shards accumulate")
	var out2 := ShardLogic.grant_shards(out1, "portrait_icon:gold", 5, 20)
	assert_eq(int((out2.get("shard_progress", {}) as Dictionary).get("portrait_icon:gold", 0)), 8, "grants stack across calls")
	assert_false(domain.has("shard_progress"), "the input is never mutated")


func test_grant_completion_moves_to_owned_and_erases_progress() -> void:
	var domain := {"owned_cosmetics": []}
	var out := ShardLogic.grant_shards(domain, "portrait_crown:crown_diamond", 20, 20)
	assert_true((out.get("owned_cosmetics", []) as Array).has("portrait_crown:crown_diamond"), "the full count unlocks the cosmetic")
	assert_false((out.get("shard_progress", {}) as Dictionary).has("portrait_crown:crown_diamond"), "the progress entry is erased on completion")


func test_grant_overfill_unlocks_without_leftover_shards() -> void:
	var domain := {"owned_cosmetics": [], "shard_progress": {"portrait_icon:silver": 18}}
	var out := ShardLogic.grant_shards(domain, "portrait_icon:silver", 5, 20)
	assert_true((out.get("owned_cosmetics", []) as Array).has("portrait_icon:silver"), "overfill completes the unlock")
	assert_false((out.get("shard_progress", {}) as Dictionary).has("portrait_icon:silver"), "no leftover shards after completion")


func test_grant_noops_leave_state_untouched() -> void:
	var owned_domain := {"owned_cosmetics": ["portrait_icon:gold"], "shard_progress": {"portrait_flair:ring_gold": 4}}
	var out_owned := ShardLogic.grant_shards(owned_domain, "portrait_icon:gold", 5, 20)
	assert_eq(int((out_owned.get("shard_progress", {}) as Dictionary).get("portrait_icon:gold", 0)), 0, "granting to an owned cosmetic is a no-op")
	assert_eq(int((out_owned.get("shard_progress", {}) as Dictionary).get("portrait_flair:ring_gold", 0)), 4, "other progress survives a no-op grant")
	var out_zero := ShardLogic.grant_shards({}, "portrait_icon:gold", 0, 20)
	assert_false((out_zero.get("shard_progress", {}) as Dictionary).has("portrait_icon:gold"), "a zero count grants nothing")
	var out_bad := ShardLogic.grant_shards({}, "", 5, 20)
	assert_false((out_bad.get("shard_progress", {}) as Dictionary).has(""), "an empty id grants nothing")


func test_unlock_percent_math() -> void:
	assert_eq(ShardLogic.unlock_percent({}, "portrait_icon:gold", 20), 0, "no progress reads 0%")
	var domain := {"shard_progress": {"portrait_icon:gold": 5}}
	assert_eq(ShardLogic.unlock_percent(domain, "portrait_icon:gold", 20), 25, "5 of 20 shards = 25%")
	var owned := {"owned_cosmetics": ["portrait_icon:gold"], "shard_progress": {"portrait_icon:gold": 3}}
	assert_eq(ShardLogic.unlock_percent(owned, "portrait_icon:gold", 20), 100, "an owned cosmetic reads 100% regardless of stale progress")


func test_is_partially_unlocked_bounds() -> void:
	assert_false(ShardLogic.is_partially_unlocked({}, "portrait_icon", "gold", 20), "0 shards is not partial")
	var domain := {"shard_progress": {"portrait_icon:gold": 1}}
	assert_true(ShardLogic.is_partially_unlocked(domain, "portrait_icon", "gold", 20), "some-but-not-full shards are partial")
	var full := {"shard_progress": {"portrait_icon:gold": 20}}
	assert_false(ShardLogic.is_partially_unlocked(full, "portrait_icon", "gold", 20), "the full count is not partial (a grant would have moved it to owned)")
	var owned := {"owned_cosmetics": ["portrait_icon:gold"], "shard_progress": {"portrait_icon:gold": 1}}
	assert_false(ShardLogic.is_partially_unlocked(owned, "portrait_icon", "gold", 20), "owned is never partial")


func test_next_lockable_target_deterministic_order() -> void:
	var domain := {"owned_cosmetics": ["portrait_icon:gold"]}
	var order := ["portrait_icon:default", "portrait_icon:gold", "portrait_icon:silver", "portrait_flair:none"]
	assert_eq(ShardLogic.next_lockable_target(domain, order), "portrait_icon:silver", "free defaults and owned cosmetics are skipped in catalog order")
	var all_owned := {"owned_cosmetics": ["portrait_icon:gold"]}  # default/none are free-owned regardless
	assert_eq(ShardLogic.next_lockable_target(all_owned, ["portrait_icon:default", "portrait_flair:none", "portrait_crown:none"]), "", "no target when everything in the list is unlocked")
	assert_eq(ShardLogic.next_lockable_target({}, ["garbage-no-colon", "portrait_icon:diamond"]), "portrait_icon:diamond", "malformed entries are skipped, not fatal")

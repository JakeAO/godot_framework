class_name ShardLogic
extends RefCounted
## Pure shard (partial-unlock) logic (TDD §3.20, H8): stateless functions over
## the `shop` domain dict returning NEW dicts — no save I/O and no signals here;
## the caller persists the result and emits the usual refresh events.
##
## A cosmetic unlocks in full once its shard count reaches `shards_per_unlock`;
## until then it renders greyed with a progress bar (0% = no indicator at all).
## Progress lives in `shop.shard_progress` as {qualified_id: int}; on completion
## the qualified id moves to `shop.owned_cosmetics` and the entry is erased.

const SHARDS_PER_UNLOCK_KEY: String = "shards_per_unlock"
const DEFAULT_SHARDS_PER_UNLOCK: int = 20


## Slot-qualified cosmetic id ("portrait_icon:gold") — the same format
## ShopLogic owns/uses for `owned_cosmetics`.
static func qualified(slot: String, id: String) -> String:
	return "%s:%s" % [slot, id]


## Adds `count` shards to `qualified_id`; a new domain is returned (inputs are
## never mutated). Reaching the full count moves the cosmetic into
## `owned_cosmetics` and erases the progress entry. Non-positive counts, empty
## ids, and already-owned cosmetics are no-ops (a duplicated, unmutated copy).
static func grant_shards(shop_domain: Dictionary, qualified_id: String, count: int, shards_per_unlock: int) -> Dictionary:
	var out := shop_domain.duplicate(true)
	if str(qualified_id).is_empty() or count <= 0 or shards_per_unlock <= 0:
		return out
	if _is_owned(out, qualified_id):
		return out
	var progress: Variant = out.get("shard_progress", {})
	if typeof(progress) != TYPE_DICTIONARY:
		progress = {}
	var progress_d := progress as Dictionary
	var total := int(progress_d.get(qualified_id, 0)) + count
	if total >= shards_per_unlock:
		var owned: Variant = out.get("owned_cosmetics", [])
		if typeof(owned) != TYPE_ARRAY:
			owned = []
		if not (owned as Array).has(qualified_id):
			(owned as Array).append(qualified_id)
		out["owned_cosmetics"] = owned
		progress_d.erase(qualified_id)
	else:
		progress_d[qualified_id] = total
	out["shard_progress"] = progress_d
	return out


## Shards collected so far (0 when absent / malformed).
static func shard_count_of(shop_domain: Dictionary, qualified_id: String) -> int:
	var progress: Variant = shop_domain.get("shard_progress", {})
	if typeof(progress) != TYPE_DICTIONARY:
		return 0
	return maxi(int((progress as Dictionary).get(str(qualified_id), 0)), 0)


## 0..100 — owned or full cosmetics read 100, a missing key reads 0.
static func unlock_percent(shop_domain: Dictionary, qualified_id: String, shards_per_unlock: int) -> int:
	if _is_owned(shop_domain, str(qualified_id)):
		return 100
	if shards_per_unlock <= 0:
		return 0
	return mini(int(shard_count_of(shop_domain, str(qualified_id)) * 100.0 / float(shards_per_unlock)), 100)


## True when the cosmetic has collected some shards but is not yet fully owned —
## the "greyed + progress bar" state (H8). 0% and 100% are both false.
static func is_partially_unlocked(shop_domain: Dictionary, slot: String, id: String, shards_per_unlock: int) -> bool:
	var qid := qualified(slot, id)
	if _is_owned(shop_domain, qid):
		return false
	if shards_per_unlock <= 0:
		return false
	var count := shard_count_of(shop_domain, qid)
	return count > 0 and count < shards_per_unlock


## First entry of `order` (an Array of qualified ids, catalog order) that is not
## yet owned — the deterministic target for shard grants. "" when everything in
## the list is already unlocked.
static func next_lockable_target(shop_domain: Dictionary, order: Array) -> String:
	for entry in order:
		var qid := str(entry)
		var parts := qid.split(":")
		if parts.size() != 2:
			continue
		if not ShopLogic.is_owned(shop_domain, str(parts[0]), str(parts[1])):
			return qid
	return ""


static func _is_owned(shop_domain: Dictionary, qualified_id: String) -> bool:
	var owned: Variant = shop_domain.get("owned_cosmetics", [])
	if typeof(owned) != TYPE_ARRAY:
		return false
	return (owned as Array).has(qualified_id)

extends GutTest
## ShopLogic pure core (TDD §3.20): can_purchase gating (balance /
## max_purchases / unlock_level / invalid items), purchase atomicity (deduct +
## grant + stamp with input immutability), and the ownership helpers used by
## Profile's owned/locked rows.


func _currency_item(price_currency: String, price_amount: int, grant_currency: String, grant_amount: int) -> Dictionary:
	return {
		"id": "test_item",
		"contents": {"type": "currency", "currency": grant_currency, "amount": grant_amount},
		"price": {"currency": price_currency, "amount": price_amount},
	}


func _cosmetic_item(slot: String, cosmetic_id: String) -> Dictionary:
	return {
		"id": "cosmetic_item",
		"contents": {"type": "cosmetic", "slot": slot, "id": cosmetic_id},
		"price": {"currency": "coins", "amount": 50},
	}


# --- can_purchase ------------------------------------------------------------

func test_can_purchase_with_sufficient_balance() -> void:
	var item := _currency_item("coins", 100, "gems", 5)
	assert_true(ShopLogic.can_purchase(item, {"coins": 100, "level": 1}, {}), "exact balance is enough")


func test_can_purchase_fails_on_insufficient_balance() -> void:
	var item := _currency_item("coins", 100, "gems", 5)
	assert_false(ShopLogic.can_purchase(item, {"coins": 99, "level": 1}, {}), "one coin short")


func test_can_purchase_uses_price_currency_not_grant_currency() -> void:
	var item := _currency_item("gems", 2, "coins", 500)
	assert_true(ShopLogic.can_purchase(item, {"gems": 2, "coins": 0}, {}), "checks the price currency")
	assert_false(ShopLogic.can_purchase(item, {"gems": 1, "coins": 9999}, {}), "grant balance is irrelevant to affordability")


func test_can_purchase_fails_at_max_purchases() -> void:
	var item := _currency_item("coins", 10, "gems", 1)
	item["max_purchases"] = 2
	var domain := {"purchases": {"test_item": 2}}
	assert_false(ShopLogic.can_purchase(item, {"coins": 999}, domain), "count == max is exhausted")


func test_can_purchase_unlimited_without_max_purchases() -> void:
	var item := _currency_item("coins", 10, "gems", 1)
	var domain := {"purchases": {"test_item": 99}}
	assert_true(ShopLogic.can_purchase(item, {"coins": 999}, domain), "absent max_purchases = repeatable")


func test_can_purchase_fails_below_unlock_level() -> void:
	var item := _currency_item("coins", 10, "gems", 1)
	item["unlock_level"] = 5
	assert_false(ShopLogic.can_purchase(item, {"coins": 999, "level": 4}, {}), "level 4 < 5")
	assert_true(ShopLogic.can_purchase(item, {"coins": 999, "level": 5}, {}), "level 5 == unlock level is enough")


func test_can_purchase_rejects_invalid_items() -> void:
	assert_false(ShopLogic.can_purchase({}, {"coins": 999}, {}), "empty item")
	assert_false(ShopLogic.can_purchase({"contents": {"type": "unknown"}, "price": {"currency": "coins", "amount": 1}}, {"coins": 999}, {}), "unknown contents type")
	assert_false(ShopLogic.can_purchase({"id": "x", "contents": {"type": "currency", "currency": "ducks", "amount": 1}, "price": {"currency": "coins", "amount": 1}}, {"coins": 999}, {}), "unknown grant currency")
	assert_false(ShopLogic.can_purchase({"id": "x", "contents": {"type": "currency", "currency": "gems", "amount": 0}, "price": {"currency": "coins", "amount": 1}}, {"coins": 999}, {}), "zero amount")


# --- purchase -----------------------------------------------------------------

func test_purchase_success_deducts_and_grants_currency() -> void:
	var item := _currency_item("coins", 300, "gems", 5)
	var profile := {"coins": 1000, "gems": 2, "level": 3}
	var result := ShopLogic.purchase(item, profile, {})
	assert_true(bool(result["ok"]), "purchase succeeds")
	var new_profile: Dictionary = result["profile"]
	assert_eq(int(new_profile["coins"]), 700, "price deducted")
	assert_eq(int(new_profile["gems"]), 7, "contents granted on top of existing")


func test_purchase_success_stamps_purchases() -> void:
	var item := _currency_item("coins", 10, "gems", 1)
	var result := ShopLogic.purchase(item, {"coins": 99}, {})
	var domain: Dictionary = result["shop_domain"]
	assert_eq(int((domain["purchases"] as Dictionary).get("test_item", 0)), 1, "first purchase stamped")
	var again := ShopLogic.purchase(item, (result["profile"] as Dictionary), domain)
	assert_eq(int(((again["shop_domain"] as Dictionary)["purchases"] as Dictionary).get("test_item", 0)), 2, "repeatable purchase increments")


func test_purchase_success_grants_cosmetic_ownership() -> void:
	var item := _cosmetic_item("portrait_icon", "gold")
	var result := ShopLogic.purchase(item, {"coins": 100}, {})
	assert_true(bool(result["ok"]), "purchase succeeds")
	var domain: Dictionary = result["shop_domain"]
	assert_eq(domain["owned_cosmetics"], ["portrait_icon:gold"], "slot-qualified id appended")


func test_purchase_fails_insufficient_without_mutation() -> void:
	var item := _currency_item("coins", 300, "gems", 5)
	var profile := {"coins": 10}
	var domain := {"purchases": {}}
	var result := ShopLogic.purchase(item, profile, domain)
	assert_false(bool(result["ok"]), "purchase rejected")
	assert_eq(str(result["reason"]), ShopLogic.REASON_INSUFFICIENT, "reason is insufficient")
	assert_true(result["profile"] == profile and result["shop_domain"] == domain, "inputs returned unmutated")


func test_purchase_fails_max_purchases_with_reason() -> void:
	var item := _currency_item("coins", 10, "gems", 1)
	item["max_purchases"] = 1
	var domain := {"purchases": {"test_item": 1}}
	var result := ShopLogic.purchase(item, {"coins": 99}, domain)
	assert_false(bool(result["ok"]), "exhausted item rejected")
	assert_eq(str(result["reason"]), ShopLogic.REASON_MAX_PURCHASES, "reason is max_purchases")


func test_purchase_fails_unlock_level_with_reason() -> void:
	var item := _currency_item("coins", 10, "gems", 1)
	item["unlock_level"] = 5
	var result := ShopLogic.purchase(item, {"coins": 99, "level": 2}, {})
	assert_false(bool(result["ok"]), "locked item rejected")
	assert_eq(str(result["reason"]), ShopLogic.REASON_LOCKED_LEVEL, "reason is locked_level")


func test_purchase_is_pure_inputs_never_mutated() -> void:
	var item := _cosmetic_item("portrait_crown", "crown_diamond")
	var profile := {"coins": 100, "gems": 0}
	var domain := {"purchases": {}, "owned_cosmetics": []}
	ShopLogic.purchase(item, profile, domain)
	assert_eq(int(profile["coins"]), 100, "profile coins untouched")
	assert_true((domain["purchases"] as Dictionary).is_empty(), "purchases untouched")
	assert_true((domain["owned_cosmetics"] as Array).is_empty(), "owned list untouched")


# --- Ownership helpers ----------------------------------------------------------

func test_is_owned_covers_free_defaults() -> void:
	assert_true(ShopLogic.is_owned({}, "portrait_icon", "default"), "default icon free")
	assert_true(ShopLogic.is_owned({}, "portrait_flair", "none"), "none flair free")
	assert_true(ShopLogic.is_owned({}, "portrait_crown", "none"), "none crown free")
	assert_false(ShopLogic.is_owned({}, "portrait_icon", "gold"), "unpurchased icon locked")


func test_is_owned_recognizes_purchases() -> void:
	var domain := {"owned_cosmetics": ["portrait_flair:ring_gold"]}
	assert_true(ShopLogic.is_owned(domain, "portrait_flair", "ring_gold"), "purchased flair owned")
	assert_false(ShopLogic.is_owned(domain, "portrait_crown", "crown_diamond"), "other slots unaffected")


func test_find_item_for_cosmetic_matches_slot_and_id() -> void:
	var items: Array[Dictionary] = [
		_currency_item("coins", 10, "gems", 1),
		_cosmetic_item("portrait_icon", "gold"),
		_cosmetic_item("portrait_flair", "ring_gold"),
	]
	var found := ShopLogic.find_item_for_cosmetic(items, "portrait_flair", "ring_gold")
	assert_eq(str(found.get("id", "")), "cosmetic_item", "matching item found")
	assert_true(ShopLogic.find_item_for_cosmetic(items, "portrait_crown", "crown_diamond").is_empty(), "no match for absent cosmetic")
	assert_true(ShopLogic.find_item_for_cosmetic(items, "portrait_icon", "ring_gold").is_empty(), "slot mismatch is not a match")

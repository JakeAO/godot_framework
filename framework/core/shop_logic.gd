class_name ShopLogic
extends RefCounted
## Pure shop purchase logic (TDD §3.20): stateless functions over
## (item, profile, shop_domain) dicts returning NEW dicts — no save I/O and no
## signals here; the screen persists the result and emits EventBus.shop_purchased.

const SHOP_DOMAIN: String = "shop"
const REASON_OK: String = "ok"
const REASON_INVALID: String = "invalid"
const REASON_INSUFFICIENT: String = "insufficient"
const REASON_MAX_PURCHASES: String = "max_purchases"
const REASON_LOCKED_LEVEL: String = "locked_level"

## Cosmetic slots that are free from first launch (never locked in Profile).
const FREE_OWNED: Array[String] = [
	"portrait_icon:default",
	"portrait_flair:none",
	"portrait_crown:none",
]


static func is_valid_item(item: Dictionary) -> bool:
	var price: Variant = item.get("price")
	if typeof(price) != TYPE_DICTIONARY:
		return false
	var price_d := price as Dictionary
	var price_currency := str(price_d.get("currency", ""))
	if (price_currency != "coins" and price_currency != "gems") or int(price_d.get("amount", 0)) <= 0:
		return false
	var contents: Variant = item.get("contents")
	if typeof(contents) != TYPE_DICTIONARY:
		return false
	var contents_d := contents as Dictionary
	match str(contents_d.get("type", "")):
		"currency":
			var currency := str(contents_d.get("currency", ""))
			return (currency == "coins" or currency == "gems") and int(contents_d.get("amount", 0)) > 0
		"cosmetic":
			var slot := str(contents_d.get("slot", ""))
			return (slot == "portrait_icon" or slot == "portrait_flair" or slot == "portrait_crown") \
					and not str(contents_d.get("id", "")).is_empty()
		_:
			return false


## JSON/save numbers surface as float in this engine build, so optional int
## fields are normalized through opt_int() — never a typeof(TYPE_INT) check.
## Returns -1 when the key is absent or non-numeric.
static func opt_int(item: Dictionary, key: String) -> int:
	var v: Variant = item.get(key)
	if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
		return int(v)
	return -1


## Sufficient balance AND under max_purchases (absent/<=0 = unlimited) AND
## player level >= unlock_level (absent/<=0 = no gate). Invalid items are
## never purchasable.
static func can_purchase(item: Dictionary, profile: Dictionary, shop_domain: Dictionary) -> bool:
	if not is_valid_item(item):
		return false
	var price := item["price"] as Dictionary
	var currency := str(price.get("currency", ""))
	if int(profile.get(currency, 0)) < int(price.get("amount", 0)):
		return false
	var max_purchases := opt_int(item, "max_purchases")
	if max_purchases > 0:
		var purchases := _purchases_of(shop_domain)
		if int(purchases.get(str(item.get("id", "")), 0)) >= max_purchases:
			return false
	var unlock_level := opt_int(item, "unlock_level")
	if unlock_level > 0 and int(profile.get("level", 1)) < unlock_level:
		return false
	return true


## Atomic purchase: deducts the price, grants the contents (currency -> profile,
## cosmetic -> shop.owned_cosmetics), stamps shop.purchases[item_id]. Returns
## {ok, reason, profile, shop_domain} — inputs are never mutated; on failure the
## returned dicts are the same (unmutated) instances passed in.
static func purchase(item: Dictionary, profile: Dictionary, shop_domain: Dictionary) -> Dictionary:
	var fail := {"ok": false, "reason": REASON_INVALID, "profile": profile, "shop_domain": shop_domain}
	if not is_valid_item(item):
		return fail
	var price := item["price"] as Dictionary
	var currency := str(price.get("currency", ""))
	var amount := int(price.get("amount", 0))
	if int(profile.get(currency, 0)) < amount:
		fail["reason"] = REASON_INSUFFICIENT
		return fail
	var max_purchases := opt_int(item, "max_purchases")
	if max_purchases > 0:
		var purchases := _purchases_of(shop_domain)
		if int(purchases.get(str(item.get("id", "")), 0)) >= max_purchases:
			fail["reason"] = REASON_MAX_PURCHASES
			return fail
	var unlock_level := opt_int(item, "unlock_level")
	if unlock_level > 0 and int(profile.get("level", 1)) < unlock_level:
		fail["reason"] = REASON_LOCKED_LEVEL
		return fail

	var new_profile := profile.duplicate(true)
	new_profile[currency] = int(new_profile.get(currency, 0)) - amount
	var new_domain := shop_domain.duplicate(true)
	var purchases_d: Variant = new_domain.get("purchases", {})
	if typeof(purchases_d) != TYPE_DICTIONARY:
		purchases_d = {}
	var item_id := str(item.get("id", ""))
	(purchases_d as Dictionary)[item_id] = int((purchases_d as Dictionary).get(item_id, 0)) + 1
	new_domain["purchases"] = purchases_d

	var contents := item["contents"] as Dictionary
	match str(contents.get("type", "")):
		"currency":
			var grant_currency := str(contents.get("currency", ""))
			new_profile[grant_currency] = int(new_profile.get(grant_currency, 0)) + int(contents.get("amount", 0))
		"cosmetic":
			var owned: Variant = new_domain.get("owned_cosmetics", [])
			if typeof(owned) != TYPE_ARRAY:
				owned = []
			(owned as Array).append("%s:%s" % [str(contents.get("slot", "")), str(contents.get("id", ""))])
			new_domain["owned_cosmetics"] = owned
	return {"ok": true, "reason": REASON_OK, "profile": new_profile, "shop_domain": new_domain}


## True if the cosmetic is a free default or was purchased (slot-qualified id).
static func is_owned(shop_domain: Dictionary, slot: String, id: String) -> bool:
	var qualified := "%s:%s" % [slot, id]
	if FREE_OWNED.has(qualified):
		return true
	var owned: Variant = shop_domain.get("owned_cosmetics", [])
	if typeof(owned) != TYPE_ARRAY:
		return false
	return (owned as Array).has(qualified)


## First catalog item granting this cosmetic (for Profile's price hints); {} if none.
static func find_item_for_cosmetic(items: Array[Dictionary], slot: String, id: String) -> Dictionary:
	for item in items:
		var contents: Variant = item.get("contents")
		if typeof(contents) != TYPE_DICTIONARY:
			continue
		var contents_d := contents as Dictionary
		if str(contents_d.get("type", "")) == "cosmetic" \
				and str(contents_d.get("slot", "")) == slot and str(contents_d.get("id", "")) == id:
			return item
	return {}


static func _purchases_of(shop_domain: Dictionary) -> Dictionary:
	var purchases: Variant = shop_domain.get("purchases", {})
	if typeof(purchases) != TYPE_DICTIONARY:
		return {}
	return purchases as Dictionary

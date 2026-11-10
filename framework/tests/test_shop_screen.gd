extends GutTest
## ShopScreen (TDD §3.20): rows built from the stub catalog, purchase flow
## through SaveSystem + EventBus, one-shot Owned state, level-lock gating,
## cosmetic ownership surfacing, and the empty-catalog state. Also pins the
## header Coins button as the shop entry point.

var _host: Control
var _mounted: Array[Node] = []
var _original_path: String = ""
var _temp_path: String = ""


func before_all() -> void:
	_host = Control.new()
	# Phone-sized test host: screens are full-rect anchored under it.
	_host.custom_minimum_size = Vector2(720, 1280)
	_host.size = Vector2(720, 1280)
	add_child(_host)


func before_each() -> void:
	_original_path = SaveSystem.get_save_path()
	var stamp := Time.get_ticks_usec()
	_temp_path = "user://gut_tmp/shop_%d.json" % stamp
	SaveSystem.set_save_path(_temp_path)
	SaveSystem.load_save()
	RemoteConfig.fetch()


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


# --- Catalog rendering ----------------------------------------------------------

func test_shop_builds_one_row_per_stub_item() -> void:
	var screen := _mount(ShopScreen.new()) as ShopScreen
	await _settle_layout(2)
	assert_eq(screen._rows.size(), 5, "five stub catalog items render rows")
	assert_false(screen._empty_label.visible, "empty state hidden with a populated catalog")
	assert_true(screen._scroll.visible, "list scroll visible")


func test_shop_skips_malformed_items_with_warning() -> void:
	RemoteConfig.set_config_path("res://resources/config/remote_config.json")
	var bad_path := "user://gut_tmp/shop_bad_config_%d.json" % Time.get_ticks_usec()
	var file := FileAccess.open(bad_path, FileAccess.WRITE)
	file.store_string(JSON.stringify({
		"flags": {}, "values": {}, "experiments": {},
		"shop_items": [
			{"id": "good", "contents": {"type": "currency", "currency": "gems", "amount": 1}, "price": {"currency": "coins", "amount": 10}},
			{"id": "bad_type", "contents": {"type": "mystery_box"}, "price": {"currency": "coins", "amount": 10}},
		],
	}))
	file.close()
	RemoteConfig.set_config_path(bad_path)
	RemoteConfig.fetch()
	var screen := _mount(ShopScreen.new()) as ShopScreen
	await _settle_layout(2)
	assert_eq(screen._rows.size(), 1, "malformed entry skipped, valid one kept")
	RemoteConfig.set_config_path("res://resources/config/remote_config.json")
	RemoteConfig.fetch()
	if FileAccess.file_exists(bad_path):
		DirAccess.remove_absolute(bad_path)


func test_shop_empty_catalog_shows_empty_state() -> void:
	var empty_path := "user://gut_tmp/shop_empty_config_%d.json" % Time.get_ticks_usec()
	var file := FileAccess.open(empty_path, FileAccess.WRITE)
	file.store_string(JSON.stringify({"flags": {}, "values": {}, "experiments": {}}))
	file.close()
	RemoteConfig.set_config_path(empty_path)
	RemoteConfig.fetch()
	var screen := _mount(ShopScreen.new()) as ShopScreen
	await _settle_layout(2)
	assert_eq(screen._rows.size(), 0, "no rows without shop_items")
	assert_true(screen._empty_label.visible, "empty state label visible")
	assert_false(screen._scroll.visible, "list scroll hidden")
	RemoteConfig.set_config_path("res://resources/config/remote_config.json")
	RemoteConfig.fetch()
	if FileAccess.file_exists(empty_path):
		DirAccess.remove_absolute(empty_path)


# --- Purchase flow ----------------------------------------------------------------

func test_purchase_currency_item_persists_and_emits() -> void:
	_seed_profile(1000, 0)
	var screen := _mount(ShopScreen.new()) as ShopScreen
	await _settle_layout(2)
	watch_signals(EventBus)
	watch_signals(UIManager.toast_host)
	screen._on_buy_pressed(_require_item("gem_bundle"))
	var profile := SaveSystem.get_domain("profile")
	assert_eq(int(profile.get("coins", 0)), 700, "price deducted from coins")
	assert_eq(int(profile.get("gems", 0)), 5, "granted gems added")
	var shop_domain := SaveSystem.get_domain(ShopLogic.SHOP_DOMAIN)
	assert_eq(int((shop_domain.get("purchases", {}) as Dictionary).get("gem_bundle", 0)), 1, "purchase stamped")
	assert_signal_emitted_with_parameters(EventBus, "shop_purchased", ["gem_bundle"])
	assert_signal_emitted_with_parameters(EventBus, "currency_changed", ["coins", 700], 0)
	assert_signal_emitted_with_parameters(EventBus, "currency_changed", ["gems", 5], 1)
	# H2 toast policy: a successful purchase is the direct effect of the tap —
	# row state + header currency ARE the feedback (no toast).
	assert_signal_not_emitted(UIManager.toast_host, "toast_shown", "purchase success shows no toast")
	assert_eq(UIManager.toast_host.queued_count(), 0, "purchase success leaves nothing in the toast queue")


func test_purchase_insufficient_balance_keeps_state() -> void:
	_seed_profile(10, 0)
	var screen := _mount(ShopScreen.new()) as ShopScreen
	await _settle_layout(2)
	watch_signals(EventBus)
	watch_signals(UIManager.toast_host)
	screen._on_buy_pressed(_require_item("gem_bundle"))
	var profile := SaveSystem.get_domain("profile")
	assert_eq(int(profile.get("coins", 0)), 10, "balance untouched on failure")
	var shop_domain := SaveSystem.get_domain(ShopLogic.SHOP_DOMAIN)
	assert_true((shop_domain.get("purchases", {}) as Dictionary).is_empty(), "no purchase stamped on failure")
	assert_signal_emit_count(EventBus, "shop_purchased", 0, "no shop_purchased on failure")
	# H2 toast policy: a FAILED purchase is an unexpected outcome — the warning
	# toast stays.
	assert_signal_emitted(UIManager.toast_host, "toast_shown", "insufficient balance still warns via toast")


func test_one_shot_item_becomes_owned_and_blocked() -> void:
	_seed_profile(500, 0)
	var screen := _mount(ShopScreen.new()) as ShopScreen
	await _settle_layout(2)
	watch_signals(EventBus)
	screen._on_buy_pressed(_require_item("portrait_icon_gold"))
	var row: Dictionary = screen._rows["portrait_icon_gold"]
	var button: Button = row["button"]
	assert_eq(button.text, tr("shop_owned"), "one-shot row shows Owned after purchase")
	assert_true(button.disabled, "Owned row is not pressable")
	screen._on_buy_pressed(_require_item("portrait_icon_gold"))
	assert_signal_emit_count(EventBus, "shop_purchased", 1, "repeat attempt does not re-emit")
	var shop_domain := SaveSystem.get_domain(ShopLogic.SHOP_DOMAIN)
	assert_eq(int((shop_domain.get("purchases", {}) as Dictionary).get("portrait_icon_gold", 0)), 1, "count stays at max")


func test_locked_level_item_shows_lv_and_blocks_purchase() -> void:
	_seed_profile(999, 9, 1)
	var screen := _mount(ShopScreen.new()) as ShopScreen
	await _settle_layout(2)
	var row: Dictionary = screen._rows["portrait_crown_diamond"]
	var button: Button = row["button"]
	assert_eq(button.text, tr("shop_locked_level") % [5], "locked row shows the required level")
	assert_true(button.disabled, "locked row is not pressable")
	watch_signals(EventBus)
	screen._on_buy_pressed(_require_item("portrait_crown_diamond"))
	assert_signal_emit_count(EventBus, "shop_purchased", 0, "locked purchase rejected")
	var shop_domain := SaveSystem.get_domain(ShopLogic.SHOP_DOMAIN)
	assert_true((shop_domain.get("purchases", {}) as Dictionary).is_empty(), "no stamp for a locked purchase")


func test_cosmetic_purchase_unlocks_ownership() -> void:
	_seed_profile(500, 0)
	var screen := _mount(ShopScreen.new()) as ShopScreen
	await _settle_layout(2)
	screen._on_buy_pressed(_require_item("portrait_flair_ring_gold"))
	var shop_domain := SaveSystem.get_domain(ShopLogic.SHOP_DOMAIN)
	assert_true(ShopLogic.is_owned(shop_domain, "portrait_flair", "ring_gold"), "purchased flair is owned")
	assert_false(ShopLogic.is_owned(shop_domain, "portrait_icon", "gold"), "other cosmetics stay locked")


# --- Entry point --------------------------------------------------------------------

func test_header_coins_button_navigates_to_shop() -> void:
	var header := PlayerInfoHeader.new()
	_host.add_child(header)
	_mounted.append(header)
	await _settle_layout(2)
	watch_signals(EventBus)
	header._coins_button.pressed.emit()
	assert_signal_emitted_with_parameters(EventBus, "navigation_requested", [ScreenIds.SHOP])


func test_header_gems_button_navigates_to_special() -> void:
	# H9: gems are the prototype-specific currency — the gems widget opens
	# the Special screen.
	var header := PlayerInfoHeader.new()
	_host.add_child(header)
	_mounted.append(header)
	await _settle_layout(2)
	watch_signals(EventBus)
	header._gems_button.pressed.emit()
	assert_signal_emitted_with_parameters(EventBus, "navigation_requested", [ScreenIds.SPECIAL])


func test_header_profile_block_navigates_to_profile() -> void:
	# H9: tapping the center avatar/name/level block opens the Profile screen.
	var header := PlayerInfoHeader.new()
	_host.add_child(header)
	_mounted.append(header)
	await _settle_layout(2)
	watch_signals(EventBus)
	var touch := InputEventScreenTouch.new()
	touch.position = Vector2.ZERO
	touch.pressed = true
	header._on_profile_tapped(touch)
	assert_signal_emitted_with_parameters(EventBus, "navigation_requested", [ScreenIds.PROFILE])


# --- Helpers ------------------------------------------------------------------------

func _seed_profile(coins: int, gems: int, level: int = 1) -> void:
	SaveSystem.set_domain("profile", {"name": "T", "coins": coins, "gems": gems, "level": level})


func _item(id: String) -> Dictionary:
	for item in RemoteConfig.get_shop_items():
		if str(item.get("id", "")) == id:
			return item
	return {}


func _require_item(id: String) -> Dictionary:
	var item := _item(id)
	assert_false(item.is_empty(), "stub catalog must contain '%s'" % id)
	return item


func _mount(node: Node) -> Node:
	_host.add_child(node)
	_mounted.append(node)
	return node


func _settle_layout(frames: int = 5) -> void:
	for i in frames:
		await get_tree().process_frame

class_name ShopScreen
extends BaseScreen
## Shop screen (TDD §3.20): vertical scrolling product list from
## RemoteConfig.get_shop_items(). Row = ProtoIcon + title + contents line +
## price chip + buy button. Opened by tapping the Coins widget in the player
## header; NOT in the bottom nav. Purchases go through ShopLogic (pure core)
## and persist to the "shop" save domain.

const PROFILE_DOMAIN: String = "profile"
const ROW_ICON_SIZE: float = 40.0
const PRICE_ICON_SIZE: float = 16.0

var _title: Label = null
var _scroll: ScrollContainer = null
var _list_host: VBoxContainer = null
var _empty_label: Label = null
## item_id -> {"button": Button, "item": Dictionary} for state refreshes.
var _rows: Dictionary = {}


func _ready() -> void:
	super._ready()
	if not EventBus.shop_purchased.is_connected(_on_shop_purchased):
		EventBus.shop_purchased.connect(_on_shop_purchased)
	if not EventBus.profile_updated.is_connected(_on_profile_updated):
		EventBus.profile_updated.connect(_on_profile_updated)
	if not EventBus.config_loaded.is_connected(_on_config_loaded):
		EventBus.config_loaded.connect(_on_config_loaded)


func _exit_tree() -> void:
	if EventBus.shop_purchased.is_connected(_on_shop_purchased):
		EventBus.shop_purchased.disconnect(_on_shop_purchased)
	if EventBus.profile_updated.is_connected(_on_profile_updated):
		EventBus.profile_updated.disconnect(_on_profile_updated)
	if EventBus.config_loaded.is_connected(_on_config_loaded):
		EventBus.config_loaded.disconnect(_on_config_loaded)
	super._exit_tree()


func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", ThemeFactory.CONTENT_MARGIN)
	margin.add_theme_constant_override("margin_top", ThemeFactory.CONTENT_MARGIN)
	margin.add_theme_constant_override("margin_right", ThemeFactory.CONTENT_MARGIN)
	margin.add_theme_constant_override("margin_bottom", ThemeFactory.CONTENT_MARGIN)
	# Pin to full rect: an unanchored container shrinks to minimum size at top-left.
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	margin.add_child(vbox)

	_title = Label.new()
	_title.theme_type_variation = &"LabelTitle"
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_title)

	_empty_label = Label.new()
	_empty_label.theme_type_variation = &"LabelDim"
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_empty_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	vbox.add_child(_empty_label)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(_scroll)

	_list_host = VBoxContainer.new()
	_list_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_host.add_theme_constant_override("separation", 12)
	_scroll.add_child(_list_host)


func _apply_locale() -> void:
	_title.text = tr("shop_title")
	_empty_label.text = tr("shop_empty")
	_rebuild_rows()


# --- Catalog ------------------------------------------------------------------

## Rebuilds the row list from the current catalog. Called on locale change and
## config reload; state-only changes go through _refresh_row_states().
func _rebuild_rows() -> void:
	for child in _list_host.get_children():
		_list_host.remove_child(child)
		child.free()
	_rows.clear()
	var items := RemoteConfig.get_shop_items()
	_empty_label.visible = items.is_empty()
	_scroll.visible = not items.is_empty()
	for item in items:
		if not ShopLogic.is_valid_item(item):
			push_warning("ShopScreen: skipping malformed shop item '%s'" % str(item.get("id", "")))
			continue
		_list_host.add_child(_build_row(item))
	_refresh_row_states()


func _build_row(item: Dictionary) -> PanelContainer:
	var id := str(item.get("id", ""))
	var panel := PanelContainer.new()
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	panel.add_child(hbox)

	var icon := ProtoIcon.new()
	icon.setup(str(item.get("icon", "gift")), ROW_ICON_SIZE)
	hbox.add_child(icon)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 2)
	var title := Label.new()
	title.text = str(item.get("title", id))
	info.add_child(title)
	var contents := Label.new()
	contents.theme_type_variation = &"LabelDim"
	contents.text = _contents_text(item)
	info.add_child(contents)
	hbox.add_child(info)

	var price := item["price"] as Dictionary
	var price_icon := ProtoIcon.new()
	price_icon.setup("gem" if str(price.get("currency", "")) == "gems" else "coin", PRICE_ICON_SIZE)
	hbox.add_child(price_icon)
	var amount := Label.new()
	amount.theme_type_variation = &"LabelGold"
	amount.add_theme_font_size_override("font_size", 14)
	amount.text = str(int(price.get("amount", 0)))
	hbox.add_child(amount)

	var button := Button.new()
	button.pressed.connect(_on_buy_pressed.bind(item))
	hbox.add_child(button)
	_rows[id] = {"button": button, "item": item}
	return panel


func _contents_text(item: Dictionary) -> String:
	var contents: Variant = item.get("contents")
	if typeof(contents) != TYPE_DICTIONARY:
		return ""
	var contents_d := contents as Dictionary
	match str(contents_d.get("type", "")):
		"currency":
			return tr("shop_contents_currency") % [int(contents_d.get("amount", 0)), _currency_name(str(contents_d.get("currency", "")))]
		"cosmetic":
			var entry := _find_catalog_entry(str(contents_d.get("slot", "")), str(contents_d.get("id", "")))
			return tr(str(entry.get("label_key", "")))
	return ""


func _find_catalog_entry(slot: String, id: String) -> Dictionary:
	match slot:
		"portrait_icon":
			return PortraitCatalog.find_icon(id)
		"portrait_flair":
			return PortraitCatalog.find_flair(id)
		"portrait_crown":
			return PortraitCatalog.find_crown(id)
	return {}


func _currency_name(currency: String) -> String:
	if currency == "coins":
		return tr("header_coins")
	return tr("header_gems")


## Button text/enabled from live state: Owned (maxed) > Lv N (locked) > Buy.
func _refresh_row_states() -> void:
	var profile := SaveSystem.get_domain(PROFILE_DOMAIN)
	var shop_domain := SaveSystem.get_domain(ShopLogic.SHOP_DOMAIN)
	for id in _rows:
		var row: Dictionary = _rows[id]
		var item: Dictionary = row["item"]
		var button: Button = row["button"]
		var max_purchases := ShopLogic.opt_int(item, "max_purchases")
		var purchases := ShopLogic._purchases_of(shop_domain)
		if max_purchases > 0 and int(purchases.get(id, 0)) >= max_purchases:
			button.text = tr("shop_owned")
			button.disabled = true
			continue
		var unlock_level := ShopLogic.opt_int(item, "unlock_level")
		if unlock_level > 0 and int(profile.get("level", 1)) < unlock_level:
			button.text = tr("shop_locked_level") % [unlock_level]
			button.disabled = true
			continue
		button.text = tr("shop_buy")
		button.disabled = false


# --- Purchases ------------------------------------------------------------------

func _on_buy_pressed(item: Dictionary) -> void:
	var profile := SaveSystem.get_domain(PROFILE_DOMAIN)
	var shop_domain := SaveSystem.get_domain(ShopLogic.SHOP_DOMAIN)
	var result := ShopLogic.purchase(item, profile, shop_domain)
	if not bool(result.get("ok", false)):
		_toast_for_reason(str(result.get("reason", "")), item)
		return

	SaveSystem.set_domain(PROFILE_DOMAIN, result["profile"] as Dictionary)
	SaveSystem.set_domain(ShopLogic.SHOP_DOMAIN, result["shop_domain"] as Dictionary)
	SaveSystem.save_game()
	var new_profile := SaveSystem.get_domain(PROFILE_DOMAIN)
	var price := item["price"] as Dictionary
	var price_currency := str(price.get("currency", ""))
	EventBus.currency_changed.emit(price_currency, int(new_profile.get(price_currency, 0)))
	var contents := item["contents"] as Dictionary
	if str(contents.get("type", "")) == "currency" and str(contents.get("currency", "")) != price_currency:
		var grant_currency := str(contents.get("currency", ""))
		EventBus.currency_changed.emit(grant_currency, int(new_profile.get(grant_currency, 0)))
	EventBus.profile_updated.emit(new_profile)
	# H2 toast policy: purchase success is the direct effect of the tap — the
	# row state + header currency update ARE the feedback (no toast). Failures
	# below still toast (unexpected outcomes).
	EventBus.shop_purchased.emit(str(item.get("id", "")))


func _toast_for_reason(reason: String, item: Dictionary) -> void:
	match reason:
		ShopLogic.REASON_INSUFFICIENT:
			var price := item["price"] as Dictionary
			UIManager.push_toast(tr("shop_toast_insufficient") % _currency_name(str(price.get("currency", ""))), "warning")
		ShopLogic.REASON_MAX_PURCHASES:
			UIManager.push_toast(tr("shop_toast_maxed"), "warning")
		ShopLogic.REASON_LOCKED_LEVEL:
			UIManager.push_toast(tr("shop_toast_locked") % [int(item.get("unlock_level", 0))], "warning")


# --- Signals --------------------------------------------------------------------

func _on_shop_purchased(_item_id: String) -> void:
	_rebuild_rows()


func _on_profile_updated(_profile: Dictionary) -> void:
	_refresh_row_states()


func _on_config_loaded() -> void:
	_rebuild_rows()

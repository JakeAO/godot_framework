class_name ProfileScreen
extends BaseScreen
## Player profile: a live portrait preview (icon + flair + crown) with tabbed
## pages for customizing each part, plus a Stats page holding the current
## progression data. Customization picks persist in the save "profile" domain
## (portrait_icon / portrait_flair / portrait_crown) and refresh everywhere
## through EventBus.profile_updated.

const PROFILE_DOMAIN: String = "profile"
const TAB_KEYS: Array[String] = [
	"profile_tab_portrait",
	"profile_tab_flair",
	"profile_tab_crown",
	"profile_tab_stats",
]
const PREVIEW_SIZE: float = 96.0
const OPTION_SIZE: float = 56.0
const GRID_COLUMNS: int = 3

var _title: Label = null
var _portrait_view: PortraitView = null
var _tabs: TabContainer = null
var _pages: Array[Control] = []
var _icon_cells: Dictionary = {}
var _flair_cells: Dictionary = {}
var _crown_cells: Dictionary = {}
var _level_label: Label = null
var _xp_label: Label = null
var _best_score_key: Label = null
var _best_score_value: Label = null
var _total_games_key: Label = null
var _total_games_value: Label = null
var _code_key_label: Label = null
var _code_label: Label = null
var _sync_status_label: Label = null
var _copy_timer: Timer = null
var _copy_feedback_timer: Timer = null
## 0 = idle (never synced this session), 1 = last sync ok, -1 = last sync failed.
var _sync_state: int = 0


func _ready() -> void:
	super._ready()
	if not EventBus.profile_updated.is_connected(_on_profile_updated):
		EventBus.profile_updated.connect(_on_profile_updated)
	if not EventBus.save_sync_completed.is_connected(_on_save_sync_completed):
		EventBus.save_sync_completed.connect(_on_save_sync_completed)
	if not EventBus.backend_state_changed.is_connected(_on_backend_state_changed):
		EventBus.backend_state_changed.connect(_on_backend_state_changed)
	if not EventBus.shop_purchased.is_connected(_on_shop_purchased):
		EventBus.shop_purchased.connect(_on_shop_purchased)
	if not EventBus.shop_domain_changed.is_connected(_on_shop_domain_changed):
		EventBus.shop_domain_changed.connect(_on_shop_domain_changed)


func _exit_tree() -> void:
	if EventBus.profile_updated.is_connected(_on_profile_updated):
		EventBus.profile_updated.disconnect(_on_profile_updated)
	if EventBus.save_sync_completed.is_connected(_on_save_sync_completed):
		EventBus.save_sync_completed.disconnect(_on_save_sync_completed)
	if EventBus.backend_state_changed.is_connected(_on_backend_state_changed):
		EventBus.backend_state_changed.disconnect(_on_backend_state_changed)
	if EventBus.shop_purchased.is_connected(_on_shop_purchased):
		EventBus.shop_purchased.disconnect(_on_shop_purchased)
	if EventBus.shop_domain_changed.is_connected(_on_shop_domain_changed):
		EventBus.shop_domain_changed.disconnect(_on_shop_domain_changed)
	super._exit_tree()


func _apply_locale() -> void:
	_title.text = tr("profile_title")
	for i in _tabs.get_tab_count():
		_tabs.set_tab_title(i, tr(TAB_KEYS[i]))
	if _best_score_key != null:
		_best_score_key.text = tr("profile_best_score")
	if _total_games_key != null:
		_total_games_key.text = tr("profile_total_games")
	if _code_key_label != null:
		# The hold-to-copy affordance lives in the key label (persistent): a
		# long-press tooltip fired at the same 0.5s as the copy itself (H1).
		_code_key_label.text = "%s · %s" % [tr("profile_player_code"), tr("profile_code_hold_to_copy")]
	_refresh()


# --- UI -----------------------------------------------------------------------

func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", ThemeFactory.CONTENT_MARGIN)
	margin.add_theme_constant_override("margin_right", ThemeFactory.CONTENT_MARGIN)
	margin.add_theme_constant_override("margin_top", ThemeFactory.CONTENT_MARGIN)
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

	var preview_row := HBoxContainer.new()
	vbox.add_child(preview_row)
	var spacer_left := Control.new()
	spacer_left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview_row.add_child(spacer_left)
	_portrait_view = PortraitView.new()
	_portrait_view.setup(PREVIEW_SIZE)
	preview_row.add_child(_portrait_view)
	var spacer_right := Control.new()
	spacer_right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview_row.add_child(spacer_right)

	# Identity row: player code (hold to copy) + cross-device sync status.
	var id_row := HBoxContainer.new()
	id_row.add_theme_constant_override("separation", 8)
	vbox.add_child(id_row)
	_code_key_label = Label.new()
	_code_key_label.theme_type_variation = &"LabelDim"
	id_row.add_child(_code_key_label)
	_code_label = Label.new()
	_code_label.theme_type_variation = &"LabelGold"
	# Hold-to-copy target: a bare 14px-tall label was nearly untappable (H1).
	_code_label.custom_minimum_size = Vector2(0.0, 44.0)
	_code_label.mouse_filter = Control.MOUSE_FILTER_STOP
	_code_label.gui_input.connect(_on_code_gui_input)
	id_row.add_child(_code_label)
	var id_spacer := Control.new()
	id_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	id_row.add_child(id_spacer)
	_sync_status_label = Label.new()
	_sync_status_label.theme_type_variation = &"LabelDim"
	id_row.add_child(_sync_status_label)

	_copy_timer = Timer.new()
	_copy_timer.wait_time = 0.5
	_copy_timer.one_shot = true
	_copy_timer.timeout.connect(_on_code_long_press)
	add_child(_copy_timer)

	# Restores the code label after the brief inline "copied" feedback (H2:
	# the copy is a direct effect of the hold — no toast).
	_copy_feedback_timer = Timer.new()
	_copy_feedback_timer.wait_time = 1.2
	_copy_feedback_timer.one_shot = true
	_copy_feedback_timer.timeout.connect(_on_copy_feedback_done)
	add_child(_copy_feedback_timer)

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_tabs)

	_pages.append(_build_option_grid(PortraitCatalog.ICONS, PortraitView.PROFILE_KEY_ICON, _icon_cells))
	_pages.append(_build_option_grid(PortraitCatalog.FLAIRS, PortraitView.PROFILE_KEY_FLAIR, _flair_cells))
	_pages.append(_build_option_grid(PortraitCatalog.CROWNS, PortraitView.PROFILE_KEY_CROWN, _crown_cells))
	_pages.append(_build_stats_page())
	for i in _pages.size():
		var page: Control = _pages[i]
		page.name = TAB_KEYS[i]
		_tabs.add_child(page)


func _build_option_grid(entries: Array[Dictionary], profile_key: String, cells: Dictionary) -> Control:
	var grid := GridContainer.new()
	grid.columns = GRID_COLUMNS
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)

	for entry in entries:
		var id := str(entry.get("id", ""))
		var cell := Panel.new()
		cell.custom_minimum_size = Vector2(OPTION_SIZE + 16.0, OPTION_SIZE * (1.0 + PortraitView.CROWN_ROW_RATIO) + 16.0)

		# H1: the hint is a reserved row UNDER the portrait (not an overlay),
		# so price/lock text never draws over the art.
		var cell_box := VBoxContainer.new()
		cell_box.add_theme_constant_override("separation", 4)
		cell_box.set_anchors_preset(Control.PRESET_FULL_RECT)
		cell.add_child(cell_box)

		var center := CenterContainer.new()
		center.size_flags_vertical = Control.SIZE_EXPAND_FILL
		cell_box.add_child(center)

		var preview := PortraitView.new()
		preview.setup(OPTION_SIZE)
		var sample: Dictionary = {"name": "P"}
		sample[profile_key] = id
		preview.apply_profile(sample)
		center.add_child(preview)

		# Locked-state hint (TDD §3.20): fixed-height row so the grid layout
		# never changes; empty text for owned options.
		var hint := Label.new()
		hint.theme_type_variation = &"LabelDim"
		hint.add_theme_font_size_override("font_size", 10)
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		hint.custom_minimum_size.y = 12.0
		cell_box.add_child(hint)

		# H8 shard progress: hidden unless the option is partially unlocked
		# (greyed + bar); 0% and 100% render nothing here.
		var progress := ProgressBar.new()
		progress.show_percentage = false
		progress.custom_minimum_size = Vector2(0.0, 5.0)
		progress.visible = false
		cell_box.add_child(progress)

		cell.gui_input.connect(_on_option_tapped.bind(id, profile_key))
		cells[id] = {"panel": cell, "preview": preview, "hint": hint, "progress": progress}
		grid.add_child(cell)

	# H1: center the grid in the full-width tab page — it previously hugged
	# the top-left corner under a centered header/preview.
	var page_center := CenterContainer.new()
	page_center.add_child(grid)
	return page_center


func _build_stats_page() -> VBoxContainer:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 12)

	_level_label = Label.new()
	_level_label.theme_type_variation = &"LabelGold"
	_level_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	page.add_child(_level_label)

	_xp_label = Label.new()
	_xp_label.theme_type_variation = &"LabelDim"
	_xp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	page.add_child(_xp_label)

	var best_row := _build_stat_row(&"profile_best_score")
	page.add_child(best_row)
	var games_row := _build_stat_row(&"profile_total_games")
	page.add_child(games_row)

	return page


func _build_stat_row(value_key: StringName) -> PanelContainer:
	var panel := PanelContainer.new()
	var row := HBoxContainer.new()
	panel.add_child(row)

	var key_label := Label.new()
	key_label.theme_type_variation = &"LabelDim"
	row.add_child(key_label)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	var value_label := Label.new()
	value_label.theme_type_variation = &"LabelGold"
	row.add_child(value_label)

	if value_key == &"profile_best_score":
		key_label.text = tr("profile_best_score")
		_best_score_key = key_label
		_best_score_value = value_label
	else:
		key_label.text = tr("profile_total_games")
		_total_games_key = key_label
		_total_games_value = value_label
	return panel


func _select_tab(index: int) -> void:
	if index < 0 or index >= _tabs.get_tab_count():
		return
	_tabs.current_tab = index


# --- State --------------------------------------------------------------------

func _refresh() -> void:
	var profile: Dictionary = SaveSystem.get_domain(PROFILE_DOMAIN)
	_portrait_view.apply_profile(profile)
	_mark_selected(_icon_cells, PortraitCatalog.find_icon(str(profile.get(PortraitView.PROFILE_KEY_ICON, ""))).get("id", ""))
	_mark_selected(_flair_cells, PortraitCatalog.find_flair(str(profile.get(PortraitView.PROFILE_KEY_FLAIR, ""))).get("id", ""))
	_mark_selected(_crown_cells, PortraitCatalog.find_crown(str(profile.get(PortraitView.PROFILE_KEY_CROWN, ""))).get("id", ""))
	var shop_domain := SaveSystem.get_domain(ShopLogic.SHOP_DOMAIN)
	var shop_items := RemoteConfig.get_shop_items()
	_mark_ownership(_icon_cells, PortraitView.PROFILE_KEY_ICON, shop_domain, shop_items)
	_mark_ownership(_flair_cells, PortraitView.PROFILE_KEY_FLAIR, shop_domain, shop_items)
	_mark_ownership(_crown_cells, PortraitView.PROFILE_KEY_CROWN, shop_domain, shop_items)
	var level: int = int(profile.get("level", 1))
	_level_label.text = tr("profile_level") % [level]
	_xp_label.text = tr("profile_xp") % [int(profile.get("xp", 0)), Scoring.xp_needed_for_level(level)]
	_best_score_value.text = str(int(profile.get("best_score", 0)))
	_total_games_value.text = str(int(profile.get("total_games", 0)))
	_code_label.text = IdentityService.get_player_code()
	_sync_status_label.text = tr(_sync_status_key())


## Priority (TDD §3.18): offline outranks everything — a stale ok/failed from
## before the drop would mislead; mock mode is always online, so this branch
## only fires in real mode (or via the DevTools force-offline QA seam).
func _sync_status_key() -> String:
	if not OnlineService.is_online():
		return "profile_sync_offline"
	match _sync_state:
		1:
			return "profile_sync_ok"
		-1:
			return "profile_sync_failed"
	return "profile_sync_idle"


func _mark_selected(cells: Dictionary, selected_id: String) -> void:
	for id in cells:
		var cell: Panel = (cells[id] as Dictionary)["panel"]
		var sb := StyleBoxFlat.new()
		sb.set_corner_radius_all(ThemeFactory.CORNER_RADIUS)
		if str(id) == selected_id:
			sb.border_color = ThemeFactory.COLOR_GOLD
			sb.set_border_width_all(2)
		cell.add_theme_stylebox_override("panel", sb)


## OWNED vs PARTIAL vs LOCKED rows (TDD §3.20, H8): owned options render normal;
## partially-unlocked ones (shards collected) are greyed with a progress bar and
## percent hint; the rest stay dimmed with a price hint pointing at the Shop
## (or a plain "Locked" when no catalog item grants them yet). Free defaults are
## always owned. 0% shard progress renders nothing extra ("not shown at all").
func _mark_ownership(cells: Dictionary, slot: String, shop_domain: Dictionary, shop_items: Array[Dictionary]) -> void:
	var shards_per_unlock := maxi(int(RemoteConfig.get_value(ShardLogic.SHARDS_PER_UNLOCK_KEY, ShardLogic.DEFAULT_SHARDS_PER_UNLOCK)), 1)
	for id in cells:
		var cell_data: Dictionary = cells[id]
		var preview: PortraitView = cell_data["preview"]
		var hint: Label = cell_data["hint"]
		var progress: ProgressBar = cell_data.get("progress", null)
		if ShopLogic.is_owned(shop_domain, slot, str(id)):
			preview.modulate.a = 1.0
			hint.text = ""
			if progress != null:
				progress.visible = false
			continue
		if ShardLogic.is_partially_unlocked(shop_domain, slot, str(id), shards_per_unlock):
			var percent := ShardLogic.unlock_percent(shop_domain, ShardLogic.qualified(slot, str(id)), shards_per_unlock)
			preview.modulate.a = 0.55
			hint.text = tr("profile_shard_progress") % [percent]
			if progress != null:
				progress.visible = true
				progress.max_value = 100.0
				progress.value = float(percent)
			continue
		preview.modulate.a = 0.35
		if progress != null:
			progress.visible = false
		var item := ShopLogic.find_item_for_cosmetic(shop_items, slot, str(id))
		if item.is_empty():
			hint.text = tr("profile_locked")
		else:
			var price := (item as Dictionary)["price"] as Dictionary
			hint.text = "%d %s" % [int(price.get("amount", 0)), _currency_name(str(price.get("currency", "")))]


func _currency_name(currency: String) -> String:
	if currency == "coins":
		return tr("header_coins")
	return tr("header_gems")


## H2 toast policy: a pick is the direct effect of the tap — the grid's
## selection border + the live preview update ARE the feedback (no toast).
func _persist_pick(profile_key: String, value: String) -> void:
	var profile := SaveSystem.get_domain(PROFILE_DOMAIN)
	profile[profile_key] = value
	SaveSystem.set_domain(PROFILE_DOMAIN, profile)
	SaveSystem.save_game()
	EventBus.profile_updated.emit(SaveSystem.get_domain(PROFILE_DOMAIN))


# --- Input --------------------------------------------------------------------

func _on_profile_updated(_profile: Dictionary) -> void:
	_refresh()


func _on_shop_purchased(_item_id: String) -> void:
	_refresh()


## H8: shard grants change ownership state outside a purchase — re-mark the
## owned/partial/locked rows.
func _on_shop_domain_changed(_shop_domain: Dictionary) -> void:
	_refresh()


func _on_option_tapped(event: InputEvent, option_id: String, profile_key: String) -> void:
	var is_press := false
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		is_press = true
	elif event is InputEventScreenTouch and event.pressed:
		is_press = true
	if not is_press:
		return
	get_viewport().set_input_as_handled()
	if not ShopLogic.is_owned(SaveSystem.get_domain(ShopLogic.SHOP_DOMAIN), profile_key, option_id):
		EventBus.navigation_requested.emit(ScreenIds.SHOP)
		return
	_persist_pick(profile_key, option_id)


# --- Player code (hold to copy) + sync status --------------------------------

func _on_code_gui_input(event: InputEvent) -> void:
	var is_press := false
	var is_release := false
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		is_press = event.pressed
		is_release = not event.pressed
	elif event is InputEventScreenTouch:
		is_press = event.pressed
		is_release = not event.pressed
	if is_press:
		_copy_timer.start()
	elif is_release:
		_copy_timer.stop()


func _on_code_long_press() -> void:
	DisplayServer.clipboard_set(IdentityService.get_player_code())
	# H2 toast policy: inline feedback instead of a toast (direct effect).
	_code_label.text = tr("profile_code_copied")
	_copy_feedback_timer.start()


func _on_copy_feedback_done() -> void:
	if is_inside_tree():
		_code_label.text = IdentityService.get_player_code()


func _on_save_sync_completed(success: bool) -> void:
	_sync_state = 1 if success else -1
	if is_inside_tree() and _sync_status_label != null:
		_sync_status_label.text = tr(_sync_status_key())


func _on_backend_state_changed(_online: bool) -> void:
	if is_inside_tree() and _sync_status_label != null:
		_sync_status_label.text = tr(_sync_status_key())

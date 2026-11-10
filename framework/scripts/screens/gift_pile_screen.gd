class_name GiftPileScreen extends BaseScreen
## Fullscreen press-your-luck minigame (GDD §8 / TDD §3.22). The pile column is
## revealed bottom-up, one tap at a time; reward slots bank into the running
## total, a trap opens the danger overlay (save with coins / watch RV / give
## up), and revealing the top slot flashes the jackpot and auto-cashes-out.
## The run persists to the "gift_pile" domain after EVERY mutation and
## gift_pile_run_changed is emitted; entering with an active saved run resumes
## it, and a finished-but-unsettled one settles on entry.

const DOMAIN: String = "gift_pile"
const PROFILE_DOMAIN: String = "profile"
const SHOP_DOMAIN: String = "shop"
const SAVE_COINS_KEY: String = "gift_pile_save_coins"
const DEFAULT_SAVE_COINS: int = 100
const BOXES_PER_LEVEL_KEY: String = "gift_pile_boxes_per_level"
const DEFAULT_BOXES_PER_LEVEL: int = 3
const SLOT_HEIGHT: float = 72.0
const JACKPOT_FLASH_SEC: float = 1.2
## How long a reward reveal (real box + fake "possible rewards") stays on
## screen before a fresh closed row replaces it (H6).
const BOX_REVEAL_SEC: float = 0.8
## Cosmetic labels for the fake reveals — never real climb contents (H6).
const FAKE_REWARD_KEYS: Array[String] = ["gift_pile_fake_coin", "gift_pile_fake_gem", "gift_pile_fake_cosmetic"]
## H8 shard source: shards granted on every cash-out toward the next locked
## cosmetic (deterministic catalog order).
const SHARD_REWARD_KEY: String = "gift_pile_shard_reward"
const DEFAULT_SHARD_REWARD: int = 2

var _run: Dictionary = {}
var _settling: bool = false
var _entered_once: bool = false
var _boxes_locked: bool = false

var _exit_button: Button = null
var _bank_label: Label = null
var _pile_box: VBoxContainer = null
var _boxes_row: HBoxContainer = null
var _box_buttons: Array[Button] = []
var _cash_out_button: Button = null
var _result_box: VBoxContainer = null
var _result_label: Label = null
var _home_button: Button = null
var _overlay: ColorRect = null
var _danger_title: Label = null
var _danger_body: Label = null
var _save_button: Button = null
var _watch_rv_button: Button = null
var _give_up_button: Button = null
var _overlay_note: Label = null
var _jackpot_label: Label = null


func _ready() -> void:
	super._ready()
	# Godot does NOT re-fire _ready() when a cached screen is re-added to the
	# tree, so re-entry is driven by ScreenManager's screen_changed emission
	# (H5: the RV extra-watch round trip used to show climb 1's stale result
	# pane). The connection is intentionally kept for the instance's whole
	# life — cached screens are never freed mid-session, and destroying the
	# object auto-disconnects. The very first emission right after creation is
	# skipped: _ready() already entered.
	EventBus.screen_changed.connect(_on_screen_changed)
	_enter()


func _on_screen_changed(screen_id: StringName, _previous_screen_id: StringName) -> void:
	if screen_id != ScreenIds.GIFT_PILE:
		return
	if not _entered_once:
		_entered_once = true
		return
	_enter()


# --- Entry / resume -------------------------------------------------------------

## Loads the saved run on (re)entry. Active run = resume; finished-but-unsettled
## run (player left during the jackpot flash) = settle now; nothing = result
## pane. A run sitting in DANGER is ALWAYS resumed, never settled — the trap
## decision (save / give up) is still pending and a trap must not auto-pay out.
func _enter() -> void:
	_settling = false
	if _jackpot_label != null:
		_jackpot_label.visible = false
	var domain: Dictionary = SaveSystem.get_domain(DOMAIN)
	var saved: Variant = domain.get("run", null)
	if typeof(saved) == TYPE_DICTIONARY:
		_run = (saved as Dictionary).duplicate(true)
		if GiftPileRun.is_active(_run) or bool(_run.get("danger", false)):
			_show_active()
			EventBus.gift_pile_run_changed.emit(_run)
		else:
			_settle_cash_out()
	else:
		_run = {}
		_show_result("")


func _show_active() -> void:
	if _result_box != null:
		_result_box.visible = false
	_overlay_note_text = ""
	if _overlay_note != null:
		_overlay_note.text = ""
	_refresh_active_ui()
	# Box state is UI-only (H6): a fresh closed row on every entry.
	_rebuild_boxes()


var _overlay_note_text: String = ""


# --- UI build --------------------------------------------------------------------

func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", ThemeFactory.CONTENT_MARGIN)
	margin.add_theme_constant_override("margin_right", ThemeFactory.CONTENT_MARGIN)
	margin.add_theme_constant_override("margin_top", ThemeFactory.CONTENT_MARGIN)
	margin.add_theme_constant_override("margin_bottom", ThemeFactory.CONTENT_MARGIN)
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", ThemeFactory.CONTENT_MARGIN)
	margin.add_child(vbox)

	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", ThemeFactory.CONTENT_MARGIN)
	vbox.add_child(top_row)
	_exit_button = Button.new()
	_exit_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_exit_button.pressed.connect(_on_exit_pressed)
	top_row.add_child(_exit_button)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_row.add_child(spacer)
	_bank_label = Label.new()
	_bank_label.theme_type_variation = "LabelGold"
	top_row.add_child(_bank_label)

	_pile_box = VBoxContainer.new()
	_pile_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_pile_box.alignment = BoxContainer.ALIGNMENT_END
	_pile_box.add_theme_constant_override("separation", 6)
	vbox.add_child(_pile_box)

	# Box-selection illusion row (H6): closed gift boxes that replace direct
	# slot taps when gift_pile_boxes_per_level > 0. Hidden in legacy mode and
	# whenever no run is active.
	_boxes_row = HBoxContainer.new()
	_boxes_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_boxes_row.add_theme_constant_override("separation", 10)
	_boxes_row.visible = false
	vbox.add_child(_boxes_row)

	_cash_out_button = Button.new()
	_cash_out_button.theme_type_variation = "ButtonPrimary"
	_cash_out_button.pressed.connect(_on_cash_out_pressed)
	vbox.add_child(_cash_out_button)

	_result_box = VBoxContainer.new()
	_result_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_result_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_result_box.visible = false
	vbox.add_child(_result_box)
	_result_label = Label.new()
	_result_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result_box.add_child(_result_label)
	_home_button = Button.new()
	_home_button.theme_type_variation = "ButtonPrimary"
	_home_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_home_button.pressed.connect(_on_exit_pressed)
	_result_box.add_child(_home_button)

	_build_overlay()
	_build_jackpot_label()


func _build_overlay() -> void:
	_overlay = ColorRect.new()
	_overlay.color = Color(0.0, 0.0, 0.0, 0.72)
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.visible = false
	add_child(_overlay)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.add_child(center)

	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = ThemeFactory.COLOR_PANEL
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(16.0)
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	panel.add_child(box)

	_danger_title = Label.new()
	_danger_title.theme_type_variation = "LabelTitle"
	_danger_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_danger_title)
	_danger_body = Label.new()
	_danger_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_danger_body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_danger_body)

	_save_button = Button.new()
	_save_button.theme_type_variation = "ButtonPrimary"
	_save_button.pressed.connect(_on_save_coins_pressed)
	box.add_child(_save_button)
	_watch_rv_button = Button.new()
	_watch_rv_button.theme_type_variation = "ButtonAccent"
	_watch_rv_button.pressed.connect(_on_watch_rv_pressed)
	box.add_child(_watch_rv_button)
	_give_up_button = Button.new()
	_give_up_button.pressed.connect(_on_give_up_pressed)
	box.add_child(_give_up_button)

	_overlay_note = Label.new()
	_overlay_note.theme_type_variation = "LabelGold"
	_overlay_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_overlay_note)


func _build_jackpot_label() -> void:
	_jackpot_label = Label.new()
	_jackpot_label.theme_type_variation = "LabelGold"
	_jackpot_label.add_theme_font_size_override("font_size", 48)
	_jackpot_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_jackpot_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_jackpot_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_jackpot_label.visible = false
	add_child(_jackpot_label)


func _apply_locale() -> void:
	if _exit_button != null:
		_exit_button.text = tr("gift_pile_exit")
	if _cash_out_button != null:
		_cash_out_button.text = tr("gift_pile_cash_out")
	if _home_button != null:
		_home_button.text = tr("results_home")
	if _danger_title != null:
		_danger_title.text = tr("gift_pile_danger_title")
	if _danger_body != null:
		_danger_body.text = tr("gift_pile_danger_body")
	if _watch_rv_button != null:
		_watch_rv_button.text = tr("gift_pile_watch_rv")
	if _give_up_button != null:
		_give_up_button.text = tr("gift_pile_give_up")
	if _jackpot_label != null:
		_jackpot_label.text = tr("gift_pile_jackpot")
	for i in _box_buttons.size():
		var box := _box_buttons[i]
		if box != null and is_instance_valid(box) and not box.disabled:
			box.text = tr("gift_pile_box_closed")
	if not _run.is_empty() and GiftPileRun.is_active(_run):
		_refresh_active_ui()


# --- Active-run UI ----------------------------------------------------------------

func _refresh_active_ui() -> void:
	var danger := bool(_run.get("danger", false))
	_bank_label.text = _bank_text()
	_cash_out_button.disabled = danger or not GiftPileRun.is_active(_run)
	if _overlay != null:
		_overlay.visible = danger
	if danger and _save_button != null:
		var cost := _save_cost()
		var coins := int(SaveSystem.get_value(PROFILE_DOMAIN, "coins", 0))
		_save_button.disabled = coins < cost
		_save_button.text = tr("gift_pile_save_btn") % [cost]
	if _overlay_note != null:
		_overlay_note.text = _overlay_note_text
	_refresh_slots()


func _refresh_slots() -> void:
	for child in _pile_box.get_children():
		_pile_box.remove_child(child)
		child.queue_free()
	var pile: Array = _run.get("pile", [])
	var revealed := int(_run.get("revealed", 0))
	var danger := bool(_run.get("danger", false))
	for i in range(pile.size() - 1, -1, -1):
		var slot: Dictionary = pile[i]
		var button := Button.new()
		button.custom_minimum_size = Vector2(0.0, SLOT_HEIGHT)
		if i < revealed:
			button.disabled = true
			button.text = _slot_text(slot)
		elif i == revealed and not danger:
			button.text = tr("gift_pile_slot_covered")
			# In box mode the covered slot is visual-only — the box row is the
			# reveal trigger (H6); legacy mode keeps direct slot taps.
			if not _boxes_enabled():
				button.pressed.connect(_on_slot_pressed.bind(i))
		else:
			button.disabled = true
			button.text = tr("gift_pile_slot_covered")
		_pile_box.add_child(button)


func _slot_text(slot: Dictionary) -> String:
	match str(slot.get("kind", "")):
		GiftPileRun.KIND_COINS:
			return "+" + str(int(slot.get("amount", 0))) + " " + tr("header_coins")
		GiftPileRun.KIND_GEMS:
			return "+" + str(int(slot.get("amount", 0))) + " " + tr("header_gems")
		GiftPileRun.KIND_COSMETIC:
			return "* " + str(slot.get("cosmetic", ""))
		_:
			return tr("gift_pile_slot_fail")


func _bank_text() -> String:
	return "%s %d   %s %d" % [
		tr("header_coins"), int(_run.get("banked_coins", 0)),
		tr("header_gems"), int(_run.get("banked_gems", 0)),
	]


func _save_cost() -> int:
	return maxi(int(RemoteConfig.get_value(SAVE_COINS_KEY, DEFAULT_SAVE_COINS)), 0)


# --- Box-selection illusion (H6) ---------------------------------------------------

## True when gift_pile_boxes_per_level > 0 (the box row replaces direct slot taps).
func _boxes_enabled() -> bool:
	return maxi(int(RemoteConfig.get_value(BOXES_PER_LEVEL_KEY, DEFAULT_BOXES_PER_LEVEL)), 0) > 0


## Builds a fresh row of N closed boxes; hides the row in legacy mode or when no
## run is active. Box state is UI-only — it never enters the persisted run dict.
func _rebuild_boxes() -> void:
	if _boxes_row == null:
		return
	for button in _box_buttons:
		if is_instance_valid(button):
			_boxes_row.remove_child(button)
			button.queue_free()
	_box_buttons.clear()
	_boxes_locked = false
	var count := maxi(int(RemoteConfig.get_value(BOXES_PER_LEVEL_KEY, DEFAULT_BOXES_PER_LEVEL)), 0)
	var has_run := not _run.is_empty() and (GiftPileRun.is_active(_run) or bool(_run.get("danger", false)))
	if count <= 0 or not has_run:
		_boxes_row.visible = false
		return
	for i in count:
		var button := Button.new()
		button.custom_minimum_size = Vector2(0.0, SLOT_HEIGHT)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.text = tr("gift_pile_box_closed")
		button.pressed.connect(_on_box_pressed.bind(i))
		_boxes_row.add_child(button)
		_box_buttons.append(button)
	_boxes_row.visible = true


func _open_box(index: int, label_text: String) -> void:
	if index < 0 or index >= _box_buttons.size():
		return
	var button := _box_buttons[index]
	if button == null or not is_instance_valid(button):
		return
	button.disabled = true
	button.text = label_text


func _has_closed_box() -> bool:
	for button in _box_buttons:
		if button != null and is_instance_valid(button) and not button.disabled:
			return true
	return false


## Random cosmetic "possible reward" label — never a real climb content (H6).
func _fake_reward_label() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return tr(FAKE_REWARD_KEYS[rng.randi_range(0, FAKE_REWARD_KEYS.size() - 1)])


## Opening ANY box reveals the predetermined next slot — the pick is pure theater.
## Reward → the other boxes open with fake "possible rewards", a short beat, then a
## fresh row. Trap → danger overlay; the unopened boxes stay for the next pick after
## the save decision (an all-trap row rebuilds so play never stalls).
func _on_box_pressed(index: int) -> void:
	if _settling or _boxes_locked or bool(_run.get("danger", false)):
		return
	var button := _box_buttons[index] if index < _box_buttons.size() else null
	if button == null or not is_instance_valid(button) or button.disabled:
		return
	var result: Dictionary = GiftPileRun.reveal(_run)
	_run = result["run"]
	_persist()
	EventBus.gift_pile_run_changed.emit(_run)
	_open_box(index, _slot_text(result["slot"]))
	if bool(result["danger"]):
		_boxes_locked = true
		_refresh_active_ui()
	elif bool(result["over"]):
		_jackpot_flash()
	else:
		_refresh_active_ui()
		for i in _box_buttons.size():
			var other := _box_buttons[i] if i < _box_buttons.size() else null
			if i != index and other != null and is_instance_valid(other) and not other.disabled:
				_open_box(i, _fake_reward_label())
		_boxes_locked = true
		await get_tree().create_timer(BOX_REVEAL_SEC).timeout
		if not is_inside_tree():
			return
		_rebuild_boxes()


# --- Actions -----------------------------------------------------------------------

func _on_slot_pressed(index: int) -> void:
	if _settling or index != int(_run.get("revealed", 0)) or bool(_run.get("danger", false)):
		return
	var result: Dictionary = GiftPileRun.reveal(_run)
	_run = result["run"]
	_persist()
	EventBus.gift_pile_run_changed.emit(_run)
	if bool(result["danger"]):
		# A trap outranks "over": even a last-slot trap opens the danger
		# overlay (save / give up) and must never auto-cash-out the bank.
		_refresh_active_ui()
	elif bool(result["over"]):
		_jackpot_flash()
	else:
		_refresh_active_ui()


func _jackpot_flash() -> void:
	_settling = true
	_refresh_active_ui()
	_jackpot_label.visible = true
	await get_tree().create_timer(JACKPOT_FLASH_SEC).timeout
	if not is_inside_tree():
		return
	_jackpot_label.visible = false
	_settle_cash_out()


func _on_cash_out_pressed() -> void:
	if _settling or bool(_run.get("danger", false)) or not GiftPileRun.is_active(_run):
		return
	_settle_cash_out()


func _settle_cash_out() -> void:
	var revealed := int(_run.get("revealed", 0))
	var payout: Dictionary = GiftPileRun.cash_out(_run)
	var coins := int(payout.get("coins", 0))
	var gems := int(payout.get("gems", 0))
	var cosmetics: Array = payout.get("cosmetics", [])
	_grant_currency("coins", coins)
	_grant_currency("gems", gems)
	_grant_cosmetics(cosmetics)
	_grant_shards()
	_clear_run()
	Analytics.track("gift_pile_cash_out", {
		"coins": coins, "gems": gems, "cosmetics": cosmetics.size(), "revealed": revealed,
	})
	var text := tr("gift_pile_cashout_result") % [coins, gems]
	if not cosmetics.is_empty():
		text += "\n" + tr("gift_pile_cosmetics_gained") % [cosmetics.size()]
	_show_result(text)


func _on_save_coins_pressed() -> void:
	var cost := _save_cost()
	var profile: Dictionary = SaveSystem.get_domain(PROFILE_DOMAIN)
	if int(profile.get("coins", 0)) < cost:
		return
	profile["coins"] = int(profile["coins"]) - cost
	SaveSystem.set_domain(PROFILE_DOMAIN, profile)
	SaveSystem.save_game()
	EventBus.currency_changed.emit("coins", int(profile["coins"]))
	EventBus.profile_updated.emit(profile)
	_apply_save(GiftPileRun.SAVE_METHOD_COINS)


func _on_watch_rv_pressed() -> void:
	AdManager.watch_rewarded(_on_rv_saved.bind())


func _on_rv_saved(success: bool) -> void:
	if not is_inside_tree():
		return
	if success:
		_apply_save(GiftPileRun.SAVE_METHOD_RV)
	else:
		_overlay_note_text = tr("dlg_ad_failed")
		if _overlay_note != null:
			_overlay_note.text = _overlay_note_text


func _apply_save(method: String) -> void:
	_run = GiftPileRun.save_run(_run, method)
	_persist()
	EventBus.gift_pile_run_changed.emit(_run)
	Analytics.track("gift_pile_saved", {"method": method})
	if GiftPileRun.is_active(_run):
		_refresh_active_ui()
		if _boxes_enabled():
			# Trap saved: the unopened boxes stay for the next pick (H6); if an
			# all-trap row exhausted them, a fresh row keeps play going.
			_boxes_locked = false
			if not _has_closed_box():
				_rebuild_boxes()
	else:
		# The trap was the last slot — nothing is left to continue with, so
		# "keep it" settles the bank right here (GDD §8).
		_settle_cash_out()


func _on_give_up_pressed() -> void:
	var snapshot: Dictionary = GiftPileRun.lose_run(_run)
	_clear_run()
	Analytics.track("gift_pile_lost", {
		"banked_coins": int(snapshot.get("banked_coins", 0)),
		"banked_gems": int(snapshot.get("banked_gems", 0)),
		"revealed": int(snapshot.get("revealed", 0)),
	})
	_show_result(tr("gift_pile_lost_result"))


func _on_exit_pressed() -> void:
	EventBus.navigation_requested.emit(ScreenIds.HOME)


# --- Persistence / grants -------------------------------------------------------------

## Writes the current run back into the domain (runs_date/runs_count survive —
## set_domain replaces the payload, so merge first). Emits nothing.
func _persist() -> void:
	var domain := SaveSystem.get_domain(DOMAIN)
	domain["run"] = _run
	SaveSystem.set_domain(DOMAIN, domain)
	SaveSystem.save_game()


func _clear_run() -> void:
	var domain := SaveSystem.get_domain(DOMAIN)
	domain["run"] = null
	SaveSystem.set_domain(DOMAIN, domain)
	SaveSystem.save_game()
	EventBus.gift_pile_run_changed.emit(null)
	_run = {}


func _grant_currency(currency: String, amount: int) -> void:
	if amount <= 0:
		return
	var profile: Dictionary = SaveSystem.get_domain(PROFILE_DOMAIN)
	profile[currency] = int(profile.get(currency, 0)) + amount
	SaveSystem.set_domain(PROFILE_DOMAIN, profile)
	SaveSystem.save_game()
	EventBus.currency_changed.emit(currency, int(profile[currency]))
	EventBus.profile_updated.emit(profile)
	var currency_name := tr("header_gems") if currency == "gems" else tr("header_coins")
	UIManager.push_toast(tr("toast_reward") % [amount, currency_name], "gem" if currency == "gems" else "coin")


func _grant_cosmetics(ids: Array) -> void:
	if ids.is_empty():
		return
	var shop: Dictionary = SaveSystem.get_domain(SHOP_DOMAIN)
	var owned: Variant = shop.get("owned_cosmetics", [])
	if typeof(owned) != TYPE_ARRAY:
		owned = []
	for id in ids:
		if not (owned as Array).has(id):
			(owned as Array).append(id)
	shop["owned_cosmetics"] = owned
	SaveSystem.set_domain(SHOP_DOMAIN, shop)
	SaveSystem.save_game()


## H8 shard source: every cash-out grants `gift_pile_shard_reward` shards toward
## the first still-locked cosmetic (deterministic catalog order). A zero reward
## or a fully-unlocked catalog is a no-op.
func _grant_shards() -> void:
	var reward := maxi(int(RemoteConfig.get_value(SHARD_REWARD_KEY, DEFAULT_SHARD_REWARD)), 0)
	if reward <= 0:
		return
	var shop: Dictionary = SaveSystem.get_domain(SHOP_DOMAIN)
	var target := ShardLogic.next_lockable_target(shop, _shard_order())
	if target.is_empty():
		return
	var shards_per_unlock := maxi(int(RemoteConfig.get_value(ShardLogic.SHARDS_PER_UNLOCK_KEY, ShardLogic.DEFAULT_SHARDS_PER_UNLOCK)), 1)
	SaveSystem.set_domain(SHOP_DOMAIN, ShardLogic.grant_shards(shop, target, reward, shards_per_unlock))
	SaveSystem.save_game()
	EventBus.shop_domain_changed.emit(SaveSystem.get_domain(SHOP_DOMAIN))


## Deterministic catalog order (icons -> flairs -> crowns) of slot-qualified ids
## — the shard grant target list (H8).
func _shard_order() -> Array:
	var order: Array = []
	for entry in PortraitCatalog.ICONS:
		order.append(ShardLogic.qualified(PortraitView.PROFILE_KEY_ICON, str(entry.get("id", ""))))
	for entry in PortraitCatalog.FLAIRS:
		order.append(ShardLogic.qualified(PortraitView.PROFILE_KEY_FLAIR, str(entry.get("id", ""))))
	for entry in PortraitCatalog.CROWNS:
		order.append(ShardLogic.qualified(PortraitView.PROFILE_KEY_CROWN, str(entry.get("id", ""))))
	return order


# --- Result pane ---------------------------------------------------------------------

func _show_result(text: String) -> void:
	_run = {}
	if _overlay != null:
		_overlay.visible = false
	if _jackpot_label != null:
		_jackpot_label.visible = false
	if _pile_box != null:
		for child in _pile_box.get_children():
			_pile_box.remove_child(child)
			child.queue_free()
	_clear_boxes()
	if _result_box != null:
		_result_box.visible = true
	if _result_label != null:
		_result_label.text = text if text != "" else tr("gift_pile_no_run")


## Hides the box row and frees its buttons (the result pane owns the screen).
func _clear_boxes() -> void:
	if _boxes_row != null:
		_boxes_row.visible = false
		for button in _box_buttons:
			if is_instance_valid(button):
				_boxes_row.remove_child(button)
				button.queue_free()
	_box_buttons.clear()
	_boxes_locked = false

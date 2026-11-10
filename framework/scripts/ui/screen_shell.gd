class_name ScreenShell
extends Control
## Shared chrome for standard screens: player header, bottom navigation, side
## zones (events + offers) and the banner ad slot. Content screens (BaseScreen
## subclasses) are hosted in `content_host` and swapped by ScreenManager.
##
## The shell derives all chrome state from EventBus.screen_changed and keeps
## its chrome out of the way on fullscreen screens (game, results).

const HEADER_RECT: Rect2 = Rect2(0.0, 0.0, 1.0, 0.16)
const CONTENT_RECT: Rect2 = Rect2(0.0, 0.16, 1.0, 0.60)
const NAV_RECT: Rect2 = Rect2(0.0, 0.76, 1.0, 0.15)
const LEFT_ZONE_RECT: Rect2 = Rect2(0.0, 0.22, 0.18, 0.40)
const RIGHT_ZONE_RECT: Rect2 = Rect2(0.82, 0.22, 0.18, 0.40)
const BANNER_RECT: Rect2 = Rect2(0.0, 0.91, 1.0, 0.09)
const FULLSCREEN_RECT: Rect2 = Rect2(0.0, 0.0, 1.0, 1.0)

const EVENTS_FLAG: String = "events_zone_enabled"
const OFFERS_FLAG: String = "offers_zone_enabled"
const DAILY_GIFT_KIND: String = "daily_gift"
const PIGGY_BANK_KIND: String = "piggy_bank"
const STREAK_KIND: String = "streak"
const OFFERS_DOMAIN: String = "offers"
const PIGGY_BANK_DOMAIN: String = "piggy_bank"
const PROFILE_DOMAIN: String = "profile"
const CAMPAIGN_CLAIMS_DOMAIN: String = "campaign_claims"
const ACTION_CLAIM: String = "claim"
const DAILY_GIFT_EXTRA_WATCHES_KEY: String = "daily_gift_extra_watches"
const DEFAULT_DAILY_GIFT_EXTRA_WATCHES: int = 2
const PIGGY_THRESHOLD_KEY: String = "piggy_redemption_threshold"
const DEFAULT_PIGGY_THRESHOLD: int = 150
## Gift Pile entry flow (Phase F3, GDD §8): the left-zone widget opens an intro
## dialog; Play consumes a date-keyed run slot or an RV extra watch.
const GIFT_PILE_DOMAIN: String = "gift_pile"
const GIFT_PILE_HEIGHT_KEY: String = "gift_pile_height"
const DEFAULT_GIFT_PILE_HEIGHT: int = 10
const GIFT_PILE_WEIGHTS_KEY: String = "gift_pile_slot_weights"
const DEFAULT_GIFT_PILE_WEIGHTS: Dictionary = {"coins": 45, "gems": 10, "cosmetic": 5, "fail": 40}
const GIFT_PILE_COIN_REWARD_KEY: String = "gift_pile_coin_reward"
const DEFAULT_GIFT_PILE_COIN_REWARD: int = 25
const GIFT_PILE_GEM_REWARD_KEY: String = "gift_pile_gem_reward"
const DEFAULT_GIFT_PILE_GEM_REWARD: int = 3
const GIFT_PILE_COSMETIC_KEY: String = "gift_pile_cosmetic"
const DEFAULT_GIFT_PILE_COSMETIC: String = "portrait_icon:gold"
const GIFT_PILE_JACKPOT_KEY: String = "gift_pile_jackpot"
const DEFAULT_GIFT_PILE_JACKPOT: Dictionary = {"kind": "gems", "amount": 25}
const GIFT_PILE_RUNS_PER_DAY_KEY: String = "gift_pile_runs_per_day"
const DEFAULT_GIFT_PILE_RUNS_PER_DAY: int = 1
const GIFT_PILE_EXTRA_WATCHES_KEY: String = "gift_pile_extra_watches"
const DEFAULT_GIFT_PILE_EXTRA_WATCHES: int = 1
const TICK_SEC: float = 1.0
const ZONE_SEPARATION: int = 8
const ICON_SIZE: float = 56.0
## Sprite-art offers route through OfferSpriteWidget.frames_path_for_icon()
## (the canonical icon key -> frames map); other icon keys fall back to
## ProtoIcon.
## Small status banner that crosses the bottom edge of each zone icon
## (countdown text for events, claim button for offers).
const BANNER_H: int = 20
const BANNER_OVERLAP: int = 8
const BANNER_FONT_SIZE: int = 11
## Each side zone holds at most this many widgets; extra events/offers from
## remote config are dropped (prototype cap, see TODO.md).
const MAX_ZONE_WIDGETS: int = 6

const NAV_ORDER: Array = [
	ScreenIds.PROFILE,
	ScreenIds.SOCIAL,
	ScreenIds.HOME,
	ScreenIds.SPECIAL,
	ScreenIds.SETTINGS,
]

## Host for the active content screen. ScreenManager adds/removes BaseScreen
## instances here; the shell never touches its children.
var content_host: Control

var _current_screen: StringName = ScreenIds.HOME
var _header_bar: PlayerInfoHeader
var _nav_bar: HBoxContainer
var _banner_host: Control
## Zones are plain (invisible) containers — the widgets inside are big icons
## with a small status banner, not filled panels.
var _left_zone: Control
var _right_zone: Control
var _left_items: VBoxContainer
var _right_items: VBoxContainer
var _tick_timer: Timer
var _nav_buttons: Dictionary = {}
## id -> {slot, strip_label, strip_kind} for live countdown refresh + expiry removal.
var _event_cards: Dictionary = {}
var _campaign_cards: Dictionary = {}
var _offer_states: Dictionary = {}
## The zone dialog currently open (null when none); kept so tests and the
## rebuild path can reach it.
var _open_dialog: ZoneDialog = null
## Live parts of the Gift Pile intro dialog (null while it is closed).
var _gp_state_label: Label = null
var _gp_button: Button = null


func _ready() -> void:
	_build_chrome()
	_rebuild_zones()
	EventBus.screen_changed.connect(_on_screen_changed)
	EventBus.config_loaded.connect(_rebuild_zones)
	LocalizationManager.locale_applied.connect(_on_locale_applied)
	_tick_timer = Timer.new()
	_tick_timer.wait_time = TICK_SEC
	_tick_timer.autostart = true
	_tick_timer.timeout.connect(_on_tick)
	add_child(_tick_timer)
	_on_screen_changed(_current_screen, &"")


func _exit_tree() -> void:
	if EventBus.screen_changed.is_connected(_on_screen_changed):
		EventBus.screen_changed.disconnect(_on_screen_changed)
	if EventBus.config_loaded.is_connected(_rebuild_zones):
		EventBus.config_loaded.disconnect(_rebuild_zones)
	if LocalizationManager.locale_applied.is_connected(_on_locale_applied):
		LocalizationManager.locale_applied.disconnect(_on_locale_applied)


func _pin(node: Control, rect: Rect2) -> void:
	node.anchor_left = rect.position.x
	node.anchor_top = rect.position.y
	node.anchor_right = rect.end.x
	node.anchor_bottom = rect.end.y
	node.offset_left = 0.0
	node.offset_top = 0.0
	node.offset_right = 0.0
	node.offset_bottom = 0.0


func _build_chrome() -> void:
	_header_bar = PlayerInfoHeader.new()
	_pin(_header_bar, HEADER_RECT)
	add_child(_header_bar)

	content_host = Control.new()
	_pin(content_host, CONTENT_RECT)
	add_child(content_host)

	_nav_bar = HBoxContainer.new()
	_nav_bar.add_theme_constant_override("separation", 0)
	_pin(_nav_bar, NAV_RECT)
	add_child(_nav_bar)
	for i in NAV_ORDER.size():
		var screen_id: StringName = NAV_ORDER[i]
		var button := NavButton.new()
		button.setup(screen_id, "nav_" + str(screen_id))
		button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		button.pressed.connect(_on_nav_button_pressed.bind(button))
		_nav_bar.add_child(button)
		_nav_buttons[screen_id] = button

	_banner_host = Control.new()
	_pin(_banner_host, BANNER_RECT)
	add_child(_banner_host)
	var banner_slot := BannerAdSlot.new()
	banner_slot.set_anchors_preset(Control.PRESET_FULL_RECT)
	_banner_host.add_child(banner_slot)

	_left_zone = _make_zone(LEFT_ZONE_RECT)
	_left_items = _make_zone_items(_left_zone)
	_right_zone = _make_zone(RIGHT_ZONE_RECT)
	_right_items = _make_zone_items(_right_zone)


func _make_zone(rect: Rect2) -> Control:
	var zone := Control.new()
	_pin(zone, rect)
	add_child(zone)
	return zone


func _make_zone_items(parent: Control) -> VBoxContainer:
	var items := VBoxContainer.new()
	items.anchor_left = 0.0
	items.anchor_top = 0.0
	items.anchor_right = 1.0
	items.anchor_bottom = 1.0
	items.offset_left = ThemeFactory.CONTENT_MARGIN
	items.offset_top = ThemeFactory.CONTENT_MARGIN
	items.offset_right = -ThemeFactory.CONTENT_MARGIN
	items.offset_bottom = -ThemeFactory.CONTENT_MARGIN
	items.add_theme_constant_override("separation", ZONE_SEPARATION)
	parent.add_child(items)
	return items


func _rebuild_zones() -> void:
	# A rebuild invalidates the widgets an open dialog acts on — close it so a
	# stale state surface never lingers over fresh zones.
	if _open_dialog != null and is_instance_valid(_open_dialog):
		UIManager.close_current_dialog()
	_open_dialog = null
	if _gp_button != null and is_instance_valid(_gp_button):
		UIManager.close_current_dialog()
	_gp_state_label = null
	_gp_button = null
	_clear_items(_left_items)
	_clear_items(_right_items)
	_event_cards.clear()
	_campaign_cards.clear()
	_offer_states.clear()
	_build_gift_pile_widget()
	for event in RemoteConfig.get_events():
		var event_id := str(event.get("id", ""))
		if event_id == "":
			push_warning("ScreenShell: skipping event without id")
			continue
		if not RemoteConfig.is_event_active(event_id):
			continue
		var items := _zone_for(_metadata_zone(event))
		if items.get_child_count() >= MAX_ZONE_WIDGETS:
			continue
		_build_event_card(event, items)
	for campaign in RemoteConfig.get_campaigns():
		var campaign_id := str(campaign.get("id", ""))
		if campaign_id == "":
			push_warning("ScreenShell: skipping campaign without id")
			continue
		if not RemoteConfig.is_campaign_active(campaign_id):
			continue
		if _is_campaign_claimed(campaign_id):
			continue
		var items := _zone_for(_metadata_zone(campaign))
		if items.get_child_count() >= MAX_ZONE_WIDGETS:
			continue
		_build_campaign_card(campaign, items)
	for offer in RemoteConfig.get_offers():
		var offer_id := str(offer.get("id", ""))
		if offer_id == "":
			push_warning("ScreenShell: skipping offer without id")
			continue
		if not RemoteConfig.is_enabled(offer_id + "_enabled", true):
			continue
		if _right_items.get_child_count() >= MAX_ZONE_WIDGETS:
			break
		_build_offer_card(offer)
	_refresh_countdowns()
	_refresh_streak_strips()
	_refresh_offers()
	_update_zone_visibility()


func _build_event_card(event: Dictionary, items: VBoxContainer) -> void:
	var event_id := str(event.get("id", ""))
	var widget := _add_widget(items, str(event.get("icon", "info")))
	var slot: Control = widget["slot"]
	var icon: Control = widget["icon"]
	var card: Dictionary = {"id": event_id, "slot": slot, "strip_label": null, "strip_kind": ""}
	if RemoteConfig.get_event_deadline(event_id) >= 0:
		card["strip_label"] = _attach_banner_label(icon)
		card["strip_kind"] = "countdown"
	var metadata := _metadata_of(event)
	var kind := str(event.get("kind", ""))
	if kind == TournamentService.KIND_SOLO or kind == TournamentService.KIND_TEAM:
		_enable_slot_tap(slot, ZoneDialog.TOURNAMENT_KIND, event, "event")
	elif kind == ZoneDialog.LEADERBOARDS_KIND:
		# TDD §3.26: evergreen leaderboards widget (no deadline, no rewards).
		_enable_slot_tap(slot, ZoneDialog.LEADERBOARDS_KIND, event, "event")
	elif kind == ZoneDialog.MATCHMAKING_KIND:
		# TDD §3.27: evergreen matchmaking hook widget (no deadline, no rewards).
		_enable_slot_tap(slot, ZoneDialog.MATCHMAKING_KIND, event, "event")
	elif typeof(metadata.get("dialog")) == TYPE_DICTIONARY:
		_enable_card_tap(slot, metadata["dialog"])
	_attach_tooltip_from_metadata(slot, metadata, str(event.get("icon", "info")))
	_event_cards[event_id] = card


func _build_campaign_card(campaign: Dictionary, items: VBoxContainer) -> void:
	var campaign_id := str(campaign.get("id", ""))
	var widget := _add_widget(items, str(campaign.get("icon", "info")))
	var slot: Control = widget["slot"]
	var icon: Control = widget["icon"]
	var action := str(campaign.get("action", ""))
	var card: Dictionary = {"id": campaign_id, "slot": slot, "strip_label": null, "strip_kind": "", "kind": str(campaign.get("kind", ""))}
	var metadata := _metadata_of(campaign)

	# Strip priority (GDD §6): claim button > progress > countdown > none. The
	# LIVE streak kind renders a progress strip from save state (Phase F2).
	if card["kind"] == STREAK_KIND:
		card["strip_label"] = _attach_banner_label(icon)
		card["strip_kind"] = "progress"
	elif action == ACTION_CLAIM:
		var button := Button.new()
		button.theme_type_variation = "ButtonAccent"
		button.add_theme_font_size_override("font_size", BANNER_FONT_SIZE)
		button.text = tr("offer_claim")
		button.pressed.connect(_open_widget_dialog.bind(ZoneDialog.CLAIM_KIND, campaign, "campaign"))
		_attach_banner(icon, button)
		card["button"] = button
		card["currency"] = str(campaign.get("reward_currency", "coins"))
		card["amount"] = int(campaign.get("reward_amount", 0))
	else:
		var progress: Variant = metadata.get("progress")
		if typeof(progress) == TYPE_DICTIONARY:
			var p := progress as Dictionary
			card["strip_label"] = _attach_banner_label(icon)
			card["strip_kind"] = "progress"
			(card["strip_label"] as Label).text = "%d/%d" % [int(p.get("current", 0)), int(p.get("goal", 0))]
		elif RemoteConfig.get_campaign_deadline(campaign_id) >= 0:
			card["strip_label"] = _attach_banner_label(icon)
			card["strip_kind"] = "countdown"
	# Tap surface (Phase F2 uniform rule): metadata.dialog keeps its legacy text
	# dialog; everything else opens the kind's state-driven ZoneDialog.
	if typeof(metadata.get("dialog")) == TYPE_DICTIONARY:
		_enable_card_tap(slot, metadata["dialog"])
	else:
		_enable_slot_tap(slot, _campaign_dialog_kind(campaign), campaign, "campaign")
	_attach_tooltip_from_metadata(slot, metadata, str(campaign.get("icon", "info")))
	_campaign_cards[campaign_id] = card


func _campaign_dialog_kind(campaign: Dictionary) -> String:
	if str(campaign.get("kind", "")) == STREAK_KIND:
		return ZoneDialog.STREAK_KIND
	if str(campaign.get("action", "")) == ACTION_CLAIM:
		return ZoneDialog.CLAIM_KIND
	return ZoneDialog.INFO_KIND


func _build_offer_card(offer: Dictionary) -> void:
	var offer_id := str(offer.get("id", ""))
	var kind := str(offer.get("kind", ""))
	var widget := _add_widget(_right_items, str(offer.get("icon", _kind_icon(kind))))
	var slot: Control = widget["slot"]
	var icon: Control = widget["icon"]

	var button := Button.new()
	button.theme_type_variation = "ButtonAccent"
	button.add_theme_font_size_override("font_size", BANNER_FONT_SIZE)
	button.text = tr("offer_claim")
	button.pressed.connect(_open_widget_dialog.bind(kind, offer, "offer"))
	_attach_banner(icon, button)
	_enable_slot_tap(slot, _offer_dialog_kind(kind), offer)

	var sprite: OfferSpriteWidget = icon if icon is OfferSpriteWidget else null
	_offer_states[offer_id] = {
		"button": button,
		"slot": slot,
		"kind": kind,
		"sprite": sprite,
		"currency": str(offer.get("reward_currency", "coins")),
		"amount": int(offer.get("reward_amount", 0)),
		"cooldown_sec": int(offer.get("cooldown_hours", 0)) * 3600,
	}
	_attach_tooltip_from_metadata(slot, _metadata_of(offer), str(offer.get("icon", _kind_icon(kind))))


## One zone widget: an equal-height slot holding a big centered icon. Returns
## {"slot": Control, "icon": Control} where the icon is an OfferSpriteWidget
## for sprite-art offers or a ProtoIcon otherwise; callers attach their status
## banner to the icon and tap handling to the slot.
func _add_widget(items: VBoxContainer, icon_key: String) -> Dictionary:
	var slot := Control.new()
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.size_flags_vertical = Control.SIZE_EXPAND_FILL
	items.add_child(slot)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	# IGNORE so taps fall through to the slot (which owns tap dialogs).
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(center)

	var host: Control
	var frames_path := OfferSpriteWidget.frames_path_for_icon(icon_key)
	if frames_path != "":
		host = _make_sprite_widget(frames_path)
	else:
		var icon := ProtoIcon.new()
		icon.setup(icon_key, ICON_SIZE)
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		host = icon
	center.add_child(host)
	return {"slot": slot, "icon": host}


## If the entry's metadata carries a non-empty `tooltip` (a tr() key), attach
## it to the widget so long-pressing shows the hint (GDD §8). Zones are
## rebuilt on locale change, which re-translates the text.
func _attach_tooltip_from_metadata(slot: Control, metadata: Dictionary, icon_key: String) -> void:
	var tooltip_key: Variant = metadata.get("tooltip")
	if typeof(tooltip_key) == TYPE_STRING and str(tooltip_key) != "":
		UIManager.attach_tooltip(slot, tr(str(tooltip_key)), icon_key)


func _make_sprite_widget(frames_path: String) -> OfferSpriteWidget:
	var widget := OfferSpriteWidget.new()
	widget.setup(frames_path, ICON_SIZE)
	return widget


# --- Gift Pile entry flow (Phase F3, GDD §8) --------------------------------------

## Fixed left-zone entry widget (not config-driven): always first, opens the
## intro dialog on tap.
func _build_gift_pile_widget() -> void:
	var widget := _add_widget(_left_items, "pile")
	var slot: Control = widget["slot"]
	slot.mouse_filter = Control.MOUSE_FILTER_STOP
	slot.gui_input.connect(_on_gift_pile_slot_input)
	UIManager.attach_tooltip(slot, tr("gift_pile_tooltip"), "pile")


func _on_gift_pile_slot_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
		_open_gift_pile_intro()


## Intro dialog: rules + top prize + save cost, then a state-driven button
## (Continue / Play / RV extra watch). The shell owns run-start bookkeeping;
## the screen owns the run itself.
func _open_gift_pile_intro() -> void:
	if UIManager.is_dialog_open():
		return
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 10)

	var rules := Label.new()
	rules.text = tr("gift_pile_intro_rules")
	rules.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rules.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(rules)

	var top_prize := Label.new()
	top_prize.theme_type_variation = "LabelGold"
	top_prize.text = tr("gift_pile_top_prize") % [_jackpot_text()]
	top_prize.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(top_prize)

	var save_line := Label.new()
	save_line.theme_type_variation = "LabelDim"
	save_line.text = tr("gift_pile_save_cost") % [int(RemoteConfig.get_value("gift_pile_save_coins", 100))]
	content.add_child(save_line)

	_gp_state_label = Label.new()
	_gp_state_label.theme_type_variation = "LabelDim"
	_gp_state_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(_gp_state_label)

	_gp_button = Button.new()
	_gp_button.theme_type_variation = "ButtonPrimary"
	_gp_button.pressed.connect(_on_gp_button_pressed)
	content.add_child(_gp_button)

	UIManager.show_dialog(content, tr("gift_pile_title"), true, Vector2(400, 0), false)
	_refresh_gift_pile_intro()


func _refresh_gift_pile_intro() -> void:
	if _gp_button == null or not is_instance_valid(_gp_button):
		return
	if _gp_has_active_run():
		_gp_state_label.text = tr("gift_pile_continue_hint")
		_gp_button.text = tr("gift_pile_continue")
	elif _gp_runs_remaining() > 0:
		_gp_state_label.text = ""
		_gp_button.text = tr("gift_pile_play")
	elif _gp_extras_remaining() > 0:
		_gp_state_label.text = tr("gift_pile_no_runs_left")
		_gp_button.text = tr("gift_pile_extra_watch")
	else:
		_gp_state_label.text = tr("gift_pile_come_back")
		_gp_button.visible = false


func _on_gp_button_pressed() -> void:
	if _gp_has_active_run():
		_close_and_enter_gift_pile()
	elif _gp_runs_remaining() > 0:
		_start_gift_pile_run()
		_close_and_enter_gift_pile()
	elif _gp_extras_remaining() > 0:
		_gp_button.disabled = true
		AdManager.watch_rewarded(_on_gp_extra_watch.bind())


func _on_gp_extra_watch(success: bool) -> void:
	if not success:
		_gp_state_label.text = tr("dlg_ad_failed")
		_gp_button.disabled = false
		return
	_consume_extra_watch()
	_start_gift_pile_run()
	_close_and_enter_gift_pile()


func _close_and_enter_gift_pile() -> void:
	UIManager.close_current_dialog()
	EventBus.navigation_requested.emit(ScreenIds.GIFT_PILE)


## Starts a fresh run and consumes one date-keyed daily slot (TDD §3.22).
func _start_gift_pile_run() -> void:
	var run := GiftPileRun.new_run(_gp_height(), _gift_pile_weights(), int(Time.get_ticks_usec()), _dict_config(GIFT_PILE_JACKPOT_KEY, DEFAULT_GIFT_PILE_JACKPOT))
	var domain := SaveSystem.get_domain(GIFT_PILE_DOMAIN)
	var today := _gp_today()
	if str(domain.get("runs_date", "")) != today:
		domain["runs_date"] = today
		domain["runs_count"] = 0
	domain["runs_count"] = int(domain.get("runs_count", 0)) + 1
	domain["run"] = run
	SaveSystem.set_domain(GIFT_PILE_DOMAIN, domain)
	SaveSystem.save_game()
	EventBus.gift_pile_run_changed.emit(run)
	Analytics.track("gift_pile_started", {"height": _gp_height()})


func _consume_extra_watch() -> void:
	var domain := SaveSystem.get_domain(GIFT_PILE_DOMAIN)
	var today := _gp_today()
	if str(domain.get("extra_watches_date", "")) != today:
		domain["extra_watches_date"] = today
		domain["extra_watches_count"] = 0
	domain["extra_watches_count"] = int(domain.get("extra_watches_count", 0)) + 1
	SaveSystem.set_domain(GIFT_PILE_DOMAIN, domain)
	SaveSystem.save_game()


## A run sitting in DANGER still counts as active: its save/give-up decision is
## pending, so the intro must offer Continue (Play would overwrite it).
func _gp_has_active_run() -> bool:
	var saved: Variant = SaveSystem.get_domain(GIFT_PILE_DOMAIN).get("run", null)
	if typeof(saved) != TYPE_DICTIONARY:
		return false
	var run := saved as Dictionary
	return GiftPileRun.is_active(run) or bool(run.get("danger", false))


func _gp_today() -> String:
	return Time.get_date_string_from_system()


func _gp_runs_remaining() -> int:
	var cap := maxi(int(RemoteConfig.get_value(GIFT_PILE_RUNS_PER_DAY_KEY, DEFAULT_GIFT_PILE_RUNS_PER_DAY)), 0)
	var domain: Dictionary = SaveSystem.get_domain(GIFT_PILE_DOMAIN)
	var used := int(domain.get("runs_count", 0)) if str(domain.get("runs_date", "")) == _gp_today() else 0
	return maxi(cap - used, 0)


func _gp_extras_remaining() -> int:
	var cap := maxi(int(RemoteConfig.get_value(GIFT_PILE_EXTRA_WATCHES_KEY, DEFAULT_GIFT_PILE_EXTRA_WATCHES)), 0)
	var domain: Dictionary = SaveSystem.get_domain(GIFT_PILE_DOMAIN)
	var used := int(domain.get("extra_watches_count", 0)) if str(domain.get("extra_watches_date", "")) == _gp_today() else 0
	return maxi(cap - used, 0)


func _gp_height() -> int:
	return maxi(int(RemoteConfig.get_value(GIFT_PILE_HEIGHT_KEY, DEFAULT_GIFT_PILE_HEIGHT)), 1)


## Merges the base slot weights with the reward-tuning values (TDD §3.22 keeps
## new_run() config-free, so the shell assembles the full generation spec).
func _gift_pile_weights() -> Dictionary:
	var weights := _dict_config(GIFT_PILE_WEIGHTS_KEY, DEFAULT_GIFT_PILE_WEIGHTS)
	weights["coin_amount"] = maxi(int(RemoteConfig.get_value(GIFT_PILE_COIN_REWARD_KEY, DEFAULT_GIFT_PILE_COIN_REWARD)), 1)
	weights["gem_amount"] = maxi(int(RemoteConfig.get_value(GIFT_PILE_GEM_REWARD_KEY, DEFAULT_GIFT_PILE_GEM_REWARD)), 1)
	weights["cosmetic_item"] = str(RemoteConfig.get_value(GIFT_PILE_COSMETIC_KEY, DEFAULT_GIFT_PILE_COSMETIC))
	return weights


func _dict_config(key: String, fallback: Dictionary) -> Dictionary:
	var value: Variant = RemoteConfig.get_value(key, fallback)
	if typeof(value) == TYPE_DICTIONARY:
		return (value as Dictionary).duplicate(true)
	return fallback.duplicate(true)


func _jackpot_text() -> String:
	var jackpot := _dict_config(GIFT_PILE_JACKPOT_KEY, DEFAULT_GIFT_PILE_JACKPOT)
	var amount := int(jackpot.get("amount", 0))
	var currency_name := tr("header_gems") if str(jackpot.get("kind", "")) == "gems" else tr("header_coins")
	return "%d %s" % [amount, currency_name]


## Pins `content` as a small strip across the bottom edge of the icon
## (overlapping it by BANNER_OVERLAP). The strip extends past both icon
## edges so localized countdown strings ("Termina en 14:59") still fit.
func _attach_banner(host: Control, content: Control) -> void:
	content.anchor_left = -0.35
	content.anchor_top = 1.0
	content.anchor_right = 1.35
	content.anchor_bottom = 1.0
	content.offset_top = -BANNER_OVERLAP
	content.offset_bottom = BANNER_H - BANNER_OVERLAP
	host.add_child(content)


## Dark strip + centered caption, used for event countdowns.
func _attach_banner_label(host: Control) -> Label:
	var strip := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(ThemeFactory.COLOR_PANEL.r, ThemeFactory.COLOR_PANEL.g, ThemeFactory.COLOR_PANEL.b, 0.92)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(2)
	strip.add_theme_stylebox_override("panel", sb)

	var label := Label.new()
	label.theme_type_variation = "LabelDim"
	label.add_theme_font_size_override("font_size", BANNER_FONT_SIZE)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	strip.add_child(label)

	_attach_banner(host, strip)
	return label


func _kind_icon(kind: String) -> String:
	match kind:
		DAILY_GIFT_KIND:
			return "gift"
		PIGGY_BANK_KIND:
			return "bank"
		_:
			return "booster"


func _refresh_countdowns() -> void:
	var now: int = int(Time.get_unix_time_from_system())
	for id in _event_cards.keys():
		_refresh_card_strip(_event_cards[id], str(id), now, true)
	for id in _campaign_cards.keys():
		_refresh_card_strip(_campaign_cards[id], str(id), now, false)


func _refresh_card_strip(card: Dictionary, card_id: String, now: int, is_event: bool) -> void:
	if str(card.get("strip_kind", "")) != "countdown":
		return
	var label: Label = card["strip_label"]
	if not is_instance_valid(label):
		return
	var deadline: int = RemoteConfig.get_event_deadline(card_id) if is_event else RemoteConfig.get_campaign_deadline(card_id)
	if deadline < 0:
		return
	var text := tr("event_ends_in") % _format_hm(maxi(deadline - now, 0))
	if label.text != text:
		label.text = text


## Removes widgets whose entries have expired (TDD §3.11 lifecycle rule).
func _reap_expired_cards() -> void:
	var expired_events: Array[String] = []
	for id in _event_cards.keys():
		if not RemoteConfig.is_event_active(str(id)):
			expired_events.append(str(id))
	for id in expired_events:
		_remove_card(_event_cards, id)
	var expired_campaigns: Array[String] = []
	for id in _campaign_cards.keys():
		if not RemoteConfig.is_campaign_active(str(id)):
			expired_campaigns.append(str(id))
	for id in expired_campaigns:
		_remove_card(_campaign_cards, id)


func _remove_card(cards: Dictionary, card_id: String) -> void:
	var card: Dictionary = cards.get(card_id, {})
	if card.is_empty():
		return
	var slot: Control = card.get("slot", null)
	if is_instance_valid(slot):
		var parent := slot.get_parent()
		if parent != null:
			parent.remove_child(slot)
		slot.queue_free()
	cards.erase(card_id)


func _is_campaign_claimed(campaign_id: String) -> bool:
	return SaveSystem.get_domain(CAMPAIGN_CLAIMS_DOMAIN).has(campaign_id)


## Once-per-id claim (GDD §6): grant reward, stamp campaign_claims, toast,
## remove the widget. Returns true when the claim applied (the zone dialog
## uses the result to decide between close and refresh).
func _on_campaign_pressed(campaign_id: String) -> bool:
	if not _campaign_cards.has(campaign_id) or _is_campaign_claimed(campaign_id):
		return false
	var card: Dictionary = _campaign_cards[campaign_id]
	var granted := int(card.get("amount", 0))
	if granted <= 0:
		push_warning("ScreenShell: campaign '%s' amount is zero; claim stamp not written" % campaign_id)
		return false
	var claims: Dictionary = SaveSystem.get_domain(CAMPAIGN_CLAIMS_DOMAIN)
	claims[campaign_id] = Time.get_unix_time_from_system()
	SaveSystem.set_domain(CAMPAIGN_CLAIMS_DOMAIN, claims)

	var profile: Dictionary = SaveSystem.get_domain(PROFILE_DOMAIN)
	_grant_and_emit(profile, str(card.get("currency", "coins")), granted)
	_remove_card(_campaign_cards, campaign_id)
	return true


## Makes a card slot input-active; a left press opens the metadata dialog.
## Only wired for display-only cards (claim buttons consume their own presses).
func _enable_card_tap(slot: Control, dialog: Dictionary) -> void:
	slot.mouse_filter = Control.MOUSE_FILTER_STOP
	slot.gui_input.connect(_on_card_gui_input.bind(dialog))


func _on_card_gui_input(event: InputEvent, dialog: Dictionary) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
		UIManager.show_text_dialog(str(dialog.get("title", "")), str(dialog.get("body", "")))


func _offer_dialog_kind(kind: String) -> String:
	match kind:
		DAILY_GIFT_KIND:
			return ZoneDialog.DAILY_GIFT_KIND
		PIGGY_BANK_KIND:
			return ZoneDialog.PIGGY_BANK_KIND
		_:
			return ZoneDialog.CLAIM_KIND


## Makes a widget slot input-active; a left press opens the kind's ZoneDialog
## (Phase F2 uniform rule — every offer/campaign widget has one).
func _enable_slot_tap(slot: Control, dialog_kind: String, entry: Dictionary, source: String = "offer") -> void:
	slot.mouse_filter = Control.MOUSE_FILTER_STOP
	slot.gui_input.connect(_on_widget_slot_input.bind(dialog_kind, entry, source))


func _on_widget_slot_input(event: InputEvent, dialog_kind: String, entry: Dictionary, source: String) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
		_open_widget_dialog(dialog_kind, entry, source)


## Builds a fresh ZoneDialog for the tapped widget and opens it through the
## dialog host. No-op while another dialog is open (the host rejects anyway).
func _open_widget_dialog(dialog_kind: String, entry: Dictionary, source: String) -> void:
	if UIManager.is_dialog_open():
		return
	var dialog := ZoneDialog.new()
	dialog.setup(dialog_kind, entry, source, str(entry.get("icon", "")))
	dialog.action_requested.connect(_on_widget_dialog_action.bind(dialog))
	dialog.closed_requested.connect(_on_widget_dialog_closed.bind(dialog))
	_open_dialog = dialog
	UIManager.show_dialog(dialog, str(entry.get("title", "")), true, Vector2(400, 0), false)


func _on_widget_dialog_closed(dialog: ZoneDialog) -> void:
	if _open_dialog == dialog:
		_open_dialog = null
	UIManager.close_current_dialog()


## Routes a ZoneDialog button press to the matching save-mutating flow. The
## shell owns all economy logic; the dialog only reports intent (GDD §8).
func _on_widget_dialog_action(action: String, dialog: ZoneDialog) -> void:
	match dialog.kind:
		ZoneDialog.DAILY_GIFT_KIND:
			_on_daily_gift_action(str(dialog.entry.get("id", "")), action, dialog)
		ZoneDialog.PIGGY_BANK_KIND:
			_on_piggy_action(action, dialog)
		ZoneDialog.STREAK_KIND:
			_on_streak_action(action, dialog)
		ZoneDialog.TOURNAMENT_KIND:
			_on_tournament_action(action, dialog)
		ZoneDialog.MATCHMAKING_KIND:
			_on_matchmaking_action(action, dialog)
		_:
			_on_claim_action(dialog.entry, str(dialog.source), action, dialog)


# --- Zone-dialog economy flows (Phase F2) ------------------------------------------

func _on_daily_gift_action(offer_id: String, action: String, dialog: ZoneDialog) -> void:
	if action == ZoneDialog.ACTION_CLAIM:
		if _claim_daily_gift(offer_id):
			dialog.play_opening_then_close()
		else:
			dialog.refresh()
	elif action == ZoneDialog.ACTION_WATCH_CLAIM:
		AdManager.watch_rewarded(func(ok: bool) -> void:
			if not ok:
				dialog.set_note(tr("dlg_ad_failed"))
				return
			if _grant_daily_gift_extra(offer_id):
				dialog.play_opening_then_close()
			else:
				dialog.refresh())


## Free daily claim (stamp + grant). Returns true when the claim applied.
func _claim_daily_gift(offer_id: String) -> bool:
	var state: Dictionary = _offer_states.get(offer_id, {})
	if state.is_empty():
		return false
	var profile: Dictionary = SaveSystem.get_domain(PROFILE_DOMAIN)
	var today := Time.get_date_string_from_system()
	if str(profile.get("last_daily_claim_day", "")) == today:
		return false
	var granted := int(state.get("amount", 0))
	if granted <= 0:
		push_warning("ScreenShell: daily gift amount is zero; claim stamp not written")
		return false
	profile["last_daily_claim_day"] = today
	SaveSystem.set_domain(PROFILE_DOMAIN, profile)
	_grant_and_emit(profile, str(state.get("currency", "coins")), granted)
	_refresh_offers()
	return true


## One RV extra redemption (date-keyed counter, capped). Returns true when it
## applied.
func _grant_daily_gift_extra(offer_id: String) -> bool:
	var state: Dictionary = _offer_states.get(offer_id, {})
	if state.is_empty():
		return false
	var profile: Dictionary = SaveSystem.get_domain(PROFILE_DOMAIN)
	var today := Time.get_date_string_from_system()
	var cap := maxi(int(RemoteConfig.get_value(DAILY_GIFT_EXTRA_WATCHES_KEY, DEFAULT_DAILY_GIFT_EXTRA_WATCHES)), 0)
	var count := int(profile.get("daily_gift_watches_count", 0)) if str(profile.get("daily_gift_watches_date", "")) == today else 0
	if cap <= 0 or count >= cap:
		return false
	var granted := int(state.get("amount", 0))
	if granted <= 0:
		push_warning("ScreenShell: daily gift amount is zero; extra watch not stamped")
		return false
	profile["daily_gift_watches_date"] = today
	profile["daily_gift_watches_count"] = count + 1
	SaveSystem.set_domain(PROFILE_DOMAIN, profile)
	_grant_and_emit(profile, str(state.get("currency", "coins")), granted)
	_refresh_offers()
	return true


func _on_piggy_action(action: String, dialog: ZoneDialog) -> void:
	if action != ZoneDialog.ACTION_COLLECT_RV and action != ZoneDialog.ACTION_COLLECT_IAP:
		return
	var bank: Dictionary = SaveSystem.get_domain(PIGGY_BANK_DOMAIN)
	var threshold := maxi(int(RemoteConfig.get_value(PIGGY_THRESHOLD_KEY, DEFAULT_PIGGY_THRESHOLD)), 0)
	if int(bank.get("balance", 0)) < threshold:
		dialog.refresh()
		return
	if action == ZoneDialog.ACTION_COLLECT_RV:
		AdManager.watch_rewarded(func(ok: bool) -> void:
			if not ok:
				dialog.set_note(tr("dlg_ad_failed"))
				return
			_collect_piggy(dialog))
	else:
		_collect_piggy(dialog)


## Collects the ENTIRE balance (threshold already checked), resets it to 0 and
## plays the opening clip in-dialog before close.
func _collect_piggy(dialog: ZoneDialog) -> void:
	var bank: Dictionary = SaveSystem.get_domain(PIGGY_BANK_DOMAIN)
	var granted := int(bank.get("balance", 0))
	if granted <= 0:
		UIManager.close_current_dialog()
		return
	bank["balance"] = 0
	SaveSystem.set_domain(PIGGY_BANK_DOMAIN, bank)
	var profile: Dictionary = SaveSystem.get_domain(PROFILE_DOMAIN)
	profile["coins"] = int(profile.get("coins", 0)) + granted
	SaveSystem.set_domain(PROFILE_DOMAIN, profile)
	SaveSystem.save_game()
	EventBus.currency_changed.emit("coins", int(profile["coins"]))
	EventBus.profile_updated.emit(profile)
	EventBus.piggy_bank_changed.emit(0)
	# H2 toast policy: collecting is the direct effect of the tap — no toast.
	_refresh_offers()
	dialog.play_opening_then_close()


func _on_streak_action(action: String, dialog: ZoneDialog) -> void:
	var today := Time.get_date_string_from_system()
	if action == ZoneDialog.ACTION_CLAIM:
		var profile: Dictionary = SaveSystem.get_domain(PROFILE_DOMAIN)
		var res: Dictionary = StreakLogic.claim_reward(profile, today)
		var coins := int(res.get("coins", 0))
		if coins <= 0:
			dialog.refresh()
			return
		profile = res["profile"]
		SaveSystem.set_domain(PROFILE_DOMAIN, profile)
		_grant_and_emit(profile, "coins", coins)
		_refresh_streak_strips()
		dialog.play_opening_then_close()
	elif action == ZoneDialog.ACTION_RECOVER_COINS:
		var cost := StreakLogic.recovery_cost()
		var profile2: Dictionary = SaveSystem.get_domain(PROFILE_DOMAIN)
		if int(profile2.get("coins", 0)) < cost:
			return
		var res2: Dictionary = StreakLogic.recover(profile2, today)
		profile2 = res2["profile"]
		profile2["coins"] = int(profile2.get("coins", 0)) - cost
		SaveSystem.set_domain(PROFILE_DOMAIN, profile2)
		SaveSystem.save_game()
		EventBus.currency_changed.emit("coins", int(profile2["coins"]))
		EventBus.profile_updated.emit(profile2)
		_refresh_streak_strips()
		dialog.refresh()
	elif action == ZoneDialog.ACTION_RECOVER_RV:
		AdManager.watch_rewarded(func(ok: bool) -> void:
			if not ok:
				dialog.set_note(tr("dlg_ad_failed"))
				return
			var profile3: Dictionary = SaveSystem.get_domain(PROFILE_DOMAIN)
			var res3: Dictionary = StreakLogic.recover(profile3, Time.get_date_string_from_system())
			profile3 = res3["profile"]
			SaveSystem.set_domain(PROFILE_DOMAIN, profile3)
			SaveSystem.save_game()
			EventBus.profile_updated.emit(profile3)
			_refresh_streak_strips()
			dialog.refresh())


func _on_tournament_action(action: String, dialog: ZoneDialog) -> void:
	if action != ZoneDialog.ACTION_TOURNAMENT_CLAIM:
		return
	var event_id := str(dialog.entry.get("id", ""))
	_claim_tournament(event_id, dialog)


## Expiry claim (TDD §3.23): the service owns band lookup + grant + one-shot
## stamp; the shell only reacts — success closes, failure leaves a note.
func _claim_tournament(event_id: String, dialog: ZoneDialog) -> void:
	var result: Dictionary = await TournamentService.claim(event_id)
	if not is_instance_valid(dialog):
		return
	if bool(result.get("ok", false)):
		dialog.play_opening_then_close()
	else:
		dialog.set_note(tr("dlg_tournament_claim_failed"))


## Matchmaking (TDD §3.27): the service owns queue/match state; the shell only
## forwards intent. A successful enqueue transitions to queued and the dialog
## re-renders via its own matchmaking_state_changed connection — no explicit
## refresh needed on success; a failure leaves an inline note.
func _on_matchmaking_action(action: String, dialog: ZoneDialog) -> void:
	if action == ZoneDialog.ACTION_MATCHMAKING_FIND:
		var result: Dictionary = await MatchmakingService.enqueue()
		if not is_instance_valid(dialog):
			return
		if not bool(result.get("ok", false)):
			dialog.set_note(tr("dlg_matchmaking_failed"))
	elif action == ZoneDialog.ACTION_MATCHMAKING_CANCEL or action == ZoneDialog.ACTION_MATCHMAKING_LEAVE:
		MatchmakingService.cancel()
		if is_instance_valid(dialog):
			dialog.refresh()


## Claim for booster offers and claim campaigns (the generic "claim" dialog kind).
func _on_claim_action(entry: Dictionary, source: String, action: String, dialog: ZoneDialog) -> void:
	if action != ZoneDialog.ACTION_CLAIM:
		return
	var entry_id := str(entry.get("id", ""))
	var ok := false
	if source == "offer":
		ok = _claim_cooldown_offer(entry_id)
	else:
		ok = _on_campaign_pressed(entry_id)
	if ok:
		dialog.play_opening_then_close()
	else:
		dialog.refresh()


## Grants a reward to the profile and persists + emits the usual bus signals.
## Shared by every zone-dialog economy flow. H2 toast policy: claims are the
## direct effect of the tap — no success toast (the dialog's opening clip is
## the feedback).
func _grant_and_emit(profile: Dictionary, currency: String, amount: int) -> void:
	profile[currency] = int(profile.get(currency, 0)) + amount
	SaveSystem.set_domain(PROFILE_DOMAIN, profile)
	SaveSystem.save_game()
	EventBus.currency_changed.emit(currency, int(profile[currency]))
	EventBus.profile_updated.emit(profile)


## Live streak progress strips (streak / reward-table length), refreshed on the
## 1s tick and after any streak mutation.
func _refresh_streak_strips() -> void:
	var profile: Dictionary = SaveSystem.get_domain(PROFILE_DOMAIN)
	var table := StreakLogic.rewards_table()
	for id in _campaign_cards.keys():
		var card: Dictionary = _campaign_cards[id]
		if str(card.get("kind", "")) != STREAK_KIND or str(card.get("strip_kind", "")) != "progress":
			continue
		var label: Label = card.get("strip_label", null)
		if not is_instance_valid(label):
			continue
		label.text = "%d/%d" % [clampi(int(profile.get("streak_days", 0)), 0, table.size()), table.size()]


func _metadata_of(entry: Dictionary) -> Dictionary:
	var metadata: Variant = entry.get("metadata", {})
	return metadata if typeof(metadata) == TYPE_DICTIONARY else {}


func _metadata_zone(entry: Dictionary) -> String:
	var zone := str(_metadata_of(entry).get("zone", "left"))
	return zone if zone == "right" else "left"


func _zone_for(zone_name: String) -> VBoxContainer:
	return _right_items if zone_name == "right" else _left_items


func _refresh_offers() -> void:
	var now: int = int(Time.get_unix_time_from_system())
	var ids: Array = _offer_states.keys()
	for i in ids.size():
		var offer_id: String = str(ids[i])
		var state: Dictionary = _offer_states[offer_id]
		var button: Button = state["button"]
		var kind: String = str(state.get("kind", ""))

		var available := _is_offer_available(offer_id, state, now)
		button.disabled = not available

		var button_text := _offer_button_text(offer_id, state, kind, available, now)
		if button.text != button_text:
			button.text = button_text


## Compact strip text per offer state (GDD §6): claim / watch (daily-gift
## extras) / claimed / balance-threshold progress / cooldown countdown.
func _offer_button_text(offer_id: String, state: Dictionary, kind: String, available: bool, now: int) -> String:
	if kind == PIGGY_BANK_KIND and not available:
		var bank: Dictionary = SaveSystem.get_domain(PIGGY_BANK_DOMAIN)
		var threshold := maxi(int(RemoteConfig.get_value(PIGGY_THRESHOLD_KEY, DEFAULT_PIGGY_THRESHOLD)), 0)
		return "%d/%d" % [int(bank.get("balance", 0)), threshold]
	if available:
		if kind == DAILY_GIFT_KIND and _is_daily_gift_claimed_today():
			return tr("offer_watch")
		return tr("offer_claim")
	if kind == DAILY_GIFT_KIND:
		return tr("offer_claimed")
	var remaining: int = _cooldown_remaining(offer_id, state, now)
	return tr("offer_ready_in") % _format_hm(remaining)


func _is_daily_gift_claimed_today() -> bool:
	var profile: Dictionary = SaveSystem.get_domain(PROFILE_DOMAIN)
	return str(profile.get("last_daily_claim_day", "")) == Time.get_date_string_from_system()


func _is_offer_available(offer_id: String, state: Dictionary, now: int) -> bool:
	var kind: String = str(state.get("kind", ""))
	if kind == DAILY_GIFT_KIND:
		if not _is_daily_gift_claimed_today():
			return true
		var profile2: Dictionary = SaveSystem.get_domain(PROFILE_DOMAIN)
		var cap := maxi(int(RemoteConfig.get_value(DAILY_GIFT_EXTRA_WATCHES_KEY, DEFAULT_DAILY_GIFT_EXTRA_WATCHES)), 0)
		var count := int(profile2.get("daily_gift_watches_count", 0)) if str(profile2.get("daily_gift_watches_date", "")) == Time.get_date_string_from_system() else 0
		return count < cap
	if kind == PIGGY_BANK_KIND:
		var bank: Dictionary = SaveSystem.get_domain(PIGGY_BANK_DOMAIN)
		var threshold := maxi(int(RemoteConfig.get_value(PIGGY_THRESHOLD_KEY, DEFAULT_PIGGY_THRESHOLD)), 0)
		return int(bank.get("balance", 0)) >= threshold
	var offers: Dictionary = SaveSystem.get_domain(OFFERS_DOMAIN)
	var last: int = int(offers.get(offer_id, 0))
	if last == 0:
		return true
	return now >= last + int(state.get("cooldown_sec", 0))


func _cooldown_remaining(offer_id: String, state: Dictionary, now: int) -> int:
	var offers: Dictionary = SaveSystem.get_domain(OFFERS_DOMAIN)
	var last: int = int(offers.get(offer_id, 0))
	if last == 0:
		return 0
	return maxi(last + int(state.get("cooldown_sec", 0)) - now, 0)


## Splits a seconds count into [hours, minutes] for "%d:%02d" countdown strings.
## Float division + explicit casts keep narrowing/integer-division lint quiet.
func _format_hm(total_sec: int) -> Array[int]:
	return [int(total_sec / 3600.0), int((total_sec % 3600) / 60.0)]


## Cooldown-based offer claim (booster & friends): stamp the offers domain,
## grant the reward. Returns true when the claim applied (daily_gift and
## piggy_bank have their own dialog flows — see _on_daily_gift_action /
## _on_piggy_action).
func _claim_cooldown_offer(offer_id: String) -> bool:
	if not _offer_states.has(offer_id):
		push_warning("ScreenShell: claim for unknown offer '%s'" % offer_id)
		return false
	var state: Dictionary = _offer_states[offer_id]
	var now := Time.get_unix_time_from_system()

	var offers: Dictionary = SaveSystem.get_domain(OFFERS_DOMAIN)
	var last: int = int(offers.get(offer_id, 0))
	var cooldown_sec: int = int(state.get("cooldown_sec", 0))
	if last != 0 and now < last + cooldown_sec:
		return false
	var granted := int(state.get("amount", 0))
	if granted <= 0:
		push_warning("ScreenShell: offer '%s' amount is zero; claim stamp not written" % offer_id)
		return false
	offers[offer_id] = now
	SaveSystem.set_domain(OFFERS_DOMAIN, offers)

	var profile: Dictionary = SaveSystem.get_domain(PROFILE_DOMAIN)
	_grant_and_emit(profile, str(state.get("currency", "coins")), granted)
	_refresh_offers()
	return true


func _on_tick() -> void:
	_reap_expired_cards()
	_refresh_countdowns()
	_refresh_streak_strips()
	_refresh_offers()


func _on_locale_applied(_language_code: String) -> void:
	_rebuild_zones()


func _on_nav_button_pressed(button: NavButton) -> void:
	EventBus.navigation_requested.emit(button.screen_id)


func _on_screen_changed(screen_id: StringName, _previous_screen_id: StringName) -> void:
	_current_screen = screen_id
	for i in NAV_ORDER.size():
		var nav_id: StringName = NAV_ORDER[i]
		var button: NavButton = _nav_buttons[nav_id]
		button.set_active(nav_id == screen_id)

	if ScreenIds.is_fullscreen(screen_id):
		_header_bar.visible = false
		_nav_bar.visible = false
		_banner_host.visible = false
		_pin(content_host, FULLSCREEN_RECT)
	else:
		_header_bar.visible = true
		_nav_bar.visible = true
		_banner_host.visible = true
		_pin(content_host, CONTENT_RECT)
	_update_zone_visibility()


func _update_zone_visibility() -> void:
	var show_zones := (_current_screen == ScreenIds.HOME) and not ScreenIds.is_fullscreen(_current_screen)
	_left_zone.visible = show_zones and RemoteConfig.is_enabled(EVENTS_FLAG, true)
	_right_zone.visible = show_zones and RemoteConfig.is_enabled(OFFERS_FLAG, true)


func _clear_items(items: VBoxContainer) -> void:
	for child in items.get_children():
		items.remove_child(child)
		child.queue_free()

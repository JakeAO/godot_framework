extends GutTest
## Home side-zone behavior (GDD §6 / TDD §3.11): zone placement via
## metadata.zone, widget strip priority, campaign claim flow, live expiry
## removal and metadata tap dialogs. A standalone ScreenShell mounts on a
## phone-sized host; RemoteConfig is pointed at a throwaway config so every
## test starts from known zone content.

var _host: Control
var _shell: ScreenShell = null
var _original_config_path: String = ""
var _original_cache_path: String = ""
var _original_save_path: String = ""
var _temp_config_path: String = ""
var _temp_cache_path: String = ""
var _temp_save_path: String = ""


func before_all() -> void:
	DirAccess.make_dir_recursive_absolute("user://gut_tmp")
	_host = Control.new()
	# Phone-sized test host so zone rects match the real 720x1280 layout.
	_host.custom_minimum_size = Vector2(720, 1280)
	_host.size = Vector2(720, 1280)
	add_child(_host)


func after_all() -> void:
	UIManager.close_current_dialog()
	UIManager.clear_toasts()
	if is_instance_valid(_host):
		_host.queue_free()


func before_each() -> void:
	_original_config_path = RemoteConfig._config_path
	_original_cache_path = RemoteConfig._cache_path
	_original_save_path = SaveSystem.get_save_path()
	var stamp := Time.get_ticks_usec()
	_temp_config_path = "user://gut_tmp/shell_%d.json" % stamp
	_temp_cache_path = "user://gut_tmp/shell_cache_%d.json" % (stamp + 1)
	_temp_save_path = "user://gut_tmp/shell_save_%d.json" % (stamp + 2)
	SaveSystem.set_save_path(_temp_save_path)
	SaveSystem.load_save()
	_reset_remote_config()
	RemoteConfig.set_config_path(_temp_config_path)
	RemoteConfig.set_cache_path(_temp_cache_path)
	_write_config()
	RemoteConfig.fetch()
	_shell = ScreenShell.new()
	_host.add_child(_shell)


func after_each() -> void:
	if is_instance_valid(_shell):
		_host.remove_child(_shell)
		_shell.queue_free()
	_shell = null
	UIManager.close_current_dialog()
	UIManager.clear_toasts()
	RemoteConfig.set_config_path(_original_config_path)
	RemoteConfig.set_cache_path(_original_cache_path)
	SaveSystem.set_save_path(_original_save_path)
	var paths: Array[String] = [_temp_config_path, _temp_cache_path, _temp_save_path]
	for p in paths:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
		var tmp := p + ".tmp"
		if FileAccess.file_exists(tmp):
			DirAccess.remove_absolute(tmp)


# --- Placement -------------------------------------------------------------------

func test_zone_placement_respects_metadata_zone() -> void:
	# Left zone (default): fixed gift-pile slot + 2 left events + 3 default-zone campaigns.
	assert_eq(_shell._left_items.get_child_count(), 6, "left zone holds the default-zone entries")
	# Right zone: 1 right event + 1 right campaign + 1 offer.
	assert_eq(_shell._right_items.get_child_count(), 3, "right zone holds offers plus right-zone entries")


func test_inactive_and_claimed_entries_filtered_at_rebuild() -> void:
	var now := Time.get_unix_time_from_system()
	RemoteConfig._event_deadlines["ev_timed"] = now - 10
	SaveSystem.set_value("campaign_claims", "camp_claim", now)
	_shell._rebuild_zones()
	assert_false(_shell._event_cards.has("ev_timed"), "expired event not rebuilt")
	assert_false(_shell._campaign_cards.has("camp_claim"), "claimed campaign not rebuilt")
	assert_eq(_shell._left_items.get_child_count(), 4, "filtered entries leave the zone empty of their widgets")


# --- Strip priority ----------------------------------------------------------------

func test_strip_priority_claim_over_progress_over_countdown() -> void:
	var claim_card: Dictionary = _shell._campaign_cards["camp_claim"]
	assert_true(claim_card.has("button"), "claim campaign shows a claim button")
	assert_eq(str(claim_card.get("strip_kind", "")), "", "claim button wins the strip (no countdown)")
	var xp_card: Dictionary = _shell._campaign_cards["camp_xp"]
	assert_eq(str(xp_card.get("strip_kind", "")), "countdown", "timed non-claim campaign falls back to a countdown")
	var progress_card: Dictionary = _shell._campaign_cards["camp_progress"]
	assert_eq(str(progress_card.get("strip_kind", "")), "progress", "progress metadata renders a progress strip")
	assert_eq((progress_card["strip_label"] as Label).text, "2/5", "progress strip shows current/goal")


# --- Campaign claim flow -----------------------------------------------------------

func test_campaign_claim_grants_reward_stamps_and_removes_widget() -> void:
	var coins_before := int(SaveSystem.get_value("profile", "coins", 0))
	watch_signals(EventBus)
	watch_signals(UIManager.toast_host)
	# Phase F2: the strip button opens the campaign's zone dialog; the grant
	# happens inside it (GDD §8 — only the surface moved).
	(_shell._campaign_cards["camp_claim"]["button"] as Button).pressed.emit()
	assert_true(UIManager.is_dialog_open(), "claim button opens the campaign's zone dialog")
	(_shell._open_dialog as ZoneDialog).action_requested.emit("claim")
	assert_false(UIManager.is_dialog_open(), "dialog closes after a successful claim")
	assert_eq(int(SaveSystem.get_value("profile", "coins", -1)), coins_before + 50, "claim reward credited")
	assert_true(SaveSystem.get_domain("campaign_claims").has("camp_claim"), "claim stamped in campaign_claims")
	assert_false(_shell._campaign_cards.has("camp_claim"), "claimed widget removed from tracking")
	assert_eq(_shell._left_items.get_child_count(), 5, "claimed widget removed from the zone")
	assert_signal_emitted(EventBus, "currency_changed", "currency change announced on the bus")
	assert_signal_emitted(EventBus, "profile_updated", "profile update announced on the bus")
	# H2 toast policy: a claim is the direct effect of the tap — no success
	# toast (while the dialog was open one would be gated into the queue and
	# pop after close, so pin the empty queue too).
	assert_signal_not_emitted(UIManager.toast_host, "toast_shown", "claim shows no success toast")
	assert_eq(UIManager.toast_host.queued_count(), 0, "claim leaves nothing in the toast queue")


func test_campaign_claim_is_once_per_id() -> void:
	(_shell._campaign_cards["camp_claim"]["button"] as Button).pressed.emit()
	(_shell._open_dialog as ZoneDialog).action_requested.emit("claim")
	# The widget is gone after the first claim; a second direct call must no-op.
	var coins_after_first := int(SaveSystem.get_value("profile", "coins", 0))
	assert_false(_shell._on_campaign_pressed("camp_claim"), "second claim attempt returns false")
	assert_eq(int(SaveSystem.get_value("profile", "coins", -1)), coins_after_first, "second claim attempt grants nothing")


# --- Expiry removal ------------------------------------------------------------------

func test_expired_entries_removed_on_tick() -> void:
	var now := Time.get_unix_time_from_system()
	RemoteConfig._event_deadlines["ev_timed"] = now - 10
	RemoteConfig._campaign_deadlines["camp_xp"] = now - 10
	assert_eq(_shell._left_items.get_child_count(), 6, "baseline: all left-zone widgets present")
	_shell._on_tick()
	assert_false(_shell._event_cards.has("ev_timed"), "expired event reaped on tick")
	assert_false(_shell._campaign_cards.has("camp_xp"), "expired campaign reaped on tick")
	assert_eq(_shell._left_items.get_child_count(), 4, "both expired widgets removed from the zone")


# --- Tap dialogs ---------------------------------------------------------------------

func test_metadata_dialog_opens_on_tap() -> void:
	var card: Dictionary = _shell._event_cards["ev_dialog"]
	var slot: Control = card["slot"]
	assert_eq(slot.mouse_filter, Control.MOUSE_FILTER_STOP, "dialog card slot is input-active")
	slot.gui_input.emit(_make_click(Vector2.ZERO))
	assert_true(UIManager.is_dialog_open(), "tapping the widget opens its metadata dialog")


func test_card_without_dialog_stays_input_transparent() -> void:
	var card: Dictionary = _shell._event_cards["ev_timed"]
	var slot: Control = card["slot"]
	assert_eq(slot.mouse_filter, Control.MOUSE_FILTER_IGNORE, "non-dialog card stays input-transparent")
	slot.gui_input.emit(_make_click(Vector2.ZERO))
	assert_false(UIManager.is_dialog_open(), "no dialog opens for a card without metadata.dialog")


# --- Zone flags ------------------------------------------------------------------------

func test_zone_flags_gate_zones() -> void:
	RemoteConfig._flags["events_zone_enabled"] = false
	_shell._update_zone_visibility()
	assert_false(_shell._left_zone.visible, "events flag off hides the left zone")
	assert_true(_shell._right_zone.visible, "offers flag still on keeps the right zone visible")
	RemoteConfig._flags["offers_zone_enabled"] = false
	_shell._update_zone_visibility()
	assert_false(_shell._right_zone.visible, "offers flag off hides the right zone")


# --- Helpers ---------------------------------------------------------------------------

func _reset_remote_config() -> void:
	RemoteConfig._loaded = false
	RemoteConfig._flags = {}
	RemoteConfig._values = {}
	RemoteConfig._experiments = {}
	RemoteConfig._events.clear()
	RemoteConfig._campaigns.clear()
	RemoteConfig._offers.clear()
	RemoteConfig._event_deadlines.clear()
	RemoteConfig._campaign_deadlines.clear()
	RemoteConfig._exposed_this_session = {}
	RemoteConfig._device_id = ""


## Known zone content exercising every card shape:
## events: timed (left), dialog-only evergreen (left), right-zone timed.
## campaigns: claim (left), timed xp modifier (left), progress display (left),
##            right-zone gem claim. offers: daily gift.
func _write_config() -> void:
	var config := {
		"flags": { "events_zone_enabled": true, "offers_zone_enabled": true },
		"values": {},
		"experiments": {},
		"events": [
			{ "id": "ev_timed", "title": "Timed Event", "icon": "trophy", "ends_in_hours": 24 },
			{ "id": "ev_dialog", "title": "Dialog Event", "icon": "crown", "metadata": { "dialog": { "title": "Ev Title", "body": "Ev Body" } } },
			{ "id": "ev_right", "title": "Right Event", "icon": "chat", "ends_in_hours": 10, "metadata": { "zone": "right" } },
		],
		"campaigns": [
			{ "id": "camp_claim", "title": "Claim Camp", "icon": "coin", "action": "claim", "reward_currency": "coins", "reward_amount": 50 },
			{ "id": "camp_xp", "title": "XP Camp", "icon": "xp", "ends_in_hours": 9, "action": "modifier", "modifies": "xp", "multiplier": 2 },
			{ "id": "camp_progress", "title": "Progress Camp", "icon": "booster", "metadata": { "progress": { "current": 2, "goal": 5 } } },
			{ "id": "camp_right", "title": "Right Camp", "icon": "team", "action": "claim", "reward_currency": "gems", "reward_amount": 3, "metadata": { "zone": "right" } },
		],
		"offers": [
			{ "id": "daily_gift", "kind": "daily_gift", "title": "Daily Gift", "icon": "gift", "reward_currency": "coins", "reward_amount": 50, "cooldown_hours": 24 },
		],
	}
	var out := FileAccess.open(_temp_config_path, FileAccess.WRITE)
	out.store_string(JSON.stringify(config))
	out.close()


func _make_click(pos: Vector2) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = pos
	event.global_position = pos
	event.pressed = true
	return event

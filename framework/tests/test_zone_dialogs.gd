extends GutTest
## Phase F2 zone widget dialogs (GDD §8 / TDD §3.21): every offer/campaign
## widget opens its kind's state-driven ZoneDialog on tap; claims, RV extras,
## piggy redemption and streak claim/recovery run through the dialog while the
## shell keeps all save mutations. A standalone ScreenShell mounts on a
## phone-sized host with an F2 config (daily gift + piggy bank + booster offers,
## live streak campaign).

class FakeResult:
	var failed := false
	func is_exception() -> bool:
		return failed
	func get_exception() -> String:
		return "fake failure"


class FakeRecord:
	var owner_id := ""
	var username := ""
	var score := "0"
	var rank := "0"
	func is_exception() -> bool:
		return false
	func get_exception() -> String:
		return ""


class FakeRecordList:
	var records: Array = []
	var owner_records: Array = []
	func is_exception() -> bool:
		return false
	func get_exception() -> String:
		return ""


## Minimal real-mode client for the leaderboard dialog tests (TDD §3.26): boot
## methods + the two listing calls; writes are not exercised here.
class FakeLeaderboardClient:
	var session_factory: Callable
	var list_calls: Array[Dictionary] = []
	var list_result: Variant = null
	var around_result: Variant = null

	func authenticate_custom_async(_key: String, _username = null, _create: bool = true, _vars = null) -> NakamaSession:
		return session_factory.call() as NakamaSession

	func get_account_async(_session) -> NakamaAPI.ApiAccount:
		return NakamaAPI.ApiAccount.create(NakamaAPI, {
			"user": {"id": "test-user-1", "username": "TestUser"},
			"custom_id": "key-1",
		})

	func write_storage_objects_async(_session, _objects):
		return null

	func list_leaderboard_records_async(_session, lb_id: String, owner_ids = null, _expiry = null, limit: int = 10, _cursor = null):
		list_calls.append({"lb_id": lb_id, "owner_ids": owner_ids, "limit": limit})
		if list_result != null:
			return list_result
		return FakeRecordList.new()

	func list_leaderboard_records_around_owner_async(_session, _lb_id: String, _owner_id: String, _expiry = null, _limit: int = 10, _cursor = null):
		if around_result != null:
			return around_result
		return FakeRecordList.new()


## Matchmaking fakes (TDD §3.27): the bridge constructor is typed NakamaSocket,
## so the socket SUBCLASSES the real addon class; the adapter stands in for the
## websocket transport. Same shape as tests/test_matchmaking_service.gd — kept
## local per this suite's self-contained convention.
class FakeAdapter extends NakamaSocketAdapter:
	func close():
		pass


class FakeSocket extends NakamaSocket:
	var join_matched_calls: Array = []
	## Set by the test (an inner-class fake is a RefCounted — no scene tree of its own).
	var scene_tree: SceneTree = null

	func _init(p_adapter : NakamaSocketAdapter, p_host: String = "localhost", p_port: int = 7350, p_scheme: String = "ws", p_free_adapter: bool = false) -> void:
		super(p_adapter, p_host, p_port, p_scheme, p_free_adapter)

	func connect_async(_p_session : NakamaSession, _p_appear_online : bool = false, _p_connect_timeout : int = 3):
		return NakamaAsyncResult.new()

	func add_matchmaker_async(_p_query : String = "*", _p_min_count : int = 2, _p_max_count : int = 8, _p_string_props : Dictionary = {}, _p_numeric_props : Dictionary = {}, _p_count_multiple : int = 0) -> NakamaRTAPI.MatchmakerTicket:
		return NakamaRTAPI.MatchmakerTicket.create(NakamaRTAPI, {"ticket": "tick-1"})

	func remove_matchmaker_async(_p_ticket : String) -> NakamaAsyncResult:
		return NakamaAsyncResult.new()

	func join_matched_async(p_matched):
		join_matched_calls.append(p_matched)
		# One frame of latency = the real server round trip. This makes the
		# matched phase observable (the UI renders opponents before in_match).
		if scene_tree != null:
			await scene_tree.process_frame
		return _ok_match()

	func leave_match_async(_p_match_id : String) -> NakamaAsyncResult:
		return NakamaAsyncResult.new()

	func send_match_state_async(_p_match_id, _p_op_code : int, _p_data : String, _p_presences = null):
		pass

	func close():
		pass

	static func _ok_match() -> NakamaRTAPI.Match:
		return NakamaRTAPI.Match.create(NakamaRTAPI, {
			"match_id": "match-1",
			"self": {"session_id": "aaa", "user_id": "test-user-1", "username": "TestUser"},
			"presences": [
				{"session_id": "bbb", "user_id": "user-x", "username": "XCode"},
			],
		})


var _host: Control
var _shell: ScreenShell = null
var _fake_lb_client: FakeLeaderboardClient = null
var _fake_mm_socket: FakeSocket = null
var _fake_mm_adapter: FakeAdapter = null
var _original_config_path: String = ""
var _original_cache_path: String = ""
var _original_save_path: String = ""
var _temp_config_path: String = ""
var _temp_cache_path: String = ""
var _temp_save_path: String = ""


func before_all() -> void:
	DirAccess.make_dir_recursive_absolute("user://gut_tmp")
	_host = Control.new()
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
	_temp_config_path = "user://gut_tmp/zd_%d.json" % stamp
	_temp_cache_path = "user://gut_tmp/zd_cache_%d.json" % (stamp + 1)
	_temp_save_path = "user://gut_tmp/zd_save_%d.json" % (stamp + 2)
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
	MatchmakingService.cancel()
	MatchmakingService.reset_socket_factory()
	if _fake_mm_socket != null:
		_fake_mm_socket = null
	if _fake_mm_adapter != null:
		_fake_mm_adapter.free()
		_fake_mm_adapter = null
	OnlineService.reset_to_mock_mode()
	SocialManager._reset_caches()
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


# --- Opening the dialogs ---------------------------------------------------------

func test_offer_tap_opens_its_kind_dialog() -> void:
	var slot: Control = _shell._offer_states["daily_gift"]["slot"]
	slot.gui_input.emit(_make_click())
	assert_true(UIManager.is_dialog_open(), "tapping an offer widget opens a dialog")
	assert_eq((_shell._open_dialog as ZoneDialog).kind, ZoneDialog.DAILY_GIFT_KIND, "daily gift opens its kind's dialog")
	UIManager.close_current_dialog()


func test_campaign_tap_opens_streak_dialog() -> void:
	var slot: Control = _shell._campaign_cards["streak_bonus"]["slot"]
	slot.gui_input.emit(_make_click())
	assert_true(UIManager.is_dialog_open(), "tapping the streak widget opens a dialog")
	assert_eq((_shell._open_dialog as ZoneDialog).kind, ZoneDialog.STREAK_KIND, "streak campaign opens the streak dialog")
	UIManager.close_current_dialog()


# --- Streak widget strip -----------------------------------------------------------

func test_streak_widget_renders_live_progress_strip() -> void:
	var card: Dictionary = _shell._campaign_cards["streak_bonus"]
	assert_eq(str(card.get("strip_kind", "")), "progress", "streak widget shows a progress strip")
	assert_eq((card["strip_label"] as Label).text, "0/5", "fresh profile renders 0 / table length")
	SaveSystem.set_value("profile", "streak_days", 3)
	_shell._refresh_streak_strips()
	assert_eq((card["strip_label"] as Label).text, "3/5", "strip tracks the live streak")


# --- Daily gift --------------------------------------------------------------------

func test_daily_gift_free_claim_via_dialog_credits_and_stamps() -> void:
	var coins_before := int(SaveSystem.get_value("profile", "coins", 0))
	watch_signals(UIManager.toast_host)
	var dialog := _open_offer_dialog("daily_gift")
	var claim := _find_button(dialog, tr("offer_claim"))
	assert_not_null(claim, "unclaimed gift offers a Claim button")
	claim.pressed.emit()
	await _await_dialog_close()
	assert_eq(int(SaveSystem.get_value("profile", "coins", -1)), coins_before + 50, "free claim credits the gift")
	assert_eq(str(SaveSystem.get_value("profile", "last_daily_claim_day", "")), _today(), "claim stamped with today's date")
	_assert_no_claim_toast("daily gift claim")


func test_daily_gift_extra_watches_grant_until_cap() -> void:
	assert_true(_shell._claim_daily_gift("daily_gift"), "free claim applies first")
	assert_true(_shell._grant_daily_gift_extra("daily_gift"), "first RV extra grants")
	assert_true(_shell._grant_daily_gift_extra("daily_gift"), "second RV extra grants (cap 2)")
	assert_false(_shell._grant_daily_gift_extra("daily_gift"), "third watch is rejected at the cap")
	var profile: Dictionary = SaveSystem.get_domain("profile")
	assert_eq(int(profile.get("daily_gift_watches_count", -1)), 2, "date-keyed counter stops at the cap")
	assert_eq(str(profile.get("daily_gift_watches_date", "")), _today(), "counter is date-keyed to today")


func test_daily_gift_extras_reset_on_new_day() -> void:
	SaveSystem.set_value("profile", "last_daily_claim_day", _today())
	SaveSystem.set_value("profile", "daily_gift_watches_date", _yesterday())
	SaveSystem.set_value("profile", "daily_gift_watches_count", 2)
	assert_true(_shell._grant_daily_gift_extra("daily_gift"), "a new day resets the extra-watch counter")
	var profile: Dictionary = SaveSystem.get_domain("profile")
	assert_eq(int(profile.get("daily_gift_watches_count", -1)), 1, "counter restarts from one on the new day")


# --- Piggy bank redemption -----------------------------------------------------------

func test_piggy_below_threshold_collect_is_noop() -> void:
	SaveSystem.set_value("piggy_bank", "balance", 100)
	var coins_before := int(SaveSystem.get_value("profile", "coins", 0))
	var dialog := _open_offer_dialog("piggy_bank")
	dialog.action_requested.emit(ZoneDialog.ACTION_COLLECT_RV)
	assert_eq(int(SaveSystem.get_value("piggy_bank", "balance", -1)), 100, "below threshold the balance is untouched")
	assert_eq(int(SaveSystem.get_value("profile", "coins", -1)), coins_before, "no coins granted below threshold")
	assert_true(UIManager.is_dialog_open(), "dialog stays open (refreshed) when the collect is rejected")
	UIManager.close_current_dialog()


func test_piggy_at_threshold_collect_iap_grants_full_balance() -> void:
	SaveSystem.set_value("piggy_bank", "balance", 150)
	var coins_before := int(SaveSystem.get_value("profile", "coins", 0))
	watch_signals(EventBus)
	watch_signals(UIManager.toast_host)
	var dialog := _open_offer_dialog("piggy_bank")
	dialog.action_requested.emit(ZoneDialog.ACTION_COLLECT_IAP)
	await _await_dialog_close()
	assert_eq(int(SaveSystem.get_value("profile", "coins", -1)), coins_before + 150, "collect grants the entire balance")
	assert_eq(int(SaveSystem.get_value("piggy_bank", "balance", -1)), 0, "balance resets to zero")
	assert_signal_emitted_with_parameters(EventBus, "piggy_bank_changed", [0])
	_assert_no_claim_toast("piggy collect")


func test_piggy_collect_rv_failure_keeps_balance() -> void:
	SaveSystem.set_value("piggy_bank", "balance", 150)
	AdManager.debug_fail_next_rewarded()
	var dialog := _open_offer_dialog("piggy_bank")
	dialog.action_requested.emit(ZoneDialog.ACTION_COLLECT_RV)
	assert_eq(int(SaveSystem.get_value("piggy_bank", "balance", -1)), 150, "a failed RV watch collects nothing")
	var note := _find_label_with(dialog, tr("dlg_ad_failed"))
	assert_not_null(note, "the dialog shows the inline failure note")
	UIManager.close_current_dialog()


func test_piggy_strip_shows_threshold_progress_then_claim() -> void:
	SaveSystem.set_value("piggy_bank", "balance", 30)
	_shell._refresh_offers()
	var button: Button = _shell._offer_states["piggy_bank"]["button"]
	assert_eq(button.text, "30/150", "below threshold the strip shows balance/threshold")
	assert_true(button.disabled, "collect is disabled below threshold")
	SaveSystem.set_value("piggy_bank", "balance", 150)
	_shell._refresh_offers()
	assert_eq(button.text, tr("offer_claim"), "at threshold the strip offers a claim")
	assert_false(button.disabled, "collect is enabled at threshold")


# --- Streak dialog --------------------------------------------------------------------

func test_streak_claim_via_dialog_credits_and_advances() -> void:
	_set_profile({"streak_date": _today(), "streak_rounds_today": 1, "streak_days": 0})
	var coins_before := int(SaveSystem.get_value("profile", "coins", 0))
	watch_signals(UIManager.toast_host)
	var dialog := _open_campaign_dialog("streak_bonus")
	var claim := _find_button(dialog, tr("offer_claim"))
	assert_not_null(claim, "met requirement offers a Claim button")
	claim.pressed.emit()
	assert_false(UIManager.is_dialog_open(), "no sprite art: the dialog closes immediately")
	var profile: Dictionary = SaveSystem.get_domain("profile")
	assert_eq(int(SaveSystem.get_value("profile", "coins", -1)), coins_before + 50, "first claim pays rewards[0]")
	assert_eq(int(profile.get("streak_days", -1)), 1, "streak advanced")
	assert_eq(str(profile.get("streak_last_date", "")), _today(), "last claim stamped today")
	_assert_no_claim_toast("streak claim")


func test_streak_recover_coins_deducts_then_claim_continues() -> void:
	_set_profile({"streak_days": 2, "streak_last_date": _days_ago(3), "streak_date": _today(), "streak_rounds_today": 1, "coins": 300})
	var dialog := _open_campaign_dialog("streak_bonus")
	dialog.action_requested.emit(ZoneDialog.ACTION_RECOVER_COINS)
	var profile: Dictionary = SaveSystem.get_domain("profile")
	assert_eq(int(profile.get("coins", -1)), 100, "recovery cost deducted")
	assert_eq(str(profile.get("streak_last_date", "")), _yesterday(), "last claim back-dated to yesterday")
	assert_true(bool(profile.get("streak_recovered", false)), "one-shot recovery flag armed")
	dialog.action_requested.emit(ZoneDialog.ACTION_CLAIM)
	profile = SaveSystem.get_domain("profile")
	assert_eq(int(profile.get("coins", -1)), 200, "post-recovery claim continues the streak (rewards[2]=100)")
	assert_eq(int(profile.get("streak_days", -1)), 3, "streak length continued, not restarted")


func test_streak_recover_rv_failure_keeps_state() -> void:
	_set_profile({"streak_days": 2, "streak_last_date": _days_ago(3), "streak_date": _today(), "streak_rounds_today": 1, "coins": 0})
	AdManager.debug_fail_next_rewarded()
	var dialog := _open_campaign_dialog("streak_bonus")
	dialog.action_requested.emit(ZoneDialog.ACTION_RECOVER_RV)
	var profile: Dictionary = SaveSystem.get_domain("profile")
	assert_eq(str(profile.get("streak_last_date", "")), _days_ago(3), "a failed RV watch does not recover the streak")
	assert_false(bool(profile.get("streak_recovered", false)), "recovery flag stays disarmed")
	var note := _find_label_with(dialog, tr("dlg_ad_failed"))
	assert_not_null(note, "the dialog shows the inline failure note")
	UIManager.close_current_dialog()


func test_streak_coin_recovery_button_disabled_when_unaffordable() -> void:
	_set_profile({"streak_days": 2, "streak_last_date": _days_ago(3), "streak_date": _today(), "streak_rounds_today": 1, "coins": 50})
	var dialog := _open_campaign_dialog("streak_bonus")
	var pay := _find_button(dialog, tr("dlg_streak_recover_coins") % [200])
	assert_not_null(pay, "broken streak offers the coin recovery option")
	assert_true(pay.disabled, "coin recovery is disabled when unaffordable")
	UIManager.close_current_dialog()


# --- Booster offer ---------------------------------------------------------------------

func test_booster_offer_claim_via_dialog_then_cooldown() -> void:
	var gems_before := int(SaveSystem.get_value("profile", "gems", 0))
	watch_signals(UIManager.toast_host)
	var dialog := _open_offer_dialog("rv_booster")
	dialog.action_requested.emit(ZoneDialog.ACTION_CLAIM)
	assert_false(UIManager.is_dialog_open(), "claim closes the dialog (no sprite art)")
	assert_eq(int(SaveSystem.get_value("profile", "gems", -1)), gems_before + 5, "booster reward credited")
	assert_true(SaveSystem.get_domain("offers").has("rv_booster"), "cooldown stamp written")
	_assert_no_claim_toast("booster claim")
	var reopened := _open_offer_dialog("rv_booster")
	assert_null(_find_button(reopened, tr("offer_claim")), "in cooldown the dialog shows a countdown instead of Claim")
	UIManager.close_current_dialog()


# --- Leaderboards (TDD §3.26) ----------------------------------------------------

func test_leaderboards_widget_tap_opens_offline_dialog_in_mock_mode() -> void:
	var slot: Control = _shell._event_cards["leaderboards"]["slot"]
	slot.gui_input.emit(_make_click())
	assert_true(UIManager.is_dialog_open(), "tapping the leaderboards widget opens a dialog")
	var dialog := _shell._open_dialog as ZoneDialog
	assert_eq(dialog.kind, ZoneDialog.LEADERBOARDS_KIND, "leaderboards event opens its kind's dialog")
	assert_not_null(_find_label_with(dialog, tr("dlg_leaderboards_offline")), "mock mode renders the disabled state")
	assert_null(_find_button(dialog, tr("dlg_leaderboards_scope_global")), "offline: no scope toggle")
	UIManager.close_current_dialog()


func test_leaderboards_dialog_renders_global_rows_in_real_mode() -> void:
	await _go_real()
	var list := FakeRecordList.new()
	list.records = [
		_make_record("user-x", "XCode", 999, 1),
		_make_record("test-user-1", "TestUser", 500, 2),
	]
	_fake_lb_client.list_result = list
	var slot: Control = _shell._event_cards["leaderboards"]["slot"]
	slot.gui_input.emit(_make_click())
	var dialog := _shell._open_dialog as ZoneDialog
	assert_not_null(_find_button(dialog, tr("dlg_leaderboards_scope_global")), "global scope toggle present")
	assert_not_null(_find_button(dialog, tr("dlg_leaderboards_scope_friends")), "friends scope toggle present")
	await _settle(10)
	var rows := _find_label_containing(dialog, "1. XCode — 999")
	assert_not_null(rows, "top row rendered (rank. name — score)")
	assert_true(rows.text.contains("2. TestUser — 500"), "own row rendered from the list")
	UIManager.close_current_dialog()


func test_leaderboards_dialog_friends_scope_lists_by_friend_ids() -> void:
	await _go_real()
	var friends: Array[Dictionary] = await SocialManager.fetch_friends()
	var expected: Array[String] = []
	for row in friends:
		expected.append(str(row.get("user_id", "")))
	assert_gt(expected.size(), 0, "mock backend seeds friends with user ids")
	var list := FakeRecordList.new()
	list.records = [_make_record("user-x", "XCode", 999, 1)]
	list.owner_records = [_make_record(expected[0], "FriendOne", 321, 1)]
	_fake_lb_client.list_result = list

	var slot: Control = _shell._event_cards["leaderboards"]["slot"]
	slot.gui_input.emit(_make_click())
	var dialog := _shell._open_dialog as ZoneDialog
	await _settle(10)
	var friends_button := _find_button(dialog, tr("dlg_leaderboards_scope_friends"))
	assert_not_null(friends_button, "friends toggle present")
	friends_button.pressed.emit()
	await _settle(10)
	var friend_call: Dictionary = _fake_lb_client.list_calls.back()
	var sent: Variant = friend_call.get("owner_ids", null)
	assert_true(sent is Array and (sent as Array).size() == expected.size(), "friends scope sends the full friend id set")
	assert_not_null(_find_label_containing(dialog, "1. FriendOne — 321"), "friend rows rendered in the friends scope")
	UIManager.close_current_dialog()


# --- Matchmaking (TDD §3.27) ----------------------------------------------------

func test_matchmaking_widget_tap_opens_offline_dialog_in_mock_mode() -> void:
	var slot: Control = _shell._event_cards["matchmaking"]["slot"]
	slot.gui_input.emit(_make_click())
	assert_true(UIManager.is_dialog_open(), "tapping the matchmaking widget opens a dialog")
	var dialog := _shell._open_dialog as ZoneDialog
	assert_eq(dialog.kind, ZoneDialog.MATCHMAKING_KIND, "matchmaking event opens its kind's dialog")
	assert_not_null(_find_label_with(dialog, tr("dlg_matchmaking_offline")), "mock mode renders the disabled state")
	assert_null(_find_button(dialog, tr("matchmaking_find")), "offline: no Find button")
	UIManager.close_current_dialog()


func test_matchmaking_dialog_idle_real_mode_offers_find() -> void:
	await _go_real()
	var slot: Control = _shell._event_cards["matchmaking"]["slot"]
	slot.gui_input.emit(_make_click())
	var dialog := _shell._open_dialog as ZoneDialog
	assert_not_null(_find_button(dialog, tr("matchmaking_find")), "idle real mode offers Find match")
	assert_null(_find_button(dialog, tr("matchmaking_cancel")), "idle: no Cancel button")
	UIManager.close_current_dialog()


func test_matchmaking_dialog_drives_queue_through_live_states() -> void:
	await _go_real()
	_fake_mm_adapter = FakeAdapter.new()
	_fake_mm_socket = FakeSocket.new(_fake_mm_adapter)
	_fake_mm_socket.scene_tree = get_tree()
	MatchmakingService._socket_factory = func(): return _fake_mm_socket

	var slot: Control = _shell._event_cards["matchmaking"]["slot"]
	slot.gui_input.emit(_make_click())
	var dialog := _shell._open_dialog as ZoneDialog
	dialog.action_requested.emit(ZoneDialog.ACTION_MATCHMAKING_FIND)
	assert_true(await _wait_for_state(MatchmakingService.STATE_QUEUED), "Find enqueues into the queue")
	await _settle(2)
	assert_not_null(_find_label_with(dialog, tr("dlg_matchmaking_queued")), "queued body rendered live (dialog re-rendered on the state emit)")
	assert_not_null(_find_button(dialog, tr("matchmaking_cancel")), "queued offers Cancel")

	_fake_mm_socket.received_matchmaker_matched.emit(_make_matched())
	# The service's handler runs first in the dispatch (connection order), so by
	# the time emit returns the matched-phase UI is rendered and the join ack is
	# still one frame away (the fake simulates the server round trip).
	assert_eq(MatchmakingService.get_state(), MatchmakingService.STATE_MATCHED, "matched state reached from the fake socket event")
	assert_not_null(_find_label_with(dialog, "XCode"), "opponent row rendered from the service (self excluded)")
	assert_null(_find_button(dialog, tr("matchmaking_leave")), "Leave appears only once the room is live")

	assert_true(await _wait_for_state(MatchmakingService.STATE_IN_MATCH), "the bridge's join ack reaches in_match")
	await _settle(2)
	assert_not_null(_find_button(dialog, tr("matchmaking_leave")), "in_match offers Leave")
	UIManager.close_current_dialog()


# --- Helpers ---------------------------------------------------------------------------

func _go_real() -> void:
	_fake_lb_client = FakeLeaderboardClient.new()
	_fake_lb_client.session_factory = func() -> NakamaSession: return _ok_session()
	OnlineService.start_real_mode_with(_fake_lb_client)
	assert_true(await _wait_until_online(), "real mode with fake client reaches ONLINE")


func _settle(frames: int) -> void:
	for i in frames:
		await get_tree().process_frame


func _wait_for_state(expected: String) -> bool:
	for i in 30:
		if MatchmakingService.get_state() == expected:
			return true
		await get_tree().process_frame
	return false


static func _make_matched() -> NakamaRTAPI.MatchmakerMatched:
	# Wire shape (spike-verified): users carries ALL matched users INCLUDING self.
	return NakamaRTAPI.MatchmakerMatched.create(NakamaRTAPI, {
		"ticket": "tick-1",
		"users": [
			{"presence": {"session_id": "aaa", "user_id": "test-user-1", "username": "TestUser"}},
			{"presence": {"session_id": "bbb", "user_id": "user-x", "username": "XCode"}},
		],
		"self": {"presence": {"session_id": "aaa", "user_id": "test-user-1", "username": "TestUser"}},
	})


func _make_record(owner_id: String, username: String, score: int, rank: int) -> FakeRecord:
	var rec := FakeRecord.new()
	rec.owner_id = owner_id
	rec.username = username
	rec.score = str(score)
	rec.rank = str(rank)
	return rec


static func _ok_session() -> NakamaSession:
	var header := JSON.stringify({"alg": "HS256", "typ": "JWT"})
	var payload := JSON.stringify({
		"exp": int(Time.get_unix_time_from_system()) + 3600,
		"uid": "test-user-1",
		"usn": "TestUser",
	})
	return NakamaSession.new(_b64url(header) + "." + _b64url(payload) + ".sig")


static func _b64url(text: String) -> String:
	return Marshalls.utf8_to_base64(text).replace("+", "-").replace("/", "_").replace("=", "")


func _wait_until_online() -> bool:
	for i in 30:
		if OnlineService.is_online():
			return true
		await get_tree().process_frame
	return false


func _find_label_containing(root: Control, text: String) -> Label:
	for node in _collect_nodes(root):
		var label := node as Label
		if label != null and label.text.contains(text):
			return label
	return null


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


func _write_config() -> void:
	var config := {
		"flags": { "events_zone_enabled": true, "offers_zone_enabled": true },
		"values": {
			"daily_gift_extra_watches": 2,
			"piggy_bank_capacity": 200,
			"piggy_redemption_threshold": 150,
			"piggy_deposit_per_stage": 10,
			"streak_min_rounds_per_day": 1,
			"streak_rewards": [50, 75, 100, 125, 150],
			"streak_recovery_coins": 200,
		},
		"experiments": {},
		"events": [
			{ "id": "leaderboards", "title": "Leaderboards", "subtitle": "Best scores — global & friends", "kind": "leaderboards", "icon": "crown" },
			{ "id": "matchmaking", "title": "Matchmaking", "subtitle": "Find an opponent", "kind": "matchmaking", "icon": "team" },
		],
		"campaigns": [
			{ "id": "streak_bonus", "title": "Streak Bonus", "icon": "crown", "kind": "streak" },
		],
		"offers": [
			{ "id": "daily_gift", "kind": "daily_gift", "title": "Daily Gift", "icon": "gift", "reward_currency": "coins", "reward_amount": 50, "cooldown_hours": 24 },
			{ "id": "piggy_bank", "kind": "piggy_bank", "title": "Piggy Bank", "icon": "bank", "reward_currency": "coins", "reward_amount": 0, "cooldown_hours": 24 },
			{ "id": "rv_booster", "kind": "booster", "title": "Booster Pack", "icon": "booster", "reward_currency": "gems", "reward_amount": 5, "cooldown_hours": 72 },
		],
	}
	var out := FileAccess.open(_temp_config_path, FileAccess.WRITE)
	out.store_string(JSON.stringify(config))
	out.close()


func _open_offer_dialog(offer_id: String) -> ZoneDialog:
	var slot: Control = _shell._offer_states[offer_id]["slot"]
	slot.gui_input.emit(_make_click())
	assert_true(UIManager.is_dialog_open(), "opening the dialog for offer '%s'" % offer_id)
	return _shell._open_dialog


func _open_campaign_dialog(campaign_id: String) -> ZoneDialog:
	var slot: Control = _shell._campaign_cards[campaign_id]["slot"]
	slot.gui_input.emit(_make_click())
	assert_true(UIManager.is_dialog_open(), "opening the dialog for campaign '%s'" % campaign_id)
	return _shell._open_dialog


func _set_profile(values: Dictionary) -> void:
	var profile: Dictionary = SaveSystem.get_domain("profile")
	for key in values:
		profile[key] = values[key]
	SaveSystem.set_domain("profile", profile)


## Waits for a sprite-opening clip to finish and the dialog to close.
func _await_dialog_close(limit_ticks: int = 900) -> void:
	var ticks := 0
	while UIManager.is_dialog_open() and ticks < limit_ticks:
		await get_tree().process_frame
		ticks += 1


## H2 toast policy: a claim/collect is the direct effect of the tap — no
## success toast. While a dialog is open, toasts are gated into the queue and
## would pop right after close, so pin BOTH that nothing was shown and that
## nothing lingers in the queue. Call after watch_signals(UIManager.toast_host).
func _assert_no_claim_toast(what: String) -> void:
	assert_signal_not_emitted(UIManager.toast_host, "toast_shown", what + ": no success toast")
	assert_eq(UIManager.toast_host.queued_count(), 0, what + ": nothing left in the toast queue")


func _find_button(root: Control, text: String) -> Button:
	for node in _collect_nodes(root):
		var button := node as Button
		if button != null and button.text == text:
			return button
	return null


func _find_label_with(root: Control, text: String) -> Label:
	for node in _collect_nodes(root):
		var label := node as Label
		if label != null and label.text == text:
			return label
	return null


func _collect_nodes(root: Node) -> Array[Node]:
	var found: Array[Node] = []
	for child in root.get_children():
		found.append(child)
		found.append_array(_collect_nodes(child))
	return found


func _today() -> String:
	return Time.get_date_string_from_system()


func _yesterday() -> String:
	return StreakLogic._minus_one_day(_today())


func _days_ago(n: int) -> String:
	var day := _today()
	for i in n:
		day = StreakLogic._minus_one_day(day)
	return day


func _make_click() -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = Vector2.ZERO
	event.global_position = Vector2.ZERO
	event.pressed = true
	return event

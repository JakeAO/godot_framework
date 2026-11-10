extends GutTest
## LeaderboardService (TDD §3.26), hermetic: a duck-typed fake client stands in
## for NakamaClient (no network or addon transport), temp save/config/identity
## paths, and the OnlineService real-mode seam. The friends scope reads the
## SocialManager cache — which in this seam keeps its MOCK backend (the real
## wiring is covered by the live smoke) — so seeded mock friends provide stable
## fake user ids. after_each restores mock mode + stub config so later suites
## in the same GUT process see the default wiring.

class FakeResult:
	var failed := false
	var detail := ""
	func is_exception() -> bool:
		return failed
	func get_exception() -> String:
		return detail


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


class FakeClient:
	var session_factory: Callable
	var writes: Array[Dictionary] = []
	var list_calls: Array[Dictionary] = []
	var around_calls: Array[String] = []
	var write_should_fail := false
	var list_should_fail := false
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

	func write_leaderboard_record_async(_session, lb_id: String, score: int, _subscore: int = 0, _metadata = null):
		writes.append({"lb_id": lb_id, "score": score})
		if write_should_fail:
			var fail := FakeResult.new()
			fail.failed = true
			fail.detail = "write boom"
			return fail
		var rec := FakeRecord.new()
		rec.owner_id = "test-user-1"
		rec.score = str(score)
		return rec

	func list_leaderboard_records_async(_session, lb_id: String, owner_ids = null, _expiry = null, limit: int = 10, _cursor = null):
		list_calls.append({"lb_id": lb_id, "owner_ids": owner_ids, "limit": limit})
		if list_should_fail:
			var fail := FakeResult.new()
			fail.failed = true
			fail.detail = "list boom"
			return fail
		if list_result != null:
			return list_result
		return FakeRecordList.new()

	func list_leaderboard_records_around_owner_async(_session, _lb_id: String, owner_id: String, _expiry = null, _limit: int = 10, _cursor = null):
		around_calls.append(owner_id)
		if around_result != null:
			return around_result
		return FakeRecordList.new()


var _fake: FakeClient = null
var _original_save_path: String = ""
var _original_config_path: String = ""
var _original_identity_path: String = ""
var _temp_save_path: String = ""
var _temp_config_path: String = ""
var _temp_identity_path: String = ""


func before_all() -> void:
	DirAccess.make_dir_recursive_absolute("user://gut_tmp")


func before_each() -> void:
	var stamp := Time.get_ticks_usec()
	_original_save_path = SaveSystem.get_save_path()
	_original_config_path = RemoteConfig._config_path
	_original_identity_path = IdentityService.get_identity_path()
	_temp_save_path = "user://gut_tmp/lb_save_%d.json" % stamp
	_temp_config_path = "user://gut_tmp/lb_config_%d.json" % (stamp + 1)
	_temp_identity_path = "user://gut_tmp/lb_identity_%d.json" % (stamp + 2)
	SaveSystem.set_save_path(_temp_save_path)
	SaveSystem.load_save()
	IdentityService.set_identity_path(_temp_identity_path)
	IdentityService.clear_session()
	OnlineService.reset_to_mock_mode()
	SocialManager._reset_caches()
	_write_config()
	RemoteConfig.set_config_path(_temp_config_path)
	RemoteConfig.fetch()
	_fake = FakeClient.new()
	_fake.session_factory = func() -> NakamaSession: return _ok_session()


func after_each() -> void:
	OnlineService.reset_to_mock_mode()
	SocialManager._reset_caches()
	SaveSystem.set_save_path(_original_save_path)
	RemoteConfig.set_config_path(_original_config_path)
	RemoteConfig.fetch()
	IdentityService.set_identity_path(_original_identity_path)
	for p in [_temp_save_path, _temp_config_path, _temp_identity_path]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)


func _write_config() -> void:
	var file := FileAccess.open(_temp_config_path, FileAccess.WRITE)
	file.store_string(JSON.stringify({
		"flags": {},
		"values": {},
		"experiments": {},
		"events": [],
		"campaigns": [],
		"offers": [],
	}))
	file.close()


func _go_real() -> void:
	OnlineService.start_real_mode_with(_fake)
	assert_true(await _wait_until_online(), "real mode with fake client reaches ONLINE")


## The stage-clear payload (game_screen._on_round_ended -> GameResult.to_dict).
func _finish(best_score: int, is_new_best: bool) -> void:
	EventBus.gameplay_finished.emit({"stage_id": "s1", "score": best_score, "best_score": best_score, "is_new_best": is_new_best})


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


static func _record(owner_id: String, username: String, score: int, rank: int) -> FakeRecord:
	var rec := FakeRecord.new()
	rec.owner_id = owner_id
	rec.username = username
	rec.score = str(score)
	rec.rank = str(rank)
	return rec


# --- Availability / inertness ---------------------------------------------------------

func test_mock_mode_is_inert() -> void:
	assert_false(LeaderboardService.is_available(), "mock mode is never available")
	_finish(500, true)
	assert_eq(_fake.writes.size(), 0, "no write in mock mode")
	var rows: Array[Dictionary] = await LeaderboardService.fetch_leaderboard()
	assert_eq(rows.size(), 0, "fetch returns empty in mock mode")


# --- Submission --------------------------------------------------------------------

func test_submit_fires_only_on_improvement() -> void:
	await _go_real()
	_finish(420, true)
	assert_eq(_fake.writes.size(), 1, "improved best fires one write")
	assert_eq(str((_fake.writes[0] as Dictionary).get("lb_id", "")), LeaderboardService.LEADERBOARD_ID, "write targets the best-score board")
	assert_eq(int((_fake.writes[0] as Dictionary).get("score", 0)), 420, "write carries the new best")

	_finish(500, false)
	assert_eq(_fake.writes.size(), 1, "non-improving round fires nothing")
	EventBus.gameplay_finished.emit({"stage_id": "s1", "score": 900})
	assert_eq(_fake.writes.size(), 1, "payload without is_new_best fires nothing")


func test_submit_best_direct_and_nonpositive_noop() -> void:
	await _go_real()
	LeaderboardService.submit_best(77)
	assert_eq(_fake.writes.size(), 1, "direct submit writes")
	assert_eq(int((_fake.writes[0] as Dictionary).get("score", 0)), 77, "score passes through")
	LeaderboardService.submit_best(0)
	assert_eq(_fake.writes.size(), 1, "non-positive score is a no-op")


# --- Fetch: global ------------------------------------------------------------------

func test_fetch_global_maps_rows_and_self_flag() -> void:
	await _go_real()
	var list := FakeRecordList.new()
	list.records = [
		_record("user-x", "XCode", 999, 1),
		_record("test-user-1", "TestUser", 500, 2),
	]
	_fake.list_result = list
	var around := FakeRecordList.new()
	around.records = [_record("test-user-1", "TestUser", 500, 2)]
	_fake.around_result = around

	var rows: Array[Dictionary] = await LeaderboardService.fetch_leaderboard(LeaderboardService.SCOPE_GLOBAL)
	assert_eq(rows.size(), 2, "two rows mapped")
	assert_eq(int(rows[0].get("rank", 0)), 1, "rank parsed from the wire string")
	assert_eq(str(rows[0].get("name", "")), "XCode", "username mapped")
	assert_eq(int(rows[0].get("score", 0)), 999, "score parsed from the wire string")
	assert_false(bool(rows[0].get("is_self", false)), "non-self row flagged false")
	assert_true(bool(rows[1].get("is_self", false)), "own row flagged by owner id")


func test_fetch_own_row_merged_when_outside_top_n() -> void:
	await _go_real()
	var list := FakeRecordList.new()
	list.records = [
		_record("user-x", "XCode", 900, 1),
		_record("user-y", "YCode", 800, 2),
		_record("user-z", "ZCode", 700, 3),
	]
	_fake.list_result = list
	var around := FakeRecordList.new()
	around.records = [_record("test-user-1", "TestUser", 100, 4)]
	_fake.around_result = around

	var rows: Array[Dictionary] = await LeaderboardService.fetch_leaderboard(LeaderboardService.SCOPE_GLOBAL, 3)
	assert_eq(rows.size(), 4, "own row appended beyond top-N")
	assert_true(bool(rows[3].get("is_self", false)), "merged row is the own row")
	assert_eq(int(rows[3].get("rank", 0)), 4, "own rank from the around-owner window")


func test_fetch_own_row_not_duplicated() -> void:
	await _go_real()
	var list := FakeRecordList.new()
	list.records = [
		_record("user-x", "XCode", 900, 1),
		_record("test-user-1", "TestUser", 500, 2),
	]
	_fake.list_result = list
	var around := FakeRecordList.new()
	around.records = [_record("test-user-1", "TestUser", 500, 2)]
	_fake.around_result = around

	var rows: Array[Dictionary] = await LeaderboardService.fetch_leaderboard(LeaderboardService.SCOPE_GLOBAL)
	assert_eq(rows.size(), 2, "own row inside top-N is not appended twice")


func test_fetch_list_failure_returns_empty() -> void:
	await _go_real()
	_fake.list_should_fail = true
	var rows: Array[Dictionary] = await LeaderboardService.fetch_leaderboard(LeaderboardService.SCOPE_GLOBAL)
	assert_eq(rows.size(), 0, "failed list yields no rows")


# --- Fetch: friends scope -------------------------------------------------------------

func test_fetch_friends_lists_by_friend_user_ids() -> void:
	await _go_real()
	var friends: Array[Dictionary] = await SocialManager.fetch_friends()
	var expected: Array[String] = []
	for row in friends:
		expected.append(str(row.get("user_id", "")))
	assert_gt(expected.size(), 0, "mock backend seeds friends with user ids")

	var list := FakeRecordList.new()
	list.records = [_record("user-x", "XCode", 999, 1)]
	list.owner_records = [_record(expected[0], "FriendOne", 321, 1)]
	_fake.list_result = list

	var rows: Array[Dictionary] = await LeaderboardService.fetch_leaderboard(LeaderboardService.SCOPE_FRIENDS)
	assert_eq(_fake.list_calls.size(), 1, "one list call")
	var sent: Variant = (_fake.list_calls[0] as Dictionary).get("owner_ids", null)
	assert_true(sent is Array and (sent as Array).size() == expected.size(), "owner_ids carries the full friend set")
	for i in expected.size():
		assert_eq(str((sent as Array)[i]), expected[i], "friend user id %d passed through" % i)
	assert_eq(rows.size(), 1, "filtered rows mapped from owner_records (verified wire shape)")
	assert_eq(str(rows[0].get("name", "")), "FriendOne", "the global window in records is ignored")


func test_fetch_friends_empty_scope_makes_no_call() -> void:
	await _go_real()
	var rows: Array[Dictionary] = await LeaderboardService.fetch_leaderboard(LeaderboardService.SCOPE_FRIENDS)
	assert_eq(rows.size(), 0, "no friends -> empty result")
	assert_eq(_fake.list_calls.size(), 0, "no list call without owner ids")

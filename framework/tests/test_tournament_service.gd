extends GutTest
## TournamentService (TDD §3.23), hermetic: a duck-typed fake client stands in
## for NakamaClient (no network or addon transport), temp save/config/identity
## paths, and the OnlineService real-mode seam. after_each restores mock mode +
## stub config so later suites in the same GUT process see the default wiring.

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


class FakeTournamentList:
	var tournaments: Array = []
	func is_exception() -> bool:
		return false
	func get_exception() -> String:
		return ""


class FakeClient:
	var session_factory: Callable
	var auth_calls := 0
	var join_calls: Array[String] = []
	var writes: Array[Dictionary] = []
	var rpc_calls: Array[Dictionary] = []
	var list_result: Variant = null
	var around_result: Variant = null

	func authenticate_custom_async(_key: String, _username = null, _create: bool = true, _vars = null) -> NakamaSession:
		auth_calls += 1
		return session_factory.call() as NakamaSession

	func get_account_async(_session) -> NakamaAPI.ApiAccount:
		return NakamaAPI.ApiAccount.create(NakamaAPI, {
			"user": {"id": "test-user-1", "username": "TestUser"},
			"custom_id": "key-1",
		})

	func write_storage_objects_async(_session, _objects):
		return null

	func join_tournament_async(_session, tournament_id: String):
		join_calls.append(tournament_id)
		return FakeResult.new()

	func write_tournament_record_async(_session, tournament_id: String, score: int):
		writes.append({"id": tournament_id, "score": score})
		var rec := FakeRecord.new()
		rec.score = str(score)
		return rec

	# Real ApiRpc instances on purpose: NakamaAnalyticsBackend (always attached)
	# assigns the result to a typed variable, so a duck type would fail there.
	func rpc_async(_session, id: String, payload: String):
		rpc_calls.append({"id": id, "payload": payload})
		var parsed: Variant = JSON.parse_string(payload)
		if typeof(parsed) == TYPE_DICTIONARY and str((parsed as Dictionary).get("action", "")) == "team_round":
			return NakamaAPI.ApiRpc.create(NakamaAPI, {"payload": JSON.stringify({"ok": true, "team_score": 42})})
		return NakamaAPI.ApiRpc.new(NakamaException.new("rpc boom", 500))

	func list_tournament_records_async(_session, _tournament_id: String, _owner_ids = null, _limit: int = 10, _cursor = null, _expiry = null):
		if list_result != null:
			return list_result
		return FakeRecordList.new()

	func list_tournament_records_around_owner_async(_session, _tournament_id: String, _owner_id: String, _limit: int = 10, _cursor = null, _expiry = null):
		if around_result != null:
			return around_result
		return FakeRecordList.new()

	func list_tournaments_async(_session, _cs: int, _ce: int, _st: int, _et: int, _limit: int = 10, _cursor = null):
		return FakeTournamentList.new()


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
	_temp_save_path = "user://gut_tmp/tour_save_%d.json" % stamp
	_temp_config_path = "user://gut_tmp/tour_config_%d.json" % (stamp + 1)
	_temp_identity_path = "user://gut_tmp/tour_identity_%d.json" % (stamp + 2)
	SaveSystem.set_save_path(_temp_save_path)
	SaveSystem.load_save()
	IdentityService.set_identity_path(_temp_identity_path)
	IdentityService.clear_session()
	OnlineService.reset_to_mock_mode()
	_write_config()
	RemoteConfig.set_config_path(_temp_config_path)
	RemoteConfig.fetch()
	_fake = FakeClient.new()
	_fake.session_factory = func() -> NakamaSession: return _ok_session()


func after_each() -> void:
	OnlineService.reset_to_mock_mode()
	SaveSystem.set_save_path(_original_save_path)
	RemoteConfig.set_config_path(_original_config_path)
	RemoteConfig.fetch()
	IdentityService.set_identity_path(_original_identity_path)
	for p in [_temp_save_path, _temp_config_path, _temp_identity_path]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)


## Test config: one active solo + one active team tournament event.
func _write_config() -> void:
	var file := FileAccess.open(_temp_config_path, FileAccess.WRITE)
	file.store_string(JSON.stringify({
		"flags": {},
		"values": {"tournament_points_per_win": 10, "tournament_score_divisor": 25},
		"experiments": {},
		"events": [
			{
				"id": "ev_solo", "title": "Solo Ev", "kind": "solo_tournament",
				"ends_in_hours": 26, "icon": "trophy",
				"metadata": {"tournament_id": "tid_solo"},
				"rewards": [
					{"min_rank": 1, "max_rank": 1, "currency": "gems", "amount": 25},
					{"min_rank": 2, "max_rank": 3, "currency": "gems", "amount": 10},
				],
			},
			{
				"id": "ev_team", "title": "Team Ev", "kind": "team_tournament",
				"ends_in_hours": 24, "icon": "trophy",
				"metadata": {"tournament_id": "tid_team"},
				"rewards": [{"min_rank": 1, "max_rank": 3, "currency": "gems", "amount": 25}],
			},
		],
	}))
	file.close()


func _go_real() -> void:
	OnlineService.start_real_mode_with(_fake)
	assert_true(await _wait_until_online(), "real mode with fake client reaches ONLINE")


func _win(score: int, won: bool = true) -> void:
	EventBus.gameplay_finished.emit({"stage_id": "s1", "score": score, "won": won})


func _set_team(members: Array, leader_code: String) -> void:
	SaveSystem.set_domain("team", {
		"on_team": true, "team_name": "T", "team_id": "grp-1",
		"members": members, "leader_code": leader_code, "power": 0,
	})


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


# --- Availability ------------------------------------------------------------------

func test_mock_mode_is_inert() -> void:
	assert_false(TournamentService.is_available(), "mock mode is never available")
	_win(250)
	assert_false(TournamentService.has_entry("ev_solo"), "no entry in mock mode")
	assert_false(TournamentService.has_entry("ev_team"), "no team entry in mock mode")


func test_points_formula_defaults() -> void:
	assert_eq(TournamentService.points_for(0), 10, "base points at zero score")
	assert_eq(TournamentService.points_for(250), 20, "base + floor(250/25)")


func test_points_formula_remote_override() -> void:
	RemoteConfig.set_value("tournament_points_per_win", 5)
	RemoteConfig.set_value("tournament_score_divisor", 50)
	assert_eq(TournamentService.points_for(100), 7, "remote base + floor(100/50)")


# --- Round flow --------------------------------------------------------------------

func test_solo_win_creates_entry_and_submits_running_total() -> void:
	await _go_real()
	_win(250)
	var entry: Dictionary = TournamentService.get_entry("ev_solo")
	assert_eq(int(entry.get("progress", 0)), 20, "first win accumulates points_for(250)")
	assert_gt(int(entry.get("joined_unix", 0)), 0, "entry stamped with join time")
	assert_eq(_fake.join_calls.size(), 1, "one idempotent join")
	assert_eq(_fake.writes.size(), 1, "one record write per round")
	assert_eq(_wires_score(), 20, "write carries the running total")

	_win(0)
	var entry2: Dictionary = TournamentService.get_entry("ev_solo")
	assert_eq(int(entry2.get("progress", 0)), 30, "second win accumulates on the total")
	assert_eq(_fake.writes.size(), 2, "second write after second round")
	assert_eq(_wires_score(), 30, "write carries the new running total")


func _wires_score() -> int:
	return int((_fake.writes.back() as Dictionary).get("score", 0))


func test_lose_round_is_ignored() -> void:
	await _go_real()
	_win(250, false)
	assert_false(TournamentService.has_entry("ev_solo"), "lost rounds do not enter")
	assert_eq(_fake.writes.size(), 0, "no write on a loss")


func test_team_win_without_team_no_entry() -> void:
	await _go_real()
	_win(250)
	assert_false(TournamentService.has_entry("ev_team"), "no team entry without a team")
	assert_eq(_fake.rpc_calls.size(), 0, "no team_round RPC without a team")


func test_team_win_submits_delta_via_rpc() -> void:
	await _go_real()
	var me := IdentityService.get_player_code()
	_set_team([me, "alpha-0001"], me)
	_win(250)
	assert_true(TournamentService.has_entry("ev_team"), "team entry created")
	assert_eq(_fake.rpc_calls.size(), 1, "one team_round RPC per round")
	var parsed: Variant = JSON.parse_string(str((_fake.rpc_calls[0] as Dictionary).get("payload", "")))
	assert_eq(str((parsed as Dictionary).get("action", "")), "team_round", "RPC action is team_round")
	assert_eq(int((parsed as Dictionary).get("points", 0)), 20, "delta = points_for(score), not the total")


# --- Standings ---------------------------------------------------------------------

func test_fetch_standings_offline() -> void:
	var result: Dictionary = await TournamentService.fetch_standings("ev_solo")
	assert_false(bool(result.get("ok", false)), "mock mode fetch fails")
	assert_eq(str(result.get("error", "")), "offline", "error is offline")

func test_fetch_standings_solo_own_row() -> void:
	await _go_real()
	var list := FakeRecordList.new()
	var rec := FakeRecord.new()
	rec.owner_id = "test-user-1"
	rec.username = "TestUser"
	rec.score = "150"
	rec.rank = "1"
	list.owner_records = [rec]
	_fake.around_result = list
	var result: Dictionary = await TournamentService.fetch_standings("ev_solo")
	assert_true(bool(result.get("ok", false)), "solo standings fetch ok")
	assert_eq(int(result.get("own_rank", 0)), 1, "own rank from around-owner row")
	assert_eq(int(result.get("own_score", 0)), 150, "own score from around-owner row")


# --- Expiry claim ------------------------------------------------------------------

func test_claim_still_active() -> void:
	await _go_real()
	_win(250)
	var result: Dictionary = await TournamentService.claim("ev_solo")
	assert_false(bool(result.get("ok", false)), "claim blocked while active")
	assert_eq(str(result.get("error", "")), "still_active", "error is still_active")


func test_claim_without_entry_not_eligible() -> void:
	await _go_real()
	RemoteConfig.set_event_deadline("ev_solo", int(Time.get_unix_time_from_system()) - 60)
	var result: Dictionary = await TournamentService.claim("ev_solo")
	assert_false(bool(result.get("ok", false)), "claim blocked without an entry")
	assert_eq(str(result.get("error", "")), "not_eligible", "error is not_eligible")


func test_claim_grants_band_and_stamps_once() -> void:
	await _go_real()
	_win(250)
	RemoteConfig.set_event_deadline("ev_solo", int(Time.get_unix_time_from_system()) - 60)
	var list := FakeRecordList.new()
	var rec := FakeRecord.new()
	rec.score = "150"
	rec.rank = "1"
	list.owner_records = [rec]
	_fake.around_result = list

	var result: Dictionary = await TournamentService.claim("ev_solo")
	assert_true(bool(result.get("ok", false)), "rank-1 claim succeeds")
	assert_eq(str(result.get("currency", "")), "gems", "band currency")
	assert_eq(int(result.get("amount", 0)), 25, "rank-1 band amount")
	var profile: Dictionary = SaveSystem.get_domain("profile")
	assert_eq(int(profile.get("gems", 0)), 25, "grant landed in the profile domain")
	var entry: Dictionary = TournamentService.get_entry("ev_solo")
	assert_gt(int(entry.get("claimed_unix", 0)), 0, "one-shot stamp written")

	var again: Dictionary = await TournamentService.claim("ev_solo")
	assert_false(bool(again.get("ok", false)), "second claim blocked")
	assert_eq(str(again.get("error", "")), "already_claimed", "error is already_claimed")


func test_claim_second_band_by_rank() -> void:
	await _go_real()
	_win(250)
	RemoteConfig.set_event_deadline("ev_solo", int(Time.get_unix_time_from_system()) - 60)
	var list := FakeRecordList.new()
	var rec := FakeRecord.new()
	rec.score = "140"
	rec.rank = "3"
	list.owner_records = [rec]
	_fake.around_result = list
	var result: Dictionary = await TournamentService.claim("ev_solo")
	assert_true(bool(result.get("ok", false)), "rank-3 claim succeeds")
	assert_eq(int(result.get("amount", 0)), 10, "ranks 2-3 band amount")


func test_team_claim_splits_evenly_remainder_to_leader() -> void:
	await _go_real()
	var me := IdentityService.get_player_code()
	_set_team([me, "alpha-0001", "beta-0002"], me)
	_win(250)
	RemoteConfig.set_event_deadline("ev_team", int(Time.get_unix_time_from_system()) - 60)
	var list := FakeRecordList.new()
	var rec := FakeRecord.new()
	rec.owner_id = "grp-1"
	rec.username = "T"
	rec.score = "90"
	rec.rank = "2"
	list.owner_records = [rec]
	_fake.list_result = list

	var result: Dictionary = await TournamentService.claim("ev_team")
	assert_true(bool(result.get("ok", false)), "team claim succeeds")
	assert_eq(int(result.get("amount", 0)), 9, "leader share = floor(25/3) + remainder")
	var profile: Dictionary = SaveSystem.get_domain("profile")
	assert_eq(int(profile.get("gems", 0)), 9, "only the leader's slice granted to this player")

func test_team_claim_non_leader_gets_floor_share() -> void:
	await _go_real()
	var me := IdentityService.get_player_code()
	_set_team([me, "alpha-0001", "beta-0002"], "alpha-0001")
	_win(250)
	RemoteConfig.set_event_deadline("ev_team", int(Time.get_unix_time_from_system()) - 60)
	var list := FakeRecordList.new()
	var rec := FakeRecord.new()
	rec.owner_id = "grp-1"
	rec.username = "T"
	rec.score = "90"
	rec.rank = "2"
	list.owner_records = [rec]
	_fake.list_result = list

	var result: Dictionary = await TournamentService.claim("ev_team")
	assert_true(bool(result.get("ok", false)), "non-leader claim succeeds")
	assert_eq(int(result.get("amount", 0)), 8, "non-leader share = floor(25/3)")

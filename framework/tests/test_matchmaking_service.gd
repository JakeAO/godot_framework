extends GutTest
## MatchmakingService (TDD §3.27), hermetic: a fake adapter + socket pair
## SUBCLASS the real addon classes (the bridge constructor is typed NakamaSocket,
## so duck-typing would fail its runtime type check) and stand in for the
## websocket transport; a minimal duck-typed client drives OnlineService into
## real mode. The NakamaMultiplayerBridge on top of the fake socket is the REAL
## one — auto-join + host election genuinely run, which also pins the service's
## ordering tolerance (matched event vs join ack). after_each restores mock mode
## + the real socket factory so later suites in the same GUT process see the
## default wiring.

class FakeAdapter extends NakamaSocketAdapter:
	var close_count := 0

	func close():
		close_count += 1


class FakeSocket extends NakamaSocket:
	var connect_calls: Array[Dictionary] = []
	var add_calls: Array[Dictionary] = []
	var remove_calls: Array[String] = []
	var join_matched_calls: Array = []
	var leave_calls: Array[String] = []
	var state_sends: Array[Dictionary] = []
	var closed_count := 0
	# Injectable results (null = default success object).
	var connect_result: Variant = null
	var ticket_result: Variant = null
	var match_result: Variant = null

	func _init(p_adapter : NakamaSocketAdapter, p_host: String = "localhost", p_port: int = 7350, p_scheme: String = "ws", p_free_adapter: bool = false) -> void:
		super(p_adapter, p_host, p_port, p_scheme, p_free_adapter)

	func connect_async(p_session : NakamaSession, p_appear_online : bool = false, _p_connect_timeout : int = 3):
		connect_calls.append({"appear_online": p_appear_online})
		return connect_result if connect_result != null else NakamaAsyncResult.new()

	func add_matchmaker_async(p_query : String = "*", p_min_count : int = 2, p_max_count : int = 8, _p_string_props : Dictionary = {}, _p_numeric_props : Dictionary = {}, _p_count_multiple : int = 0) -> NakamaRTAPI.MatchmakerTicket:
		add_calls.append({"query": p_query, "min": p_min_count, "max": p_max_count})
		return ticket_result if ticket_result != null else _ok_ticket()

	func remove_matchmaker_async(p_ticket : String) -> NakamaAsyncResult:
		remove_calls.append(p_ticket)
		return NakamaAsyncResult.new()

	func join_matched_async(p_matched):
		join_matched_calls.append(p_matched)
		return match_result if match_result != null else _ok_match()

	func leave_match_async(p_match_id : String) -> NakamaAsyncResult:
		leave_calls.append(p_match_id)
		return NakamaAsyncResult.new()

	func send_match_state_async(p_match_id, p_op_code : int, p_data : String, _p_presences = null):
		state_sends.append({"match_id": p_match_id, "op_code": p_op_code, "data": p_data})

	func close():
		closed_count += 1

	static func _ok_ticket() -> NakamaRTAPI.MatchmakerTicket:
		return NakamaRTAPI.MatchmakerTicket.create(NakamaRTAPI, {"ticket": "tick-1"})

	## Join ack shaped like the live wire (spike): self first alphabetically so
	## the real bridge deterministically becomes HOST — match_joined fires with
	## no meta-message round trip.
	static func _ok_match() -> NakamaRTAPI.Match:
		return NakamaRTAPI.Match.create(NakamaRTAPI, {
			"match_id": "match-1",
			"self": {"session_id": "aaa", "user_id": "test-user-1", "username": "TestUser"},
			"presences": [
				{"session_id": "bbb", "user_id": "user-x", "username": "XCode"},
			],
		})


## Minimal real-mode client (same shape as the leaderboard suites): boot auth +
## account probe; storage writes are fire-and-forget no-ops here.
class FakeClient:
	var session_factory: Callable

	func authenticate_custom_async(_key: String, _username = null, _create: bool = true, _vars = null) -> NakamaSession:
		return session_factory.call() as NakamaSession

	func get_account_async(_session) -> NakamaAPI.ApiAccount:
		return NakamaAPI.ApiAccount.create(NakamaAPI, {
			"user": {"id": "test-user-1", "username": "TestUser"},
			"custom_id": "key-1",
		})

	func write_storage_objects_async(_session, _objects):
		return null


var _socket: FakeSocket = null
var _adapter: FakeAdapter = null
var _client: FakeClient = null
var _factory_calls := 0
var _original_save_path: String = ""
var _original_identity_path: String = ""
var _temp_save_path: String = ""
var _temp_identity_path: String = ""


func before_all() -> void:
	DirAccess.make_dir_recursive_absolute("user://gut_tmp")


func before_each() -> void:
	var stamp := Time.get_ticks_usec()
	_original_save_path = SaveSystem.get_save_path()
	_original_identity_path = IdentityService.get_identity_path()
	_temp_save_path = "user://gut_tmp/mm_save_%d.json" % stamp
	_temp_identity_path = "user://gut_tmp/mm_identity_%d.json" % (stamp + 1)
	SaveSystem.set_save_path(_temp_save_path)
	SaveSystem.load_save()
	IdentityService.set_identity_path(_temp_identity_path)
	IdentityService.clear_session()
	OnlineService.reset_to_mock_mode()
	MatchmakingService.cancel()
	_client = FakeClient.new()
	_client.session_factory = func() -> NakamaSession: return _ok_session()
	_adapter = FakeAdapter.new()
	_socket = FakeSocket.new(_adapter)
	_factory_calls = 0
	MatchmakingService._socket_factory = func():
		_factory_calls += 1
		return _socket


func after_each() -> void:
	MatchmakingService.cancel()
	MatchmakingService.reset_socket_factory()
	OnlineService.reset_to_mock_mode()
	# The adapter is a plain Node (never tree-added): free it explicitly so GUT
	# reports no orphans. Null the socket first so its PREDELETE sees a valid
	# adapter weakref during teardown.
	if _socket != null:
		_socket = null
	if _adapter != null:
		_adapter.free()
		_adapter = null
	SaveSystem.set_save_path(_original_save_path)
	IdentityService.set_identity_path(_original_identity_path)
	for p in [_temp_save_path, _temp_identity_path]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)


# --- Availability / inertness ---------------------------------------------------------

func test_mock_mode_is_inert() -> void:
	assert_false(MatchmakingService.is_available(), "mock mode is never available")
	var result: Dictionary = await MatchmakingService.enqueue()
	assert_false(bool(result.get("ok", true)), "enqueue refuses in mock mode")
	assert_eq(str(result.get("error", "")), "unavailable", "the refusal reason is 'unavailable'")
	assert_eq(_factory_calls, 0, "no socket is created in mock mode")
	MatchmakingService.cancel()
	assert_eq(MatchmakingService.get_state(), MatchmakingService.STATE_IDLE, "cancel on idle is a clean no-op")


# --- Enqueue --------------------------------------------------------------------------

func test_enqueue_opens_socket_and_holds_ticket() -> void:
	await _go_real()
	watch_signals(EventBus)
	var result: Dictionary = await MatchmakingService.enqueue()
	assert_true(bool(result.get("ok", false)), "enqueue succeeds in real mode")
	assert_eq(MatchmakingService.get_state(), MatchmakingService.STATE_QUEUED, "state is queued after enqueue")
	assert_eq(_factory_calls, 1, "one dedicated socket per queue session")
	assert_eq(_socket.connect_calls.size(), 1, "socket connected once")
	assert_true(bool((_socket.connect_calls[0] as Dictionary).get("appear_online", false)), "the queue socket appears online (matchmaker needs presence)")
	assert_eq(_socket.add_calls.size(), 1, "one matchmaker add")
	var call: Dictionary = _socket.add_calls[0]
	assert_eq(str(call.get("query", "")), "*", "wildcard query (no filters in v1)")
	assert_eq(int(call.get("min", -1)), MatchmakingService.MIN_PLAYERS, "min players pinned to 2")
	assert_eq(int(call.get("max", -1)), MatchmakingService.MAX_PLAYERS, "max players pinned to 2")
	assert_signal_emitted_with_parameters(EventBus, "matchmaking_state_changed", [MatchmakingService.STATE_QUEUED, {}])


func test_enqueue_while_active_is_noop() -> void:
	await _go_real()
	var first: Dictionary = await MatchmakingService.enqueue()
	assert_true(bool(first.get("ok", false)), "first enqueue succeeds")
	var second: Dictionary = await MatchmakingService.enqueue()
	assert_false(bool(second.get("ok", true)), "second enqueue is refused")
	assert_eq(str(second.get("error", "")), "already_queued", "the refusal reason is 'already_queued'")
	assert_eq(_factory_calls, 1, "no second socket is opened")


func test_add_failure_closes_socket_and_stays_idle() -> void:
	await _go_real()
	# create() with a missing required prop yields an exception-carrying ticket —
	# the same shape the transport produces on a server error.
	_socket.ticket_result = NakamaRTAPI.MatchmakerTicket.create(NakamaRTAPI, {})
	var result: Dictionary = await MatchmakingService.enqueue()
	assert_false(bool(result.get("ok", true)), "a failed add fails the enqueue")
	assert_ne(str(result.get("error", "")), "", "the failure carries a reason")
	assert_eq(MatchmakingService.get_state(), MatchmakingService.STATE_IDLE, "state stays idle on failure")
	assert_gt(_socket.closed_count, 0, "the dead socket is closed")


func test_connect_failure_stays_idle() -> void:
	await _go_real()
	_socket.connect_result = NakamaAsyncResult.new(NakamaException.new("connect boom", 500))
	var result: Dictionary = await MatchmakingService.enqueue()
	assert_false(bool(result.get("ok", true)), "a failed connect fails the enqueue")
	assert_eq(MatchmakingService.get_state(), MatchmakingService.STATE_IDLE, "state stays idle on failure")
	assert_gt(_socket.closed_count, 0, "the dead socket is closed")
	assert_eq(_socket.add_calls.size(), 0, "no matchmaker add after a connect failure")


# --- Matched -> in_match ---------------------------------------------------------------

func test_matched_event_lists_opponent_and_bridge_reaches_in_match() -> void:
	await _go_real()
	var result: Dictionary = await MatchmakingService.enqueue()
	assert_true(bool(result.get("ok", false)), "enqueue succeeds")
	_socket.received_matchmaker_matched.emit(_make_matched("aaa"))
	# The bridge's auto-join completes across frames; poll for the terminal state.
	assert_true(await _wait_for_state(MatchmakingService.STATE_IN_MATCH), "the room reaches in_match after matched + join ack")
	var opponents: Array[Dictionary] = MatchmakingService.get_opponents()
	assert_eq(opponents.size(), 1, "one opponent (self excluded from the wire list)")
	assert_eq(str(opponents[0].get("name", "")), "XCode", "opponent name mapped from the presence username")
	assert_eq(str(opponents[0].get("player_code", "")), "XCode", "username == player code in v1")
	assert_eq(_socket.join_matched_calls.size(), 1, "the bridge auto-joined exactly once")
	assert_gt(_socket.state_sends.size(), 0, "host election meta messages were sent (self sorts first = host)")
	var send: Dictionary = _socket.state_sends[0]
	assert_eq(int(send.get("op_code", -1)), 9001, "meta traffic uses the bridge's meta op code")


func test_stale_matched_event_after_cancel_is_ignored() -> void:
	await _go_real()
	var result: Dictionary = await MatchmakingService.enqueue()
	assert_true(bool(result.get("ok", false)), "enqueue succeeds")
	MatchmakingService.cancel()
	_socket.received_matchmaker_matched.emit(_make_matched("aaa"))
	await _settle(4)
	assert_eq(MatchmakingService.get_state(), MatchmakingService.STATE_IDLE, "a stale matched event cannot re-enter the state machine")
	assert_eq(MatchmakingService.get_opponents().size(), 0, "no opponents recorded from the stale event")


# --- Cancel / leave ---------------------------------------------------------------------

func test_cancel_in_queue_removes_ticket_and_closes_socket() -> void:
	await _go_real()
	var result: Dictionary = await MatchmakingService.enqueue()
	assert_true(bool(result.get("ok", false)), "enqueue succeeds")
	MatchmakingService.cancel()
	assert_eq(MatchmakingService.get_state(), MatchmakingService.STATE_IDLE, "cancel returns to idle")
	assert_true(_socket.remove_calls.has("tick-1"), "the matchmaker ticket is removed")
	assert_gt(_socket.closed_count, 0, "the queue socket is closed")


func test_cancel_in_match_leaves_room_and_queue() -> void:
	await _go_real()
	var result: Dictionary = await MatchmakingService.enqueue()
	assert_true(bool(result.get("ok", false)), "enqueue succeeds")
	_socket.received_matchmaker_matched.emit(_make_matched("aaa"))
	assert_true(await _wait_for_state(MatchmakingService.STATE_IN_MATCH), "reached in_match before leaving")
	MatchmakingService.cancel()
	assert_eq(MatchmakingService.get_state(), MatchmakingService.STATE_IDLE, "leave returns to idle")
	assert_true(_socket.leave_calls.has("match-1"), "the match room is left")
	assert_true(_socket.remove_calls.has("tick-1"), "the ticket is removed too (belt and braces)")
	assert_eq(MatchmakingService.get_opponents().size(), 0, "opponent rows cleared on leave")


# --- Backend drop ------------------------------------------------------------------------

func test_backend_offline_cancels_active_queue() -> void:
	await _go_real()
	var result: Dictionary = await MatchmakingService.enqueue()
	assert_true(bool(result.get("ok", false)), "enqueue succeeds")
	OnlineService.force_offline(true)
	assert_eq(MatchmakingService.get_state(), MatchmakingService.STATE_IDLE, "a backend drop cancels the active queue")
	assert_gt(_socket.closed_count, 0, "the dead socket is closed")


# --- Helpers -----------------------------------------------------------------------------

func _go_real() -> void:
	OnlineService.start_real_mode_with(_client)
	assert_true(await _wait_until_online(), "real mode with fake client reaches ONLINE")


func _make_matched(self_session: String) -> NakamaRTAPI.MatchmakerMatched:
	# Wire shape (spike-verified): users carries ALL matched users INCLUDING self.
	return NakamaRTAPI.MatchmakerMatched.create(NakamaRTAPI, {
		"ticket": "tick-1",
		"users": [
			{"presence": {"session_id": self_session, "user_id": "test-user-1", "username": "TestUser"}},
			{"presence": {"session_id": "bbb", "user_id": "user-x", "username": "XCode"}},
		],
		"self": {"presence": {"session_id": self_session, "user_id": "test-user-1", "username": "TestUser"}},
	})


func _wait_for_state(expected: String) -> bool:
	for i in 30:
		if MatchmakingService.get_state() == expected:
			return true
		await get_tree().process_frame
	return false


func _settle(frames: int) -> void:
	for i in frames:
		await get_tree().process_frame


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

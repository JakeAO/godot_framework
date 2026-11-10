extends GutTest
## NakamaAnalyticsBackend (TDD §3.17): build_payload wire shape (pure static, no
## client) and flush() semantics against a duck-typed fake client injected via
## OnlineService.start_real_mode_with — hermetic, no network. The real-mode seams
## are the same ones test_online_service.gd uses; after_each restores mock mode
## so later suites in the same GUT process see the default wiring.

class FakeClient:
	## Synchronous duck-typed stand-in for NakamaClient (contract mirrors
	## test_online_service.gd plus rpc_async).
	var rpc_calls: Array = []
	var auth_factory: Callable
	var rpc_result_factory: Callable

	func authenticate_custom_async(_key: String, _username = null, _create: bool = true, _vars = null) -> NakamaSession:
		if auth_factory.is_valid():
			return auth_factory.call() as NakamaSession
		return ok_session()

	func get_account_async(_session) -> NakamaAPI.ApiAccount:
		return ok_account()

	func write_storage_objects_async(_session, _objects):
		return null

	func rpc_async(_session, id: String, payload: String):
		rpc_calls.append({"id": id, "payload": str(payload)})
		if rpc_result_factory.is_valid():
			return rpc_result_factory.call() as NakamaAPI.ApiRpc
		return NakamaAPI.ApiRpc.create(NakamaAPI, {"payload": "{\"ok\":true,\"count\":1}"})

	## A locally-built JWT that NakamaSession parses offline (exp/uid/usn claims).
	static func ok_session() -> NakamaSession:
		var header := JSON.stringify({"alg": "HS256", "typ": "JWT"})
		var payload := JSON.stringify({
			"exp": int(Time.get_unix_time_from_system()) + 3600,
			"uid": "analytics-test-user",
			"usn": "AnalyticsTestUser",
		})
		return NakamaSession.new(_b64url(header) + "." + _b64url(payload) + ".sig")

	static func _b64url(text: String) -> String:
		return Marshalls.utf8_to_base64(text).replace("+", "-").replace("/", "_").replace("=", "")

	## A successful ApiAccount (the probe requires a non-null user).
	static func ok_account() -> NakamaAPI.ApiAccount:
		return NakamaAPI.ApiAccount.create(NakamaAPI, {
			"user": {"id": "analytics-test-user", "username": "AnalyticsTestUser"},
			"custom_id": "key-1",
		})


var _fake: FakeClient = null
var _backend: NakamaAnalyticsBackend = null
var _original_identity_path: String = ""
var _temp_identity_path: String = ""


func before_all() -> void:
	DirAccess.make_dir_recursive_absolute("user://gut_tmp")


func before_each() -> void:
	_original_identity_path = IdentityService.get_identity_path()
	_temp_identity_path = "user://gut_tmp/identity_nakama_analytics_%d.json" % Time.get_ticks_usec()
	IdentityService.set_identity_path(_temp_identity_path)
	OnlineService.reset_to_mock_mode()
	IdentityService.clear_session()
	_fake = FakeClient.new()
	_backend = NakamaAnalyticsBackend.new()


func after_each() -> void:
	OnlineService.reset_to_mock_mode()
	IdentityService.set_identity_path(_original_identity_path)
	if FileAccess.file_exists(_temp_identity_path):
		DirAccess.remove_absolute(_temp_identity_path)


# --- build_payload (pure wire shape) ---------------------------------------------

func test_build_payload_maps_queue_entries_to_wire_shape() -> void:
	var events := _sample_events()
	var payload: Dictionary = NakamaAnalyticsBackend.build_payload(events)
	assert_eq(payload.size(), 1, "payload has a single top-level key")
	var evs: Array = payload.get("events", [])
	assert_eq(evs.size(), 2, "one wire event per queue entry")
	var e0: Dictionary = evs[0]
	assert_eq(str(e0.get("name", "")), "stage_complete", "name passes through")
	assert_eq(int(e0.get("ts", -1)), 1762594800, "unix ts passes through")
	assert_eq(str(e0.get("session_id", "")), "sess-1", "per-event session_id passes through")
	var props: Dictionary = e0.get("props", {})
	assert_eq(int(props.get("stage", -1)), 3, "nested int prop survives (JSONB)")
	assert_true(bool(props.get("perfect", false)), "bool prop survives")
	var e1: Dictionary = evs[1]
	assert_eq(str(e1.get("name", "")), "no_props", "second event name")
	assert_eq(int(e1.get("ts", -1)), 0, "missing ts defaults to 0 (server stores NULL)")
	assert_eq(str(e1.get("session_id", "")), "", "missing session_id defaults to empty")
	assert_eq((e1.get("props", {}) as Dictionary).size(), 0, "missing properties default to {}")


func test_build_payload_output_is_json_stringifiable() -> void:
	var text := JSON.stringify(NakamaAnalyticsBackend.build_payload(_sample_events()))
	var parsed: Variant = JSON.parse_string(text)
	assert_true(typeof(parsed) == TYPE_DICTIONARY, "payload round-trips through JSON")


# --- flush() semantics -----------------------------------------------------------

func test_flush_in_mock_mode_is_silent_noop() -> void:
	_backend.flush(_sample_events())
	await _settle(3)
	assert_eq(_fake.rpc_calls.size(), 0, "mock mode never calls the RPC")
	assert_push_warning_count(0, "mock mode must not warn (gate stays hermetic)")


func test_flush_sends_batch_to_analytics_rpc() -> void:
	assert_true(await _go_online(), "real mode reaches a valid session first")
	_backend.flush(_sample_events())
	await _settle(3)
	assert_eq(_fake.rpc_calls.size(), 1, "one RPC per flush")
	var call: Dictionary = _fake.rpc_calls[0]
	assert_eq(str(call.get("id", "")), NakamaAnalyticsBackend.ANALYTICS_FUNCTION, "RPC id is the plugin function name")
	var parsed: Variant = JSON.parse_string(str(call.get("payload", "")))
	assert_true(typeof(parsed) == TYPE_DICTIONARY, "RPC payload is a JSON object string")
	var evs: Array = (parsed as Dictionary).get("events", [])
	assert_eq(evs.size(), 2, "both events ride the one RPC")
	var e0: Dictionary = evs[0]
	assert_eq(str(e0.get("name", "")), "stage_complete", "wire shape intact after JSON round-trip")
	assert_eq(int((e0.get("props", {}) as Dictionary).get("stage", -1)), 3, "nested props survive the round-trip")


func test_flush_without_session_drops_and_warns_once() -> void:
	_fake.auth_factory = func() -> NakamaSession: return _failed_session(500, "boom")
	OnlineService.start_real_mode_with(_fake)
	await _settle(12)
	assert_false(OnlineService.is_online(), "auth failure stays offline (precondition)")
	_backend.flush(_sample_events())
	await _settle(3)
	_backend.flush(_sample_events())
	await _settle(3)
	assert_eq(_fake.rpc_calls.size(), 0, "no RPC without a session")
	assert_push_warning_count(1, "warn-once: the second dropped batch is silent")


func test_rpc_failure_drops_and_warns_once() -> void:
	assert_true(await _go_online(), "real mode reaches a valid session first")
	_fake.rpc_result_factory = func() -> NakamaAPI.ApiRpc: return NakamaAPI.ApiRpc.new(NakamaException.new("boom", 500))
	_backend.flush(_sample_events())
	await _settle(3)
	_backend.flush(_sample_events())
	await _settle(3)
	assert_eq(_fake.rpc_calls.size(), 2, "both flushes attempted the RPC")
	assert_push_warning_count(1, "warn-once across repeated RPC failures")


func test_flush_empty_batch_is_noop() -> void:
	assert_true(await _go_online(), "real mode reaches a valid session first")
	_backend.flush([])
	await _settle(2)
	assert_eq(_fake.rpc_calls.size(), 0, "empty batch sends nothing")


# --- Fixtures / helpers -------------------------------------------------------------

func _sample_events() -> Array[Dictionary]:
	return [
		{"name": "stage_complete", "ts": 1762594800, "session_id": "sess-1", "properties": {"stage": 3, "perfect": true}},
		{"name": "no_props"},
	]


func _go_online() -> bool:
	OnlineService.start_real_mode_with(_fake)
	for i in 120:
		if OnlineService.is_online():
			return true
		await get_tree().process_frame
	return false


func _failed_session(status_code: int, message: String) -> NakamaSession:
	return NakamaSession.new(null, false, null, NakamaException.new(message, status_code))


func _settle(frames: int = 5) -> void:
	for i in frames:
		await get_tree().process_frame

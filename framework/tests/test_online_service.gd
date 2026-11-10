extends GutTest
## OnlineService state machine (TDD §3.17/§3.18), hermetic: a duck-typed fake
## client stands in for NakamaClient, so no network or addon transport is
## touched. The real-mode seams start_real_mode_with()/reset_to_mock_mode()
## exist exactly for this file — after_each restores mock mode so later suites
## (same GUT process) see the default wiring.

class FakeClient:
	## Synchronous duck-typed stand-in: probes complete within the call stack,
	## so a test needs only a couple of process frames to settle.
	var auth_calls := 0
	var account_calls := 0
	var auth_factory: Callable
	var account_factory: Callable

	func authenticate_custom_async(_key: String, _username = null, _create: bool = true, _vars = null) -> NakamaSession:
		auth_calls += 1
		return auth_factory.call(auth_calls) as NakamaSession

	func get_account_async(_session) -> NakamaAPI.ApiAccount:
		account_calls += 1
		return account_factory.call(account_calls) as NakamaAPI.ApiAccount

	func write_storage_objects_async(_session, _objects):
		return null


var _fake: FakeClient = null
var _emits: Array[bool] = []
var _spy_connected := false
var _original_identity_path: String = ""
var _temp_identity_path: String = ""


func before_all() -> void:
	DirAccess.make_dir_recursive_absolute("user://gut_tmp")


func before_each() -> void:
	_original_identity_path = IdentityService.get_identity_path()
	_temp_identity_path = "user://gut_tmp/identity_online_%d.json" % Time.get_ticks_usec()
	IdentityService.set_identity_path(_temp_identity_path)
	OnlineService.reset_to_mock_mode()
	IdentityService.clear_session()
	_fake = FakeClient.new()
	_emits = []
	EventBus.backend_state_changed.connect(_on_backend_state_changed)
	_spy_connected = true


func after_each() -> void:
	if _spy_connected and EventBus.backend_state_changed.is_connected(_on_backend_state_changed):
		EventBus.backend_state_changed.disconnect(_on_backend_state_changed)
		_spy_connected = false
	OnlineService.reset_to_mock_mode()
	IdentityService.set_identity_path(_original_identity_path)
	if FileAccess.file_exists(_temp_identity_path):
		DirAccess.remove_absolute(_temp_identity_path)


func _on_backend_state_changed(online: bool) -> void:
	_emits.append(online)


# --- Tests ------------------------------------------------------------------------

func test_mock_mode_is_permanently_online_without_emitting() -> void:
	await _settle(3)
	assert_true(OnlineService.is_online(), "mock mode is always online")
	assert_false(OnlineService.is_real_mode(), "mock mode flag off")
	assert_eq(_emits.size(), 0, "no state emits in mock mode (hermetic gate)")


func test_probe_success_transitions_to_online_with_single_emit() -> void:
	_fake.auth_factory = func(_call: int) -> NakamaSession: return _ok_session()
	_fake.account_factory = func(_call: int) -> NakamaAPI.ApiAccount: return _ok_account()
	OnlineService.start_real_mode_with(_fake)
	assert_true(await _wait_until_online(), "probe success reaches ONLINE")
	await _settle(2)
	assert_eq(_emits, [true], "exactly one transition emit (CONNECTING -> ONLINE)")
	assert_eq(_fake.auth_calls, 1, "one session exchange")
	assert_eq(_fake.account_calls, 1, "one account probe")


func test_probe_failure_stays_offline_without_emitting() -> void:
	_fake.auth_factory = func(_call: int) -> NakamaSession: return _failed_session(500, "boom")
	OnlineService.start_real_mode_with(_fake)
	await _settle(10)
	assert_false(OnlineService.is_online(), "auth failure stays offline")
	assert_eq(_emits.size(), 0, "no emit (OFFLINE is the initial published value)")
	assert_eq(_fake.auth_calls, 1, "no retry on a plain auth failure")


func test_username_collision_retries_without_username() -> void:
	_fake.auth_factory = func(n: int) -> NakamaSession:
		if n == 1:
			return _failed_session(409, "Username is already in use.")
		return _ok_session()
	_fake.account_factory = func(_call: int) -> NakamaAPI.ApiAccount: return _ok_account()
	OnlineService.start_real_mode_with(_fake)
	assert_true(await _wait_until_online(), "collision retry reaches ONLINE")
	await _settle(2)
	assert_eq(_fake.auth_calls, 2, "claimed username retried once without a username")
	assert_push_warning("already in use", "collision warns once")


func test_401_mid_session_re_exchanges_once() -> void:
	_fake.auth_factory = func(_call: int) -> NakamaSession: return _ok_session()
	_fake.account_factory = func(n: int) -> NakamaAPI.ApiAccount:
		if n == 1:
			return NakamaAPI.ApiAccount.new(NakamaException.new("unauthorized", 401))
		return _ok_account()
	OnlineService.start_real_mode_with(_fake)
	assert_true(await _wait_until_online(), "401 recovery reaches ONLINE")
	await _settle(2)
	assert_eq(_fake.auth_calls, 2, "rejected token dropped and re-exchanged once")
	assert_eq(_fake.account_calls, 2, "probe retried with the fresh session")
	assert_eq(_emits, [true], "recovery is invisible to state emits")


func test_force_offline_overrides_and_recovers() -> void:
	_fake.auth_factory = func(_call: int) -> NakamaSession: return _ok_session()
	_fake.account_factory = func(_call: int) -> NakamaAPI.ApiAccount: return _ok_account()
	OnlineService.start_real_mode_with(_fake)
	assert_true(await _wait_until_online(), "established online first")

	OnlineService.force_offline(true)
	assert_false(OnlineService.is_online(), "forced offline overrides the state")
	assert_eq(_emits, [true, false], "force-offline emits the transition")

	OnlineService.force_offline(false)
	assert_true(OnlineService.is_online(), "release reports online immediately")
	await _settle(3)
	assert_eq(_emits, [true, false, true], "exactly one emit per transition")


# --- Fixtures / helpers -------------------------------------------------------------

## A locally-built JWT that NakamaSession parses offline (exp/uid/usn claims).
static func _make_jwt() -> String:
	var header := JSON.stringify({"alg": "HS256", "typ": "JWT"})
	var payload := JSON.stringify({
		"exp": int(Time.get_unix_time_from_system()) + 3600,
		"uid": "test-user-1",
		"usn": "TestUser",
	})
	return _b64url(header) + "." + _b64url(payload) + ".sig"


static func _b64url(text: String) -> String:
	return Marshalls.utf8_to_base64(text).replace("+", "-").replace("/", "_").replace("=", "")


func _ok_session() -> NakamaSession:
	return NakamaSession.new(_make_jwt())


func _failed_session(status_code: int, message: String = "boom") -> NakamaSession:
	return NakamaSession.new(null, false, null, NakamaException.new(message, status_code))


## A successful ApiAccount (the probe requires a non-null user).
static func _ok_account() -> NakamaAPI.ApiAccount:
	return NakamaAPI.ApiAccount.create(NakamaAPI, {
		"user": {"id": "test-user-1", "username": "TestUser"},
		"custom_id": "key-1",
	})


func _wait_until_online(timeout_frames: int = 120) -> bool:
	for i in timeout_frames:
		if OnlineService.is_online():
			return true
		await get_tree().process_frame
	return false


func _settle(frames: int = 5) -> void:
	for i in frames:
		await get_tree().process_frame

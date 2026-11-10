extends Node
## OnlineService (TDD §3.18): the ONLY owner of backend connection state and, in
## real mode, of the Nakama client (§3.17). State machine OFFLINE -> CONNECTING
## -> ONLINE; "verified online" = an authenticated account probe succeeded on a
## cadence from remote value `backend_health_sec` (immediate at boot + on
## visibility resume). Emits backend_state_changed on TRANSITIONS only.
## Mock mode (empty game/backend_base_url) is permanently ONLINE with no probing
## and no emits — today's UX is byte-identical and the gate stays hermetic.

const _NAKAMA_FACTORY: GDScript = preload("res://addons/com.heroiclabs.nakama/Nakama.gd")
const BASE_URL_SETTING: String = "game/backend_base_url"
const SERVER_KEY_SETTING: String = "game/nakama_server_key"
const HEALTH_KEY: String = "backend_health_sec"
const DEFAULT_HEALTH_SEC: int = 30
const MIN_HEALTH_SEC: int = 5
const MAX_HEALTH_SEC: int = 300
const HTTP_TIMEOUT_SEC: int = 15

enum State { OFFLINE, CONNECTING, ONLINE }

# Untyped on purpose (documented exception): real mode holds a NakamaClient; the
# test seam start_real_mode_with() injects a duck-typed fake instead.
var _client = null
var _session: NakamaSession = null
# Untyped on purpose (documented exception): the factory script has no
# class_name, and it hosts create_client()/create_socket_from() which are not
# members of Node.
var _factory = null
var _timer: Timer = null

var _real_mode := false
var _state: int = State.OFFLINE
var _forced_offline := false
var _probe_in_flight := false
var _save_loaded := false
var _first_online_done := false
var _username_collision_warned := false
var _last_published: bool = false


func _ready() -> void:
	_real_mode = not str(ProjectSettings.get_setting(BASE_URL_SETTING, "")).is_empty()
	if not _real_mode:
		_state = State.ONLINE  # permanently online; no probing, no emits (TDD §3.18)
		return
	var parsed := parse_backend_url(str(ProjectSettings.get_setting(BASE_URL_SETTING, "")))
	if parsed.is_empty():
		push_warning("OnlineService: %s is not a valid URL; staying offline" % BASE_URL_SETTING)
		return
	# Own instance of the factory (NOT the Nakama autoload): at this point in
	# _ready the later-registered autoload singletons do not exist yet.
	_factory = _NAKAMA_FACTORY.new()
	add_child(_factory)
	_client = _factory.create_client(
		str(ProjectSettings.get_setting(SERVER_KEY_SETTING, "defaultkey")),
		str(parsed["host"]), int(parsed["port"]), str(parsed["scheme"]),
		HTTP_TIMEOUT_SEC, NakamaLogger.LOG_LEVEL.WARNING)
	SocialManager.set_backend(NakamaSocialBackend.new(_client))
	SaveSystem.set_sync_backend(NakamaSaveSyncBackend.new(_client))
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.timeout.connect(_probe)
	add_child(_timer)
	EventBus.visibility_changed.connect(_on_visibility_changed)
	EventBus.profile_updated.connect(_on_profile_updated)
	SaveSystem.save_loaded.connect(_on_save_loaded)
	_start_connect()


# --- Public API (TDD §3.18) ---------------------------------------------------------

func is_real_mode() -> bool:
	return _real_mode


## True when the backend is verified reachable. Mock mode: always true unless
## force_offline is set (QA seam).
func is_online() -> bool:
	if _forced_offline:
		return false
	if not _real_mode:
		return true
	return _state == State.ONLINE


## The Nakama client in real mode; null in mock mode.
func get_client():
	return _client if _real_mode and _client != null else null


## The current authenticated session, or null when unavailable. Backends treat
## null as "unavailable" (the §3.16 failure convention).
func get_session() -> NakamaSession:
	if not _real_mode or _session == null:
		return null
	if _session.is_exception() or _session.expired:
		return null
	return _session


## Real mode only: a websocket bound to the owned client (TDD §3.17 — chat send
## is websocket-only; REST has no send endpoint). Null in mock mode.
func create_socket() -> NakamaSocket:
	if not _real_mode or _factory == null or _client == null:
		return null
	return _factory.create_socket_from(_client)


## The force-offline override (DevTools BACKEND section).
func is_forced_offline() -> bool:
	return _forced_offline


## QA seam (DevTools): state override — flips the reported online value without
## touching the client, and emits backend_state_changed with the new value.
func force_offline(force: bool) -> void:
	if _forced_offline == force:
		return
	_forced_offline = force
	if not force and _real_mode and _client != null and not _probe_in_flight:
		_probe()
	_publish(is_online())


# --- Test seams (GUT hermetic; see tests/test_online_service.gd) ---------------------

## Runs the real-mode state machine against a duck-typed client (must implement
## authenticate_custom_async + get_account_async). Deliberately does NOT wire the
## SocialManager/SaveSystem backends — that path is covered by the live smoke.
func start_real_mode_with(client: Variant) -> void:
	_real_mode = true
	_client = client
	if _timer == null:
		_timer = Timer.new()
		_timer.one_shot = true
		_timer.timeout.connect(_probe)
		add_child(_timer)
	_state = State.CONNECTING
	_start_connect()


## Restores mock mode after real-mode testing so later suites in the same GUT
## process see the default wiring.
func reset_to_mock_mode() -> void:
	if _timer != null:
		_timer.stop()
	_real_mode = false
	_client = null
	_session = null
	_state = State.ONLINE
	_forced_offline = false
	_probe_in_flight = false
	_save_loaded = false
	_first_online_done = false
	_last_published = false


# --- Connection lifecycle -------------------------------------------------------------

func _start_connect() -> void:
	_set_state(State.CONNECTING)
	await get_tree().process_frame  # tree-activation guard for HTTPRequest children
	await _probe()


func _probe() -> void:
	if not _real_mode or _client == null or _forced_offline or _probe_in_flight:
		return
	_probe_in_flight = true
	var online := false
	var session := await _ensure_session()
	if session != null:
		online = await _account_probe(session)
	_probe_in_flight = false
	_set_state(State.ONLINE if online else State.OFFLINE)
	_schedule_next()


func _account_probe(session: NakamaSession) -> bool:
	var account: NakamaAPI.ApiAccount = await _client.get_account_async(session)
	if not account.is_exception() and account.user != null:
		return true
	if _is_auth_error(account):
		# 401/expired mid-session: drop the rejected token and re-exchange with
		# the raw key (TDD §3.17).
		_session = null
		IdentityService.clear_session()
		var fresh := await _ensure_session()
		if fresh != null:
			var retry: NakamaAPI.ApiAccount = await _client.get_account_async(fresh)
			return not retry.is_exception() and retry.user != null
	return false


func _ensure_session() -> NakamaSession:
	if _session != null and not _session.is_exception() and not _session.expired:
		return _session
	var stored := IdentityService.get_stored_session()
	if not stored.is_empty():
		_session = NakamaClient.restore_session(str(stored.get("token", "")))
		if not _session.is_exception():
			return _session
		_session = null
	return await _exchange_session()


func _exchange_session() -> NakamaSession:
	var key := IdentityService.get_player_key()
	var code := IdentityService.get_player_code()
	_session = await _client.authenticate_custom_async(key, code, true, null)
	if _session.is_exception() and _looks_like_username_collision(_session):
		# Code collision (~1 in 160k): retry WITHOUT a username — the player still
		# works, just isn't findable by code (TDD §3.17). Warn once per session.
		if not _username_collision_warned:
			_username_collision_warned = true
			push_warning("OnlineService: player code '%s' is already in use; continuing without a username" % code)
		_session = await _client.authenticate_custom_async(key, null, true, null)
	if _session.is_exception():
		return null
	IdentityService.set_session(str(_session.token), int(_session.expire_time))
	_sync_profile_summary()
	_sync_last_seen()  # fresh session establishment (TDD §3.25)
	return _session


# --- State machine ---------------------------------------------------------------------

func _set_state(new_state: int) -> void:
	if new_state == _state:
		return
	_state = new_state
	if new_state == State.ONLINE:
		_try_first_online_actions()
	if not _forced_offline:
		_publish(new_state == State.ONLINE)


## First verified connection: cross-device save fetch + profile summary write +
## last-seen stamp (covers the RESTORED-session path — a fresh exchange already
## stamps in _exchange_session). Gated on BOTH ONLINE and save-loaded.
func _try_first_online_actions() -> void:
	if not _real_mode or _first_online_done or _state != State.ONLINE or not _save_loaded:
		return
	_first_online_done = true
	SaveSystem.fetch_synced_domains()
	_sync_profile_summary()
	_sync_last_seen()


func _publish(online: bool) -> void:
	if online == _last_published:
		return
	_last_published = online
	EventBus.backend_state_changed.emit(online)


## App exit: best-effort last-seen stamp (TDD §3.25). The write is issued but
## may not complete before the process exits — that is acceptable by design
## (the friend's own next session re-stamps; a missed stamp only makes their
## "seen X ago" slightly stale).
func _notification(what: int) -> void:
	# Godot 4.7 has NO app-close notification (verified in core/os/main_loop.h —
	# the enum only covers 2009-2020: memory/translation/wm/crash/ime/app-state).
	# PREDELETE fires when this autoload is freed at shutdown; _sync_last_seen
	# touches only member state (_session/_client), so free order is irrelevant.
	if what == NOTIFICATION_PREDELETE and _real_mode:
		_sync_last_seen()


# --- Profile summary (friend-facing card; TDD §3.17 deviation — see NOTES.md) ----------

func _on_profile_updated(_profile: Dictionary) -> void:
	_sync_profile_summary()


func _sync_profile_summary() -> void:
	var session := get_session()
	if session == null:
		return
	var profile := SaveSystem.get_domain("profile")
	var summary := {
		"player_code": IdentityService.get_player_code(),
		"name": str(profile.get("name", "Player")),
		"level": int(profile.get("level", 1)),
		"best_score": int(profile.get("best_score", 0)),
		"portrait_icon": str(profile.get("portrait_icon", "classic")),
		"portrait_flair": str(profile.get("portrait_flair", "none")),
		"portrait_crown": str(profile.get("portrait_crown", "none")),
	}
	var obj := NakamaWriteStorageObject.new("profile", "summary", 2, 0, JSON.stringify(summary), "")
	# Fire-and-forget: summaries are last-known by design; failures are invisible.
	await _client.write_storage_objects_async(session, [obj])


## Last-seen stamp (TDD §3.25): friends read this back for offline rows via the
## social backend's batched storage read — with THEIR session and our user_id,
## so the object must be PUBLIC (permission_read=2), same as the profile
## summary. Verified filter (NOTES.md): read = 2 OR (read = 1 AND caller) — a
## permission_read=1 stamp would be invisible to friends.
func _sync_last_seen() -> void:
	var session := get_session()
	if session == null:
		return
	var obj := NakamaWriteStorageObject.new("profile", "last_seen", 2, 0, JSON.stringify({"ts": int(Time.get_unix_time_from_system())}), "")
	await _client.write_storage_objects_async(session, [obj])


# --- Signals / helpers -------------------------------------------------------------------

func _on_save_loaded(_version: int) -> void:
	_save_loaded = true
	_try_first_online_actions()


func _on_visibility_changed(is_visible: bool) -> void:
	if not is_visible or not _real_mode or _forced_offline or _probe_in_flight:
		return
	_probe()


func _schedule_next() -> void:
	if _timer != null and not _forced_offline:
		_timer.start(_health_cadence())


func _health_cadence() -> float:
	var raw: Variant = RemoteConfig.get_value(HEALTH_KEY, DEFAULT_HEALTH_SEC)
	return float(clampi(int(raw), MIN_HEALTH_SEC, MAX_HEALTH_SEC))


static func _is_auth_error(result: NakamaAsyncResult) -> bool:
	if not result.is_exception():
		return false
	var ex := result.get_exception()
	return ex != null and int(ex.status_code) == 401


## Live-verified against Nakama 3.37.0: a claimed username returns HTTP 409 with
## "Username is already in use." (gRPC ALREADY_EXISTS).
static func _looks_like_username_collision(result: NakamaSession) -> bool:
	if not result.is_exception():
		return false
	var ex := result.get_exception()
	if ex == null:
		return false
	return int(ex.status_code) == 409 or str(ex.message).to_lower().find("username") != -1


## Parses "scheme://host[:port][/...]" into {scheme, host, port}; {} when invalid.
## IPv6 literals are unsupported (VPS targets are IPv4).
static func parse_backend_url(base_url: String) -> Dictionary:
	var sep := base_url.find("://")
	if sep <= 0:
		return {}
	var scheme := base_url.left(sep).to_lower()
	var rest := base_url.substr(sep + 3)
	var slash := rest.find("/")
	if slash >= 0:
		rest = rest.left(slash)
	var port := -1
	var colon := rest.rfind(":")
	if colon > 0:
		port = int(rest.substr(colon + 1))
		rest = rest.left(colon)
	if rest.is_empty():
		return {}
	if port <= 0:
		port = 443 if scheme == "https" else 80
	return {"scheme": scheme, "host": rest, "port": port}

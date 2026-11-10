extends Node
## Social data facade (TDD §3.16; chat realtime per TDD §3.24 — Phase E1): owns
## the ISocialBackend + caches and is the ONLY consumer-facing surface for
## social data — screens never touch backends directly (same doctrine as
## UIManager/AdManager). Swapping the mock for a real backend is set_backend()
## with no UI/flow changes (TDD §9).
##
## Chat: the manager owns the realtime subscription lifecycle (subscribe while
## on a team + online, drop otherwise) and re-emits backend pushes through the
## existing social_chat_message signal after id-dedupe — screens see no
## difference from the v1 polling contract.
##
## Failure semantics: transport/auth failure -> the service reports
## unavailable and callers fall back to local/mock state, warning once per
## session per operation (the RemoteConfig cache-fallback pattern).

const TEAM_DOMAIN: String = "team"
const DEFAULT_CHAT_LIMIT: int = 50

var _backend: ISocialBackend = null
var _friends_cache: Array[Dictionary] = []
var _invitations_cache: Array[Dictionary] = []
var _teams_cache: Array[Dictionary] = []
var _chat_cache: Array[Dictionary] = []
var _known_chat_ids: Dictionary = {}
var _chat_baseline_ready: bool = false
## Presence state (TDD §3.25): player code -> {online: bool, last_seen: int};
## merged from backend presence_updated deltas. Own presence is never tracked.
var _presence: Dictionary = {}
var _unavailable_warned: Dictionary = {}


func _ready() -> void:
	_backend = MockSocialBackend.new(IdentityService.get_player_code())
	# Wire the default backend's push signals too — set_backend() only wires a
	# SWAPPED backend, so without this the mock's presence seam (and any future
	# mock push) would be silently dropped.
	_backend.chat_message_received.connect(_on_chat_push)
	_backend.presence_updated.connect(_on_presence_updated)
	EventBus.social_team_changed.connect(_on_team_changed)
	EventBus.backend_state_changed.connect(_on_backend_state_changed)


## Swap point (TDD §9): pass a real ISocialBackend here.
func set_backend(backend: ISocialBackend) -> void:
	if backend == null:
		push_warning("SocialManager: ignoring null backend")
		return
	if is_instance_valid(_backend):
		if _backend.chat_message_received.is_connected(_on_chat_push):
			_backend.chat_message_received.disconnect(_on_chat_push)
		if _backend.presence_updated.is_connected(_on_presence_updated):
			_backend.presence_updated.disconnect(_on_presence_updated)
	_backend = backend
	_reset_caches()
	_backend.chat_message_received.connect(_on_chat_push)
	_backend.presence_updated.connect(_on_presence_updated)
	_sync_chat_subscription()


func get_backend() -> ISocialBackend:
	return _backend


## Local snapshot of the last good friends list (no network) — presence-driven
## row re-renders use this instead of refetching.
func get_friends_cache() -> Array[Dictionary]:
	return _friends_cache.duplicate(true)


# --- Friends --------------------------------------------------------------------

func fetch_friends() -> Array[Dictionary]:
	var result: Variant = await _backend.fetch_friends()
	if typeof(result) != TYPE_ARRAY:
		_warn_unavailable_once("fetch_friends")
		return _friends_cache
	_friends_cache = _as_dictionary_array(result)
	EventBus.social_friends_changed.emit(_friends_cache)
	_sync_presence_subscription()
	return _friends_cache


## After every successful friend fetch in real mode, (re)subscribe to presence
## for the current friend set (TDD §3.25) — the backend re-follows the diff.
## Mock mode stays inert (live features are never faked).
func _sync_presence_subscription() -> void:
	if not OnlineService.is_real_mode():
		return
	var codes: Array[String] = []
	for row in _friends_cache:
		var code := str(row.get("player_code", "")).strip_edges().to_upper()
		if not code.is_empty():
			codes.append(code)
	var result: Variant = await _backend.subscribe_presence(codes)
	if typeof(result) != TYPE_DICTIONARY:
		_warn_unavailable_once("subscribe_presence")


## Returns {ok: bool, error: String}; on success a SENT invitation exists and
## the friends + invitations lists are refetched (both changed signals render).
func add_friend(player_code: String) -> Dictionary:
	var result: Variant = await _backend.add_friend(player_code)
	if typeof(result) != TYPE_DICTIONARY:
		_warn_unavailable_once("add_friend")
		return {"ok": false, "error": "social_unavailable"}
	var response := result as Dictionary
	if not bool(response.get("ok", false)):
		return _business_or_unavailable(response, "add_friend")
	await fetch_friends()
	await fetch_invitations()
	return {"ok": true, "error": ""}


func remove_friend(player_code: String) -> void:
	await _backend.remove_friend(player_code)
	await fetch_friends()
	await fetch_invitations()


## Pending invitations in both directions; social_invitations_changed renders.
func fetch_invitations() -> Array[Dictionary]:
	var result: Variant = await _backend.fetch_invitations()
	if typeof(result) != TYPE_ARRAY:
		_warn_unavailable_once("fetch_invitations")
		return _invitations_cache
	_invitations_cache = _as_dictionary_array(result)
	EventBus.social_invitations_changed.emit(_invitations_cache)
	return _invitations_cache


## Accept/reject a received invitation, or cancel a sent one (accept=false).
func respond_invitation(player_code: String, accept: bool) -> Dictionary:
	var result: Variant = await _backend.respond_invitation(player_code, accept)
	if typeof(result) != TYPE_DICTIONARY:
		_warn_unavailable_once("respond_invitation")
		return {"ok": false, "error": "social_unavailable"}
	var response := result as Dictionary
	if not bool(response.get("ok", false)):
		return _business_or_unavailable(response, "respond_invitation")
	await fetch_friends()
	await fetch_invitations()
	return {"ok": true, "error": ""}


func block_user(player_code: String) -> Dictionary:
	var result: Variant = await _backend.block_user(player_code)
	if typeof(result) != TYPE_DICTIONARY:
		_warn_unavailable_once("block_user")
		return {"ok": false, "error": "social_unavailable"}
	var response := result as Dictionary
	if not bool(response.get("ok", false)):
		return _business_or_unavailable(response, "block_user")
	await fetch_friends()
	await fetch_invitations()
	return {"ok": true, "error": ""}


func unblock_user(player_code: String) -> Dictionary:
	var result: Variant = await _backend.unblock_user(player_code)
	if typeof(result) != TYPE_DICTIONARY or not bool((result as Dictionary).get("ok", false)):
		_warn_unavailable_once("unblock_user")
		return {"ok": false, "error": "social_unavailable"}
	return {"ok": true, "error": ""}


func fetch_blocked() -> Array[Dictionary]:
	var result: Variant = await _backend.fetch_blocked()
	if typeof(result) != TYPE_ARRAY:
		_warn_unavailable_once("fetch_blocked")
		return []
	return _as_dictionary_array(result)


# --- Teams ------------------------------------------------------------------------

func search_teams(query: String) -> Array[Dictionary]:
	var result: Variant = await _backend.search_teams(query)
	if typeof(result) != TYPE_ARRAY:
		_warn_unavailable_once("search_teams")
		return _teams_cache
	_teams_cache = _as_dictionary_array(result)
	return _teams_cache


## Writes the `team` save domain + saves via SaveSystem (the existing join
## flow, TDD §9) and announces via social_team_changed. The wholesale domain
## write also clears any pending `requested_team_id`. By-request teams fail
## with the backend's team_by_request error key (UI routes to request_join).
func join_team(team_id: String) -> Dictionary:
	var result: Variant = await _backend.join_team(team_id)
	if typeof(result) != TYPE_DICTIONARY:
		_warn_unavailable_once("join_team")
		return {"ok": false, "error": "social_unavailable"}
	var response := result as Dictionary
	if not bool(response.get("ok", false)):
		return _business_or_unavailable(response, "join_team")
	var team: Variant = response.get("team", {})
	if typeof(team) != TYPE_DICTIONARY or (team as Dictionary).is_empty():
		return {"ok": false, "error": "social_invalid_response"}
	SaveSystem.set_domain(TEAM_DOMAIN, team as Dictionary)
	SaveSystem.save_game()
	EventBus.social_team_changed.emit(team as Dictionary)
	return {"ok": true, "error": ""}


## Sends a join request for a by-request team; on success stores
## `requested_team_id` in the team domain (the "Request sent" state).
func request_join(team_id: String) -> Dictionary:
	var result: Variant = await _backend.request_join(team_id)
	if typeof(result) != TYPE_DICTIONARY:
		_warn_unavailable_once("request_join")
		return {"ok": false, "error": "social_unavailable"}
	var response := result as Dictionary
	if not bool(response.get("ok", false)):
		return _business_or_unavailable(response, "request_join")
	SaveSystem.set_value(TEAM_DOMAIN, "requested_team_id", team_id)
	SaveSystem.save_game()
	EventBus.social_team_changed.emit(SaveSystem.get_domain(TEAM_DOMAIN))
	return {"ok": true, "error": ""}


func leave_team() -> void:
	await _backend.leave_team()
	SaveSystem.set_domain(TEAM_DOMAIN, {"on_team": false})
	SaveSystem.save_game()
	EventBus.social_team_changed.emit(SaveSystem.get_domain(TEAM_DOMAIN))


## Creator = leader; on success writes the `team` domain like join_team.
func create_team(name: String, access_mode: String, banner_recipe: Dictionary) -> Dictionary:
	var result: Variant = await _backend.create_team(name, access_mode, banner_recipe)
	if typeof(result) != TYPE_DICTIONARY:
		_warn_unavailable_once("create_team")
		return {"ok": false, "error": "social_unavailable"}
	var response := result as Dictionary
	if not bool(response.get("ok", false)):
		return _business_or_unavailable(response, "create_team")
	var team: Variant = response.get("team", {})
	if typeof(team) != TYPE_DICTIONARY or (team as Dictionary).is_empty():
		return {"ok": false, "error": "social_invalid_response"}
	SaveSystem.set_domain(TEAM_DOMAIN, team as Dictionary)
	SaveSystem.save_game()
	EventBus.social_team_changed.emit(team as Dictionary)
	return {"ok": true, "error": ""}


## Leader only; updates the local `team` domain from the backend result.
func update_team_settings(settings: Dictionary) -> Dictionary:
	var result: Variant = await _backend.update_team_settings(settings)
	if typeof(result) != TYPE_DICTIONARY:
		_warn_unavailable_once("update_team_settings")
		return {"ok": false, "error": "social_unavailable"}
	var response := result as Dictionary
	if not bool(response.get("ok", false)):
		return _business_or_unavailable(response, "update_team_settings")
	var team: Variant = response.get("team", {})
	if typeof(team) != TYPE_DICTIONARY or (team as Dictionary).is_empty():
		return {"ok": false, "error": "social_invalid_response"}
	SaveSystem.set_domain(TEAM_DOMAIN, team as Dictionary)
	SaveSystem.save_game()
	EventBus.social_team_changed.emit(team as Dictionary)
	return {"ok": true, "error": ""}


## Leader only; empty for non-leaders (and off-team).
func fetch_join_requests() -> Array[Dictionary]:
	var result: Variant = await _backend.fetch_join_requests()
	if typeof(result) != TYPE_ARRAY:
		_warn_unavailable_once("fetch_join_requests")
		return []
	return _as_dictionary_array(result)


## Leader only; on success the roster changed, so the team is refreshed.
func respond_join_request(player_code: String, approve: bool) -> Dictionary:
	var result: Variant = await _backend.respond_join_request(player_code, approve)
	if typeof(result) != TYPE_DICTIONARY:
		_warn_unavailable_once("respond_join_request")
		return {"ok": false, "error": "social_unavailable"}
	var response := result as Dictionary
	if not bool(response.get("ok", false)):
		return _business_or_unavailable(response, "respond_join_request")
	await refresh_team()
	return {"ok": true, "error": ""}


## Fresh roster/stats from the backend; keeps the local domain when the
## service is off-team or unavailable.
func refresh_team() -> Dictionary:
	var result: Variant = await _backend.fetch_team()
	if typeof(result) != TYPE_DICTIONARY:
		_warn_unavailable_once("fetch_team")
		return SaveSystem.get_domain(TEAM_DOMAIN)
	var team := result as Dictionary
	if team.is_empty():
		return SaveSystem.get_domain(TEAM_DOMAIN)
	SaveSystem.set_domain(TEAM_DOMAIN, team)
	SaveSystem.save_game()
	EventBus.social_team_changed.emit(team)
	return team


# --- Chat (realtime per TDD §3.24 — v1 polling contract preserved) ------------------

## First fetch establishes the baseline silently; later fetches emit
## social_chat_message for each unseen message (catch-up after reconnects).
func fetch_chat(limit: int = DEFAULT_CHAT_LIMIT) -> Array[Dictionary]:
	var result: Variant = await _backend.fetch_chat_history(limit)
	if typeof(result) != TYPE_ARRAY:
		_warn_unavailable_once("fetch_chat")
		return _chat_cache
	_chat_cache = _as_dictionary_array(result)
	if not _chat_baseline_ready:
		for message in _chat_cache:
			_known_chat_ids[_chat_id(message)] = true
		_chat_baseline_ready = true
	else:
		for message in _chat_cache:
			var id: Variant = _chat_id(message)
			if not _known_chat_ids.has(id):
				_known_chat_ids[id] = true
				EventBus.social_chat_message.emit(message)
	return _chat_cache


## Send failures warn once and never block the UI; a bounded retry queue is a
## real-backend concern (the mock cannot fail).
func send_chat(text: String) -> Dictionary:
	var result: Variant = await _backend.send_chat_message(text)
	if typeof(result) != TYPE_DICTIONARY or not bool((result as Dictionary).get("ok", false)):
		_warn_unavailable_once("send_chat")
		return {"ok": false, "error": "social_unavailable"}
	var message: Variant = (result as Dictionary).get("message", {})
	if typeof(message) != TYPE_DICTIONARY or (message as Dictionary).is_empty():
		return {"ok": false, "error": "social_invalid_response"}
	_known_chat_ids[_chat_id(message as Dictionary)] = true
	EventBus.social_chat_message.emit(message as Dictionary)
	return {"ok": true, "error": ""}


## Realtime push from the backend socket (TDD §3.24). The server echoes the
## sender's own message too (verified live), so id-dedupe covers history
## fetch + send echo + socket push in one mechanism: known ids drop silently.
func _on_chat_push(message: Dictionary) -> void:
	var id: Variant = _chat_id(message)
	if _known_chat_ids.has(id):
		return
	_known_chat_ids[id] = true
	_chat_cache.append(message)
	EventBus.social_chat_message.emit(message)


## Subscribe while on a team + online; drop the subscription otherwise. Called
## from set_backend() and on every team/backend-state transition, so the
## socket channel always matches the player's current state.
func _sync_chat_subscription() -> void:
	var on_team := bool(SaveSystem.get_domain(TEAM_DOMAIN).get("on_team", false))
	if on_team and OnlineService.is_online():
		var result: Variant = await _backend.subscribe_chat()
		if typeof(result) != TYPE_DICTIONARY:
			_warn_unavailable_once("subscribe_chat")
		return
	await _backend.unsubscribe_chat()


func _on_team_changed(_team: Dictionary) -> void:
	await _sync_chat_subscription()


## Re-online while on a team: resubscribe, then catch up on messages missed
## while offline (id-dedupe makes the overlap with the subscription harmless).
func _on_backend_state_changed(online: bool) -> void:
	await _sync_chat_subscription()
	if online and bool(SaveSystem.get_domain(TEAM_DOMAIN).get("on_team", false)):
		await fetch_chat()


# --- Presence (TDD §3.25) -----------------------------------------------------------

## The UI lookup: {online: bool, last_seen: int}; unknown codes get the
## offline default so rows render their plain level line.
func get_presence(player_code: String) -> Dictionary:
	var entry: Variant = _presence.get(player_code, null)
	if entry == null:
		return {"online": false, "last_seen": 0}
	return (entry as Dictionary).duplicate(true)


## Batched delta from the backend socket. Merges into _presence (last_seen only
## ever moves forward — a leave stamp of "now" wins over stale storage reads)
## and re-emits ONLY the entries that actually changed, batched in one signal.
func _on_presence_updated(delta: Dictionary) -> void:
	var changed := {}
	for code in delta.keys():
		var d: Variant = delta.get(code, {})
		if typeof(d) != TYPE_DICTIONARY:
			continue
		var current: Variant = _presence.get(str(code), null)
		var online := false
		var last_seen := 0
		if current != null:
			online = bool((current as Dictionary).get("online", false))
			last_seen = int((current as Dictionary).get("last_seen", 0))
		var new_online := bool((d as Dictionary).get("online", online))
		var new_last := int((d as Dictionary).get("last_seen", 0))
		if new_last < last_seen:
			new_last = last_seen
		if new_online == online and new_last == last_seen:
			continue
		_presence[str(code)] = {"online": new_online, "last_seen": new_last}
		changed[str(code)] = {"online": new_online, "last_seen": new_last}
	if not changed.is_empty():
		EventBus.social_presence_changed.emit(changed)


# --- Internals --------------------------------------------------------------------

## Warn-once-per-session for "service unavailable": first failure warns,
## repeats stay quiet (TDD §3.16).
func _warn_unavailable_once(operation: String) -> void:
	if _unavailable_warned.has(operation):
		return
	_unavailable_warned[operation] = true
	push_warning("SocialManager: %s unavailable; keeping last good state" % operation)


## A backend {ok: false} with a NON-empty error key is a business failure —
## surface the key as-is (no warn); an empty error means "no such entity" or
## transport trouble -> social_unavailable + warn-once.
func _business_or_unavailable(response: Dictionary, operation: String) -> Dictionary:
	var error := str(response.get("error", ""))
	if not error.is_empty():
		return {"ok": false, "error": error}
	_warn_unavailable_once(operation)
	return {"ok": false, "error": "social_unavailable"}


func _reset_caches() -> void:
	_friends_cache = []
	_invitations_cache = []
	_teams_cache = []
	_chat_cache = []
	_known_chat_ids = {}
	_chat_baseline_ready = false
	_presence = {}
	_unavailable_warned = {}


static func _chat_id(message: Dictionary) -> Variant:
	return message.get("id", "")


func _as_dictionary_array(value: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry in value:
		if typeof(entry) == TYPE_DICTIONARY:
			out.append(entry as Dictionary)
	return out

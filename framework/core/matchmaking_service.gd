extends Node
## MatchmakingService (TDD §3.27): the ONLY owner of queue/match state. The HOOK
## only — v1 proves queue -> matched -> realtime match room between real clients;
## no in-match gameplay rides it yet (post-E4 content plugs into the states +
## the attached NakamaMultiplayerBridge). Mock mode is INERT (never faked — GDD §8
## gating table): enqueue refuses, cancel still cleans up local state.
##
## Live-verified semantics (spike 2026-11-09, folded into probe_nakama.gd):
## - The matchmaker forms matches on a 15s default interval (config.go
##   IntervalSec) — queue waits can reach ~15s; the UI shows an indeterminate
##   "searching" state, never a countdown promise.
## - `MatchmakerMatched.users` carries ALL matched users INCLUDING self —
##   opponent rows are built by subtracting self_user (username = player code).
## - The join ack's `size` is racy for sequential joins; membership proof is the
##   match-presence JOIN event, not the ack.
##
## Socket design: ONE dedicated socket per queue session, opened via
## OnlineService.create_socket() and closed on cancel/leave/offline (two
## concurrent sockets per user are fine — verified in E1). The join itself is
## owned by the addon's NakamaMultiplayerBridge (start_matchmaking auto-joins on
## matched + runs host election); the service listens to the raw matched event
## only for the UI state payload.

const STATE_IDLE: String = "idle"
const STATE_QUEUED: String = "queued"
const STATE_MATCHED: String = "matched"
const STATE_IN_MATCH: String = "in_match"
const MIN_PLAYERS: int = 2
const MAX_PLAYERS: int = 2

var _state: String = STATE_IDLE
var _ticket: String = ""
# Untyped on purpose (documented exception): tests inject a duck-typed fake
# socket through the factory seam below.
var _socket = null
var _bridge: NakamaMultiplayerBridge = null
var _match_id: String = ""
var _opponents: Array[Dictionary] = []
## Test seam: defaults to the real factory; tests swap in a fake-socket factory.
var _socket_factory: Callable = func() -> Variant: return OnlineService.create_socket()


func _ready() -> void:
	EventBus.backend_state_changed.connect(_on_backend_state_changed)


# --- Availability / accessors ------------------------------------------------------

## Matchmaking needs a VERIFIED real backend; mock mode is inert by design.
func is_available() -> bool:
	return OnlineService.is_real_mode() and OnlineService.is_online()


func get_state() -> String:
	return _state


## Opponent rows {name, player_code} (self excluded); empty outside matched states.
func get_opponents() -> Array[Dictionary]:
	return _opponents


## Test seam: restore the real socket factory after a test injected a fake.
func reset_socket_factory() -> void:
	_socket_factory = func() -> Variant: return OnlineService.create_socket()


# --- Queue lifecycle ------------------------------------------------------------------

## Enqueue into the 1v1 pool. ONE queue at a time (enqueue while active = no-op
## error). Returns {ok, error}; await it (socket connect + add are async).
func enqueue() -> Dictionary:
	if _state != STATE_IDLE:
		return {"ok": false, "error": "already_queued"}
	if not is_available():
		return {"ok": false, "error": "unavailable"}
	var session := OnlineService.get_session()
	if session == null:
		return {"ok": false, "error": "unavailable"}
	var socket: Variant = _socket_factory.call()
	if socket == null:
		return {"ok": false, "error": "no_socket"}
	var connected: Variant = await socket.connect_async(session, true)
	if connected.is_exception():
		_close_socket(socket)
		return {"ok": false, "error": str(connected.get_exception()).left(80)}
	var ticket_res: Variant = await socket.add_matchmaker_async("*", MIN_PLAYERS, MAX_PLAYERS)
	if ticket_res.is_exception():
		_close_socket(socket)
		return {"ok": false, "error": str(ticket_res.get_exception()).left(80)}
	_socket = socket
	_ticket = str(ticket_res.ticket)
	# Connect BEFORE building the bridge: its _init also listens to
	# received_matchmaker_matched, and dispatch order follows connection order.
	# Our handler must run first so the UI sees queued->matched (with opponents)
	# before a join ack that completes synchronously promotes us straight to
	# in_match — otherwise the dialog renders the room with empty opponents.
	socket.received_matchmaker_matched.connect(_on_socket_matched)
	_bridge = NakamaMultiplayerBridge.new(socket)
	# The bridge filters by ticket (stale matched events are ignored) and owns
	# the join: auto-join on matched + host election for the multiplayer peer.
	_bridge.start_matchmaking(ticket_res)
	_bridge.match_joined.connect(_on_bridge_match_joined)
	_set_state(STATE_QUEUED, {})
	return {"ok": true}


## Leave the queue / match room and go idle. No-op when already idle.
func cancel() -> void:
	if _state == STATE_IDLE:
		return
	var socket: Variant = _socket
	_socket = null
	if socket != null and is_instance_valid(socket) \
			and socket.received_matchmaker_matched.is_connected(_on_socket_matched):
		socket.received_matchmaker_matched.disconnect(_on_socket_matched)
	if _bridge != null:
		if _bridge.match_joined.is_connected(_on_bridge_match_joined):
			_bridge.match_joined.disconnect(_on_bridge_match_joined)
		# Fire-and-forget: remove ticket + leave match. Closing the socket right
		# after makes server-side session teardown the authoritative cleanup —
		# a pending RPC on a closed socket fails silently by design.
		_bridge.leave()
		_bridge = null
	_close_socket(socket)
	_ticket = ""
	_match_id = ""
	_opponents.clear()
	_set_state(STATE_IDLE, {})


# --- Event handlers ----------------------------------------------------------------------

## Wire shape (verified): `users` includes SELF — subtract self_user. Username
## is the player code (auth design), so name and code share the value in v1.
## Ordering note: the bridge's handler and this one listen to the SAME signal
## (bridge first — it connected in its _init), and the join ack can complete
## before or after this handler runs. Both orderings must land on in_match with
## opponents populated, so the state guards below are ordering-tolerant: record
## opponents whenever the ticket matches and we're not idle; only promote
## queued->matched when still queued (in_match never downgrades).
func _on_socket_matched(matched: Variant) -> void:
	if str(matched.ticket) != _ticket or _state == STATE_IDLE:
		return
	var self_id := str(matched.self_user.presence.user_id)
	var opponents: Array[Dictionary] = []
	for u in matched.users:
		var presence: Variant = u.presence
		if str(presence.user_id) == self_id:
			continue
		opponents.append({"name": str(presence.username), "player_code": str(presence.username)})
	_opponents = opponents
	if _state == STATE_QUEUED:
		_set_state(STATE_MATCHED, {"opponents": opponents})


## The bridge finished join + host election — the realtime room is live. Accepts
## queued too: if the join ack beat the matched event's UI transition (see the
## ordering note on _on_socket_matched), skip straight to in_match.
func _on_bridge_match_joined() -> void:
	if _bridge == null or (_state != STATE_MATCHED and _state != STATE_QUEUED):
		return
	_match_id = str(_bridge.match_id)
	_set_state(STATE_IN_MATCH, {"match_id": _match_id})


## Backend drop while queued/matched/in-match: the socket is dead — clean up.
func _on_backend_state_changed(online: bool) -> void:
	if not online and _state != STATE_IDLE:
		cancel()


# --- Internals -----------------------------------------------------------------------------

func _set_state(new_state: String, payload: Dictionary) -> void:
	if new_state == _state:
		return
	_state = new_state
	EventBus.matchmaking_state_changed.emit(new_state, payload)


func _close_socket(socket: Variant) -> void:
	if socket == null or not is_instance_valid(socket):
		return
	socket.close()

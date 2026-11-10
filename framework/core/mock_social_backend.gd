class_name MockSocialBackend
extends ISocialBackend
## FULL LOCAL SIMULATION of the ISocialBackend v2+ surface (TDD §3.16, D5a):
## a fake user directory + friendships + pending invitations (both directions)
## + block lists + teams with settings/join requests, all in-process state.
## Every flow is exercisable headless; reset() reseeds. The one documented
## simplification vs Nakama: no cross-device simultaneity (one local player
## per process). Constructor takes the local player code; an empty argument
## falls back to IdentityService.get_player_code().

const ACCESS_OPEN: String = "open"
const ACCESS_BY_REQUEST: String = "by-request"
const ACCESS_MODES: Array[String] = [ACCESS_OPEN, ACCESS_BY_REQUEST]
const MAX_TEAM_NAME_LENGTH: int = 24
## The local player's display name in the mock world (legacy seed rows used it).
const LOCAL_NAME: String = "You"

var _local_code: String = ""
var _users: Dictionary = {}  # code -> {name, level, best_score, portrait_*}
var _friendships: Dictionary = {}  # sorted "a|b" pair key -> true
var _invitations: Dictionary = {}  # "<from>|<to>" -> {from_code, to_code, ts}
var _blocks: Dictionary = {}  # blocker code -> Array[String] of blocked codes
var _teams_by_id: Dictionary = {}  # team_id -> team entry (see _seed_data)
var _join_requests: Dictionary = {}  # team_id -> Array[Dictionary] {player_code, name, ts}
var _chat_history: Array[Dictionary] = []
var _next_chat_id: int = 1
var _chat_subscribed: bool = false
var _joined_team_id: String = ""
var _created_team_count: int = 0


func _init(local_player_code: String = "") -> void:
	_local_code = local_player_code.strip_edges()
	if _local_code.is_empty():
		_local_code = IdentityService.get_player_code()
	_seed_data()


## Re-seeds all mock state (test isolation: the manager's backend is a
## process-wide singleton in the GUT run). Keeps the local player code.
func reset() -> void:
	_seed_data()


# --- Friends ---------------------------------------------------------------------

func fetch_friends() -> Variant:
	var out: Array[Dictionary] = []
	for pair_key in _friendships.keys():
		var codes := str(pair_key).split("|", true, 1)
		if codes.size() != 2:
			continue
		var other: String = codes[1] if codes[0] == _local_code else codes[0]
		if other != _local_code:
			out.append(_user_row(other))
	return out


func add_friend(player_code: String) -> Variant:
	var code := player_code.strip_edges().to_upper()
	if not _is_valid_code(code):
		return {"ok": false, "error": "friend_invalid_code"}
	if not _users.has(code):
		return {"ok": false, "error": "friend_unknown_code"}
	if _friendships.has(_pair_key(_local_code, code)):
		return {"ok": false, "error": "friend_already_added"}
	if _pending_exists(_local_code, code) or _pending_exists(code, _local_code):
		return {"ok": false, "error": "friend_pending_exists"}
	if _is_blocked_pair(_local_code, code):
		return {"ok": false, "error": "friend_blocked"}
	# The LOCAL player sends the invitation TO the target.
	_invitations[_invitation_key(_local_code, code)] = {
		"from_code": _local_code,
		"to_code": code,
		"ts": Time.get_unix_time_from_system(),
	}
	return {"ok": true, "error": ""}


func remove_friend(player_code: String) -> void:
	var code := player_code.strip_edges().to_upper()
	_remove_pair(_local_code, code)
	_remove_pending(_local_code, code)
	_remove_pending(code, _local_code)


func fetch_invitations() -> Variant:
	var out: Array[Dictionary] = []
	for entry in _invitations.values():
		var from := str((entry as Dictionary).get("from_code", ""))
		var to := str((entry as Dictionary).get("to_code", ""))
		if from == _local_code:
			out.append({"player_code": to, "name": _name_for(to), "direction": "sent", "ts": int((entry as Dictionary).get("ts", 0))})
		elif to == _local_code:
			out.append({"player_code": from, "name": _name_for(from), "direction": "received", "ts": int((entry as Dictionary).get("ts", 0))})
	return out


func respond_invitation(player_code: String, accept: bool) -> Variant:
	var code := player_code.strip_edges().to_upper()
	if _pending_exists(code, _local_code):
		_remove_pending(code, _local_code)
		if accept:
			_ensure_user(code)
			_add_pair(_local_code, code)
		return {"ok": true, "error": ""}
	if not accept and _pending_exists(_local_code, code):
		_remove_pending(_local_code, code)
		return {"ok": true, "error": ""}
	return {"ok": false, "error": "friend_no_pending"}


func block_user(player_code: String) -> Variant:
	var code := player_code.strip_edges().to_upper()
	if not _is_valid_code(code):
		return {"ok": false, "error": "friend_invalid_code"}
	var blocked: Array = _blocks.get(_local_code, [])
	if not blocked.has(code):
		blocked.append(code)
		_blocks[_local_code] = blocked
	_remove_pair(_local_code, code)
	_remove_pending(_local_code, code)
	_remove_pending(code, _local_code)
	return {"ok": true, "error": ""}


func unblock_user(player_code: String) -> Variant:
	var code := player_code.strip_edges().to_upper()
	if _blocks.has(_local_code):
		(_blocks[_local_code] as Array).erase(code)
	return {"ok": true, "error": ""}


func fetch_blocked() -> Variant:
	var out: Array[Dictionary] = []
	for code in _blocks.get(_local_code, []):
		out.append({"player_code": str(code), "name": _name_for(str(code))})
	return out


# --- Teams -------------------------------------------------------------------------

func search_teams(query: String) -> Variant:
	var q := query.strip_edges().to_lower()
	var out: Array[Dictionary] = []
	for id in _teams_by_id.keys():
		var team: Dictionary = _teams_by_id[id]
		if q.is_empty() or str(team.get("name", "")).to_lower().contains(q):
			out.append(_team_row(team))
	return out


func join_team(team_id: String) -> Variant:
	var team: Variant = _teams_by_id.get(team_id, null)
	if team == null:
		return {"ok": false, "error": "", "team": {}}
	var t := team as Dictionary
	if str(t.get("access_mode", ACCESS_OPEN)) != ACCESS_OPEN:
		return {"ok": false, "error": "team_by_request", "team": {}}
	var members: Array = t.get("members", [])
	if not members.has(LOCAL_NAME):
		members.append(LOCAL_NAME)
	_joined_team_id = team_id
	return {"ok": true, "error": "", "team": _team_domain_shape(t)}


func request_join(team_id: String) -> Variant:
	var team: Variant = _teams_by_id.get(team_id, null)
	if team == null:
		return {"ok": false, "error": "", "pending": false}
	var t := team as Dictionary
	if str(t.get("access_mode", ACCESS_OPEN)) == ACCESS_OPEN:
		return {"ok": false, "error": "team_open", "pending": false}
	if (t.get("members", []) as Array).has(LOCAL_NAME):
		return {"ok": false, "error": "team_already_member", "pending": false}
	var requests: Array = _join_requests.get(team_id, [])
	for request in requests:
		if str((request as Dictionary).get("player_code", "")) == _local_code:
			return {"ok": false, "error": "team_request_pending", "pending": true}
	requests.append({"player_code": _local_code, "name": LOCAL_NAME, "ts": Time.get_unix_time_from_system()})
	_join_requests[team_id] = requests
	return {"ok": true, "error": "", "pending": true}


func leave_team() -> void:
	if not _joined_team_id.is_empty():
		var team: Variant = _teams_by_id.get(_joined_team_id, null)
		if team != null:
			((team as Dictionary).get("members", []) as Array).erase(LOCAL_NAME)
	_joined_team_id = ""


func fetch_team() -> Variant:
	if _joined_team_id.is_empty():
		return {}
	var team: Variant = _teams_by_id.get(_joined_team_id, null)
	if team == null:
		return {}
	return _team_domain_shape(team as Dictionary)


func create_team(name: String, access_mode: String, banner_recipe: Dictionary) -> Variant:
	var clean := name.strip_edges()
	if clean.is_empty() or clean.length() > MAX_TEAM_NAME_LENGTH:
		return {"ok": false, "error": "team_invalid_name", "team": {}}
	if not ACCESS_MODES.has(access_mode):
		return {"ok": false, "error": "team_invalid_name", "team": {}}
	if not _joined_team_id.is_empty():
		return {"ok": false, "error": "team_already_on_team", "team": {}}
	_created_team_count += 1
	var team_id := "mock_created_%d" % _created_team_count
	var entry := {
		"team_id": team_id,
		"name": clean,
		"access_mode": access_mode,
		"power": 0,
		"members": [LOCAL_NAME],
		"banner_recipe": (banner_recipe if banner_recipe != null else {}).duplicate(true),
		"leader_code": _local_code,
		"leader_name": LOCAL_NAME,
	}
	_teams_by_id[team_id] = entry
	_joined_team_id = team_id
	return {"ok": true, "error": "", "team": _team_domain_shape(entry)}


func update_team_settings(settings: Dictionary) -> Variant:
	var team: Variant = _teams_by_id.get(_joined_team_id, null)
	if team == null or str((team as Dictionary).get("leader_code", "")) != _local_code:
		return {"ok": false, "error": "team_not_leader", "team": {}}
	var t := team as Dictionary
	if settings.has("name"):
		var clean := str(settings.get("name", "")).strip_edges()
		if clean.is_empty() or clean.length() > MAX_TEAM_NAME_LENGTH:
			return {"ok": false, "error": "team_invalid_name", "team": {}}
		t["name"] = clean
	if settings.has("access_mode"):
		var mode := str(settings.get("access_mode", ""))
		if not ACCESS_MODES.has(mode):
			return {"ok": false, "error": "team_invalid_name", "team": {}}
		t["access_mode"] = mode
	if settings.has("banner_recipe"):
		var recipe: Variant = settings.get("banner_recipe", {})
		if typeof(recipe) == TYPE_DICTIONARY:
			t["banner_recipe"] = (recipe as Dictionary).duplicate(true)
	return {"ok": true, "error": "", "team": _team_domain_shape(t)}


func fetch_join_requests() -> Variant:
	if _joined_team_id.is_empty():
		return []
	var team: Variant = _teams_by_id.get(_joined_team_id, null)
	if team == null or str((team as Dictionary).get("leader_code", "")) != _local_code:
		return []
	var out: Array[Dictionary] = []
	for request in _join_requests.get(_joined_team_id, []):
		out.append((request as Dictionary).duplicate(true))
	return out


func respond_join_request(player_code: String, approve: bool) -> Variant:
	if _joined_team_id.is_empty():
		return {"ok": false, "error": "team_not_leader"}
	var team: Variant = _teams_by_id.get(_joined_team_id, null)
	if team == null or str((team as Dictionary).get("leader_code", "")) != _local_code:
		return {"ok": false, "error": "team_not_leader"}
	var code := player_code.strip_edges().to_upper()
	var requests: Array = _join_requests.get(_joined_team_id, [])
	for i in requests.size():
		if str((requests[i] as Dictionary).get("player_code", "")) == code:
			var request := requests[i] as Dictionary
			requests.remove_at(i)
			if approve:
				((team as Dictionary).get("members", []) as Array).append(str(request.get("name", "")))
			return {"ok": true, "error": ""}
	return {"ok": false, "error": ""}


# --- Chat --------------------------------------------------------------------------

func fetch_chat_history(limit: int) -> Variant:
	if limit <= 0 or limit >= _chat_history.size():
		return _chat_history.duplicate(true)
	var out := _chat_history.slice(_chat_history.size() - limit)
	return (out as Array).duplicate(true)


func send_chat_message(text: String) -> Variant:
	var message := {
		"id": _next_chat_id,
		"sender_code": _local_code,
		"sender_name": LOCAL_NAME,
		"text": text,
		"ts": Time.get_unix_time_from_system(),
	}
	_next_chat_id += 1
	_chat_history.append(message)
	return {"ok": true, "message": message.duplicate(true)}


func subscribe_chat() -> Variant:
	if _joined_team_id.is_empty():
		return {"ok": false, "error": "chat_no_team"}
	_chat_subscribed = true
	return {"ok": true, "error": ""}


func unsubscribe_chat() -> void:
	_chat_subscribed = false


# --- Presence (v3+ — TDD §3.25) --------------------------------------------------------

var _presence_followed: Array[String] = []


func subscribe_presence(friend_codes: Array[String]) -> Variant:
	_presence_followed = friend_codes.duplicate()
	return {"ok": true, "error": ""}


func unsubscribe_presence() -> void:
	_presence_followed = []


## Test seam mirroring a real status-presence push (TDD §3.25): emits
## presence_updated with a single-entry delta. Own presence is never tracked.
func set_friend_presence(code: String, online: bool, last_seen: int = 0) -> void:
	presence_updated.emit({code.to_upper(): {"online": online, "last_seen": last_seen}})


## Test seam mirroring the real socket push (TDD §3.24): records the message in
## history and emits chat_message_received — but ONLY while a subscription is
## active (a real socket delivers nothing otherwise). Returns the message
## either way so tests can assert on both behaviors.
func simulate_incoming_chat(sender_code: String, sender_name: String, text: String) -> Dictionary:
	var message := {
		"id": _next_chat_id,
		"sender_code": sender_code,
		"sender_name": sender_name,
		"text": text,
		"ts": Time.get_unix_time_from_system(),
	}
	_next_chat_id += 1
	_chat_history.append(message)
	if _chat_subscribed:
		chat_message_received.emit(message.duplicate(true))
	return message


# --- Internals -----------------------------------------------------------------------

func _seed_data() -> void:
	_chat_subscribed = false
	_presence_followed = []
	_users = {}
	for spec in [
		["Ada", 1240, 7, "gold", "ring_gold", "crown_gold"],
		["Grace", 980, 5, "diamond", "capsule_blue", ""],
		["Linus", 460, 3, "silver", "none", "crown_silver"],
		["Mia", 620, 4, "classic", "", ""],
		["Kofi", 310, 2, "classic", "", ""],
	]:
		var s: Array = spec
		_users[_code_for(str(s[0]))] = {
			"name": str(s[0]),
			"best_score": int(s[1]),
			"level": int(s[2]),
			"portrait_icon": str(s[3]),
			"portrait_flair": str(s[4]),
			"portrait_crown": str(s[5]),
		}

	_friendships = {}
	for name in ["Ada", "Grace", "Linus"]:
		_add_pair(_local_code, _code_for(name))

	# One RECEIVED pending invitation so the invitations section is visible on
	# first open (Mia is a directory user who is not yet a friend).
	_invitations = {}
	_invitations[_invitation_key(_code_for("Mia"), _local_code)] = {
		"from_code": _code_for("Mia"),
		"to_code": _local_code,
		"ts": Time.get_unix_time_from_system(),
	}

	_blocks = {}

	_teams_by_id = {}
	for team in [
		{"name": "Golden Owls", "access_mode": ACCESS_OPEN, "power": 4200, "members": ["Ada", LOCAL_NAME], "leader": "Ada",
		 "banner_recipe": {"base": "base_01", "base_lut": "lut_01", "icon": "icon_01", "icon_lut": "lut_02"}},
		{"name": "Blue Tide", "access_mode": ACCESS_OPEN, "power": 3100, "members": ["Grace", "Linus"], "leader": "Grace",
		 "banner_recipe": {"base": "base_04", "base_lut": "lut_05", "icon": "icon_07", "icon_lut": "lut_03"}},
		{"name": "Emerald Foxes", "access_mode": ACCESS_BY_REQUEST, "power": 2750, "members": ["Mia", "Kofi"], "leader": "Mia",
		 "banner_recipe": {"base": "base_08", "base_lut": "lut_12", "icon": "icon_12", "icon_lut": "lut_08"}},
	]:
		var entry := (team as Dictionary).duplicate(true)
		var leader_code := _code_for(str(entry.get("leader", "")))
		entry["leader_name"] = str(entry.get("leader", ""))
		entry.erase("leader")
		entry["team_id"] = _team_id_for(str(team.get("name", "")))
		entry["leader_code"] = leader_code
		_teams_by_id[str(entry["team_id"])] = entry

	_join_requests = {}

	_chat_history = [
		_chat_message(1, "Ada", "gl hf tonight!"),
		_chat_message(2, LOCAL_NAME, "ready when you are"),
		_chat_message(3, "Grace", "brb, grabbing snacks"),
	]
	_next_chat_id = 4
	_joined_team_id = ""
	_created_team_count = 0


func _team_row(team: Dictionary) -> Dictionary:
	return {
		"team_id": str(team.get("team_id", "")),
		"name": str(team.get("name", "")),
		"access_mode": str(team.get("access_mode", ACCESS_OPEN)),
		"power": int(team.get("power", 0)),
		"members": (team.get("members", []) as Array).duplicate(true),
		"banner_recipe": (team.get("banner_recipe", {}) as Dictionary).duplicate(true),
	}


func _team_domain_shape(team: Dictionary) -> Dictionary:
	var recipe := team.get("banner_recipe", {}) as Dictionary
	var members: Array = (team.get("members", []) as Array).duplicate(true)
	# Parallel to `members` (TDD §3.25): presence lookups key on player codes,
	# and the mock derives them deterministically from display names.
	var member_codes: Array = []
	for member in members:
		member_codes.append(_code_for(str(member)))
	return {
		"on_team": true,
		"team_name": str(team.get("name", "")),
		"access_mode": str(team.get("access_mode", ACCESS_OPEN)),
		"banner_base": str(recipe.get("base", "")),
		"banner_icon": str(recipe.get("icon", "")),
		"banner_base_lut": str(recipe.get("base_lut", "")),
		"banner_icon_lut": str(recipe.get("icon_lut", "")),
		"banner_icon_scale": float(recipe.get("icon_scale", 1.0)),
		"power": int(team.get("power", 0)),
		"members": members,
		"member_codes": member_codes,
		"leader_code": str(team.get("leader_code", "")),
		"leader_name": str(team.get("leader_name", "")),
	}


func _user_row(code: String) -> Dictionary:
	_ensure_user(code)
	var row := (_users[code] as Dictionary).duplicate(true)
	row["player_code"] = code
	# TDD §3.26: friend rows carry a user_id (real mode = Nakama UUID; the mock
	# synthesizes a stable fake so both backends share the row shape).
	row["user_id"] = _user_id_for(code)
	return row


## Stable deterministic fake id per player code (never a real UUID).
static func _user_id_for(code: String) -> String:
	return "mock-user-" + code.to_lower().replace("-", "")


func _ensure_user(code: String) -> void:
	if not _users.has(code):
		_users[code] = {
			"name": code,
			"best_score": 0,
			"level": 1,
			"portrait_icon": "classic",
			"portrait_flair": "none",
			"portrait_crown": "none",
		}


func _name_for(code: String) -> String:
	if _users.has(code):
		return str((_users[code] as Dictionary).get("name", code))
	return code


func _code_for(name: String) -> String:
	return IdentityService.derive_player_code("mock:" + name)


func _team_id_for(team_name: String) -> String:
	return "mock_" + team_name.to_lower().replace(" ", "_")


func _chat_message(id: int, sender_name: String, text: String) -> Dictionary:
	var code := _local_code if sender_name == LOCAL_NAME else _code_for(sender_name)
	return {
		"id": id,
		"sender_code": code,
		"sender_name": sender_name,
		"text": text,
		"ts": Time.get_unix_time_from_system(),
	}


func _invitation_key(from_code: String, to_code: String) -> String:
	return from_code + "|" + to_code


func _pair_key(a: String, b: String) -> String:
	if a < b:
		return a + "|" + b
	return b + "|" + a


func _add_pair(a: String, b: String) -> void:
	_friendships[_pair_key(a, b)] = true


func _remove_pair(a: String, b: String) -> void:
	_friendships.erase(_pair_key(a, b))


func _pending_exists(from_code: String, to_code: String) -> bool:
	return _invitations.has(_invitation_key(from_code, to_code))


func _remove_pending(from_code: String, to_code: String) -> void:
	_invitations.erase(_invitation_key(from_code, to_code))


func _is_blocked_pair(a: String, b: String) -> bool:
	for code in _blocks.get(a, []):
		if str(code) == b:
			return true
	for code in _blocks.get(b, []):
		if str(code) == a:
			return true
	return false


func _is_valid_code(code: String) -> bool:
	var parts := code.split("-", true, 1)
	if parts.size() != 2:
		return false
	if not IdentityService.CODE_WORDS.has(parts[0]):
		return false
	var digits := parts[1]
	if digits.length() != 4:
		return false
	for c in digits:
		if not ("0" <= c and c <= "9"):
			return false
	return true

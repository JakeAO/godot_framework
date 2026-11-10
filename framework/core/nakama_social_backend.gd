class_name NakamaSocialBackend
extends ISocialBackend
## Real ISocialBackend on Nakama (TDD §3.17 mapping table). The session comes
## from OnlineService per call — null = unavailable -> return null (the §3.16
## failure signal; the manager falls back to last-good cache + warn-once).
## Business failures return {ok: false, error: "<key>"} with mock-compatible keys.
## Static pure mappers take API objects so GUT can pin shapes against recorded
## fixtures without a client or network.
##
## Verified Nakama 3.37.0 semantics baked in here (NOTES.md):
## - friend edges are two-way; from the caller's ListFriends perspective:
##   0=friends, 1=sent pending, 2=received pending, 3=I-block-them;
## - AddFriends SILENTLY no-ops on pending/blocked pairs, so business error
##   keys require pre-checking the edge via ListFriends;
## - group channel id = "3.<group_id>.." (mode.subject.subcontext.label with
##   empty subcontext+label — two trailing dots);
## - profile summaries live in storage objects (collection "profile", key
##   "summary") because user metadata is NOT client-writable in Nakama 3.x.

const ACCESS_OPEN: String = "open"
const ACCESS_BY_REQUEST: String = "by-request"
const ACCESS_MODES: Array[String] = [ACCESS_OPEN, ACCESS_BY_REQUEST]
const MAX_TEAM_NAME_LENGTH: int = 24
const PROFILE_COLLECTION: String = "profile"
const SUMMARY_KEY: String = "summary"
## Last-seen stamp (TDD §3.25): OnlineService writes {"ts": unix} here on
## session establishment + best-effort at exit; friend rows read it back for
## offline friends via the _summaries_for batch read.
const LAST_SEEN_KEY: String = "last_seen"
const TEAM_OPS_FUNCTION: String = "team_ops"

# Friend edge states (core_friend.go v3.37.0, caller's perspective).
const EDGE_FRIENDS: int = 0
const EDGE_SENT: int = 1
const EDGE_RECEIVED: int = 2
const EDGE_BLOCKED: int = 3

# Group edge states (core_group.go v3.37.0).
const GROUP_OWNER: int = 0
const GROUP_ADMIN: int = 1
const GROUP_MEMBER: int = 2
const GROUP_REQUESTER: int = 3

var _client: NakamaClient
## ONE lazily-opened websocket shared by chat (TDD §3.17 send path, §3.24
## realtime) and presence (§3.25). Always connected with appear_online=true so
## this client is visible to followers; reopened when dead (prototype-grade).
var _socket: NakamaSocket = null
var _socket_channel_id: String = ""
## Active presence follows, player code -> true (TDD §3.25). Server-side follow
## state is per-socket, so a reopen re-follows the whole set.
var _presence_followed: Dictionary = {}
## Display names resolved by the history fetches (user_id -> name); realtime
## pushes look up here before falling back to the username (= player code).
var _sender_names: Dictionary = {}


func _init(client: NakamaClient) -> void:
	_client = client


# --- Friends ---------------------------------------------------------------------

func fetch_friends() -> Variant:
	var session := _session()
	if session == null:
		return null
	var result: NakamaAPI.ApiFriendList = await _client.list_friends_async(session, EDGE_FRIENDS)
	if result.is_exception():
		return null
	var ids: Array = []
	for entry in result.friends:
		var friend := entry as NakamaAPI.ApiFriend
		if friend != null and friend.user != null:
			ids.append(str(friend.user.id))
	var summaries := await _summaries_for(session, ids)
	var rows: Array[Dictionary] = []
	for entry in result.friends:
		var friend := entry as NakamaAPI.ApiFriend
		if friend == null or friend.user == null:
			continue
		rows.append(map_user_row(str(friend.user.username), summaries.get(str(friend.user.id), {}) as Dictionary, str(friend.user.id)))
	return rows


func add_friend(player_code: String) -> Variant:
	var session := _session()
	if session == null:
		return null
	var code := player_code.strip_edges().to_upper()
	if not _is_valid_code(code):
		return {"ok": false, "error": "friend_invalid_code"}
	var target := await _resolve_user(session, code)
	if target == null:
		return {"ok": false, "error": "friend_unknown_code"}
	# Pre-check the edge: AddFriends silently no-ops on pending/blocked pairs
	# (verified core_friend.go), so the business key must come from the edge.
	var edge := await _my_edge_state(session, str(target.id))
	match edge:
		EDGE_FRIENDS:
			return {"ok": false, "error": "friend_already_added"}
		EDGE_SENT, EDGE_RECEIVED:
			return {"ok": false, "error": "friend_pending_exists"}
		EDGE_BLOCKED:
			return {"ok": false, "error": "friend_blocked"}
	var result: NakamaAsyncResult = await _client.add_friends_async(session, [str(target.id)], null)
	if result.is_exception():
		return null
	return {"ok": true, "error": ""}


func remove_friend(player_code: String) -> void:
	var session := _session()
	if session == null:
		return
	var target := await _resolve_user(session, player_code)
	if target != null:
		await _client.delete_friends_async(session, [str(target.id)], null)


func fetch_invitations() -> Variant:
	var session := _session()
	if session == null:
		return null
	var result: NakamaAPI.ApiFriendList = await _client.list_friends_async(session)
	if result.is_exception():
		return null
	var ids: Array = []
	for entry in result.friends:
		var friend := entry as NakamaAPI.ApiFriend
		if friend != null and friend.user != null and int(friend.state) > EDGE_FRIENDS:
			ids.append(str(friend.user.id))
	var summaries := await _summaries_for(session, ids)
	var rows: Array[Dictionary] = []
	for entry in result.friends:
		var friend := entry as NakamaAPI.ApiFriend
		if friend == null or friend.user == null:
			continue
		var state := int(friend.state)
		if state != EDGE_SENT and state != EDGE_RECEIVED:
			continue
		rows.append({
			"player_code": str(friend.user.username),
			"name": name_from_summary(str(friend.user.username), summaries.get(str(friend.user.id), {}) as Dictionary),
			"direction": "sent" if state == EDGE_SENT else "received",
			"ts": _parse_ts(friend.update_time),
		})
	return rows


func respond_invitation(player_code: String, accept: bool) -> Variant:
	var session := _session()
	if session == null:
		return null
	var target := await _resolve_user(session, player_code)
	if target == null:
		return {"ok": false, "error": "friend_no_pending"}
	var edge := await _my_edge_state(session, str(target.id))
	if accept and edge == EDGE_RECEIVED:
		# AddFriend on a two-way pending pair auto-accepts (both edges -> 0).
		var result: NakamaAsyncResult = await _client.add_friends_async(session, [str(target.id)], null)
		return {"ok": true, "error": ""} if not result.is_exception() else null
	if not accept and (edge == EDGE_SENT or edge == EDGE_RECEIVED):
		# Decline a received one / cancel a sent one = delete the pending edges.
		var result: NakamaAsyncResult = await _client.delete_friends_async(session, [str(target.id)], null)
		return {"ok": true, "error": ""} if not result.is_exception() else null
	return {"ok": false, "error": "friend_no_pending"}


func block_user(player_code: String) -> Variant:
	var session := _session()
	if session == null:
		return null
	var code := player_code.strip_edges().to_upper()
	if not _is_valid_code(code):
		return {"ok": false, "error": "friend_invalid_code"}
	var target := await _resolve_user(session, code)
	if target == null:
		return {"ok": false, "error": "friend_unknown_code"}
	var result: NakamaAsyncResult = await _client.block_friends_async(session, PackedStringArray(), [str(target.username)])
	if result.is_exception():
		return null
	return {"ok": true, "error": ""}


func unblock_user(player_code: String) -> Variant:
	var session := _session()
	if session == null:
		return null
	# Nakama has NO dedicated unban API — delete on the state-3 edge IS the unban.
	var target := await _resolve_user(session, player_code)
	if target != null:
		await _client.delete_friends_async(session, [str(target.id)], null)
	return {"ok": true, "error": ""}


func fetch_blocked() -> Variant:
	var session := _session()
	if session == null:
		return null
	var result: NakamaAPI.ApiFriendList = await _client.list_friends_async(session, EDGE_BLOCKED)
	if result.is_exception():
		return null
	var ids: Array = []
	for entry in result.friends:
		var friend := entry as NakamaAPI.ApiFriend
		if friend != null and friend.user != null:
			ids.append(str(friend.user.id))
	var summaries := await _summaries_for(session, ids)
	var rows: Array[Dictionary] = []
	for entry in result.friends:
		var friend := entry as NakamaAPI.ApiFriend
		if friend == null or friend.user == null:
			continue
		rows.append({
			"player_code": str(friend.user.username),
			"name": name_from_summary(str(friend.user.username), summaries.get(str(friend.user.id), {}) as Dictionary),
		})
	return rows


# --- Teams -------------------------------------------------------------------------

func search_teams(query: String) -> Variant:
	var session := _session()
	if session == null:
		return null
	var q := query.strip_edges()
	var result: NakamaAPI.ApiGroupList = await _client.list_groups_async(session, q if not q.is_empty() else null, 50)
	if result.is_exception():
		return null
	var rows: Array[Dictionary] = []
	for entry in result.groups:
		var group := entry as NakamaAPI.ApiGroup
		if group == null or str(group.id).is_empty():
			continue
		rows.append(map_team_row(group))
	return rows


func join_team(team_id: String) -> Variant:
	var session := _session()
	if session == null:
		return null
	var joined: NakamaAsyncResult = await _client.join_group_async(session, team_id)
	if joined.is_exception():
		return {"ok": false, "error": "", "team": {}}
	var membership := await _my_membership(session, team_id)
	if membership == null or (membership as NakamaAPI.UserGroupListUserGroup).group == null:
		return {"ok": false, "error": "", "team": {}}
	if int((membership as NakamaAPI.UserGroupListUserGroup).state) == GROUP_REQUESTER:
		# Closed team: JoinGroup created a REQUEST, not membership.
		return {"ok": false, "error": "team_by_request", "team": {}}
	var team := await _team_domain_shape(session, (membership as NakamaAPI.UserGroupListUserGroup).group)
	if team.is_empty():
		return {"ok": false, "error": "", "team": {}}
	return {"ok": true, "error": "", "team": team}


func request_join(team_id: String) -> Variant:
	var session := _session()
	if session == null:
		return null
	var membership := await _my_membership(session, team_id)
	if membership != null:
		match int((membership as NakamaAPI.UserGroupListUserGroup).state):
			GROUP_OWNER, GROUP_ADMIN, GROUP_MEMBER:
				return {"ok": false, "error": "team_already_member", "pending": false}
			GROUP_REQUESTER:
				return {"ok": false, "error": "team_request_pending", "pending": true}
	var joined: NakamaAsyncResult = await _client.join_group_async(session, team_id)
	if joined.is_exception():
		return {"ok": false, "error": "", "pending": false}
	var after := await _my_membership(session, team_id)
	if after == null:
		return {"ok": false, "error": "", "pending": false}
	match int((after as NakamaAPI.UserGroupListUserGroup).state):
		GROUP_REQUESTER:
			return {"ok": true, "error": "", "pending": true}
		GROUP_OWNER, GROUP_ADMIN, GROUP_MEMBER:
			# The team was OPEN — JoinGroup joined directly; undo and report.
			await _client.leave_group_async(session, team_id)
			return {"ok": false, "error": "team_open", "pending": false}
		_:
			return {"ok": false, "error": "", "pending": false}


func leave_team() -> void:
	var session := _session()
	if session == null:
		return
	var membership := await _any_membership(session)
	if membership != null and (membership as NakamaAPI.UserGroupListUserGroup).group != null:
		await _client.leave_group_async(session, str(((membership as NakamaAPI.UserGroupListUserGroup).group).id))


func fetch_team() -> Variant:
	var session := _session()
	if session == null:
		return null
	var membership := await _any_membership(session)
	if membership == null or (membership as NakamaAPI.UserGroupListUserGroup).group == null:
		return {}
	var team := await _team_domain_shape(session, (membership as NakamaAPI.UserGroupListUserGroup).group)
	return team if not team.is_empty() else null


func create_team(name: String, access_mode: String, banner_recipe: Dictionary) -> Variant:
	var session := _session()
	if session == null:
		return null
	var clean := name.strip_edges()
	if clean.is_empty() or clean.length() > MAX_TEAM_NAME_LENGTH:
		return {"ok": false, "error": "team_invalid_name", "team": {}}
	if not ACCESS_MODES.has(access_mode):
		return {"ok": false, "error": "team_invalid_name", "team": {}}
	if await _any_membership(session) != null:
		return {"ok": false, "error": "team_already_on_team", "team": {}}
	var recipe := (banner_recipe if banner_recipe != null else {}) as Dictionary
	var rpc: NakamaAPI.ApiRpc = await _client.rpc_async(session, TEAM_OPS_FUNCTION, JSON.stringify({
		"action": "create",
		"name": clean,
		"access_mode": access_mode,
		"banner_base": str(recipe.get("base", "")),
		"banner_icon": str(recipe.get("icon", "")),
		"banner_base_lut": str(recipe.get("base_lut", "")),
		"banner_icon_lut": str(recipe.get("icon_lut", "")),
		"banner_icon_scale": float(recipe.get("icon_scale", 1.0)),
	}))
	if rpc.is_exception():
		return null
	var parsed: Dictionary = parse_rpc_payload(rpc.payload)
	if not bool(parsed.get("ok", false)):
		return {"ok": false, "error": str(parsed.get("error", "")), "team": {}}
	var membership := await _my_membership(session, str(parsed.get("team_id", "")))
	if membership == null or (membership as NakamaAPI.UserGroupListUserGroup).group == null:
		return {"ok": false, "error": "", "team": {}}
	var team := await _team_domain_shape(session, (membership as NakamaAPI.UserGroupListUserGroup).group)
	if team.is_empty():
		return {"ok": false, "error": "", "team": {}}
	return {"ok": true, "error": "", "team": team}


func update_team_settings(settings: Dictionary) -> Variant:
	var session := _session()
	if session == null:
		return null
	var membership := await _any_membership(session)
	if membership == null or int((membership as NakamaAPI.UserGroupListUserGroup).state) != GROUP_OWNER:
		return {"ok": false, "error": "team_not_leader", "team": {}}
	if settings.has("name"):
		var clean := str(settings.get("name", "")).strip_edges()
		if clean.is_empty() or clean.length() > MAX_TEAM_NAME_LENGTH:
			return {"ok": false, "error": "team_invalid_name", "team": {}}
	if settings.has("access_mode") and not ACCESS_MODES.has(str(settings.get("access_mode", ""))):
		return {"ok": false, "error": "team_invalid_name", "team": {}}
	var group := (membership as NakamaAPI.UserGroupListUserGroup).group
	var payload := {"action": "update", "group_id": str(group.id)}
	if settings.has("name"):
		payload["name"] = str(settings.get("name", "")).strip_edges()
	if settings.has("access_mode"):
		payload["access_mode"] = str(settings.get("access_mode", ""))
	var recipe: Variant = settings.get("banner_recipe", null)
	if typeof(recipe) == TYPE_DICTIONARY:
		payload["banner_base"] = str((recipe as Dictionary).get("base", ""))
		payload["banner_icon"] = str((recipe as Dictionary).get("icon", ""))
		payload["banner_base_lut"] = str((recipe as Dictionary).get("base_lut", ""))
		payload["banner_icon_lut"] = str((recipe as Dictionary).get("icon_lut", ""))
		payload["banner_icon_scale"] = float((recipe as Dictionary).get("icon_scale", 1.0))
	var rpc: NakamaAPI.ApiRpc = await _client.rpc_async(session, TEAM_OPS_FUNCTION, JSON.stringify(payload))
	if rpc.is_exception():
		return null
	var parsed: Dictionary = parse_rpc_payload(rpc.payload)
	if not bool(parsed.get("ok", false)):
		return {"ok": false, "error": str(parsed.get("error", "")), "team": {}}
	# Re-fetch: the in-memory group still carries pre-update metadata.
	var after := await _my_membership(session, str(group.id))
	if after == null or (after as NakamaAPI.UserGroupListUserGroup).group == null:
		return {"ok": false, "error": "", "team": {}}
	var team := await _team_domain_shape(session, (after as NakamaAPI.UserGroupListUserGroup).group)
	if team.is_empty():
		return {"ok": false, "error": "", "team": {}}
	return {"ok": true, "error": "", "team": team}


func fetch_join_requests() -> Variant:
	var session := _session()
	if session == null:
		return null
	var membership := await _any_membership(session)
	if membership == null or int((membership as NakamaAPI.UserGroupListUserGroup).state) != GROUP_OWNER:
		return []
	var group := (membership as NakamaAPI.UserGroupListUserGroup).group
	var result: NakamaAPI.ApiGroupUserList = await _client.list_group_users_async(session, str(group.id), GROUP_REQUESTER)
	if result.is_exception():
		return []
	var ids: Array = []
	for entry in result.group_users:
		var gu := entry as NakamaAPI.GroupUserListGroupUser
		if gu != null and gu.user != null:
			ids.append(str(gu.user.id))
	var summaries := await _summaries_for(session, ids)
	var rows: Array[Dictionary] = []
	for entry in result.group_users:
		var gu := entry as NakamaAPI.GroupUserListGroupUser
		if gu == null or gu.user == null:
			continue
		rows.append({
			"player_code": str(gu.user.username),
			"name": name_from_summary(str(gu.user.username), summaries.get(str(gu.user.id), {}) as Dictionary),
			"ts": 0,  # group-user edges carry no timestamp; the UI does not render it
		})
	return rows


func respond_join_request(player_code: String, approve: bool) -> Variant:
	var session := _session()
	if session == null:
		return null
	var membership := await _any_membership(session)
	if membership == null or int((membership as NakamaAPI.UserGroupListUserGroup).state) != GROUP_OWNER:
		return {"ok": false, "error": "team_not_leader"}
	var group := (membership as NakamaAPI.UserGroupListUserGroup).group
	var target := await _resolve_user(session, player_code)
	if target == null:
		return {"ok": false, "error": ""}
	var result: NakamaAsyncResult
	if approve:
		result = await _client.add_group_users_async(session, str(group.id), PackedStringArray([str(target.id)]))
	else:
		result = await _client.kick_group_users_async(session, str(group.id), PackedStringArray([str(target.id)]))
	return {"ok": true, "error": ""} if not result.is_exception() else null


# --- Chat --------------------------------------------------------------------------

func fetch_chat_history(limit: int) -> Variant:
	var session := _session()
	if session == null:
		return null
	var group_id := await _my_team_group_id(session)
	if group_id.is_empty():
		return []
	var result: NakamaAPI.ApiChannelMessageList = await _client.list_channel_messages_async(session, group_channel_id(group_id), limit)
	if result.is_exception():
		return null
	var ids: Array = []
	for entry in result.messages:
		var message := entry as NakamaAPI.ApiChannelMessage
		if message != null and not str(message.sender_id).is_empty():
			ids.append(str(message.sender_id))
	var summaries := await _summaries_for(session, ids)
	var rows: Array[Dictionary] = []
	for entry in result.messages:
		var message := entry as NakamaAPI.ApiChannelMessage
		if message == null or str(message.message_id).is_empty():
			continue
		var sender_name := name_from_summary(str(message.username), summaries.get(str(message.sender_id), {}) as Dictionary)
		_sender_names[str(message.sender_id)] = sender_name
		rows.append(map_chat_message(message, sender_name))
	return rows


func send_chat_message(text: String) -> Variant:
	var session := _session()
	if session == null:
		return null
	var group_id := await _my_team_group_id(session)
	if group_id.is_empty():
		return {"ok": false, "message": {}}
	var socket := await _ensure_socket(session, group_id)
	if socket == null:
		return null
	var channel_id := group_channel_id(group_id)
	var ack: Variant = await socket.write_chat_message_async(channel_id, {"text": text})
	if ack is NakamaAsyncResult and (ack as NakamaAsyncResult).is_exception():
		return null
	# Echo with the SERVER-assigned id so the realtime push of the same
	# message (the sender receives its own write — spike-verified) dedupes.
	var message := {
		"id": str((ack as NakamaRTAPI.ChannelMessageAck).message_id) if ack != null else "echo-%d" % Time.get_ticks_msec(),
		"sender_code": IdentityService.get_player_code(),
		"sender_name": str(SaveSystem.get_value("profile", "name", "Player")),
		"text": text,
		"ts": int(Time.get_unix_time_from_system()),
	}
	return {"ok": true, "message": message}


func subscribe_chat() -> Variant:
	var session := _session()
	if session == null:
		return null
	var group_id := await _my_team_group_id(session)
	if group_id.is_empty():
		return {"ok": false, "error": "chat_no_team"}
	var socket := await _ensure_socket(session, group_id)
	if socket == null:
		return null
	return {"ok": true, "error": ""}


func unsubscribe_chat() -> void:
	if _socket != null and is_instance_valid(_socket) and not _socket_channel_id.is_empty():
		var left: Variant = await _socket.leave_chat_async(_socket_channel_id)
		if left is NakamaAsyncResult and (left as NakamaAsyncResult).is_exception():
			push_warning("NakamaSocialBackend: leave chat failed (%s)" % str(left).left(120))
	# The socket stays open (the send path reuses it); clearing the tracked
	# channel makes the next _ensure_socket re-join.
	_socket_channel_id = ""


# --- Presence (v3+ — TDD §3.25) ----------------------------------------------------

func subscribe_presence(friend_codes: Array[String]) -> Variant:
	var session := _session()
	if session == null:
		return null
	var socket := await _open_socket(session)
	if socket == null:
		return null
	if not socket.received_status_presence.is_connected(_on_socket_status_presence):
		socket.received_status_presence.connect(_on_socket_status_presence)
	var wanted := {}
	for code in friend_codes:
		wanted[str(code).strip_edges().to_upper()] = true
	var to_follow := PackedStringArray()
	for code in wanted.keys():
		if not _presence_followed.has(code):
			_presence_followed[code] = true
			to_follow.append(str(code))
	var to_unfollow: Array[String] = []
	for code in _presence_followed.keys():
		if not wanted.has(code):
			to_unfollow.append(str(code))
	# Follow first, then drop the stale follows (unfollow needs user ids — one
	# batch resolve; a partial failure just leaves a harmless extra follow).
	if to_follow.size() > 0:
		var follow: NakamaRTAPI.Status = await socket.follow_users_async(PackedStringArray(), PackedStringArray(to_follow))
		if follow.is_exception():
			return null
		# The follow ack IS the replay (nakama v3.37.0 server/pipeline_status.go):
		# presences[] = the followed users who are online RIGHT NOW. No JOIN push
		# is sent for them — so without this, already-online friends would stay
		# invisible until their next connect/disconnect cycle.
		var now := int(Time.get_unix_time_from_system())
		var initial := {}
		for p in follow.presences:
			var presence := p as NakamaRTAPI.UserPresence
			if presence != null and not presence.is_exception():
				initial[str(presence.username)] = {"online": true, "last_seen": now}
		if not initial.is_empty():
			presence_updated.emit(initial)
	for code in to_unfollow:
		_presence_followed.erase(code)
	if to_unfollow.size() > 0:
		var ids := await _user_ids_for(session, PackedStringArray(to_unfollow))
		if not ids.is_empty():
			await socket.unfollow_users_async(ids)
	return {"ok": true, "error": ""}


func unsubscribe_presence() -> void:
	if _presence_followed.is_empty():
		return
	var codes := PackedStringArray(_presence_followed.keys())
	_presence_followed = {}
	if _socket == null or not is_instance_valid(_socket) or not _socket.is_connected_to_host():
		return
	var session := _session()
	if session == null:
		return
	var ids := await _user_ids_for(session, codes)
	if not ids.is_empty():
		await _socket.unfollow_users_async(ids)


## Status-presence push -> batched delta (TDD §3.25). Joins = online; leaves =
## offline stamped with NOW — the friend was online until this instant, a close
## approximation of their own last-seen write (which lands on their app exit).
## Verified live: already-online friends arrive via the follow ACK (see
## subscribe_presence), not via this push — no JOIN is sent at follow time.
func _on_socket_status_presence(event: NakamaRTAPI.StatusPresenceEvent) -> void:
	if event == null or event.is_exception():
		return
	var delta := {}
	var now := int(Time.get_unix_time_from_system())
	for p in _as_array(event.joins):
		var presence := p as NakamaRTAPI.UserPresence
		if presence != null and not str(presence.username).is_empty():
			delta[str(presence.username)] = {"online": true, "last_seen": 0}
	for p in _as_array(event.leaves):
		var presence := p as NakamaRTAPI.UserPresence
		if presence != null and not str(presence.username).is_empty():
			delta[str(presence.username)] = {"online": false, "last_seen": now}
	if not delta.is_empty():
		presence_updated.emit(delta)


## Batch-resolves player codes (usernames) to user ids; unresolved codes are
## simply absent (best-effort unfollows tolerate a partial list).
func _user_ids_for(session: NakamaSession, codes: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	if codes.is_empty():
		return out
	var users: NakamaAPI.ApiUsers = await _client.get_users_async(session, PackedStringArray(), codes)
	if users.is_exception() or users.users == null:
		return out
	for entry in users.users as Array:
		var user := entry as NakamaAPI.ApiUser
		if user != null and not str(user.id).is_empty():
			out.append(str(user.id))
	return out


static func _as_array(value: Variant) -> Array:
	return (value as Array) if value is Array else []


## Realtime push -> chat row (TDD §3.24). Only messages for the CURRENTLY
## joined channel are forwarded; sender names come from the fetch cache with a
## username (= player code) fallback. The manager dedupes by id — the same
## message can also arrive via the history fetch or the send echo.
func _on_socket_chat_message(message: NakamaAPI.ApiChannelMessage) -> void:
	if str(message.channel_id) != _socket_channel_id:
		return
	var row := map_chat_message(message, _sender_names.get(str(message.sender_id), str(message.username)))
	chat_message_received.emit(row)


# --- Static pure mappers (fixture-testable, no client needed) -------------------------

## ApiUser username + optional profile summary -> friend row (mock _ensure_user
## defaults when the summary object is missing). `last_seen` (TDD §3.25) comes
## from the profile/last_seen storage object merged into the summary; 0 = never
## stamped (the UI then shows the plain level line). `user_id` (TDD §3.26) is
## the Nakama user UUID — the leaderboard friends scope lists records by it.
static func map_user_row(username: String, summary: Dictionary, user_id: String = "") -> Dictionary:
	var row := {
		"name": name_from_summary(username, summary),
		"level": int(summary.get("level", 1)),
		"best_score": int(summary.get("best_score", 0)),
		"portrait_icon": str(summary.get("portrait_icon", "classic")),
		"portrait_flair": str(summary.get("portrait_flair", "none")),
		"portrait_crown": str(summary.get("portrait_crown", "none")),
		"last_seen": int(summary.get("last_seen", 0)),
	}
	row["player_code"] = username
	row["user_id"] = user_id
	return row


## Display name from a summary dict; falls back to the username (= player code).
static func name_from_summary(username: String, summary: Dictionary) -> String:
	var name := str(summary.get("name", ""))
	return name if not name.is_empty() else username


## ApiGroup -> search row (TDD §3.17 row shape; members stay empty — search rows
## do not render them).
static func map_team_row(group: NakamaAPI.ApiGroup) -> Dictionary:
	var meta := parse_meta(group.metadata)
	var access_mode := str(meta.get("access_mode", ""))
	if access_mode.is_empty():
		access_mode = ACCESS_OPEN if group.open else ACCESS_BY_REQUEST
	return {
		"team_id": str(group.id),
		"name": str(meta.get("display_name", str(group.name))),
		"access_mode": access_mode,
		"power": int(meta.get("power", 0)),
		"members": [],
		"banner_recipe": banner_recipe_from_meta(meta),
	}


## Group channel id (live-verified): "3.<group_id>.." — mode.subject.subcontext.label.
static func group_channel_id(group_id: String) -> String:
	return "3.%s.." % str(group_id)


## ApiChannelMessage + resolved sender name -> chat row. REST returns messages
## oldest-first (live-verified) — no reversal needed.
static func map_chat_message(message: NakamaAPI.ApiChannelMessage, sender_name: String) -> Dictionary:
	return {
		"id": str(message.message_id),
		"sender_code": str(message.username),
		"sender_name": sender_name,
		"text": message_text(str(message.content)),
		"ts": _parse_ts(message.create_time),
	}


## Content is usually a plain string; tolerate the JSON {"text": ...} wrapper.
## Only strings that LOOK like JSON are parsed — a failed parse logs an engine
## error, so plain chat text must never reach the parser.
static func message_text(content: String) -> String:
	var text := str(content)
	if not text.begins_with("{"):
		return text
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) == TYPE_DICTIONARY and (parsed as Dictionary).has("text"):
		return str((parsed as Dictionary).get("text", ""))
	return text


## team_ops RPC payload {ok, error, team_id} -> parsed dict; {} on malformed.
static func parse_rpc_payload(payload: String) -> Dictionary:
	var text := str(payload).strip_edges()
	if text.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(text)
	return (parsed as Dictionary).duplicate(true) if typeof(parsed) == TYPE_DICTIONARY else {}


## Group metadata JSON -> dict; {} when absent/malformed. The empty-string
## guard matters: groups without metadata are the common case and a failed
## parse would log an engine error per team render.
static func parse_meta(metadata: String) -> Dictionary:
	var text := str(metadata).strip_edges()
	if text.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(text)
	return (parsed as Dictionary).duplicate(true) if typeof(parsed) == TYPE_DICTIONARY else {}


## Metadata banner_* keys -> recipe {base, icon, base_lut, icon_lut, icon_scale}
## (§3.19: ids only + the H7 scale). The server stores the scale as a STRING in
## metadata; float() parses both the string form and a raw number, and a missing
## key (pre-H7 teams) falls back to 1.0 = the classic icon size.
static func banner_recipe_from_meta(meta: Dictionary) -> Dictionary:
	return {
		"base": str(meta.get("banner_base", "")),
		"icon": str(meta.get("banner_icon", "")),
		"base_lut": str(meta.get("banner_base_lut", "")),
		"icon_lut": str(meta.get("banner_icon_lut", "")),
		"icon_scale": float(meta.get("banner_icon_scale", 1.0)),
	}


# --- Internals -----------------------------------------------------------------------

func _session() -> NakamaSession:
	return OnlineService.get_session()


## The `team` save-domain shape (TDD §3.4 keys) from a group + its roster;
## {} when the roster cannot be fetched.
func _team_domain_shape(session: NakamaSession, group: NakamaAPI.ApiGroup) -> Dictionary:
	var meta := parse_meta(group.metadata)
	var access_mode := str(meta.get("access_mode", ""))
	if access_mode.is_empty():
		access_mode = ACCESS_OPEN if group.open else ACCESS_BY_REQUEST
	var users_result: NakamaAPI.ApiGroupUserList = await _client.list_group_users_async(session, str(group.id))
	if users_result.is_exception() or users_result.group_users == null:
		return {}
	var roster: Array = []  # [user_id, username] pairs, owner first
	for entry in users_result.group_users:
		var gu := entry as NakamaAPI.GroupUserListGroupUser
		if gu == null or gu.user == null or int(gu.state) > GROUP_MEMBER:
			continue
		roster.append([str(gu.user.id), str(gu.user.username)])
	for i in range(roster.size() - 1, 0, -1):
		if str((roster[i] as Array)[0]) == str(group.creator_id):
			var owner_pair: Variant = roster[i]
			roster.remove_at(i)
			roster.push_front(owner_pair)
			break
	var summaries := await _summaries_for(session, roster.map(func(pair: Array) -> String: return str(pair[0])))
	var members: Array = []
	# Parallel to `members` (TDD §3.25): presence lookups key on player codes;
	# the display names above are not reversible, so codes travel alongside.
	var member_codes: Array = []
	var leader_code := ""
	for pair in roster:
		var user_id := str((pair as Array)[0])
		var username := str((pair as Array)[1])
		members.append(name_from_summary(username, summaries.get(user_id, {}) as Dictionary))
		member_codes.append(username)
		if user_id == str(group.creator_id):
			leader_code = username
	return {
		"on_team": true,
		"team_name": str(meta.get("display_name", str(group.name))),
		"access_mode": access_mode,
		"banner_base": str(meta.get("banner_base", "")),
		"banner_icon": str(meta.get("banner_icon", "")),
		"banner_base_lut": str(meta.get("banner_base_lut", "")),
		"banner_icon_lut": str(meta.get("banner_icon_lut", "")),
		"banner_icon_scale": float(meta.get("banner_icon_scale", 1.0)),
		"power": int(meta.get("power", 0)),
		"members": members,
		"member_codes": member_codes,
		"leader_code": leader_code,
		"leader_name": name_from_summary(leader_code, summaries.get(leader_code, {}) as Dictionary),
	}


## Batch profile-summary + last-seen storage objects for user ids (TDD §3.25):
## TWO read ids per user in ONE round-trip. Missing objects are simply absent
## (callers fall back to mock-compatible defaults); the returned dict gains a
## `last_seen` int (unix seconds, 0 when never stamped) alongside the summary
## fields.
func _summaries_for(session: NakamaSession, user_ids: Array) -> Dictionary:
	var out := {}
	if user_ids.is_empty():
		return out
	var read_ids: Array = []
	for uid in user_ids:
		read_ids.append(NakamaStorageObjectId.new(PROFILE_COLLECTION, SUMMARY_KEY, str(uid)))
		read_ids.append(NakamaStorageObjectId.new(PROFILE_COLLECTION, LAST_SEEN_KEY, str(uid)))
	var objects: NakamaAPI.ApiStorageObjects = await _client.read_storage_objects_async(session, read_ids)
	if objects.is_exception() or objects.objects == null:
		return out
	for obj in objects.objects:
		var stored_obj := obj as NakamaAPI.ApiStorageObject
		var entry: Variant = out.get(str(stored_obj.user_id), null)
		if entry == null:
			entry = {}
			out[str(stored_obj.user_id)] = entry
		if str(stored_obj.key) == LAST_SEEN_KEY:
			var seen: Variant = JSON.parse_string(str(stored_obj.value))
			if typeof(seen) == TYPE_DICTIONARY:
				(entry as Dictionary)["last_seen"] = int((seen as Dictionary).get("ts", 0))
			continue
		var stored: Variant = JSON.parse_string(str(stored_obj.value))
		if typeof(stored) == TYPE_DICTIONARY:
			for k in (stored as Dictionary).keys():
				(entry as Dictionary)[k] = (stored as Dictionary)[k]
	return out


## Resolves a player code (username) to an ApiUser; null when unknown/unavailable.
func _resolve_user(session: NakamaSession, player_code: String) -> NakamaAPI.ApiUser:
	var users: NakamaAPI.ApiUsers = await _client.get_users_async(session, PackedStringArray(), [player_code.strip_edges().to_upper()])
	if users.is_exception() or users.users == null:
		return null
	var arr := users.users as Array
	return (arr[0] as NakamaAPI.ApiUser) if arr.size() > 0 else null


## My friend edge state toward user_id via ListFriends (all states); -1 when absent.
func _my_edge_state(session: NakamaSession, user_id: String) -> int:
	var result: NakamaAPI.ApiFriendList = await _client.list_friends_async(session)
	if result.is_exception():
		return -1
	for entry in result.friends:
		var friend := entry as NakamaAPI.ApiFriend
		if friend != null and friend.user != null and str(friend.user.id) == user_id:
			return int(friend.state)
	return -1


## My UserGroupListUserGroup entry for team_id (any state); null when absent.
func _my_membership(session: NakamaSession, team_id: String) -> NakamaAPI.UserGroupListUserGroup:
	var result: NakamaAPI.ApiUserGroupList = await _client.list_user_groups_async(session, session.user_id)
	if result.is_exception():
		return null
	for entry in result.user_groups:
		var ug := entry as NakamaAPI.UserGroupListUserGroup
		if ug != null and ug.group != null and str(ug.group.id) == team_id:
			return ug
	return null


## My current membership (edge state <= member) in ANY group; null when off-team.
func _any_membership(session: NakamaSession) -> NakamaAPI.UserGroupListUserGroup:
	var result: NakamaAPI.ApiUserGroupList = await _client.list_user_groups_async(session, session.user_id)
	if result.is_exception():
		return null
	for entry in result.user_groups:
		var ug := entry as NakamaAPI.UserGroupListUserGroup
		if ug != null and ug.group != null and int(ug.state) <= GROUP_MEMBER:
			return ug
	return null


## The group id my membership points at; "" when off-team or unavailable.
func _my_team_group_id(session: NakamaSession) -> String:
	var membership := await _any_membership(session)
	if membership == null or (membership as NakamaAPI.UserGroupListUserGroup).group == null:
		return ""
	return str(((membership as NakamaAPI.UserGroupListUserGroup).group).id)


## Opens (or reuses) the shared websocket WITHOUT joining a channel — presence
## subscriptions need no channel (TDD §3.25). Reopens when dead; on reopen any
## active presence follows are re-established (server-side follow state is
## per-socket, spike-verified: no replay of current presence at follow time).
func _open_socket(session: NakamaSession) -> NakamaSocket:
	if _socket != null and is_instance_valid(_socket) and _socket.is_connected_to_host():
		return _socket
	if _socket != null and is_instance_valid(_socket):
		_socket.close()
		_socket = null
	var socket: NakamaSocket = OnlineService.create_socket()
	if socket == null:
		return null
	# appear_online=true: this client must be visible for friends' presence
	# feeds to work (TDD §3.25). Verified live: visibility does not affect
	# channel-message delivery, so the chat path shares it harmlessly.
	var connected: NakamaAsyncResult = await socket.connect_async(session, true)
	if connected.is_exception():
		socket.close()
		return null
	socket.received_channel_message.connect(_on_socket_chat_message)
	_socket = socket
	if not _presence_followed.is_empty():
		var follow: NakamaRTAPI.Status = await socket.follow_users_async(PackedStringArray(), PackedStringArray(_presence_followed.keys()))
		if follow.is_exception():
			push_warning("NakamaSocialBackend: re-follow after socket reopen failed (%s)" % str(follow).left(120))
	return _socket


## Lazily opens the shared websocket joined to the team's group channel (TDD
## §3.17). A live socket on a DIFFERENT channel is reused — the new channel is
## just joined alongside (messages for the old one are filtered out by
## _on_socket_chat_message), avoiding reconnect churn on team changes.
func _ensure_socket(session: NakamaSession, group_id: String) -> NakamaSocket:
	var channel_id := group_channel_id(group_id)
	if _socket != null and is_instance_valid(_socket) and _socket_channel_id == channel_id \
			and _socket.is_connected_to_host():
		return _socket
	var socket := await _open_socket(session)
	if socket == null:
		return null
	var channel: NakamaRTAPI.Channel = await socket.join_chat_async(group_id, NakamaRTMessage.ChannelJoin.ChannelType.Group, true)
	if channel.is_exception() or str(channel.id).is_empty():
		socket.close()
		return null
	_socket_channel_id = channel_id
	return _socket


## RFC3339 (e.g. "2026-11-07T19:31:21.868Z") -> unix seconds; 0 on failure.
## Manual parse: the Date/DateTime classes are unavailable in this Godot build
## (parse error — see NOTES.md); String.find_first_of / float.is_nan() likewise.
static func _parse_ts(rfc3339: String) -> int:
	var text := str(rfc3339).strip_edges()
	if text.length() < 20 or text[10] != "T" or text[13] != ":" or text[16] != ":":
		return 0
	var year := int(text.substr(0, 4))
	var month := int(text.substr(5, 2))
	var day := int(text.substr(8, 2))
	var hour := int(text.substr(11, 2))
	var minute := int(text.substr(14, 2))
	var sec_text := text.substr(17)  # "21", "21.868Z", or "21+05:30"
	var offset_sec := 0
	var z := sec_text.find("Z", 0)
	if z < 0:
		z = sec_text.find("z", 0)
	if z >= 0:
		sec_text = sec_text.left(z)
	else:
		var sign_idx := -1
		for i in range(1, sec_text.length()):
			if sec_text[i] == "+" or sec_text[i] == "-":
				sign_idx = i
				break
		if sign_idx > 0 and sec_text.length() >= sign_idx + 6:
			offset_sec = (1 if sec_text[sign_idx] == "+" else -1) \
					* (int(sec_text.substr(sign_idx + 1, 2)) * 3600 + int(sec_text.substr(sign_idx + 4, 2)) * 60)
			sec_text = sec_text.left(sign_idx)
	if sec_text.is_empty() or not ("0" <= sec_text[0] and sec_text[0] <= "9"):
		return 0
	var base := Time.get_unix_time_from_datetime_dict({
		"year": year, "month": month, "day": day,
		"hour": hour, "minute": minute, "second": int(sec_text),
	})
	if base == -1:
		return 0
	return int(base - offset_sec)


static func _is_valid_code(code: String) -> bool:
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

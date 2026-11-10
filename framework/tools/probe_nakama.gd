extends SceneTree
## Headless one-shot Nakama integration probe (BACKEND.md §4). Runs against a
## running backend stack (local compose or VPS) and prints PASS/FAIL per step.
## -s SceneTree scripts compile BEFORE the main loop starts, so they must not
## reference autoload names at compile time (identity_service.gd references
## RemoteConfig) — it is lazy-loaded in _run(). The Nakama client is built
## manually from the addon script (no game coupling), like build_stages.gd.
##
## Usage:
##   ~/tools/godot --headless --path . -s res://tools/probe_nakama.gd -- \
##       [--host localhost] [--port 8080] [--scheme http] [--key defaultkey] [--timeout 15]

const NAKAMA_SINGLETON: GDScript = preload("res://addons/com.heroiclabs.nakama/Nakama.gd")

var _identity: GDScript = null
var _host := "localhost"
var _port := 8080
var _scheme := "http"
var _key := "defaultkey"
var _timeout := 15
var _nakama: Node = null
var _client: NakamaClient = null
var _passed := 0
var _failed := 0


func _initialize() -> void:
	_run()


func _run() -> void:
	_identity = load("res://core/identity_service.gd")
	if _identity == null:
		push_error("probe_nakama: could not load identity_service.gd")
		quit(1)
		return
	_parse_args(OS.get_cmdline_user_args())
	print("probe_nakama: %s://%s:%d (server_key=%s)" % [_scheme, _host, _port, "default" if _key == "defaultkey" else "<custom>"])

	_nakama = NAKAMA_SINGLETON.new()
	root.add_child(_nakama)
	# _initialize() runs before the tree is active: nodes added now only become
	# "inside tree" after the first frame (HTTPRequest requires it).
	await process_frame
	_client = _nakama.create_client(_key, _host, _port, _scheme, _timeout, NakamaLogger.LOG_LEVEL.WARNING)

	await _step_healthcheck()
	await _step_auth_fresh()
	await _step_auth_restore()
	await _step_storage_roundtrip()
	await _step_analytics_rpc()
	var open_team: Dictionary = await _step_team_ops_create("open")
	if not open_team.is_empty():
		var team_id: String = str(open_team.get("team_id", ""))
		var session_b: NakamaSession = await _auth_probe_user()
		if session_b != null:
			await _step_open_join(team_id, session_b)
			var closed_team: Dictionary = await _step_team_ops_create("by-request")
			if not closed_team.is_empty():
				# The LEADER must be the creator (owner edge state 0) or the
				# server denies AddGroupUsers — pass the creating session.
				await _step_closed_request_flow(str(closed_team.get("team_id", "")), closed_team.get("session"), session_b)
			await _step_chat_roundtrip(team_id)
			await _step_chat_realtime(team_id)
		await _step_block_unblock()
		await _step_presence()

	var tourn_ctx: Dictionary = await _step_tournament_ensure()
	if not tourn_ctx.is_empty():
		await _step_tournament_solo(tourn_ctx)
		await _step_tournament_team_rounds(tourn_ctx)
		await _step_tournament_no_team(tourn_ctx)

	await _step_leaderboard()
	await _step_matchmaking()

	print("")
	print("probe_nakama: %d passed, %d failed" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


# --- Steps ---------------------------------------------------------------------

func _step_healthcheck() -> void:
	var res := await _http_get("/healthcheck")
	# Contract (apigrpc.swagger.json): 200 = healthy, body is an empty object.
	_check("healthcheck", int(res.get("status", 0)) == 200, "status=%s body=%s" % [res.get("status"), str(res.get("body")).left(120)])


func _step_auth_fresh() -> void:
	var user := await _auth_fresh_user()
	if user.is_empty():
		_check("auth_fresh (custom id + username=player code)", false, "setup auth failed")
		return
	var session := user["session"] as NakamaSession
	var ok: bool = not session.token.is_empty() \
		and not session.user_id.is_empty() and session.username == str(user["code"]) and not session.expired
	_check("auth_fresh (custom id + username=player code)", ok, _detail(session))


func _step_auth_restore() -> void:
	var user := await _auth_fresh_user()
	if user.is_empty():
		_check("auth_restore (persisted token)", false, "setup auth failed")
		return
	var session := user["session"] as NakamaSession
	var restored: NakamaSession = NakamaClient.restore_session(session.token)
	var account: NakamaAPI.ApiAccount = await _client.get_account_async(restored)
	var ok: bool = not session.user_id.is_empty() and restored.user_id == session.user_id \
		and not restored.expired and not account.is_exception() \
		and account.user != null and str(account.user.id) == session.user_id
	_check("auth_restore (persisted token re-hydrates + server accepts)", ok, _detail(restored))


func _step_storage_roundtrip() -> void:
	var user := await _auth_fresh_user()
	if user.is_empty():
		_check("storage round-trip", false, "setup auth failed")
		return
	var session := user["session"] as NakamaSession
	var value := JSON.stringify({"data": {"probe": 42}, "updated_at": Time.get_unix_time_from_system()})
	# Verified semantics (core_storage.go v3.37.0): permission_read=0 objects are
	# invisible to ALL client REST reads (owner included) — only runtime functions
	# can see them. permission_read=1 = owner-readable via client API ("private").
	# value must be a valid JSON string (server validates).
	var obj := NakamaWriteStorageObject.new("save", "probe_domain", 1, 0, value, "")
	var acks: NakamaAPI.ApiStorageObjectAcks = await _client.write_storage_objects_async(session, [obj])
	if acks.is_exception():
		_check("storage round-trip", false, "write failed: %s" % _detail(acks))
		return
	# Verified: reading own objects requires the explicit user_id in the read id.
	var read_ids: Array = [NakamaStorageObjectId.new("save", "probe_domain", session.user_id)]
	var objects: NakamaAPI.ApiStorageObjects = await _client.read_storage_objects_async(session, read_ids)
	var ok: bool = not objects.is_exception() and objects.objects != null and (objects.objects as Array).size() == 1
	if ok:
		var stored: Variant = JSON.parse_string(str((objects.objects as Array)[0].value))
		ok = typeof(stored) == TYPE_DICTIONARY \
			and int(((stored as Dictionary).get("data", {}) as Dictionary).get("probe", -1)) == 42
	_check("storage round-trip (write -> read, collection 'save')", ok, "objects=%s" % str(objects).left(160))


func _step_analytics_rpc() -> void:
	var user := await _auth_fresh_user()
	if user.is_empty():
		_check("analytics RPC (Go plugin)", false, "setup auth failed")
		return
	var session := user["session"] as NakamaSession
	var payload := JSON.stringify({
		"events": [
			{"name": "probe_event", "ts": int(Time.get_unix_time_from_system()), "session_id": "probe-sess", "props": {"stage": 3, "result": "win"}},
			{"name": "probe_no_ts", "ts": 0, "session_id": "probe-sess"},
		],
	})
	var rpc: NakamaAPI.ApiRpc = await _client.rpc_async(session, "analytics", payload)
	if rpc.is_exception():
		_check("analytics RPC (Go plugin)", false, "rpc failed: %s" % _detail(rpc))
		return
	var parsed: Variant = JSON.parse_string(str(rpc.payload))
	var ok := typeof(parsed) == TYPE_DICTIONARY \
		and bool((parsed as Dictionary).get("ok", false)) \
		and int((parsed as Dictionary).get("count", -1)) == 2
	_check("analytics RPC (Go plugin, batch of 2)", ok, "rpc output=%s" % str(rpc.payload).left(160))


func _step_team_ops_create(access_mode: String) -> Dictionary:
	var user := await _auth_fresh_user()
	if user.is_empty():
		_check("team_ops create (%s)" % access_mode, false, "setup auth failed")
		return {}
	var session := user["session"] as NakamaSession
	var name := "probe-%s-%d" % [access_mode, Time.get_ticks_msec() % 100000]
	var payload := JSON.stringify({
		"action": "create",
		"name": name,
		"access_mode": access_mode,
		"banner_base": "base_01",
		"banner_icon": "icon_01",
		"banner_base_lut": "lut_01",
		"banner_icon_lut": "lut_02",
		"banner_icon_scale": 1.25,
	})
	var rpc: NakamaAPI.ApiRpc = await _client.rpc_async(session, "team_ops", payload)
	if rpc.is_exception():
		_check("team_ops create (%s)" % access_mode, false, "rpc failed: %s" % _detail(rpc))
		return {}
	var parsed: Variant = JSON.parse_string(str(rpc.payload))
	if typeof(parsed) != TYPE_DICTIONARY or not bool((parsed as Dictionary).get("ok", false)):
		_check("team_ops create (%s)" % access_mode, false, "rpc output=%s" % str(rpc.payload).left(160))
		return {}
	var team_id := str((parsed as Dictionary).get("team_id", ""))
	# Verify the metadata actually landed (REST cannot write it — only this function can).
	var groups: NakamaAPI.ApiGroupList = await _client.list_groups_async(session, name, 5)
	var meta_ok := false
	if not groups.is_exception() and groups.groups != null:
		for g in groups.groups as Array:
			var group: NakamaAPI.ApiGroup = g
			if group.id == team_id:
				var meta: Variant = JSON.parse_string(group.metadata)
				meta_ok = typeof(meta) == TYPE_DICTIONARY \
					and str((meta as Dictionary).get("display_name", "")) == name \
					and str((meta as Dictionary).get("access_mode", "")) == access_mode \
					# H7: the scale round-trips as a STRING in metadata (server String()s every banner_* value).
					and float((meta as Dictionary).get("banner_icon_scale", 0.0)) == 1.25 \
					and group.open == (access_mode == "open")
	_check("team_ops create (%s) + metadata" % access_mode, meta_ok, "team_id=%s" % team_id)
	return {"team_id": team_id, "session": session} if meta_ok else {}


func _auth_probe_user() -> NakamaSession:
	var user := await _auth_fresh_user()
	if user.is_empty():
		_check("auth probe user", false, "setup auth failed")
		return null
	var session := user["session"] as NakamaSession
	_check("auth probe user", true, "user_id=%s" % session.user_id)
	return session


func _step_open_join(team_id: String, session_b: NakamaSession) -> void:
	var join: NakamaAsyncResult = await _client.join_group_async(session_b, team_id)
	if join.is_exception():
		_check("open group join", false, _detail(join))
		return
	var ug: NakamaAPI.ApiUserGroupList = await _client.list_user_groups_async(session_b, session_b.user_id)
	var state := -1
	if not ug.is_exception() and ug.user_groups != null:
		for entry in ug.user_groups as Array:
			if entry.group != null and str(entry.group.id) == team_id:
				state = int(entry.state)
	_check("open group join (member state=2)", state == 2, "state=%d" % state)


func _step_closed_request_flow(closed_id: String, session_a: NakamaSession, session_b: NakamaSession) -> void:
	# Joining a CLOSED group as non-admin = native join request (core_group.go).
	var req_join: NakamaAsyncResult = await _client.join_group_async(session_b, closed_id)
	if req_join.is_exception():
		_check("closed-group request flow", false, "request join failed: %s" % _detail(req_join))
		return
	# Leader sees the pending request (state 3).
	var gu: NakamaAPI.ApiGroupUserList = await _client.list_group_users_async(session_a, closed_id, 3)
	var requester_found := false
	if not gu.is_exception() and gu.group_users != null:
		for entry in gu.group_users as Array:
			if entry.user != null and str(entry.user.id) == session_b.user_id:
				requester_found = true
	if not requester_found:
		_check("closed-group request flow", false, "request not visible to leader")
		return
	# Non-leader must NOT be able to approve (server-side permission check).
	var bad_add: NakamaAsyncResult = await _client.add_group_users_async(session_b, closed_id, PackedStringArray([session_a.user_id]))
	# Leader approves.
	var add: NakamaAsyncResult = await _client.add_group_users_async(session_a, closed_id, PackedStringArray([session_b.user_id]))
	if add.is_exception():
		_check("closed-group request flow", false, "approve failed: %s" % _detail(add))
		return
	var ug_b: NakamaAPI.ApiUserGroupList = await _client.list_user_groups_async(session_b, session_b.user_id)
	var state := -1
	if not ug_b.is_exception() and ug_b.user_groups != null:
		for entry in ug_b.user_groups as Array:
			if entry.group != null and str(entry.group.id) == closed_id:
				state = int(entry.state)
	_check("closed-group request flow (request -> leader-only approve -> member)", \
		bad_add.is_exception() and state == 2, "non-leader add blocked=%s, member state=%d" % [bad_add.is_exception(), state])


func _step_chat_roundtrip(team_id: String) -> void:
	var session: NakamaSession = await _auth_probe_user_quiet()
	if session == null:
		_check("chat send -> fetch", false, "setup auth failed")
		return
	var join: NakamaAsyncResult = await _client.join_group_async(session, team_id)
	if join.is_exception():
		_check("chat send -> fetch", false, "join failed: %s" % _detail(join))
		return
	var socket: NakamaSocket = _nakama.create_socket_from(_client)
	var conn: NakamaAsyncResult = await socket.connect_async(session)
	if conn.is_exception():
		_check("chat send -> fetch", false, "socket connect failed: %s" % _detail(conn))
		return
	var channel: NakamaRTAPI.Channel = await socket.join_chat_async(team_id, NakamaRTMessage.ChannelJoin.ChannelType.Group, true)
	if channel.is_exception() or channel.id.is_empty():
		_check("chat send -> fetch", false, "join chat failed: %s" % str(channel).left(160))
		return
	var text := "probe-hello-%d" % Time.get_ticks_msec()
	await socket.write_chat_message_async(channel.id, {"text": text})
	await _wait_seconds(1.0)
	var msgs: NakamaAPI.ApiChannelMessageList = await _client.list_channel_messages_async(session, channel.id, 20)
	var found := false
	if not msgs.is_exception() and msgs.messages != null:
		for m in msgs.messages as Array:
			if str(m.content).find(text) != -1:
				found = true
	_check("chat send -> fetch (websocket send, REST poll)", found, "messages=%s" % (msgs.messages.size() if msgs.messages != null else 0))


func _step_chat_realtime(team_id: String) -> void:
	# E1 semantics (TDD §3.24): A subscribes to the group channel over the
	# socket, B writes, and A receives it via received_channel_message with the
	# correct id/text/sender. Also pins the self-echo fact (the sender receives
	# its own message) that drives SocialManager's id-dedupe across the
	# history-fetch / send-echo / socket-push paths.
	var session_a: NakamaSession = await _auth_probe_user_quiet()
	if session_a == null:
		_check("chat realtime push (A subscribes, B writes)", false, "setup auth A failed")
		return
	# Membership is required before a socket can join the group channel —
	# non-members get "Group not found" from join_chat.
	var join_a: NakamaAsyncResult = await _client.join_group_async(session_a, team_id)
	if join_a.is_exception():
		_check("chat realtime push (A subscribes, B writes)", false, "A join group failed: %s" % _detail(join_a))
		return
	var user_b := await _auth_fresh_user()
	if user_b.is_empty():
		_check("chat realtime push (A subscribes, B writes)", false, "auth B failed")
		return
	var code_b := str(user_b["code"])
	var session_b := user_b["session"] as NakamaSession
	var join_b: NakamaAsyncResult = await _client.join_group_async(session_b, team_id)
	if join_b.is_exception():
		_check("chat realtime push (A subscribes, B writes)", false, "B join group failed: %s" % _detail(join_b))
		return

	var received: Array = []
	var socket_a: NakamaSocket = _nakama.create_socket_from(_client)
	socket_a.received_channel_message.connect(func(m: NakamaAPI.ApiChannelMessage) -> void: received.append(m))
	var conn_a: NakamaAsyncResult = await socket_a.connect_async(session_a)
	if conn_a.is_exception():
		socket_a.close()
		_check("chat realtime push (A subscribes, B writes)", false, "A socket connect failed: %s" % _detail(conn_a))
		return
	var channel_a: NakamaRTAPI.Channel = await socket_a.join_chat_async(team_id, NakamaRTMessage.ChannelJoin.ChannelType.Group, true)
	if channel_a.is_exception() or str(channel_a.id).is_empty():
		socket_a.close()
		_check("chat realtime push (A subscribes, B writes)", false, "A join chat failed: %s" % str(channel_a).left(160))
		return
	await _wait_seconds(1.0)

	var text := "probe-rt-%d" % Time.get_ticks_msec()
	var socket_b: NakamaSocket = _nakama.create_socket_from(_client)
	var conn_b: NakamaAsyncResult = await socket_b.connect_async(session_b)
	if conn_b.is_exception():
		socket_a.close()
		_check("chat realtime push (A subscribes, B writes)", false, "B socket connect failed: %s" % _detail(conn_b))
		return
	var channel_b: NakamaRTAPI.Channel = await socket_b.join_chat_async(team_id, NakamaRTMessage.ChannelJoin.ChannelType.Group, true)
	if channel_b.is_exception() or str(channel_b.id).is_empty():
		socket_a.close()
		socket_b.close()
		_check("chat realtime push (A subscribes, B writes)", false, "B join chat failed: %s" % str(channel_b).left(160))
		return
	var write_b: Variant = await socket_b.write_chat_message_async(str(channel_b.id), {"text": text})

	var found: NakamaAPI.ApiChannelMessage = await _find_received(received, text, 8.0)
	if found == null:
		socket_a.close()
		socket_b.close()
		_check("chat realtime push (A subscribes, B writes)", false, "A did not receive B's message within 8s (got %d msgs, write ok=%s)" % [received.size(), not (write_b is NakamaAsyncResult and (write_b as NakamaAsyncResult).is_exception())])
		return
	var push_ok := not str(found.message_id).is_empty() and str(found.username) == code_b and str(found.content).find(text) != -1
	_check("chat realtime push (A subscribes, B writes)", push_ok, "id=%s sender=%s" % [str(found.message_id).left(12), str(found.username)])

	var echo_text := "probe-rt-echo-%d" % Time.get_ticks_msec()
	await socket_a.write_chat_message_async(str(channel_a.id), {"text": echo_text})
	var echo: NakamaAPI.ApiChannelMessage = await _find_received(received, echo_text, 5.0)
	_check("chat self-echo (sender receives own message)", echo != null, "echo received=%s" % (echo != null))
	socket_a.close()
	socket_b.close()


func _find_received(received: Array, text: String, max_secs: float) -> NakamaAPI.ApiChannelMessage:
	var end := Time.get_ticks_msec() + int(max_secs * 1000.0)
	while Time.get_ticks_msec() < end:
		for m in received:
			if str((m as NakamaAPI.ApiChannelMessage).content).find(text) != -1:
				return m as NakamaAPI.ApiChannelMessage
		await _wait_seconds(0.2)
	return null


func _find_presence(events: Array, code: String, which: String, max_secs: float) -> NakamaRTAPI.UserPresence:
	var end := Time.get_ticks_msec() + int(max_secs * 1000.0)
	while Time.get_ticks_msec() < end:
		for e in events:
			var ev := e as NakamaRTAPI.StatusPresenceEvent
			if ev == null or ev.is_exception():
				continue
			var list: Variant = ev.joins if which == "joins" else ev.leaves
			if not (list is Array):
				continue
			for p in list:
				var presence := p as NakamaRTAPI.UserPresence
				if presence != null and not presence.is_exception() and str(presence.username) == code:
					return presence
		await _wait_seconds(0.2)
	return null


func _step_block_unblock() -> void:
	var session_b: NakamaSession = await _auth_probe_user_quiet()
	if session_b == null:
		_check("block -> unblock", false, "setup auth failed")
		return
	var user_a := await _auth_fresh_user()
	if user_a.is_empty():
		_check("block -> unblock", false, "second auth failed")
		return
	var code_a := str(user_a["code"])
	var session_a := user_a["session"] as NakamaSession
	var block: NakamaAsyncResult = await _client.block_friends_async(session_b, PackedStringArray(), [code_a])
	if block.is_exception():
		_check("block -> unblock", false, "block failed: %s" % _detail(block))
		return
	# Nakama has NO dedicated unban API — delete on the blocked (state-3) edge IS the unban (core_friend.go).
	var unblock: NakamaAsyncResult = await _client.delete_friends_async(session_b, PackedStringArray(), [code_a])
	_check("block -> unblock (delete on state-3 edge)", not unblock.is_exception(), _detail(unblock))


func _step_presence() -> void:
	# E2 semantics (TDD §3.25), live-verified in the E2 spike + nakama v3.37.0
	# source (server/pipeline_status.go): presence is EVENT-DRIVEN, and the
	# FOLLOW ACK carries the current presence of already-online friends (no JOIN
	# push is sent for them at follow time). This step orders the events as
	# follow-B-offline (ack must parse with empty presences — pins the addon
	# Status schema patch) -> B connects (JOIN push) -> B disconnects (LEAVE).
	# Both sockets use appear_online=true: the production socket is always
	# visible (chat + presence share one socket), and visibility was verified
	# harmless to event delivery.
	var user_a := await _auth_fresh_user()
	var user_b := await _auth_fresh_user()
	if user_a.is_empty() or user_b.is_empty():
		_check("presence join/leave push", false, "setup auth failed")
		return
	var code_a := str(user_a["code"])
	var session_a := user_a["session"] as NakamaSession
	var code_b := str(user_b["code"])
	var session_b := user_b["session"] as NakamaSession

	var events: Array = []
	var socket_a: NakamaSocket = _nakama.create_socket_from(_client)
	socket_a.received_status_presence.connect(func(e: NakamaRTAPI.StatusPresenceEvent) -> void: events.append(e))
	var conn_a: NakamaAsyncResult = await socket_a.connect_async(session_a, true)
	if conn_a.is_exception():
		_check("presence join/leave push", false, "A connect failed: %s" % _detail(conn_a))
		return
	var follow: NakamaRTAPI.Status = await socket_a.follow_users_async(PackedStringArray(), PackedStringArray([code_b]))
	if follow.is_exception():
		socket_a.close()
		_check("presence join/leave push", false, "follow failed: %s" % _detail(follow))
		return
	# B is offline right now: the ack must parse cleanly with an EMPTY presences
	# list (protojson omits the field — the addon schema patch makes that legal).
	var follow_ack_ok := int((follow.presences as Array).size()) == 0
	_check("presence follow ack (offline user -> empty presences)", follow_ack_ok, "presences=%s" % str(follow.presences))
	await _wait_seconds(1.0)

	var socket_b: NakamaSocket = _nakama.create_socket_from(_client)
	var conn_b: NakamaAsyncResult = await socket_b.connect_async(session_b, true)
	if conn_b.is_exception():
		socket_a.close()
		_check("presence join/leave push", false, "B connect failed: %s" % _detail(conn_b))
		return

	var join: NakamaRTAPI.UserPresence = await _find_presence(events, code_b, "joins", 8.0)
	var join_ok := join != null and str(join.username) == code_b
	_check("presence JOIN push (B connects after A follows)", join_ok, \
		"got=%s" % ("yes username=%s" % str(join.username) if join != null else "no event in 8s"))

	socket_b.close()
	var leave: NakamaRTAPI.UserPresence = await _find_presence(events, code_b, "leaves", 8.0)
	_check("presence LEAVE push (B disconnects)", leave != null and str(leave.username) == code_b, \
		"got=%s" % ("yes username=%s" % str(leave.username) if leave != null else "no event in 8s"))

	# Replay pin: re-follow while B is ONLINE — the ack must carry B's current
	# presence (this is what subscribe_presence turns into the initial delta).
	var socket_b3: NakamaSocket = _nakama.create_socket_from(_client)
	var conn_b3: NakamaAsyncResult = await socket_b3.connect_async(session_b, true)
	if not conn_b3.is_exception():
		await _wait_seconds(1.0)
		var refollow: NakamaRTAPI.Status = await socket_a.follow_users_async(PackedStringArray(), PackedStringArray([code_b]))
		var replay_ok := false
		if not refollow.is_exception():
			for p in refollow.presences:
				var presence := p as NakamaRTAPI.UserPresence
				if presence != null and not presence.is_exception() and str(presence.username) == code_b:
					replay_ok = true
		_check("presence follow ack replay (online user in presences)", replay_ok, \
			"presences=%s" % str(refollow.presences).left(160))
		socket_b3.close()
	else:
		_check("presence follow ack replay (online user in presences)", false, "B reconnect failed: %s" % _detail(conn_b3))

	socket_a.close()
	await _wait_seconds(0.5)


func _step_tournament_ensure() -> Dictionary:
	# Verified semantics (F4 spike): Nakama 3.x has NO REST admin API — creation
	# goes through the tournament_ops JS function, and ensure is idempotent.
	var user := await _auth_fresh_user()
	if user.is_empty():
		_check("tournament_ops ensure (idempotent)", false, "setup auth failed")
		return {}
	var session_a := user["session"] as NakamaSession
	var stamp := Time.get_ticks_msec() % 1000000
	var solo_id := "probe-solo-%d" % stamp
	var team_id := "probe-team-%d" % stamp
	var ok_solo := true
	var ok_team := true
	var last := ""
	for i in 2:
		var s: Dictionary = await _rpc(session_a, "tournament_ops", {"action": "ensure", "id": solo_id, "title": "Probe Solo", "duration_sec": 7200, "event_id": "probe"})
		last = str(s).left(120)
		if not bool(s.get("ok", false)):
			ok_solo = false
		var t: Dictionary = await _rpc(session_a, "tournament_ops", {"action": "ensure", "id": team_id, "title": "Probe Team", "duration_sec": 7200, "event_id": "probe"})
		last += " / " + str(t).left(120)
		if not bool(t.get("ok", false)):
			ok_team = false
	_check("tournament_ops ensure (idempotent create, solo + team)", ok_solo and ok_team, last)
	return {"solo_id": solo_id, "team_id": team_id, "session_a": session_a} if ok_solo and ok_team else {}


func _step_tournament_solo(ctx: Dictionary) -> void:
	var session_a: NakamaSession = ctx.get("session_a")
	var solo_id := str(ctx.get("solo_id", ""))
	var join1: NakamaAsyncResult = await _client.join_tournament_async(session_a, solo_id)
	var write1: Variant = await _client.write_tournament_record_async(session_a, solo_id, 100)
	var write2: Variant = await _client.write_tournament_record_async(session_a, solo_id, 150)
	var join2: NakamaAsyncResult = await _client.join_tournament_async(session_a, solo_id)
	_check("solo join idempotency (second join is a no-op)", not join1.is_exception() and not join2.is_exception(), _detail(join1) + " / " + _detail(join2))
	var around: Variant = await _client.list_tournament_records_around_owner_async(session_a, solo_id, session_a.user_id, 3)
	var row_ok := false
	if not around.is_exception() and around.records != null and (around.records as Array).size() > 0:
		var rec: Variant = (around.records as Array)[0]
		row_ok = str(rec.owner_id) == session_a.user_id and str(rec.score) == "150" and str(rec.rank) == "1"
	_check("solo best-op running total (100 -> 150, rank=1)", not write1.is_exception() and not write2.is_exception() and row_ok, _detail(around))


func _step_tournament_team_rounds(ctx: Dictionary) -> void:
	# Verified semantics (F4 spike): team scoring = ONE group-owned record built
	# from member INCR deltas — the server function writes as the group owner
	# UUID, so the row's username is the team name.
	var session_a: NakamaSession = ctx.get("session_a")
	var team_id := str(ctx.get("team_id", ""))
	var grp_name := "probe-team-grp-%d" % (Time.get_ticks_msec() % 100000)
	var created: Dictionary = await _rpc(session_a, "team_ops", {"action": "create", "name": grp_name, "access_mode": "open"})
	var group_id := str(created.get("team_id", ""))
	if group_id == "":
		_check("team round (group-owned record)", false, "team create failed: %s" % str(created).left(160))
		return
	var session_b: NakamaSession = await _auth_probe_user_quiet()
	if session_b == null:
		_check("team round (group-owned record)", false, "setup auth B failed")
		return
	var join_b: NakamaAsyncResult = await _client.join_group_async(session_b, group_id)
	if join_b.is_exception():
		_check("team round (group-owned record)", false, "B join group failed: %s" % _detail(join_b))
		return
	await _wait_seconds(0.5)
	var tr_a: Dictionary = await _rpc(session_a, "tournament_ops", {"action": "team_round", "tournament_id": team_id, "points": 100})
	var tr_b: Dictionary = await _rpc(session_b, "tournament_ops", {"action": "team_round", "tournament_id": team_id, "points": 50})
	if not bool(tr_a.get("ok", false)) or not bool(tr_b.get("ok", false)):
		_check("team round (group-owned record)", false, "A: %s / B: %s" % [str(tr_a).left(120), str(tr_b).left(120)])
		return
	await _wait_seconds(1.0)
	var tlist: Variant = await _client.list_tournament_records_async(session_a, team_id, null, 10)
	var rows_ok := false
	if not tlist.is_exception() and tlist.records != null and (tlist.records as Array).size() == 1:
		var r0: Variant = (tlist.records as Array)[0]
		rows_ok = str(r0.owner_id) == group_id and str(r0.score) == "150" and str(r0.username) == grp_name
	_check("team round (A:100 + B:50 -> single group-owned record, score=150)", rows_ok, _detail(tlist))


func _step_tournament_no_team(ctx: Dictionary) -> void:
	var session_c: NakamaSession = await _auth_probe_user_quiet()
	if session_c == null:
		_check("team_round no-team guard", false, "setup auth C failed")
		return
	var res: Dictionary = await _rpc(session_c, "tournament_ops", {"action": "team_round", "tournament_id": str(ctx.get("team_id", "")), "points": 10})
	_check("team_round no-team guard (expect no_team)", not bool(res.get("ok", true)) and str(res.get("error", "")) == "no_team", str(res).left(160))


func _step_leaderboard() -> void:
	# E5 (TDD §3.26): leaderboard_ops ensure is idempotent; clients write their
	# own best directly (operator "best"), list global, list owner-filtered
	# (friend scope), and read the around-owner rank. Records on the SHARED
	# lb_best_score board accumulate across runs, so the write/list assertions
	# use a fresh per-run board created through the SAME ensure path.
	var user := await _auth_fresh_user()
	if user.is_empty():
		_check("leaderboard_ops ensure (idempotent)", false, "setup auth failed")
		return
	var session_a := user["session"] as NakamaSession
	var first: Dictionary = await _rpc(session_a, "leaderboard_ops", {"action": "ensure", "id": "lb_best_score"})
	var second: Dictionary = await _rpc(session_a, "leaderboard_ops", {"action": "ensure", "id": "lb_best_score"})
	_check("leaderboard_ops ensure (idempotent on the shared board)", bool(first.get("ok", false)) and bool(second.get("ok", false)), str(first).left(120) + " / " + str(second).left(120))

	var stamp := Time.get_ticks_msec() % 1000000
	var lb_id := "probe-lb-%d" % stamp
	var created: Dictionary = await _rpc(session_a, "leaderboard_ops", {"action": "ensure", "id": lb_id})
	if not bool(created.get("ok", false)) or not bool(created.get("created", false)):
		_check("leaderboard fresh board (created=true on first ensure)", false, str(created).left(160))
		return
	var session_b: NakamaSession = await _auth_probe_user_quiet()
	if session_b == null:
		_check("leaderboard write + lists", false, "setup auth B failed")
		return

	var write_a: Variant = await _client.write_leaderboard_record_async(session_a, lb_id, 100)
	var write_b: Variant = await _client.write_leaderboard_record_async(session_b, lb_id, 250)
	await _wait_seconds(0.5)

	# Global list: desc order with ranks (enableRanks=true at creation).
	var glob: Variant = await _client.list_leaderboard_records_async(session_a, lb_id, null, null, 10, null)
	var glob_ok := false
	if not glob.is_exception() and glob.records != null:
		var recs := glob.records as Array
		if recs.size() == 2:
			var r0: Variant = recs[0]
			var r1: Variant = recs[1]
			glob_ok = str(r0.owner_id) == session_b.user_id and str(r0.score) == "250" and str(r0.rank) == "1" \
				and str(r1.owner_id) == session_a.user_id and str(r1.score) == "100" and str(r1.rank) == "2"
	_check("leaderboard global list (desc, ranked, string scores)", not write_a.is_exception() and not write_b.is_exception() and glob_ok, _detail(glob))

	# Friend scope: owner_ids filters to the given user ids — verified in
	# LeaderboardRecordsList (core_leaderboard.go): the filtered rows ride in
	# owner_records (ranks filled), while records stays the global window.
	var friends: Variant = await _client.list_leaderboard_records_async(session_a, lb_id, [session_b.user_id], null, 10, null)
	var fs_ok := false
	if not friends.is_exception() and friends.owner_records != null:
		var recs := friends.owner_records as Array
		if recs.size() == 1:
			var r0: Variant = recs[0]
			fs_ok = str(r0.owner_id) == session_b.user_id and str(r0.score) == "250" and str(r0.rank) == "1"
	_check("leaderboard owner-filtered list (friend scope, rows in owner_records)", fs_ok, _detail(friends))

	# Around-owner: the owner's OWN row rides in `records` (verified in
	# getLeaderboardRecordsHaystack — not owner_records).
	var around: Variant = await _client.list_leaderboard_records_around_owner_async(session_a, lb_id, session_a.user_id, null, 3, null)
	var ar_ok := false
	if not around.is_exception() and around.records != null:
		for rec in around.records as Array:
			var r: Variant = rec
			if str(r.owner_id) == session_a.user_id and str(r.score) == "100" and str(r.rank) == "2":
				ar_ok = true
	_check("leaderboard around-owner (own row in records, rank=2)", ar_ok, _detail(around))


func _step_matchmaking() -> void:
	# E4 (TDD §3.27), live-verified in the E4 spike + nakama v3.37.0 source
	# (server/matchmaker.go): the matchmaker forms matches on a fixed interval
	# (IntervalSec, default 15s — no compose override on the local stack), so
	# queue waits can reach ~15s and this step uses generous time-based bounds.
	# Wire facts pinned here: matched.users carries ALL matched users INCLUDING
	# self; the join ack's `size` is racy for sequential joins (membership proof
	# is the presence event, not the ack); match data round-trips op_code +
	# base64 payload. Query stays "*" (spike-verified): a stray third client on
	# the shared local stack would fail the "both see each other" assertion —
	# which is exactly what a probe should flag.
	var step := "matchmaking 1v1 (queue -> matched -> room)"
	var user_a := await _auth_fresh_user()
	if user_a.is_empty():
		_check(step, false, "setup auth A failed")
		return
	var code_a := str(user_a["code"])
	var session_a := user_a["session"] as NakamaSession
	var user_b := await _auth_fresh_user()
	if user_b.is_empty():
		_check(step, false, "setup auth B failed")
		return
	var code_b := str(user_b["code"])
	var session_b := user_b["session"] as NakamaSession

	# appear_online=true on both sockets: the matchmaker needs live presence to
	# form matches (two concurrent sockets per user are fine — verified in E1).
	var socket_a: NakamaSocket = _nakama.create_socket_from(_client)
	var conn_a: NakamaAsyncResult = await socket_a.connect_async(session_a, true)
	if conn_a.is_exception():
		socket_a.close()
		_check(step, false, "A socket connect failed: %s" % _detail(conn_a))
		return
	var socket_b: NakamaSocket = _nakama.create_socket_from(_client)
	var conn_b: NakamaAsyncResult = await socket_b.connect_async(session_b, true)
	if conn_b.is_exception():
		socket_a.close()
		socket_b.close()
		_check(step, false, "B socket connect failed: %s" % _detail(conn_b))
		return

	var matched_a: Array = []
	var matched_b: Array = []
	socket_a.received_matchmaker_matched.connect(func(m) -> void: matched_a.append(m))
	socket_b.received_matchmaker_matched.connect(func(m) -> void: matched_b.append(m))
	var add_a: Variant = await socket_a.add_matchmaker_async("*", 2, 2)
	var add_b: Variant = await socket_b.add_matchmaker_async("*", 2, 2)
	_check("matchmaker add (both clients hold a ticket)", not add_a.is_exception() and not add_b.is_exception(), "A=%s B=%s" % [_detail(add_a), _detail(add_b)])
	if add_a.is_exception() or add_b.is_exception():
		socket_a.close()
		socket_b.close()
		return

	var end := Time.get_ticks_msec() + 40000
	while (matched_a.is_empty() or matched_b.is_empty()) and Time.get_ticks_msec() < end:
		await _wait_seconds(0.5)
	var users_a := _matched_users(matched_a[0] if not matched_a.is_empty() else null)
	var users_b := _matched_users(matched_b[0] if not matched_b.is_empty() else null)
	var sees_each_other := _users_see(users_a, session_a.user_id, code_a) and _users_see(users_a, session_b.user_id, code_b) \
		and _users_see(users_b, session_a.user_id, code_a) and _users_see(users_b, session_b.user_id, code_b)
	var self_ok := not matched_a.is_empty() and not matched_b.is_empty() \
		and str((matched_a[0] as NakamaRTAPI.MatchmakerMatched).self_user.presence.user_id) == session_a.user_id \
		and str((matched_b[0] as NakamaRTAPI.MatchmakerMatched).self_user.presence.user_id) == session_b.user_id
	_check("matchmaker matched (both see each other, users includes self)", sees_each_other and self_ok, "A users=%s B users=%s" % [str(users_a), str(users_b)])
	if not sees_each_other or not self_ok:
		socket_a.close()
		socket_b.close()
		return

	var join_a: Variant = await socket_a.join_matched_async(matched_a[0])
	var join_b: Variant = await socket_b.join_matched_async(matched_b[0])
	var same_match := not str(join_a.match_id).is_empty() and str(join_a.match_id) == str(join_b.match_id)
	_check("join_matched (same match id on both sides)", not join_a.is_exception() and not join_b.is_exception() and same_match, "a=%s b=%s" % [str(join_a.match_id).left(12), str(join_b.match_id).left(12)])
	if not same_match:
		socket_a.close()
		socket_b.close()
		return

	var received_b: Array = []
	socket_b.received_match_state.connect(func(d) -> void: received_b.append(d))
	await _wait_seconds(1.0)  # let B settle into the match before A sends
	var payload := "e4-ping-%d" % Time.get_ticks_msec()
	await socket_a.send_match_state_async(str(join_a.match_id), 7, payload)
	var found: NakamaRTAPI.MatchData = null
	var end2 := Time.get_ticks_msec() + 8000
	while found == null and Time.get_ticks_msec() < end2:
		for d in received_b:
			var md := d as NakamaRTAPI.MatchData
			if md != null and not md.is_exception() and int(md.op_code) == 7 and str(md.data) == payload:
				found = md
		await _wait_seconds(0.2)
	_check("match data round-trip (op code + decoded payload)", found != null, "B received %d state msgs" % received_b.size())

	var presence_b: Array = []
	socket_b.received_match_presence.connect(func(e) -> void: presence_b.append(e))
	await socket_a.leave_match_async(str(join_a.match_id))
	var saw_leave := false
	var end3 := Time.get_ticks_msec() + 8000
	while not saw_leave and Time.get_ticks_msec() < end3:
		for e in presence_b:
			var ev := e as NakamaRTAPI.MatchPresenceEvent
			if ev == null or ev.is_exception():
				continue
			for p in ev.leaves:
				var presence := p as NakamaRTAPI.UserPresence
				if presence != null and not presence.is_exception() and str(presence.user_id) == session_a.user_id:
					saw_leave = true
		await _wait_seconds(0.2)
	_check("match presence leave (A leaves, B sees the event)", saw_leave, "B received %d presence events" % presence_b.size())
	socket_a.close()
	socket_b.close()


func _matched_users(matched: Variant) -> Array:
	var out: Array = []
	if matched == null or (matched as NakamaAsyncResult).is_exception():
		return out
	for u in (matched as NakamaRTAPI.MatchmakerMatched).users:
		var presence: Variant = (u as NakamaRTAPI.MatchmakerUser).presence
		out.append({"user_id": str(presence.user_id), "username": str(presence.username)})
	return out


func _users_see(users: Array, user_id: String, username: String) -> bool:
	for row in users:
		var r := row as Dictionary
		if str(r.get("user_id", "")) == user_id and str(r.get("username", "")) == username:
			return true
	return false


## Fresh probe user with collision retry. The 16-word x 4-digit code space
## (160k) accumulates users in the PERSISTENT dev DB across runs, so a random
## draw can land on a taken username — Nakama answers 409 "Username is already
## in use" and the probe must redraw, not fail. Mirrors OnlineService's
## collision handling (TDD §3.17) while keeping username==code intact for the
## steps that assert it. Returns {key, code, session} or {} after exhaustion.
func _auth_fresh_user(max_attempts: int = 5) -> Dictionary:
	for i in max_attempts:
		var key := _random_key()
		var code := str(_identity.derive_player_code(key))
		var session: NakamaSession = await _client.authenticate_custom_async(key, code, true, null)
		if not session.is_exception():
			return {"key": key, "code": code, "session": session}
		if not _is_username_collision(session):
			break
	return {}


static func _is_username_collision(result: Variant) -> bool:
	if result == null or not (result is NakamaAsyncResult and (result as NakamaAsyncResult).is_exception()):
		return false
	var ex := (result as NakamaAsyncResult).get_exception()
	if ex == null:
		return false
	return int(ex.status_code) == 409 or str(ex.message).to_lower().find("username") != -1


func _auth_probe_user_quiet() -> NakamaSession:
	var user := await _auth_fresh_user()
	return (user.get("session") as NakamaSession) if not user.is_empty() else null


# --- Helpers -------------------------------------------------------------------

func _check(step_name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("PASS  %s" % step_name)
	else:
		_failed += 1
		print("FAIL  %s — %s" % [step_name, detail])


func _detail(result: Variant) -> String:
	if result == null:
		return "null result"
	if result is NakamaAsyncResult and (result as NakamaAsyncResult).is_exception():
		return str((result as NakamaAsyncResult).get_exception()).left(200)
	return str(result).left(200)


func _rpc(session: NakamaSession, id: String, payload: Dictionary) -> Dictionary:
	var res: NakamaAPI.ApiRpc = await _client.rpc_async(session, id, JSON.stringify(payload))
	if res.is_exception():
		return {"ok": false, "error": str(res.get_exception()).left(200)}
	var parsed: Variant = JSON.parse_string(str(res.payload))
	if typeof(parsed) == TYPE_DICTIONARY:
		return parsed as Dictionary
	return {"ok": false, "error": "bad_payload_shape", "raw": str(res.payload).left(200)}


func _random_key() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var hex_chars := "0123456789abcdef"
	var out := ""
	for i in 16:
		out += hex_chars[rng.randi() % 16] + hex_chars[rng.randi() % 16]
	return out


func _wait_seconds(seconds: float) -> void:
	await create_timer(seconds).timeout


func _http_get(path: String) -> Dictionary:
	var http := HTTPRequest.new()
	root.add_child(http)
	http.timeout = float(_timeout)
	var err := http.request("%s://%s:%d%s" % [_scheme, _host, _port, path], PackedStringArray(["Accept: application/json"]))
	if err != OK:
		http.queue_free()
		return {"status": 0, "body": "request error %d" % err}
	var res: Array = await http.request_completed
	http.queue_free()
	return {"status": int(res[1]), "body": (res[3] as PackedByteArray).get_string_from_utf8()}


func _parse_args(args: PackedStringArray) -> void:
	for i in args.size():
		var arg := str(args[i])
		if arg == "--host" and i + 1 < args.size():
			_host = str(args[i + 1])
		elif arg == "--port" and i + 1 < args.size():
			_port = int(str(args[i + 1]))
		elif arg == "--scheme" and i + 1 < args.size():
			_scheme = str(args[i + 1])
		elif arg == "--key" and i + 1 < args.size():
			_key = str(args[i + 1])
		elif arg == "--timeout" and i + 1 < args.size():
			_timeout = int(str(args[i + 1]))

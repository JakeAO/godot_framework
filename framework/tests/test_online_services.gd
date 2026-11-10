extends GutTest
## Online services (TDD §3.16): IdentityService key lifecycle + player code,
## MockSocialBackend pinned data, SocialManager facade behavior (fake backend),
## and SaveSystem cross-device sync hooks (LWW merge, debounced upload).

class FakeSocialBackend extends ISocialBackend:
	var friends: Array[Dictionary] = []
	var teams: Array[Dictionary] = []
	var chat_history: Array[Dictionary] = []
	var join_response: Dictionary = {"ok": false, "team": {}}
	var add_response: Dictionary = {"ok": true, "error": ""}
	var send_response: Dictionary = {"ok": false, "message": {}}
	var fail_fetch_friends: bool = false
	var fetch_calls: int = 0
	var join_calls: int = 0
	# v3 (TDD §3.24): null = transport failure; a Dictionary = business result.
	var subscribe_result: Variant = {"ok": true, "error": ""}
	var subscribed: bool = false

	func fetch_friends() -> Variant:
		fetch_calls += 1
		if fail_fetch_friends:
			return null
		return friends.duplicate(true)

	func add_friend(_player_code: String) -> Variant:
		return add_response.duplicate(true)

	func search_teams(_query: String) -> Variant:
		return teams.duplicate(true)

	func join_team(_team_id: String) -> Variant:
		join_calls += 1
		return join_response.duplicate(true)

	func fetch_chat_history(_limit: int) -> Variant:
		return chat_history.duplicate(true)

	func send_chat_message(_text: String) -> Variant:
		return send_response.duplicate(true)

	func subscribe_chat() -> Variant:
		subscribed = true
		return subscribe_result

	func unsubscribe_chat() -> void:
		subscribed = false

	## Test seam mirroring the real socket push (TDD §3.24).
	func push_chat(message: Dictionary) -> void:
		chat_message_received.emit(message)

	# v4 (TDD §3.25): presence subscription state + push seam.
	var presence_subscribed_codes: Array[String] = []
	var subscribe_presence_result: Variant = {"ok": true, "error": ""}

	func subscribe_presence(friend_codes: Array[String]) -> Variant:
		presence_subscribed_codes = friend_codes.duplicate()
		return subscribe_presence_result

	func unsubscribe_presence() -> void:
		presence_subscribed_codes = []

	## Test seam mirroring the real socket presence push (TDD §3.25).
	func push_presence(delta: Dictionary) -> void:
		presence_updated.emit(delta)


class FakeSyncBackend extends ISaveSyncBackend:
	var fetch_result: Dictionary = {"domains": {}, "fetched_at": 0}
	var upload_ok: bool = true
	var uploads: Array[Dictionary] = []

	func fetch_synced_domains() -> Dictionary:
		return fetch_result.duplicate(true)

	func upload_synced_domains(domains: Dictionary) -> bool:
		uploads.append(domains.duplicate(true))
		return upload_ok


var _fake_social: FakeSocialBackend
var _fake_sync: FakeSyncBackend
var _original_save_path: String = ""
var _temp_save_path: String = ""
var _original_identity_path: String = ""
var _temp_identity_path: String = ""
var _original_social_backend: ISocialBackend


func before_all() -> void:
	DirAccess.make_dir_recursive_absolute("user://gut_tmp")
	_original_social_backend = SocialManager.get_backend()


func before_each() -> void:
	var stamp := Time.get_ticks_usec()
	_original_save_path = SaveSystem.get_save_path()
	_temp_save_path = "user://gut_tmp/online_%d.json" % stamp
	SaveSystem.set_save_path(_temp_save_path)
	SaveSystem.load_save()

	_original_identity_path = IdentityService.get_identity_path()
	_temp_identity_path = "user://gut_tmp/identity_%d.json" % stamp
	IdentityService.set_identity_path(_temp_identity_path)

	_fake_social = FakeSocialBackend.new()
	SocialManager.set_backend(_fake_social)
	_fake_sync = FakeSyncBackend.new()
	SaveSystem.set_sync_backend(_fake_sync)


func after_each() -> void:
	SocialManager.set_backend(_original_social_backend)
	SaveSystem.set_sync_backend(null)
	SaveSystem.set_save_path(_original_save_path)
	IdentityService.set_identity_path(_original_identity_path)
	for path in [_temp_save_path, _temp_save_path + ".tmp", _temp_identity_path]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


# --- IdentityService --------------------------------------------------------------

func test_identity_key_is_generated_and_persisted() -> void:
	var key := IdentityService.get_player_key()
	assert_eq(key.length(), 64, "key is 32 bytes of hex")
	assert_true(_is_hex(key), "key is lowercase hex")
	assert_true(FileAccess.file_exists(IdentityService.get_identity_path()), "identity persisted to its own file")
	assert_eq(IdentityService.get_player_key(), key, "key stable across calls")


func test_identity_is_reloaded_from_file() -> void:
	var known := "ab".repeat(32)
	_write_identity_file(known)
	IdentityService.set_identity_path(_temp_identity_path)
	assert_eq(IdentityService.get_player_key(), known, "existing valid key is reused")


func test_identity_corrupt_file_regenerates() -> void:
	_write_identity_file("not-a-key")
	IdentityService.set_identity_path(_temp_identity_path)
	var key := IdentityService.get_player_key()
	assert_ne(key, "not-a-key", "corrupt key rejected")
	assert_eq(key.length(), 64, "fresh valid key generated")
	assert_push_warning("invalid", "corrupt identity file warns once")


func test_identity_survives_save_reset() -> void:
	var key := IdentityService.get_player_key()
	SaveSystem.clear_save()
	IdentityService.set_identity_path(IdentityService.get_identity_path())
	assert_eq(IdentityService.get_player_key(), key, "identity survives a save reset (own file)")


func test_player_code_format_and_determinism() -> void:
	var key := IdentityService.get_player_key()
	var code := IdentityService.get_player_code()
	var parts := code.split("-", true, 1)
	assert_eq(parts.size(), 2, "code is WORD-NNNN")
	assert_true(IdentityService.CODE_WORDS.has(parts[0]), "word from the fixed list")
	assert_eq(parts[1].length(), 4, "four digits")
	assert_true(_is_all_digits(parts[1]), "digits only")
	assert_eq(IdentityService.derive_player_code(key), code, "code derived from the key")
	assert_eq(IdentityService.derive_player_code(key), IdentityService.derive_player_code(key), "derivation deterministic")


func test_auth_headers_carry_the_key() -> void:
	var headers := IdentityService.get_auth_headers()
	assert_eq(str(headers.get("X-Player-Key", "")), IdentityService.get_player_key(), "v1 auth = raw key via the token seam")


# --- MockSocialBackend (pinned data) ------------------------------------------------

func test_mock_social_data_is_pinned_to_legacy_consts() -> void:
	var mock := MockSocialBackend.new()
	var friends: Array = mock.fetch_friends()
	assert_eq(friends.size(), 3, "three mock friends")
	assert_eq(str(friends[0].get("name", "")), "Ada", "first friend is Ada")
	assert_eq(int(friends[0].get("best_score", 0)), 1240, "Ada's score pinned")
	assert_eq(int(friends[1].get("best_score", 0)), 980, "Grace's score pinned")
	assert_eq(int(friends[2].get("best_score", 0)), 460, "Linus's score pinned")
	for friend in friends:
		assert_true(not str(friend.get("player_code", "")).is_empty(), "friend carries a player code")

	var teams: Array = mock.search_teams("")
	assert_eq(teams.size(), 3, "three mock teams")
	assert_eq(str(teams[0].get("name", "")), "Golden Owls", "first team pinned")
	for team in teams:
		assert_true(not str(team.get("team_id", "")).is_empty(), "team carries a team id")

	var chat: Array = mock.fetch_chat_history(50)
	assert_eq(chat.size(), 3, "three seed messages")
	assert_eq(str(chat[0].get("sender_name", "")), "Ada", "first message from Ada")
	for message in chat:
		assert_true(message.has("id") and message.has("ts"), "message carries id + ts")


func test_mock_friend_rows_carry_stable_user_ids() -> void:
	var mock := MockSocialBackend.new()
	var first: Array = mock.fetch_friends()
	var second: Array = mock.fetch_friends()
	assert_eq(first.size(), second.size(), "same friend set on re-fetch")
	for i in first.size():
		var uid_a := str((first[i] as Dictionary).get("user_id", ""))
		var uid_b := str((second[i] as Dictionary).get("user_id", ""))
		assert_true(uid_a.begins_with("mock-user-"), "row %d carries a fake user id (E5 row shape)" % i)
		assert_eq(uid_a, uid_b, "user id is stable across fetches")


func test_mock_add_friend_validates_and_invites() -> void:
	var mock := MockSocialBackend.new("TEST-0001")
	var invalid: Dictionary = mock.add_friend("nope")
	assert_false(bool(invalid.get("ok", false)), "malformed code rejected")
	assert_eq(str(invalid.get("error", "")), "friend_invalid_code", "invalid-code error key")

	var unknown: Dictionary = mock.add_friend("OWL-1234")
	assert_false(bool(unknown.get("ok", false)), "well-formed but unknown code rejected")
	assert_eq(str(unknown.get("error", "")), "friend_unknown_code", "unknown-code error key")

	# Kofi is a seeded directory user who is not yet a friend.
	var kofi_code := IdentityService.derive_player_code("mock:Kofi")
	var ok: Dictionary = mock.add_friend(kofi_code.to_lower())
	assert_true(bool(ok.get("ok", false)), "known non-friend accepted (case-insensitive)")
	var invitations: Array = mock.fetch_invitations()
	assert_eq(invitations.size(), 2, "seeded received + new sent invitation")
	var sent_found := false
	for entry in invitations:
		if str((entry as Dictionary).get("direction", "")) == "sent" and str((entry as Dictionary).get("player_code", "")) == kofi_code:
			sent_found = true
	assert_true(sent_found, "add creates a SENT invitation row")

	var dup: Dictionary = mock.add_friend(kofi_code)
	assert_false(bool(dup.get("ok", false)), "add while pending rejected")
	assert_eq(str(dup.get("error", "")), "friend_pending_exists", "pending-exists error key")

	var cancel: Dictionary = mock.respond_invitation(kofi_code, false)
	assert_true(bool(cancel.get("ok", false)), "sent invitation cancelled with accept=false")
	var invitations_after: Array = mock.fetch_invitations()
	assert_eq(invitations_after.size(), 1, "only the seeded received one remains")

	# The seeded RECEIVED invitation (from Mia) accepts into a friendship.
	var mia_code := IdentityService.derive_player_code("mock:Mia")
	var accept: Dictionary = mock.respond_invitation(mia_code, true)
	assert_true(bool(accept.get("ok", false)), "received invitation accepted")
	var friends: Array = mock.fetch_friends()
	assert_eq(friends.size(), 4, "accepted invite becomes a friend")
	assert_eq((mock.fetch_invitations() as Array).size(), 0, "no pendings after accept + cancel")

	# Block prevents re-adding; unblock reverses it.
	var block: Dictionary = mock.block_user(kofi_code)
	assert_true(bool(block.get("ok", false)), "block ok")
	var blocked_add: Dictionary = mock.add_friend(kofi_code)
	assert_false(bool(blocked_add.get("ok", false)), "blocked user cannot be re-added")
	assert_eq(str(blocked_add.get("error", "")), "friend_blocked", "blocked error key")
	var unblock: Dictionary = mock.unblock_user(kofi_code)
	assert_true(bool(unblock.get("ok", false)), "unblock ok")

	# Already friends -> friend_already_added.
	var ada_code := IdentityService.derive_player_code("mock:Ada")
	var already: Dictionary = mock.add_friend(ada_code)
	assert_false(bool(already.get("ok", false)), "adding an existing friend rejected")
	assert_eq(str(already.get("error", "")), "friend_already_added", "already-added error key")

	mock.remove_friend(ada_code)
	var after_remove: Array = mock.fetch_friends()
	for friend in after_remove:
		assert_ne(str(friend.get("player_code", "")), ada_code, "remove drops the friend")


func test_mock_join_and_fetch_team_roundtrip() -> void:
	var mock := MockSocialBackend.new()
	var teams: Array = mock.search_teams("")
	var joined: Dictionary = mock.join_team(str(teams[0].get("team_id", "")))
	assert_true(bool(joined.get("ok", false)), "join succeeds for a known team")
	var domain: Dictionary = joined.get("team", {})
	assert_eq(str(domain.get("team_name", "")), "Golden Owls", "join returns the domain shape")
	assert_true(bool(domain.get("on_team", false)), "domain marks on-team")
	assert_eq(mock.fetch_team(), domain, "fetch_team returns the joined team")
	mock.leave_team()
	assert_eq(mock.fetch_team(), {}, "leave clears the joined team")


func test_mock_simulate_incoming_chat_pushes_only_while_subscribed() -> void:
	var mock := MockSocialBackend.new()
	# Off-team: subscribe is a business no-op and pushes are dropped.
	var off_team: Dictionary = mock.subscribe_chat()
	assert_false(bool(off_team.get("ok", false)), "off-team subscribe fails")
	assert_eq(str(off_team.get("error", "")), "chat_no_team", "business error key, not transport null")
	watch_signals(mock)
	mock.simulate_incoming_chat("OWL-9001", "Ada", "no one is listening")
	assert_eq(get_signal_emit_count(mock, "chat_message_received"), 0, "push dropped without a subscription")

	var teams: Array = mock.search_teams("")
	mock.join_team(str(teams[0].get("team_id", "")))
	var ok: Dictionary = mock.subscribe_chat()
	assert_true(bool(ok.get("ok", false)), "on-team subscribe succeeds")
	var pushed: Dictionary = mock.simulate_incoming_chat("OWL-9002", "Grace", "hello team")
	assert_eq(get_signal_emit_count(mock, "chat_message_received"), 1, "push delivered while subscribed")
	assert_eq(str(pushed.get("text", "")), "hello team", "seam returns the recorded message")

	mock.unsubscribe_chat()
	mock.simulate_incoming_chat("OWL-9003", "Linus", "gone quiet")
	assert_eq(get_signal_emit_count(mock, "chat_message_received"), 1, "unsubscribe stops the push")


# --- SocialManager (fake backend) -----------------------------------------------------

func test_manager_fetch_friends_caches_and_emits() -> void:
	watch_signals(EventBus)
	_fake_social.friends = [
		{"player_code": "OWL-0001", "name": "Ada", "level": 7, "best_score": 1240, "portrait_icon": "gold", "portrait_flair": "ring_gold", "portrait_crown": "crown_gold"},
	]
	var friends: Array[Dictionary] = await SocialManager.fetch_friends()
	assert_eq(friends.size(), 1, "fetched friends returned")
	assert_signal_emitted_with_parameters(EventBus, "social_friends_changed", [friends])


func test_manager_fetch_friends_failure_returns_cache_and_warns_once() -> void:
	_fake_social.friends = [{"player_code": "OWL-0001", "name": "Ada"}]
	await SocialManager.fetch_friends()  # prime the cache
	_fake_social.fail_fetch_friends = true
	var first: Array[Dictionary] = await SocialManager.fetch_friends()
	assert_eq(first.size(), 1, "first failure falls back to cache")
	assert_push_warning("unavailable", "failure warns once")
	await SocialManager.fetch_friends()
	# A second warning would remain unconsumed and fail this test: warn-once holds.


func test_manager_add_friend_success_refetches() -> void:
	_fake_social.add_response = {"ok": true, "error": ""}
	var result: Dictionary = await SocialManager.add_friend("OWL-0001")
	assert_true(bool(result.get("ok", false)), "add reports ok")
	assert_eq(_fake_social.fetch_calls, 1, "success triggers a friends refetch")


func test_manager_add_friend_failure_surfaces_error() -> void:
	_fake_social.add_response = {"ok": false, "error": "friend_unknown_code"}
	var result: Dictionary = await SocialManager.add_friend("ZZZ-9999")
	assert_false(bool(result.get("ok", false)), "add reports failure")
	assert_eq(str(result.get("error", "")), "friend_unknown_code", "backend error key surfaced")
	assert_eq(_fake_social.fetch_calls, 0, "failure does not refetch")


func test_manager_join_team_writes_domain_and_emits() -> void:
	var team := {"on_team": true, "team_name": "Golden Owls", "banner_color": "gold", "power": 4200, "members": ["Ada", "You"]}
	_fake_social.join_response = {"ok": true, "team": team}
	watch_signals(EventBus)
	var result: Dictionary = await SocialManager.join_team("mock_golden_owls")
	assert_true(bool(result.get("ok", false)), "join ok")
	assert_eq(SaveSystem.get_domain("team"), team.duplicate(true), "join wrote the team domain")
	assert_signal_emitted(EventBus, "social_team_changed", "team change announced")


func test_manager_join_failure_keeps_local_state() -> void:
	SaveSystem.set_domain("team", {"on_team": false})
	_fake_social.join_response = {"ok": false, "team": {}}
	var result: Dictionary = await SocialManager.join_team("mock_golden_owls")
	assert_false(bool(result.get("ok", false)), "join failure reported")
	assert_eq(bool(SaveSystem.get_domain("team").get("on_team", false)), false, "local domain untouched on failure")
	assert_push_warning("unavailable", "failure warns once")


func test_manager_leave_team_clears_domain() -> void:
	SaveSystem.set_domain("team", {"on_team": true, "team_name": "X"})
	await SocialManager.leave_team()
	assert_eq(bool(SaveSystem.get_domain("team").get("on_team", false)), false, "leave clears the team domain")


func test_manager_chat_baseline_then_new_messages_emit() -> void:
	_fake_social.chat_history = [
		{"id": 1, "sender_code": "OWL-0002", "sender_name": "Ada", "text": "hi", "ts": 1},
		{"id": 2, "sender_code": "OWL-0003", "sender_name": "Grace", "text": "yo", "ts": 2},
	]
	watch_signals(EventBus)
	var first: Array[Dictionary] = await SocialManager.fetch_chat(50)
	assert_eq(first.size(), 2, "baseline fetched")
	assert_signal_not_emitted(EventBus, "social_chat_message", "baseline fetch does not emit per-message")
	_fake_social.chat_history.append({"id": 3, "sender_code": "OWL-0002", "sender_name": "Ada", "text": "again", "ts": 3})
	await SocialManager.fetch_chat(50)
	assert_signal_emitted(EventBus, "social_chat_message", "new message emitted on next fetch")


func test_manager_send_chat_echoes_message() -> void:
	_fake_social.send_response = {"ok": true, "message": {"id": 99, "sender_code": "OWL-0001", "sender_name": "You", "text": "hello", "ts": 9}}
	watch_signals(EventBus)
	var result: Dictionary = await SocialManager.send_chat("hello")
	assert_true(bool(result.get("ok", false)), "send ok")
	assert_signal_emitted(EventBus, "social_chat_message", "sent message echoed to listeners")


# --- Chat realtime (v3, TDD §3.24) ------------------------------------------------------

func test_manager_subscribes_when_on_team() -> void:
	SaveSystem.set_domain("team", {"on_team": true})
	EventBus.social_team_changed.emit(SaveSystem.get_domain("team"))
	await get_tree().process_frame
	assert_true(_fake_social.subscribed, "on-team + online subscribes to the chat channel")


func test_manager_unsubscribes_when_leaving_team() -> void:
	SaveSystem.set_domain("team", {"on_team": true})
	EventBus.social_team_changed.emit(SaveSystem.get_domain("team"))
	await get_tree().process_frame
	assert_true(_fake_social.subscribed, "subscribed while on a team")
	SaveSystem.set_domain("team", {"on_team": false})
	EventBus.social_team_changed.emit(SaveSystem.get_domain("team"))
	await get_tree().process_frame
	assert_false(_fake_social.subscribed, "leaving the team drops the subscription")


func test_manager_push_dedupes_against_fetch_and_echo() -> void:
	_fake_social.chat_history = [
		{"id": 1, "sender_code": "OWL-0002", "sender_name": "Ada", "text": "hi", "ts": 1},
	]
	watch_signals(EventBus)
	await SocialManager.fetch_chat(50)
	var baseline: int = get_signal_emit_count(EventBus, "social_chat_message")
	assert_eq(baseline, 0, "baseline fetch emits nothing")

	_fake_social.push_chat({"id": 1, "sender_code": "OWL-0002", "sender_name": "Ada", "text": "hi", "ts": 1})
	assert_eq(get_signal_emit_count(EventBus, "social_chat_message"), baseline, "re-push of a known id is dropped")

	_fake_social.push_chat({"id": 2, "sender_code": "OWL-0003", "sender_name": "Grace", "text": "yo", "ts": 2})
	assert_eq(get_signal_emit_count(EventBus, "social_chat_message"), baseline + 1, "fresh push emits exactly once")

	# The send echo marks its id known, so the server's self-echo push is dropped.
	_fake_social.send_response = {"ok": true, "message": {"id": 3, "sender_code": "OWL-0001", "sender_name": "You", "text": "hey", "ts": 3}}
	await SocialManager.send_chat("hey")
	assert_eq(get_signal_emit_count(EventBus, "social_chat_message"), baseline + 2, "send echo emits exactly once")
	_fake_social.push_chat({"id": 3, "sender_code": "OWL-0001", "sender_name": "You", "text": "hey", "ts": 3})
	assert_eq(get_signal_emit_count(EventBus, "social_chat_message"), baseline + 2, "self-echo push is dropped (dedupe)")


func test_manager_reonline_resubscribes_and_catches_up() -> void:
	SaveSystem.set_domain("team", {"on_team": true})
	EventBus.social_team_changed.emit(SaveSystem.get_domain("team"))
	await get_tree().process_frame
	assert_true(_fake_social.subscribed, "subscribed while on a team")

	# The screen's first visible fetch establishes the baseline (production
	# flow) — only then does a later refetch emit per new message.
	_fake_social.chat_history = [{"id": 1, "sender_code": "OWL-0002", "sender_name": "Ada", "text": "hi", "ts": 1}]
	await SocialManager.fetch_chat(50)

	# Offline: the QA seam flips is_online(); the manual emit mirrors the
	# transition publish real mode performs (mock mode publishes nothing).
	OnlineService.force_offline(true)
	EventBus.backend_state_changed.emit(false)
	await get_tree().process_frame
	assert_false(_fake_social.subscribed, "offline drops the subscription")

	var missed := {"id": 7, "sender_code": "OWL-0002", "sender_name": "Ada", "text": "missed you", "ts": 7}
	_fake_social.chat_history.append(missed.duplicate(true))

	var received: Array[Dictionary] = []
	var collector := func(message: Dictionary) -> void:
		received.append(message.duplicate(true))
	EventBus.social_chat_message.connect(collector)
	OnlineService.force_offline(false)
	EventBus.backend_state_changed.emit(true)
	# The handler chain suspends once per awaited backend call (subscribe, then
	# fetch), so the catch-up emit lands a couple of frames out.
	for i in 3:
		await get_tree().process_frame
	EventBus.social_chat_message.disconnect(collector)
	assert_true(_fake_social.subscribed, "re-online resubscribes")
	assert_eq(received.size(), 1, "offline gap caught up with exactly one emission")
	if received.size() == 1:
		assert_eq(str(received[0].get("id", "")), "7", "the missed message is the one emitted")
		assert_eq(str(received[0].get("text", "")), "missed you", "message payload intact")


# --- Presence (v4, TDD §3.25) ------------------------------------------------------

func test_get_presence_defaults_offline() -> void:
	var presence := SocialManager.get_presence("OWL-0001")
	assert_false(bool(presence.get("online", true)), "unknown code defaults to offline")
	assert_eq(int(presence.get("last_seen", -1)), 0, "unknown code has no last-seen stamp")


func test_manager_merges_presence_delta_and_emits_changed_only() -> void:
	watch_signals(EventBus)
	_fake_social.push_presence({
		"OWL-0001": {"online": true, "last_seen": 100},
		"OWL-0002": {"online": false, "last_seen": 200},
	})
	var ada := SocialManager.get_presence("OWL-0001")
	assert_true(bool(ada.get("online", false)), "join delta marks the friend online")
	assert_eq(int(ada.get("last_seen", 0)), 100, "delta last-seen stored")
	var grace := SocialManager.get_presence("OWL-0002")
	assert_false(bool(grace.get("online", true)), "leave delta marks the friend offline")
	assert_signal_emitted(EventBus, "social_presence_changed", "batched delta announced once")

	var emitted_before: int = get_signal_emit_count(EventBus, "social_presence_changed")
	_fake_social.push_presence({"OWL-0001": {"online": true, "last_seen": 100}})
	assert_eq(get_signal_emit_count(EventBus, "social_presence_changed"), emitted_before, "unchanged delta does not re-emit")


func test_manager_last_seen_only_moves_forward() -> void:
	_fake_social.push_presence({"OWL-0001": {"online": false, "last_seen": 500}})
	_fake_social.push_presence({"OWL-0001": {"online": false, "last_seen": 100}})
	var presence := SocialManager.get_presence("OWL-0001")
	assert_eq(int(presence.get("last_seen", 0)), 500, "stale last-seen cannot move the stamp backward")


func test_manager_partial_delta_preserves_stored_last_seen() -> void:
	_fake_social.push_presence({"OWL-0001": {"online": true, "last_seen": 100}})
	_fake_social.push_presence({"OWL-0001": {"online": false}})
	var presence := SocialManager.get_presence("OWL-0001")
	assert_false(bool(presence.get("online", true)), "leave without last-seen still applies")
	assert_eq(int(presence.get("last_seen", 0)), 100, "missing last-seen key keeps the stored stamp")


func test_manager_fetch_friends_in_mock_mode_does_not_subscribe_presence() -> void:
	_fake_social.friends = [{"player_code": "owl-0001", "name": "Ada"}]
	await SocialManager.fetch_friends()
	assert_eq(_fake_social.presence_subscribed_codes.size(), 0, "mock mode never touches the presence subscription (hermetic)")


func test_mock_set_friend_presence_emits_upper_cased_delta() -> void:
	var mock := MockSocialBackend.new()
	var received: Array[Dictionary] = []
	var collector := func(delta: Dictionary) -> void:
		received.append(delta.duplicate(true))
	mock.presence_updated.connect(collector)
	mock.set_friend_presence("owl-9001", true, 123)
	assert_eq(received.size(), 1, "seam emits exactly one delta")
	if received.size() == 1:
		var entry: Variant = (received[0] as Dictionary).get("OWL-9001", null)
		assert_true(entry != null, "code upper-cased in the delta key")
		if entry != null:
			assert_true(bool((entry as Dictionary).get("online", false)), "online flag carried")
			assert_eq(int((entry as Dictionary).get("last_seen", 0)), 123, "last-seen carried")
	mock.presence_updated.disconnect(collector)


func test_mock_presence_subscribe_and_unsubscribe() -> void:
	var mock := MockSocialBackend.new()
	var result: Dictionary = mock.subscribe_presence(["OWL-1", "OWL-2"])
	assert_true(bool(result.get("ok", false)), "mock subscribe succeeds")
	assert_eq(mock._presence_followed, ["OWL-1", "OWL-2"], "followed codes tracked")
	mock.unsubscribe_presence()
	assert_eq(mock._presence_followed.size(), 0, "unsubscribe clears the follow set")


# --- SaveSystem sync hooks ---------------------------------------------------------------

func test_synced_upload_after_save_is_debounced() -> void:
	SaveSystem.set_value("profile", "coins", 777)
	SaveSystem.save_game()  # auto-schedules the debounced upload
	await get_tree().create_timer(SaveSystem._SYNC_DEBOUNCE_SEC + 0.3).timeout
	assert_eq(_fake_sync.uploads.size(), 1, "one upload after the debounce window")
	var payload: Dictionary = _fake_sync.uploads[0]
	assert_true(payload.has("profile"), "profile domain uploaded")
	assert_false(payload.has("settings"), "local-only settings not uploaded")
	assert_false(payload.has("meta"), "local-only meta not uploaded")
	assert_eq(int((payload["profile"] as Dictionary)["data"]["coins"]), 777, "uploaded the latest profile data")
	assert_gt(int((payload["profile"] as Dictionary)["updated_at"]), 0, "upload carries an updated_at stamp")


func test_sync_upload_debounces_multiple_saves() -> void:
	SaveSystem.set_value("profile", "coins", 1)
	SaveSystem.save_game()
	SaveSystem.set_value("profile", "coins", 2)
	SaveSystem.save_game()
	await get_tree().create_timer(SaveSystem._SYNC_DEBOUNCE_SEC + 0.3).timeout
	assert_eq(_fake_sync.uploads.size(), 1, "multiple saves collapse into one upload")
	var payload: Dictionary = _fake_sync.uploads[0]
	assert_eq(int((payload["profile"] as Dictionary)["data"]["coins"]), 2, "upload carries the latest state")


func test_request_sync_without_backend_is_a_noop() -> void:
	SaveSystem.set_sync_backend(null)
	SaveSystem.request_sync()
	await get_tree().create_timer(SaveSystem._SYNC_DEBOUNCE_SEC + 0.3).timeout
	assert_eq(_fake_sync.uploads.size(), 0, "no upload without a backend")


func test_fetch_merge_newer_remote_wins() -> void:
	SaveSystem.set_value("profile", "coins", 10)
	SaveSystem.save_game()
	var now := int(Time.get_unix_time_from_system())
	_fake_sync.fetch_result = {
		"domains": {"profile": {"data": {"name": "Player", "level": 1, "xp": 0, "coins": 999, "gems": 0, "best_score": 0, "total_games": 0, "last_daily_claim_day": ""}, "updated_at": now + 3600}},
		"fetched_at": now,
	}
	watch_signals(EventBus)
	await SaveSystem.fetch_synced_domains()
	assert_eq(int(SaveSystem.get_value("profile", "coins", 0)), 999, "newer remote domain adopted")
	assert_signal_emitted_with_parameters(EventBus, "save_sync_completed", [true])
	assert_signal_emitted(EventBus, "profile_updated", "merged profile re-announced")


func test_fetch_merge_older_remote_discarded() -> void:
	SaveSystem.set_value("profile", "coins", 10)
	SaveSystem.save_game()
	var now := int(Time.get_unix_time_from_system())
	_fake_sync.fetch_result = {"domains": {"profile": {"data": {"coins": 999}, "updated_at": now - 3600}}, "fetched_at": now}
	await SaveSystem.fetch_synced_domains()
	assert_eq(int(SaveSystem.get_value("profile", "coins", 0)), 10, "older remote domain discarded (LWW)")


func test_fetch_merge_malformed_reports_failure() -> void:
	_fake_sync.fetch_result = {"domains": "not-a-dict"}
	watch_signals(EventBus)
	await SaveSystem.fetch_synced_domains()
	assert_signal_emitted_with_parameters(EventBus, "save_sync_completed", [false])


func test_fetch_merge_no_remote_domains_is_success_noop() -> void:
	_fake_sync.fetch_result = {"domains": {}, "fetched_at": 1}
	watch_signals(EventBus)
	await SaveSystem.fetch_synced_domains()
	assert_signal_emitted_with_parameters(EventBus, "save_sync_completed", [true])


# --- MockSaveSyncBackend ------------------------------------------------------------------

func test_mock_save_sync_backend_is_noop_success() -> void:
	var mock := MockSaveSyncBackend.new()
	assert_true(mock.upload_synced_domains({"profile": {"data": {}, "updated_at": 1}}), "upload succeeds")
	assert_eq(mock.uploads.size(), 1, "uploads recorded for inspection")
	var fetched := mock.fetch_synced_domains()
	assert_eq(fetched.get("domains", {}), {}, "fetch returns empty domains (local-only)")


# --- Helpers -----------------------------------------------------------------------------

func _write_identity_file(key: String) -> void:
	var file := FileAccess.open(_temp_identity_path, FileAccess.WRITE)
	file.store_string(JSON.stringify({"key": key}))
	file.close()


func _is_hex(value: String) -> bool:
	for c in value:
		if not ("0" <= c and c <= "9") and not ("a" <= c and c <= "f"):
			return false
	return true


func _is_all_digits(value: String) -> bool:
	for c in value:
		if not ("0" <= c and c <= "9"):
			return false
	return true
